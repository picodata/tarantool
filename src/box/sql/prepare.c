/*
 * Copyright 2010-2017, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/*
 * This file contains the implementation of the sql_prepare()
 * interface, and routines that contribute to loading the database schema
 * from disk.
 */
#include "sqlInt.h"
#include "tarantoolInt.h"
#include "box/space.h"
#include "box/session.h"

/** A column of the result of EXPLAIN: its name and type. */
struct ExplainColumn {
	/** The name of the column. */
	const char *name;
	/** The type of the column. */
	const char *type;
};

typedef struct ExplainColumn ExplainColumn;

/**
 * Set the names and types of the columns of EXPLAIN. For EXPLAIN without
 * QUERY PLAN they depend on the facets.
 */
static void
sql_explain_set_columns(struct Vdbe *v, ExplainMode explain, uint8_t facets)
{
	static const ExplainColumn graph[] = {
		{"graph", "text"},
	};
	static const ExplainColumn opcode[] = {
		{"addr", "integer"}, {"opcode", "text"}, {"p1", "integer"},
		{"p2", "integer"}, {"p3", "integer"}, {"p4", "text"},
		{"p5", "text"},
	};
	static const ExplainColumn pseudocode[] = {
		{"addr", "integer"}, {"pseudocode", "text"},
	};
	static const ExplainColumn plan[] = {
		{"selectid", "integer"}, {"order", "integer"},
		{"from", "integer"}, {"detail", "text"},
	};
	static_assert(ArraySize(graph) + ArraySize(opcode) +
		      ArraySize(pseudocode) == EXPLAIN_MAX_COLUMNS,
		      "EXPLAIN_MAX_COLUMNS must be the number of columns");
	bool is_program = explain == EXPLAIN_MODE_PROGRAM;
	/* The groups of columns, in the order of the result. */
	const struct {
		const ExplainColumn *columns;
		int count;
		bool is_shown;
	} groups[] = {
		{plan, ArraySize(plan), explain == EXPLAIN_MODE_QUERY_PLAN},
		{graph, ArraySize(graph),
		 is_program && (facets & EXPLAIN_FACET_GRAPH) != 0},
		{opcode, ArraySize(opcode),
		 is_program && (facets & EXPLAIN_FACET_OPCODE) != 0},
		{pseudocode, ArraySize(pseudocode),
		 is_program && (facets & EXPLAIN_FACET_PSEUDOCODE) != 0},
	};
	int count = 0;
	for (int i = 0; i < ArraySize(groups); i++) {
		if (groups[i].is_shown)
			count += groups[i].count;
	}
	sqlVdbeSetNumCols(v, count);
	int column = 0;
	for (int i = 0; i < ArraySize(groups); i++) {
		if (!groups[i].is_shown)
			continue;
		for (int j = 0; j < groups[i].count; j++, column++) {
			vdbe_metadata_set_col_name(v, column,
						   groups[i].columns[j].name);
			vdbe_metadata_set_col_type(v, column,
						   groups[i].columns[j].type);
		}
	}
}

/** Fail the parse with an error about EXPLAIN (...). */
static void
sql_explain_error(struct Parse *parse, const char *message)
{
	diag_set(ClientError, ER_SQL_PARSER_GENERIC_WITH_POS, parse->line_count,
		 parse->line_pos, message);
	parse->is_aborted = true;
}

void
sql_explain_add_facet(struct Parse *parse, const struct Token *name,
		      bool has_lines)
{
	static const struct {
		const char *name;
		enum explain_facet facet;
	} facets[] = {
		{"graph", EXPLAIN_FACET_GRAPH},
		{"opcode", EXPLAIN_FACET_OPCODE},
		{"pseudocode", EXPLAIN_FACET_PSEUDOCODE},
	};
	if (parse->is_aborted)
		return;
	for (int i = 0; i < ArraySize(facets); i++) {
		if (name->n != strlen(facets[i].name) ||
		    strncasecmp(name->z, facets[i].name, name->n) != 0)
			continue;
		if (has_lines && facets[i].facet != EXPLAIN_FACET_GRAPH) {
			sql_explain_error(parse, tt_sprintf(
				"EXPLAIN facet '%s' takes no lines",
				facets[i].name));
			return;
		}
		/* The lines of a list that is not empty are added now. */
		if (has_lines && parse->explain_opts.graph_filter_count == 0)
			parse->explain_opts.graph_filter_count = -1;
		parse->explain_opts.facets |= facets[i].facet;
		return;
	}
	sql_explain_error(parse, tt_sprintf("Unknown EXPLAIN facet '%.*s'",
					    (int)name->n, name->z));
}

void
sql_explain_add_line(struct Parse *parse, const struct Token *number)
{
	int line;
	if (parse->is_aborted)
		return;
	if (sqlGetInt32(number->z, &line) == 0) {
		sql_explain_error(parse, tt_sprintf(
			"EXPLAIN line %.*s is too big", (int)number->n,
			number->z));
		return;
	}
	ExplainOpts *opts = &parse->explain_opts;
	/* A list that is not empty comes after an empty one. */
	if (opts->graph_filter_count < 0)
		opts->graph_filter_count = 0;
	int i;
	opts->graph_filter = sqlArrayAllocate(opts->graph_filter, sizeof(int),
					      &opts->graph_filter_count, &i);
	opts->graph_filter[i] = line;
}

void
sql_explain_check_facets(struct Parse *parse)
{
	if (parse->is_aborted)
		return;
	uint8_t columns = EXPLAIN_FACET_OPCODE | EXPLAIN_FACET_PSEUDOCODE;
	/* The graph alone says nothing: show the pseudocode next to it. */
	ExplainOpts *opts = &parse->explain_opts;
	if ((columns & opts->facets) == 0)
		opts->facets |= EXPLAIN_FACET_PSEUDOCODE;
}

/**
 * Compile an SQL statement with an optional RAW EXPLAIN hook provider.
 */
static int
sql_stmt_compile_impl(const char *zSql, int nBytes, struct Vdbe *pReprepare,
		      sql_stmt **ppStmt, const char **pzTail,
		      const struct sql_raw_explain_provider *provider)
{
	int rc = 0;	/* Result code */
	Parse sParse;		/* Parsing context */
	sql_parser_create(&sParse, current_session()->sql_flags);
	sParse.pReprepare = pReprepare;
	sParse.raw_explain_provider = provider;
	*ppStmt = NULL;

	/* Check to verify that it is possible to get a read lock on all
	 * database schemas.  The inability to get a read lock indicates that
	 * some other database connection is holding a write-lock, which in
	 * turn means that the other connection has made uncommitted changes
	 * to the schema.
	 *
	 * Were we to proceed and prepare the statement against the uncommitted
	 * schema changes and if those schema changes are subsequently rolled
	 * back and different changes are made in their place, then when this
	 * prepared statement goes to run the schema cookie would fail to detect
	 * the schema change.  Disaster would follow.
	 *
	 * Note that setting READ_UNCOMMITTED overrides most lock detection,
	 * but it does *not* override schema lock detection, so this all still
	 * works even if READ_UNCOMMITTED is set.
	 */
	if (nBytes >= 0 && (nBytes == 0 || zSql[nBytes - 1] != 0)) {
		char *zSqlCopy;
		int mxLen = SQL_MAX_SQL_LENGTH;
		if (nBytes > mxLen) {
			diag_set(ClientError, ER_SQL_PARSER_LIMIT,
				 "SQL command length", nBytes, mxLen);
			rc = -1;
			goto end_prepare;
		}
		zSqlCopy = sql_xstrndup(zSql, nBytes);
		if (zSqlCopy) {
			sqlRunParser(&sParse, zSqlCopy);
			sParse.zTail = &zSql[sParse.zTail - zSqlCopy];
			sql_xfree(zSqlCopy);
		} else {
			sParse.zTail = &zSql[nBytes];
		}
	} else {
		sqlRunParser(&sParse, zSql);
	}
	assert(0 == sParse.nQueryLoop || sParse.is_aborted);

	if (pzTail) {
		*pzTail = sParse.zTail;
	}
	if (sParse.is_aborted)
		rc = -1;

	if (rc == 0 && sParse.pVdbe != NULL &&
	    sParse.explain != EXPLAIN_MODE_OFF) {
		sql_explain_set_columns(sParse.pVdbe, sParse.explain,
					sParse.explain_opts.facets);
	}

	if (sql_get()->init.busy == 0) {
		Vdbe *pVdbe = sParse.pVdbe;
		sqlVdbeSetSql(pVdbe, zSql, (int)(sParse.zTail - zSql));
	}
	if (sParse.pVdbe != NULL && rc != 0) {
		sqlVdbeFinalize(sParse.pVdbe);
		assert(!(*ppStmt));
	} else {
		*ppStmt = (sql_stmt *) sParse.pVdbe;
	}

	/* Delete any TriggerPrg structures allocated while parsing this statement. */
	while (sParse.pTriggerPrg) {
		TriggerPrg *pT = sParse.pTriggerPrg;
		sParse.pTriggerPrg = pT->pNext;
		sql_xfree(pT);
	}

 end_prepare:

	sql_parser_destroy(&sParse);
	return rc;
}

int
sql_stmt_compile(const char *zSql, int nBytes, struct Vdbe *pReprepare,
		 sql_stmt **ppStmt, const char **pzTail)
{
	return sql_stmt_compile_impl(zSql, nBytes, pReprepare, ppStmt, pzTail,
				     NULL);
}

int
sql_stmt_compile_wrapper(const char *sql, int bytes_count, sql_stmt **stmt)
{
	return sql_stmt_compile(sql, bytes_count, NULL, stmt, NULL);
}

int
sql_stmt_compile_raw_explain(
	const char *sql, int bytes_count,
	const struct sql_raw_explain_provider *provider, sql_stmt **stmt)
{
	return sql_stmt_compile_impl(sql, bytes_count, NULL, stmt, NULL,
				     provider);
}

/*
 * Rerun the compilation of a statement after a schema change.
 */
int
sqlReprepare(Vdbe * p)
{
	sql_stmt *pNew;
	const char *zSql;

	zSql = sql_sql((sql_stmt *) p);
	assert(zSql != 0);
	if (sql_stmt_compile(zSql, -1, p, &pNew, 0) != 0) {
		assert(pNew == 0);
		return -1;
	}
	assert(pNew != 0);
	sqlVdbeSwap((Vdbe *) pNew, p);
	sqlTransferBindings(pNew, (sql_stmt *) p);
	sqlVdbeResetStepResult((Vdbe *) pNew);
	sqlVdbeFinalize((Vdbe *) pNew);
	return 0;
}

void
sql_parser_create(struct Parse *parser, uint32_t sql_flags)
{
	memset(parser, 0, sizeof(struct Parse));
	parser->sql_flags = sql_flags;
	parser->line_count = 1;
	parser->line_pos = 1;
	parser->has_autoinc = false;
	region_create(&parser->region, &cord()->slabc);
}

void
sql_parser_destroy(Parse *parser)
{
	assert(parser != NULL);
	assert(!parser->parse_only || parser->pVdbe == NULL);
	sql_xfree(parser->aLabel);
	sql_xfree(parser->explain_opts.graph_filter);
	sql_expr_list_delete(parser->pConstExpr);
	struct create_fk_constraint_parse_def *create_fk_constraint_parse_def =
		&parser->create_fk_constraint_parse_def;
	create_fk_constraint_parse_def_destroy(create_fk_constraint_parse_def);
	assert(sql_get()->lookaside.bDisable >= parser->disableLookaside);
	sql_get()->lookaside.bDisable -= parser->disableLookaside;
	parser->disableLookaside = 0;
	switch (parser->parsed_ast_type) {
	case AST_TYPE_SELECT:
		sql_select_delete(parser->parsed_ast.select);
		break;
	case AST_TYPE_EXPR:
		sql_expr_delete(parser->parsed_ast.expr);
		break;
	case AST_TYPE_TRIGGER:
		sql_trigger_delete(parser->parsed_ast.trigger);
		break;
	default:
		assert(parser->parsed_ast_type == AST_TYPE_UNDEFINED);
	}
	region_destroy(&parser->region);
}
