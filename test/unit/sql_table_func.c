#include "memory.h"
#include "coll/coll.h"
#include "fiber.h"
#include "box/session.h"
#include "box/box.h"
#include "box/execute.h"
#include "box/sql.h"
#include "box/sql/sqlInt.h"
#include "box/sql/table_func.h"
#include "box/sql/vdbeInt.h"
#include "box/sql/mem.h"
#include "msgpuck.h"

#define UNIT_TAP_COMPATIBLE 1
#include "unit.h"

static int live_contexts;
static bool fail_open;
static bool fail_next;

static int
resolve_schema(struct ExprList *args, struct field_def *fields)
{
	(void)args;
	fields[0].type = FIELD_TYPE_INTEGER;
	return 0;
}

static uint64_t
estimate_zero(struct ExprList *args)
{
	(void)args;
	return 0;
}

static uint64_t
estimate_one(struct ExprList *args)
{
	(void)args;
	return 1;
}

static int
open_iterator(const char *args, const char *args_end, void **ctx)
{
	(void)args;
	(void)args_end;
	int *state = xmalloc(sizeof(*state));
	if (fail_open) {
		free(state);
		diag_set(IllegalParams, "test open error");
		return -1;
	}
	*state = 3;
	*ctx = state;
	live_contexts++;
	return 0;
}

static int
next_row(void *ctx, const char **row, const char **end)
{
	int *left = ctx;
	if (fail_next) {
		diag_set(IllegalParams, "test next error");
		return -1;
	}
	static const char result[] = "\x91\x01";
	*row = (*left)-- > 0 ? result : NULL;
	*end = *row == NULL ? NULL : result + 2;
	return 0;
}

static void
close_iterator(void *ctx)
{
	free(ctx);
	live_contexts--;
}

static struct sql_table_func_ops ops = {
	.resolve_schema = resolve_schema,
	.estimate_rows = estimate_zero,
	.open = open_iterator,
	.next = next_row,
	.close = close_iterator,
};

static const struct field_def fields[] = {
	{.name = "VALUE", .type = FIELD_TYPE_INTEGER},
};

static struct sql_table_func_def defs[] = {
	{.name = "TEST_ZERO", .param_count = 0, .fields = fields,
	 .field_count = 1, .ops = &ops},
};

static void
execute(const char *query, int expected_rows, bool expect_error)
{
	sql_stmt *stmt = NULL;
	int rc = sql_stmt_compile_wrapper(query, strlen(query), &stmt);
	fail_unless(rc == 0);
	int rows = 0;
	while ((rc = sql_step(stmt)) == SQL_ROW)
		rows++;
	is(rows, expected_rows, "%s: row count", query);
	is(rc, expect_error ? -1 : SQL_DONE, "%s: completion", query);
	sql_stmt_finalize(stmt);
	is(live_contexts, 0, "%s: contexts released", query);
}

int
main(void)
{
	memory_init();
	fiber_init(fiber_c_invoke);
	coll_init();
	plan(34);
	struct sql_table_func_ops saved = ops;
#define CHECK_REQUIRED(method) do { \
	ops = saved; \
	ops.method = NULL; \
	is(sql_table_func_register(defs, 1), -1, #method " is mandatory"); \
} while (0)
	CHECK_REQUIRED(resolve_schema);
	CHECK_REQUIRED(estimate_rows);
	CHECK_REQUIRED(open);
	CHECK_REQUIRED(next);
	CHECK_REQUIRED(close);
#undef CHECK_REQUIRED
	ops = saved;
	is(sql_table_func_register(defs, 1), 0, "register during startup");
	box_init();
	sql_init();
	is(sql_table_func_register(defs, 1), -1,
	   "registry sealed after startup");
	execute("SELECT * FROM TEST_ZERO()", 3, false);
	/* Fault injection is local to this unit executable. */
	ops.estimate_rows = estimate_one;
	execute("SELECT * FROM TEST_ZERO()", 3, false);
	execute("SELECT * FROM TEST_ZERO() LIMIT 1", 1, false);
	execute("SELECT t.VALUE FROM TEST_ZERO() g CROSS JOIN "
		"TEST_ZERO() t", 9, false);
	fail_next = true;
	execute("SELECT * FROM TEST_ZERO()", 0, true);
	fail_next = false;
	fail_open = true;
	execute("SELECT * FROM TEST_ZERO()", 0, true);
	fail_open = false;
	execute("SELECT * FROM TEST_ZERO()", 3, false);
	/* Reach the uint64 boundary without iterating 2^64 rows. */
	sql_stmt *stmt;
	const char *query = "SELECT * FROM TEST_ZERO() WITH ORDINALITY";
	fail_unless(sql_stmt_compile_wrapper(query, strlen(query), &stmt) == 0);
	is(sql_step(stmt), SQL_ROW, "ordinality starts normally");
	struct Vdbe *vdbe = (struct Vdbe *)stmt;
	for (int i = 0; i < vdbe->nCursor; i++) {
		struct VdbeCursor *cursor = vdbe->apCsr[i];
		if (cursor != NULL && cursor->eCurType == CURTYPE_TABLEFUNC)
			cursor->uc.pTFunc->ordinality = UINT64_MAX;
	}
	is(sql_step(stmt), SQL_ROW, "maximum ordinality is valid");
	is(vdbe->pResultSet[1].u.u, UINT64_MAX, "maximum is preserved");
	is(sql_step(stmt), -1, "ordinality does not wrap to zero");
	sql_stmt_finalize(stmt);
	is(live_contexts, 0, "ordinality error releases the iterator");
	is(live_contexts, 0, "all iterator contexts released");
	return check_plan();
}
