#include "sql/sqlInt.h"
#include "sql/mem.h"
#include "sql/vdbeInt.h"
#include "sql/whereInt.h"
#include "box/sql/parse.h"
#include "fiber.h"
#include "memory.h"
#include "index.h"
#include "tuple.h"
#include "msgpuck.h"

#define UNIT_TAP_COMPATIBLE 1
#include "unit.h"

/* Run the real cost adjustment and dominance test in both orders. */
static void
check_cost(WhereLoop *ordinary, WhereLoop *skip, unsigned cost)
{
	for (int reverse = 0; reverse < 2; ++reverse) {
		ordinary->rRun = sqlLogEst(100);
		skip->rRun = sqlLogEst(cost);
		ordinary->nOut = sqlLogEst(10);
		skip->nOut = sqlLogEst(10);
		WhereLoop *first = reverse ? skip : ordinary;
		WhereLoop *second = reverse ? ordinary : skip;
		whereLoopAdjustCost(first, second);
		is(ordinary->rRun, sqlLogEst(100),
		   "ordinary cost is preserved");
		is(skip->rRun, sqlLogEst(cost),
		   "external IN cost is preserved");
		is(ordinary->nOut, sqlLogEst(10),
		   "ordinary output is preserved");
		is(skip->nOut, sqlLogEst(10), "no output-estimate backdoor");
		WhereLoop *head = first;
		WhereLoop **replace = whereLoopFindLesser(&head, second, true);
		WhereLoop *chosen = replace != NULL ? second : first;
		is(chosen, cost < 100 ? skip : ordinary,
		   "the cheaper search wins in either insertion order");
	}
}

static void
cost_test(void)
{
	header();
	plan(78);
	struct key_part_def parts[5];
	for (int i = 0; i < 5; ++i) {
		parts[i] = key_part_def_default;
		parts[i].fieldno = i;
		parts[i].type = FIELD_TYPE_SCALAR;
	}
	struct key_def *key = key_def_new(parts, 5, false);
	struct index_def index = {.key_def = key};
	Expr column = {.op = TK_COLUMN};
	ExprList vector_list = {.nExpr = 2};
	Expr vector = {.op = TK_VECTOR, .x.pList = &vector_list};
	Expr scalar_in = {.op = TK_IN, .flags = EP_xIsSelect,
			  .pLeft = &column};
	Expr vector_in = {.op = TK_IN, .flags = EP_xIsSelect,
			  .pLeft = &vector};
	WhereTerm eq = {.eOperator = WO_EQ};
	WhereTerm in = {.eOperator = WO_IN, .pExpr = &scalar_in};
	WhereTerm pair0 = {.eOperator = WO_IN, .pExpr = &vector_in};
	WhereTerm pair1 = {.eOperator = WO_IN, .pExpr = &vector_in};
	WhereTerm *short_terms[] = {&eq};
	WhereTerm *long_terms[] = {&eq, NULL, &pair0, &pair1};
	WhereLoop ordinary = {.nEq = 1, .nLTerm = 1,
		.wsFlags = WHERE_INDEXED | WHERE_COLUMN_EQ,
		.aLTerm = short_terms};
	WhereLoop skip = {.nEq = 4, .nLTerm = 4, .nSkip = 1, .nSkipStart = 1,
		.wsFlags = WHERE_INDEXED | WHERE_COLUMN_EQ | WHERE_SKIPSCAN,
		.aLTerm = long_terms, .index_def = &index};
	is(whereLoopInnerInStart(&skip), -1, "vector IN is external");
	check_cost(&ordinary, &skip, 200);
	check_cost(&ordinary, &skip, 50);

	/*
	 * Projecting (a,c) to a can remove repeated a values, so the shared
	 * prefix component alone must not erase the full vector's cost.
	 */
	short_terms[0] = &pair0;
	long_terms[0] = &pair0;
	long_terms[2] = &pair1;
	skip.nEq = 3;
	skip.nLTerm = 3;
	check_cost(&ordinary, &skip, 200);

	/* A shared scalar prefix IN is already charged in both candidates. */
	short_terms[0] = &in;
	long_terms[0] = &in;
	long_terms[2] = &eq;
	ordinary.rRun = sqlLogEst(100);
	skip.rRun = sqlLogEst(200);
	whereLoopAdjustCost(&ordinary, &skip);
	is(skip.rRun, ordinary.rRun, "shared prefix IN is not charged twice");
	is(skip.nOut, ordinary.nOut - 1, "subset correction is retained");

	/* Scalar invariant suffix IN is inside groups and adds no passes. */
	short_terms[0] = &eq;
	long_terms[0] = &eq;
	long_terms[2] = &in;
	is(whereLoopInnerInStart(&skip), 2, "invariant suffix IN is internal");
	skip.rRun = sqlLogEst(200);
	whereLoopAdjustCost(&ordinary, &skip);
	is(skip.rRun, ordinary.rRun, "internal IN does not block correction");
	/* A different set comparator makes the same scalar IN external. */
	in.in_coll_id = 1;
	is(whereLoopInnerInStart(&skip), -1, "different IN order is external");
	check_cost(&ordinary, &skip, 200);
	check_cost(&ordinary, &skip, 50);
	in.in_coll_id = 0;

	/* (a,b,c,d,e): adding vector (d,e) also moves scalar c outside. */
	WhereTerm *mixed_terms[] = {&eq, NULL, &in, &pair0, &pair1};
	WhereLoop mixed = skip;
	mixed.aLTerm = mixed_terms;
	mixed.nEq = 5;
	mixed.nLTerm = 5;
	is(whereLoopInnerInStart(&mixed), -1,
	   "mixed suffix INs are all external");
	check_cost(&skip, &mixed, 200);
	check_cost(&skip, &mixed, 50);
	/* Correlation has the same effect on all suffix lists. */
	scalar_in.flags |= EP_VarSelect;
	is(whereLoopInnerInStart(&skip), -1, "rebuilt suffix IN is external");
	key_def_delete(key);
	footer();
	check_plan();
}

/*
 * Only the engine iterator is replaced. Comparisons, key checks, cursor
 * movement and adaptive state all use production code and real tuples.
 */
struct counting_iterator {
	struct iterator base;
	unsigned calls;
	int value;
	int direction;
};

static struct tuple *
integer_tuple(int value)
{
	char data[16];
	char *end = mp_encode_array(data, 1);
	end = mp_encode_uint(end, value);
	struct tuple *tuple = tuple_new_checked(tuple_format_runtime, data,
						end);
	fail_if(tuple == NULL);
	return tuple;
}

static int
counting_next(struct iterator *base, struct tuple **result)
{
	struct counting_iterator *it = (struct counting_iterator *)base;
	++it->calls;
	it->value += it->direction;
	*result = integer_tuple(it->value);
	return 0;
}

static void
position(struct VdbeCursor *cur, int value)
{
	struct BtCursor *bt = cur->uc.pCursor;
	struct counting_iterator *it = (struct counting_iterator *)bt->iter;
	if (bt->last_tuple != NULL)
		tuple_unref(bt->last_tuple);
	bt->last_tuple = integer_tuple(value);
	tuple_ref(bt->last_tuple);
	bt->eState = CURSOR_VALID;
	it->value = value;
	it->calls = 0;
}

static bool
probe(struct VdbeCursor *cur, unsigned site, int value)
{
	struct Mem bound = {.type = MEM_TYPE_UINT, .u.u = value};
	bool done;
	int res = 0;
	uint8_t flags = OPFLAG_SEEK_FORWARD;
	if (site == 1)
		flags |= OPFLAG_SEEK_SITE;
	int rc = vdbe_seek_probe(cur, &bound, 1, flags, &done, &res);
	fail_if(rc != 0 || res != 0);
	return done;
}

static void
probe_test(void)
{
	header();
	plan(63);
	struct key_part_def part = key_part_def_default;
	part.fieldno = 0;
	part.type = FIELD_TYPE_UNSIGNED;
	struct key_def *key = key_def_new(&part, 1, false);
	struct index_def def = {.type = TREE, .key_def = key};
	struct index index = {.def = &def};
	struct counting_iterator it = {.base = {.index = &index,
		.next = counting_next}, .direction = 1};
	struct BtCursor bt = {.curFlags = BTCF_TEphemCursor,
		.index = &index, .iter = &it.base, .iter_type = ITER_GE};
	struct VdbeCursor cur = {.uc.pCursor = &bt, .key_def = key,
		.seek_probe_first = true};
	position(&cur, 1);
	ok(!probe(&cur, 1, 5), "first suffix seek needs an iterator");
	is(it.calls, 0, "first suffix seek takes zero steps");
	is(cur.seek_backoff[1], 0, "first suffix seek does not back off");
	ok(probe(&cur, 1, 5), "next suffix seek can advance");
	is(it.calls, 4, "four steps to the first matching row");

	for (unsigned pause = 1; pause <= 63; pause = 2 * pause + 1) {
		position(&cur, 1);
		ok(!probe(&cur, 1, 100), "distant goal falls back to a seek");
		is(it.calls, 8, "at most eight unsuccessful steps");
		is(cur.seek_backoff[1], pause, "exponential pause length");
		is(cur.seek_skip[1], pause, "pause is installed");
		position(&cur, 100);
		ok(probe(&cur, 1, 100), "current row is checked during pause");
		is(it.calls, 0, "current row needs no step");
		is(cur.seek_backoff[1], pause,
		   "zero-step hit retains pause length");
		is(cur.seek_skip[1], pause - 1,
		   "zero-step hit only consumes a call");
		position(&cur, 1);
		for (unsigned i = 1; i < pause; ++i)
			fail_if(probe(&cur, 1, 100));
	}
	is(cur.seek_backoff[0], 0, "other seek site remains independent");
	position(&cur, 1);
	ok(!probe(&cur, 1, 100), "another miss at maximum backoff");
	is(cur.seek_skip[1], 63, "pause is capped at 63 calls");
	position(&cur, 1);
	ok(probe(&cur, 0, 3), "group seek can step during suffix pause");
	is(it.calls, 2, "independent group seek takes two steps");
	/* Consume the pause and succeed with positive movement. */
	for (unsigned i = 0; i < 63; ++i)
		fail_if(probe(&cur, 1, 100));
	ok(probe(&cur, 1, 5), "positive movement reaches a nearby suffix");
	is(cur.seek_backoff[1], 0, "positive hit resets pause length");
	is(cur.seek_skip[1], 0, "positive hit resets remaining pause");
	/* The same primitive handles reverse scans. */
	it.direction = -1;
	bt.iter_type = ITER_LE;
	position(&cur, 10);
	ok(probe(&cur, 1, 7), "reverse seek reaches its first matching row");
	is(it.calls, 3, "reverse seek takes three steps");
	tuple_unref(bt.last_tuple);
	key_def_delete(key);
	footer();
	check_plan();
}

static uint32_t
test_field_name_hash(const char *str, uint32_t len)
{
	return len > 0 ? str[0] + len : 0;
}

int
main(void)
{
	memory_init();
	fiber_init(fiber_c_invoke);
	tuple_init(test_field_name_hash);
	plan(2);
	cost_test();
	probe_test();
	int rc = check_plan();
	tuple_free();
	fiber_free();
	memory_free();
	return rc;
}
