#include "sql/sqlInt.h"
#include "sql/whereInt.h"
#include "box/sql/parse.h"
#include "fiber.h"
#include "memory.h"
#include "tuple.h"

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
	plan(1);
	cost_test();
	int rc = check_plan();
	tuple_free();
	fiber_free();
	memory_free();
	return rc;
}
