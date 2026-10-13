/*
** 2001 September 15
**
** The author disclaims copyright to this source code.  In place of
** a legal notice, here is a blessing:
**
**    May you do good and not evil.
**    May you find forgiveness for yourself and forgive others.
**    May you share freely, never taking more than you give.
**
*************************************************************************
** This file contains sql's grammar for SQL.  Process this file
** using the lemon parser generator to generate C code that runs
** the parser.  Lemon will also generate a header file containing
** numeric codes for all of the tokens.
*/

// All token codes are small integers with #defines that begin with "TK_"
%token_prefix TK_

// The type of the data attached to each token is Token.  This is also the
// default type for non-terminals.
//
%token_type {Token}
%default_type {Token}

// The generated parser function takes a 4th argument as follows:
%extra_argument {Parse *pParse}

// This code runs whenever there is a syntax error
//
%syntax_error {
  UNUSED_PARAMETER(yymajor);  /* Silence some compiler warnings */
  if (yypParser->is_fallback_failed && TOKEN.isReserved) {
    diag_set(ClientError, ER_SQL_KEYWORD_IS_RESERVED, pParse->line_count,
             pParse->line_pos, TOKEN.n, TOKEN.z, TOKEN.n, TOKEN.z);
  } else {
    diag_set(ClientError, ER_SQL_SYNTAX_NEAR_TOKEN, pParse->line_count, TOKEN.n,
             TOKEN.z);
  }
  pParse->is_aborted = true;
}
%stack_overflow {
  diag_set(ClientError, ER_SQL_STACK_OVERFLOW);
  pParse->is_aborted = true;
}

// The name of the generated procedure that implements the parser
// is as follows:
%name sqlParser

// The following text is included near the beginning of the C source
// code file that implements the parser.
//
%include {
#include "sqlInt.h"

/*
** Disable all error recovery processing in the parser push-down
** automaton.
*/
#define YYNOERRORRECOVERY 1

/*
** Indicate that sqlParserFree() will never be called with a null
** pointer.
*/
#define YYPARSEFREENEVERNULL 1

/*
 * Stop the parser if an error occurs. This macro adds an
 * additional check that allows the parser to be stopped if any
 * error was noticed.
 */
#define PARSER_ERROR_CHECK && ! pParse->is_aborted

/*
** An instance of this structure holds information about the
** LIMIT clause of a SELECT statement.
*/
struct LimitVal {
  Expr *pLimit;    /* The LIMIT expression.  NULL if there is no limit */
  Expr *pOffset;   /* The OFFSET expression.  NULL if there is none */
};

/*
** An instance of the following structure describes the event of a
** TRIGGER.  "a" is the event type, one of TK_UPDATE, TK_INSERT,
** TK_DELETE, or TK_INSTEAD.  If the event is of the form
**
**      UPDATE ON (a,b,c)
**
** Then the "b" IdList records the list "a,b,c".
*/
struct TrigEvent { int a; IdList * b; };

struct FrameBound { int eType; Expr *pExpr; };

/*
** Disable lookaside memory allocation for objects that might be
** shared across database connections.
*/
static void disableLookaside(Parse *pParse){
  pParse->disableLookaside++;
  sql_get()->lookaside.bDisable++;
}

} // end %include

// Input is a single SQL command
input ::= ecmd.
ecmd ::= explain cmdx SEMI. {
	if (!pParse->parse_only)
		sql_finish_coding(pParse);
}
ecmd ::= SEMI. {
  diag_set(ClientError, ER_SQL_STATEMENT_EMPTY);
  pParse->is_aborted = true;
}
explain ::= .
explain ::= EXPLAIN. {
  pParse->explain = EXPLAIN_MODE_PROGRAM;
  sql_explain_check_facets(pParse);
}
explain ::= EXPLAIN QUERY PLAN. {
  pParse->explain = EXPLAIN_MODE_QUERY_PLAN;
}
cmdx ::= cmd.

// Define operator precedence early so that this is the first occurrence
// of the operator tokens in the grammer.  Keeping the operators together
// causes them to be assigned integer values that are close together,
// which keeps parser tables smaller.
//
// The token values assigned to these symbols is determined by the order in
// which lemon first sees them.  It must be the case that NE/EQ, GT/LE, and
// GE/LT are separated by only a single value.  See the sqlExprIfFalse()
// routine for additional information on this constraint.
//
%left OR.
%left AND.
%right NOT.
%left IS MATCH LIKE_KW BETWEEN IN NE EQ.
%left GT LE LT GE.
%right ESCAPE.
%left BITAND BITOR LSHIFT RSHIFT.
%left PLUS MINUS.
%left STAR SLASH REM.
%left CONCAT.
%left COLLATE.
%right BITNOT.
%right LB.
%left DCOLON.


///////////////////// Begin and end transactions. ////////////////////////////
//

// EXPLAIN ANALYZE does not take the statements of two kinds: ctl_cmd, which
// controls the transaction or the session, and ddl_cmd, which changes the
// schema. A new statement of such a kind must be a rule of that kind.
cmd ::= ctl_cmd. {
  sql_explain_analyze_forbid(pParse, "a statement that controls the "
                             "transaction or the session");
}
cmd ::= ddl_cmd. {
  sql_explain_analyze_forbid(pParse, "a statement that changes the schema");
}
ctl_cmd ::= START TRANSACTION.  {sql_transaction_begin(pParse);}
ctl_cmd ::= COMMIT.      {sql_transaction_commit(pParse);}
ctl_cmd ::= ROLLBACK.    {sql_transaction_rollback(pParse);}

savepoint_opt ::= SAVEPOINT.
savepoint_opt ::= .
ctl_cmd ::= SAVEPOINT nm(X). {
  sqlSavepoint(pParse, SAVEPOINT_BEGIN, &X);
}
ctl_cmd ::= RELEASE savepoint_opt nm(X). {
  sqlSavepoint(pParse, SAVEPOINT_RELEASE, &X);
}
ctl_cmd ::= ROLLBACK TO savepoint_opt nm(X). {
  sqlSavepoint(pParse, SAVEPOINT_ROLLBACK, &X);
}

///////////////////// The CREATE TABLE statement ////////////////////////////
//
ddl_cmd ::= create_table create_table_args with_opts create_table_end.
create_table ::= createkw TABLE ifnotexists(E) nm(Y). {
  create_table_def_init(&pParse->create_table_def, &Y, E);
  create_ck_constraint_parse_def_init(&pParse->create_ck_constraint_parse_def);
  create_fk_constraint_parse_def_init(&pParse->create_fk_constraint_parse_def);
  pParse->create_table_def.new_space = sqlStartTable(pParse, &Y);
  pParse->initiateTTrans = true;
}
createkw(A) ::= CREATE(A).  {disableLookaside(pParse);}

%type ifnotexists {int}
ifnotexists(A) ::= .              {A = 0;}
ifnotexists(A) ::= IF NOT EXISTS. {A = 1;}

create_table_args ::= LP columnlist RP.

with_opts ::= WITH engine_opts.
with_opts ::= .

engine_opts ::= ENGINE EQ STRING(A). {
  /* Note that specifying engine clause overwrites default engine. */
  if (A.n > ENGINE_NAME_MAX) {
    diag_set(ClientError, ER_CREATE_SPACE,
             pParse->create_table_def.new_space->def->name,
             "space engine name is too long");
    pParse->is_aborted = true;
    return;
  }
  /* Need to dequote name. */
  char *normalized_name = sql_name_from_token(&A);
  memcpy(pParse->create_table_def.new_space->def->engine_name, normalized_name,
         strlen(normalized_name) + 1);
  sql_xfree(normalized_name);
}

create_table_end ::= . { sqlEndTable(pParse); }

/*
 * CREATE TABLE AS SELECT is broken. To be re-implemented
 * in gh-3223.
 *
 * create_table_args ::= AS select(S). {
 *   sqlEndTable(pParse);
 *   sql_select_delete(S);
 * }
 */

columnlist ::= columnlist COMMA tcons.
columnlist ::= columnlist COMMA column_def create_column_end.
columnlist ::= column_def create_column_end.

column_def ::= column_name_and_type carglist.

column_name_and_type ::= nm(A) typedef(Y). {
  create_column_def_init(&pParse->create_column_def, NULL, &A, &Y);
  sql_create_column_start(pParse);
}

create_column_end ::= autoinc(I). {
  uint32_t fieldno = pParse->create_column_def.space->def->field_count - 1;
  if (I == 1 && sql_add_autoincrement(pParse, fieldno) != 0)
    return;
  if (pParse->create_table_def.new_space == NULL)
    sql_create_column_end(pParse);
}
columnlist ::= tcons.

// An IDENTIFIER can be a generic identifier, or one of several
// keywords.  Any non-standard keyword can also be an identifier.
//
%token_class id  ID|INDEXED.

// The following directive causes tokens ABORT, AFTER, ASC, etc. to
// fallback to ID if they will not parse as their original value.
// This obviates the need for the "id" nonterminal.
//
// A keyword is checked for being a reserve one in `nm`, before
// processing of this %fallback directive. Reserved keywords included
// here to avoid the situation when a keyword has no usages within
// `parse.y` file (a keyword can have more or less usages depending on
// compiler defines). When a keyword has no usages it is excluded
// from autogenerated file `parse.h` that lead to compile-time error.
//
%fallback ID
  ABORT ACTION ADD AFTER AUTOINCREMENT BEFORE CASCADE
  CONFLICT DEFERRED END ENGINE FAIL
  IGNORE INITIALLY INSTEAD NO MATCH PLAN
  QUERY KEY OFFSET RAISE RELEASE REPLACE RESTRICT ROWS
  RENAME CTIME_KW IF ENABLE DISABLE UUID JSON
  .
%wildcard WILDCARD.


// And "ids" is an identifer-or-string.
//
%token_class ids  ID|STRING.

// The name of a column or table can be any of the following:
//
%type nm {Token}
nm(A) ::= id(A). {
  if(A.isReserved) {
    diag_set(ClientError, ER_SQL_KEYWORD_IS_RESERVED, pParse->line_count,
             pParse->line_pos, A.n, A.z, A.n, A.z);
    pParse->is_aborted = true;
  }
}

/**
 * "carglist" is a list of additional constraints and clauses that
 * come after the column name and column type in a <CREATE TABLE>
 * or <ALTER TABLE ADD COLUMN> statement.
 */
carglist ::= carglist ccons.
carglist ::= .
%type cconsname { struct Token }
cconsname(N) ::= CONSTRAINT nm(X). { N = X; }
cconsname(N) ::= . { N = Token_nil; }

// The scanpt non-terminal takes a value which is a pointer to the
// input text just past the last token that has been shifted into
// the parser.  By surrounding some phrase in the grammar with two
// scanpt non-terminals, we can capture the input text for that phrase.
// For example:
//
//      something ::= .... scanpt(A) phrase scanpt(Z).
//
// The text that is parsed as "phrase" is a string starting at A
// and containing (int)(Z-A) characters.  There might be some extra
// whitespace on either end of the text, but that can be removed in
// post-processing, if needed.
//
%type scanpt {const char*}
scanpt(A) ::= . {
  assert( yyLookahead!=YYNOCODE );
  A = yyLookaheadToken.z;
}
scantok(A) ::= . {
  assert( yyLookahead!=YYNOCODE );
  A = yyLookaheadToken;
}

ccons ::= DEFAULT scantok(A) term(X).
                            {sqlAddDefaultValue(pParse,X,A.z,&A.z[A.n]);}
ccons ::= DEFAULT LP(A) expr(X) RP(Z).
                            {sqlAddDefaultValue(pParse,X,A.z+1,Z.z);}
ccons ::= DEFAULT PLUS(A) scantok(Z) term(X).
                            {sqlAddDefaultValue(pParse,X,A.z,&Z.z[Z.n]);}
ccons ::= DEFAULT MINUS(A) scantok(Z) term(X). {
  Expr *p = sqlPExpr(pParse, TK_UMINUS, X, 0);
  sqlAddDefaultValue(pParse,p,A.z,&Z.z[Z.n]);
}

// In addition to the type name, we also care about the primary key and
// UNIQUE constraints.
//
ccons ::= NULL onconf(R).        {
    sql_column_add_nullable_action(pParse, ON_CONFLICT_ACTION_NONE);
    /* Trigger nullability mismatch error if required. */
    if (R != ON_CONFLICT_ACTION_ABORT)
        sql_column_add_nullable_action(pParse, R);
}
ccons ::= NOT NULL onconf(R).    {sql_column_add_nullable_action(pParse, R);}
ccons ::= cconsname(N) PRIMARY KEY sortorder(Z). {
  create_index_def_init(&pParse->create_index_def, NULL, &N, NULL,
                        SQL_INDEX_TYPE_CONSTRAINT_PK, Z, false);
  sqlAddPrimaryKey(pParse);
}
ccons ::= cconsname(N) UNIQUE. {
  create_index_def_init(&pParse->create_index_def, NULL, &N, NULL,
                        SQL_INDEX_TYPE_CONSTRAINT_UNIQUE, SORT_ORDER_ASC,
                        false);
  sql_create_index(pParse);
}

ccons ::= cconsname(N) CHECK LP scanpt(A) expr(X) RP(Z). {
  create_ck_def_init(&pParse->create_ck_def, NULL, &N, X, A, Z.z);
  sql_create_check_contraint(pParse, true);
}

ccons ::= cconsname(N) REFERENCES nm(T) eidlist_opt(TA). {
  create_fk_def_init(&pParse->create_fk_def, NULL, &N, NULL, &T, TA);
  sql_create_foreign_key(pParse);
}
ccons ::= COLLATE id(C).        {sqlAddCollateType(pParse, &C);}

// The optional AUTOINCREMENT keyword
%type autoinc {int}
autoinc(X) ::= .          {X = 0;}
autoinc(X) ::= AUTOINCR.  {X = 1;}

// The next group of rules parses the arguments to a REFERENCES clause.
tcons ::= cconsname(N) PRIMARY KEY LP col_list_with_autoinc(X) RP. {
  create_index_def_init(&pParse->create_index_def, NULL, &N, X,
                        SQL_INDEX_TYPE_CONSTRAINT_PK, SORT_ORDER_ASC, false);
  sqlAddPrimaryKey(pParse);
}
tcons ::= cconsname(N) UNIQUE LP sortlist(X) RP. {
  create_index_def_init(&pParse->create_index_def, NULL, &N, X,
                        SQL_INDEX_TYPE_CONSTRAINT_UNIQUE, SORT_ORDER_ASC,
                        false);
  sql_create_index(pParse);
}
tcons ::= cconsname(N) CHECK LP scanpt(A) expr(X) RP(Z). {
  create_ck_def_init(&pParse->create_ck_def, NULL, &N, X, A, Z.z);
  sql_create_check_contraint(pParse, false);
}
tcons ::= cconsname(N) FOREIGN KEY LP eidlist(FA) RP
          REFERENCES nm(T) eidlist_opt(TA). {
  create_fk_def_init(&pParse->create_fk_def, NULL, &N, FA, &T, TA);
  sql_create_foreign_key(pParse);
}

// The following is a non-standard extension that allows us to declare the
// default behavior when there is a constraint conflict.
//
%type onconf {int}
%type index_onconf {int}
%type orconf {int}
%type resolvetype {int}
onconf(A) ::= .                              {A = ON_CONFLICT_ACTION_ABORT;}
onconf(A) ::= ON CONFLICT resolvetype(X).    {A = X;}
orconf(A) ::= .                              {A = ON_CONFLICT_ACTION_DEFAULT;}
orconf(A) ::= OR resolvetype(X).             {A = X;}
resolvetype(A) ::= raisetype(A).
resolvetype(A) ::= IGNORE.                   {A = ON_CONFLICT_ACTION_IGNORE;}
resolvetype(A) ::= REPLACE.                  {A = ON_CONFLICT_ACTION_REPLACE;}

////////////////////////// The DROP TABLE /////////////////////////////////////
//

ddl_cmd ::= DROP TABLE ifexists(E) fullname(X) . {
  struct Token t = Token_nil;
  drop_table_def_init(&pParse->drop_table_def, X, &t, E);
  pParse->initiateTTrans = true;
  sql_drop_table(pParse);
}

ddl_cmd ::= DROP VIEW ifexists(E) fullname(X) . {
  struct Token t = Token_nil;
  drop_view_def_init(&pParse->drop_view_def, X, &t, E);
  pParse->initiateTTrans = true;
  sql_drop_table(pParse);
}

%type ifexists {int}
ifexists(A) ::= IF EXISTS.   {A = 1;}
ifexists(A) ::= .            {A = 0;}

///////////////////// The CREATE VIEW statement /////////////////////////////
//
ddl_cmd ::= createkw(X) VIEW ifnotexists(E) nm(Y) eidlist_opt(C)
          AS select(S). {
  if (!pParse->parse_only) {
    create_view_def_init(&pParse->create_view_def, &Y, &X, C, S, E);
    pParse->initiateTTrans = true;
    sql_create_view(pParse);
  } else {
    sql_expr_list_delete(C);
    pParse->parsed_ast_type = AST_TYPE_SELECT;
    pParse->parsed_ast.select = S;
  }
}

//////////////////////// The SELECT statement /////////////////////////////////
//
cmd ::= select(X).  {
  SelectDest dest = {SRT_Output, 0, 0, 0, 0, 0};
  if(pParse->parse_only) {
    diag_set(ClientError, ER_SQL_PARSER_GENERIC,
             "Failed to parse SQL expression");
    pParse->is_aborted = true;
    return;
  }
  sqlSelect(pParse, X, &dest);
  sql_select_delete(X);
}

%type select {Select*}
%destructor select {sql_select_delete($$);}
%type selectnowith {Select*}
%destructor selectnowith {sql_select_delete($$);}
%type oneselect {Select*}
%destructor oneselect {sql_select_delete($$);}

%include {
  /**
   * For a compound SELECT statement, make sure
   * p->pPrior->pNext==p for all elements in the list. And make
   * sure list length does not exceed SQL_MAX_COMPOUND_SELECT.
   */
  static void parserDoubleLinkSelect(Parse *pParse, Select *p){
    if( p->pPrior ){
      Select *pNext = 0, *pLoop;
      int mxSelect, cnt = 0;
      for(pLoop=p; pLoop; pNext=pLoop, pLoop=pLoop->pPrior, cnt++){
        pLoop->pNext = pNext;
        pLoop->selFlags |= SF_Compound;
      }
      if((p->selFlags & SF_MultiValue) == 0 &&
         (mxSelect = sql_get()->aLimit[SQL_LIMIT_COMPOUND_SELECT]) > 0 &&
         cnt > mxSelect) {
          diag_set(ClientError, ER_SQL_PARSER_LIMIT, "The number of UNION or "\
                   "EXCEPT or INTERSECT operations", cnt,
                   sql_get()->aLimit[SQL_LIMIT_COMPOUND_SELECT]);
         pParse->is_aborted = true;
      }
    }
  }
}

select(A) ::= with(W) selectnowith(X). {
  Select *p = X;
  if( p ){
    p->pWith = W;
    parserDoubleLinkSelect(pParse, p);
  }else{
    sqlWithDelete(W);
  }
  A = p; /*A-overwrites-W*/
}

selectnowith(A) ::= oneselect(A).

selectnowith(A) ::= selectnowith(A) multiselect_op(Y) oneselect(Z).  {
  Select *pRhs = Z;
  Select *pLhs = A;
  if( pRhs && pRhs->pPrior ){
    SrcList *pFrom;
    Token x;
    x.n = 0;
    parserDoubleLinkSelect(pParse, pRhs);
    pFrom = sqlSrcListAppendFromTerm(pParse,0,0,&x,pRhs,0,0,false);
    pRhs = sqlSelectNew(pParse,0,pFrom,0,0,0,0,0,0,0);
  }
  if( pRhs ){
    pRhs->op = (u8)Y;
    pRhs->pPrior = pLhs;
    if( ALWAYS(pLhs) ) pLhs->selFlags &= ~SF_MultiValue;
    pRhs->selFlags &= ~SF_MultiValue;
    if( Y!=TK_ALL ) pParse->hasCompound = 1;
  }else{
    sql_select_delete(pLhs);
  }
  A = pRhs;
}
%type multiselect_op {int}
multiselect_op(A) ::= UNION(OP).             {A = @OP; /*A-overwrites-OP*/}
multiselect_op(A) ::= UNION ALL.             {A = TK_ALL;}
multiselect_op(A) ::= EXCEPT|INTERSECT(OP).  {A = @OP; /*A-overwrites-OP*/}

oneselect(A) ::= SELECT(S) distinct(D) selcollist(W) from(X) where_opt(Y)
                 groupby_opt(P) having_opt(Q)
                 windowdefn_opt(R)
                 orderby_opt(Z) limit_opt(L). {
#ifdef SQL_DEBUG
  Token s = S; /*A-overwrites-S*/
#endif
  A = sqlSelectNew(pParse,W,X,Y,P,Q,Z,D,L.pLimit,L.pOffset);
  if( A ){
    A->pWinDefn = R;
  }else{
    sqlWindowListDelete(R);
  }
#ifdef SQL_DEBUG
  /* Populate the Select.zSelName[] string that is used to help with
  ** query planner debugging, to differentiate between multiple Select
  ** objects in a complex query.
  **
  ** If the SELECT keyword is immediately followed by a C-style comment
  ** then extract the first few alphanumeric characters from within that
  ** comment to be the zSelName value.  Otherwise, the label is #N where
  ** is an integer that is incremented with each SELECT statement seen.
  */
  if( A!=0 ){
    const char *z = s.z+6;
    int i;
    sql_snprintf(sizeof(A->zSelName), A->zSelName, "#%d",
                     ++pParse->nSelect);
    while( z[0]==' ' ) z++;
    if( z[0]=='/' && z[1]=='*' ){
      z += 2;
      while( z[0]==' ' ) z++;
      for(i=0; sqlIsalnum(z[i]); i++){}
      sql_snprintf(sizeof(A->zSelName), A->zSelName, "%.*s", i, z);
    }
  }
#endif /* SQL_DEBUG */
}
oneselect(A) ::= values(A).

%type values {Select*}
%destructor values {sql_select_delete($$);}
values(A) ::= VALUES LP nexprlist(X) RP. {
  A = sqlSelectNew(pParse,X,0,0,0,0,0,SF_Values,0,0);
}
values(A) ::= values(A) COMMA LP exprlist(Y) RP. {
  Select *pRight, *pLeft = A;
  pRight = sqlSelectNew(pParse,Y,0,0,0,0,0,SF_Values|SF_MultiValue,0,0);
  if( ALWAYS(pLeft) ) pLeft->selFlags &= ~SF_MultiValue;
  if( pRight ){
    pRight->op = TK_ALL;
    pRight->pPrior = pLeft;
    A = pRight;
  }else{
    A = pLeft;
  }
}

// The "distinct" nonterminal is true (1) if the DISTINCT keyword is
// present and false (0) if it is not.
//
%type distinct {int}
distinct(A) ::= DISTINCT.   {A = SF_Distinct;}
distinct(A) ::= ALL.        {A = SF_All;}
distinct(A) ::= .           {A = 0;}

// selcollist is a list of expressions that are to become the return
// values of the SELECT statement.  The "*" in statements like
// "SELECT * FROM ..." is encoded as a special expression with an
// opcode of TK_ASTERISK.
//
%type selcollist {ExprList*}
%destructor selcollist {sql_expr_list_delete($$);}
%type sclp {ExprList*}
%destructor sclp {sql_expr_list_delete($$);}
sclp(A) ::= selcollist(A) COMMA.
sclp(A) ::= .                                {A = 0;}
selcollist(A) ::= sclp(A) scanpt(B) expr(X) scanpt(Z) as(Y).     {
   A = sql_expr_list_append(A, X);
   if( Y.n>0 ) sqlExprListSetName(pParse, A, &Y, 1);
   sqlExprListSetSpan(A,B,Z);
}
selcollist(A) ::= sclp(A) scanpt STAR. {
  A = sql_expr_list_append(A, sql_expr_new_anon(TK_ASTERISK));
}
selcollist(A) ::= sclp(A) scanpt nm(X) DOT STAR. {
  struct Expr *pLeft = sql_expr_new_dequoted(TK_ID, &X);
  Expr *pRight = sqlPExpr(pParse, TK_ASTERISK, 0, 0);
  Expr *pDot = sqlPExpr(pParse, TK_DOT, pLeft, pRight);
  A = sql_expr_list_append(A, pDot);
}

// An option "AS <id>" phrase that can follow one of the expressions that
// define the result set, or one of the tables in the FROM clause.
//
%type as {Token}
as(X) ::= AS nm(Y).    {X = Y;}
as(X) ::= ids(X).
as(X) ::= .            {X.n = 0; X.z = 0;}

%type seqscan {int}
seqscan(X) ::= SEQSCAN.     {X = 0;}
seqscan(X) ::= .            {X = 1;}

%type seltablist {SrcList*}
%destructor seltablist {sqlSrcListDelete($$);}
%type stl_prefix {SrcList*}
%destructor stl_prefix {sqlSrcListDelete($$);}
%type from {SrcList*}
%destructor from {sqlSrcListDelete($$);}

// A complete FROM clause.
//
from(A) ::= .                {A = sql_xmalloc0(sizeof(*A));}
from(A) ::= FROM seltablist(X). {
  A = X;
  sqlSrcListShiftJoinType(A);
}

// "seltablist" is a "Select Table List" - the content of the FROM clause
// in a SELECT statement.  "stl_prefix" is a prefix of this list.
//
stl_prefix(A) ::= seltablist(A) joinop(Y).    {
   if( ALWAYS(A && A->nSrc>0) ) A->a[A->nSrc-1].fg.jointype = (u8)Y;
}
stl_prefix(A) ::= .                           {A = 0;}
seltablist(A) ::= stl_prefix(A) seqscan(X) nm(Y) as(Z) indexed_opt(I)
                  on_opt(N) using_opt(U). {
  A = sqlSrcListAppendFromTerm(pParse,A,&Y,&Z,0,N,U,X);
  sqlSrcListIndexedBy(A, &I);
}
seltablist(A) ::= stl_prefix(A) seqscan(X) nm(Y) LP exprlist(E) RP as(Z)
                  on_opt(N) using_opt(U). {
  A = sqlSrcListAppendFromTerm(pParse,A,&Y,&Z,0,N,U,X);
  sqlSrcListFuncArgs(A, E);
}
seltablist(A) ::= stl_prefix(A) LP select(S) RP
                  as(Z) on_opt(N) using_opt(U). {
  A = sqlSrcListAppendFromTerm(pParse,A,0,&Z,S,N,U,false);
}
seltablist(A) ::= stl_prefix(A) LP seltablist(F) RP
                  as(Z) on_opt(N) using_opt(U). {
  if( A==0 && Z.n==0 && N==0 && U==0 ){
    A = F;
  }else if( F->nSrc==1 ){
    A = sqlSrcListAppendFromTerm(pParse,A,0,&Z,0,N,U,false);
    if( A ){
      struct SrcItem *pNew = &A->a[A->nSrc-1];
      struct SrcItem *pOld = F->a;
      pNew->zName = pOld->zName;
      pNew->pSubq = pOld->pSubq;
      pOld->zName =  0;
      pOld->pSubq = 0;
      /*
       * The hints and restrictions of the item stay in force: INDEXED BY,
       * NOT INDEXED, the arguments of a table function, and the ban on
       * scanning it without SEQSCAN.
       */
      pNew->fg.notIndexed = pOld->fg.notIndexed;
      pNew->fg.isIndexedBy = pOld->fg.isIndexedBy;
      pNew->fg.isTabFunc = pOld->fg.isTabFunc;
      pNew->fg.disallow_scan = pOld->fg.disallow_scan;
      pNew->u1 = pOld->u1;
      pOld->fg.isIndexedBy = 0;
      pOld->fg.isTabFunc = 0;
      /* Without an alias of its own, the item keeps that of the inside. */
      if( pNew->zAlias==0 ){
        pNew->zAlias = pOld->zAlias;
        pOld->zAlias = 0;
      }
    }
    sqlSrcListDelete(F);
  }else{
    Select *pSubquery;
    sqlSrcListShiftJoinType(F);
    pSubquery = sqlSelectNew(pParse,0,F,0,0,0,0,SF_NestedFrom,0,0);
    A = sqlSrcListAppendFromTerm(pParse,A,0,&Z,pSubquery,N,U,false);
  }
}

%type fullname {SrcList*}
%destructor fullname {sqlSrcListDelete($$);}
fullname(A) ::= nm(X). {
  /* A-overwrites-X. */
  A = sql_src_list_append(NULL ,&X);
}

%type joinop {int}
join_nm(A) ::= id(A).
join_nm(A) ::= JOIN_KW(A).

joinop(X) ::= COMMA|JOIN.              { X = JT_INNER; }
joinop(X) ::= JOIN_KW(A) JOIN.
                  {X = sqlJoinType(pParse,&A,0,0);  /*X-overwrites-A*/}
joinop(X) ::= JOIN_KW(A) join_nm(B) JOIN.
                  {X = sqlJoinType(pParse,&A,&B,0); /*X-overwrites-A*/}
joinop(X) ::= JOIN_KW(A) join_nm(B) join_nm(C) JOIN.
                  {X = sqlJoinType(pParse,&A,&B,&C);/*X-overwrites-A*/}

%type on_opt {Expr*}
%destructor on_opt {sql_expr_delete($$);}
on_opt(N) ::= ON expr(E).   {N = E;}
on_opt(N) ::= .             {N = 0;}

// Note that this block abuses the Token type just a little. If there is
// no "INDEXED BY" clause, the returned token is empty (z==0 && n==0). If
// there is an INDEXED BY clause, then the token is populated as per normal,
// with z pointing to the token data and n containing the number of bytes
// in the token.
//
// If there is a "NOT INDEXED" clause, then (z==0 && n==1), which is 
// normally illegal. The sqlSrcListIndexedBy() function
// recognizes and interprets this as a special case.
//
%type indexed_opt {Token}
indexed_opt(A) ::= .                 {A.z=0; A.n=0;}
indexed_opt(A) ::= INDEXED BY nm(X). {A = X;}
indexed_opt(A) ::= NOT INDEXED.      {A.z=0; A.n=1;}

%type using_opt {IdList*}
%destructor using_opt {sqlIdListDelete($$);}
using_opt(U) ::= USING LP idlist(L) RP.  {U = L;}
using_opt(U) ::= .                        {U = 0;}


%type orderby_opt {ExprList*}
%destructor orderby_opt {sql_expr_list_delete($$);}

// the sortlist non-terminal stores a list of expression where each
// expression is optionally followed by ASC or DESC to indicate the
// sort order.
//
%type sortlist {ExprList*}
%destructor sortlist {sql_expr_list_delete($$);}

orderby_opt(A) ::= .                          {A = 0;}
orderby_opt(A) ::= ORDER BY sortlist(X).      {A = X;}
sortlist(A) ::= sortlist(A) COMMA expr(Y) sortorder(Z). {
  A = sql_expr_list_append(A, Y);
  sqlExprListSetSortOrder(A,Z);
}
sortlist(A) ::= expr(Y) sortorder(Z). {
  /* A-overwrites-Y. */
  A = sql_expr_list_append(NULL, Y);
  sqlExprListSetSortOrder(A,Z);
}

/**
 * Non-terminal rule to store a list of columns within PRIMARY KEY
 * declaration.
 */
%type col_list_with_autoinc {ExprList*}
%destructor col_list_with_autoinc {sql_expr_list_delete($$);}

col_list_with_autoinc(A) ::= col_list_with_autoinc(A) COMMA expr(Y)
                             autoinc(I). {
  uint32_t fieldno;
  if (I == 1) {
    if (sql_fieldno_by_name(pParse, Y, &fieldno) != 0)
      return;
    if (sql_add_autoincrement(pParse, fieldno) != 0)
      return;
  }
  A = sql_expr_list_append(A, Y);
}

col_list_with_autoinc(A) ::= expr(Y) autoinc(I). {
  if (I == 1) {
    uint32_t fieldno = 0;
    if (sql_fieldno_by_name(pParse, Y, &fieldno) != 0)
      return;
    if (sql_add_autoincrement(pParse, fieldno) != 0)
      return;
  }
  /* A-overwrites-Y. */
  A = sql_expr_list_append(NULL, Y);
}

%type sortorder {int}

sortorder(A) ::= ASC.           {A = SORT_ORDER_ASC;}
sortorder(A) ::= DESC.          {A = SORT_ORDER_DESC;}
sortorder(A) ::= .              {A = SORT_ORDER_UNDEF;}

%type groupby_opt {ExprList*}
%destructor groupby_opt {sql_expr_list_delete($$);}
groupby_opt(A) ::= .                      {A = 0;}
groupby_opt(A) ::= GROUP BY nexprlist(X). {A = X;}

%type having_opt {Expr*}
%destructor having_opt {sql_expr_delete($$);}
having_opt(A) ::= .                {A = 0;}
having_opt(A) ::= HAVING expr(X).  {A = X;}

%type limit_opt {struct LimitVal}

// The destructor for limit_opt will never fire in the current grammar.
// The limit_opt non-terminal only occurs at the end of a single production
// rule for SELECT statements.  As soon as the rule that create the 
// limit_opt non-terminal reduces, the SELECT statement rule will also
// reduce.  So there is never a limit_opt non-terminal on the stack 
// except as a transient.  So there is never anything to destroy.
//
//%destructor limit_opt {
//  sqlExprDelete($$.pLimit);
//  sqlExprDelete($$.pOffset);
//}
limit_opt(A) ::= .                    {A.pLimit = 0; A.pOffset = 0;}
limit_opt(A) ::= LIMIT expr(X).       {A.pLimit = X; A.pOffset = 0;}
limit_opt(A) ::= LIMIT expr(X) OFFSET expr(Y). 
                                      {A.pLimit = X; A.pOffset = Y;}
limit_opt(A) ::= LIMIT expr(X) COMMA expr(Y). 
                                      {A.pOffset = X; A.pLimit = Y;}

/////////////////////////// The DELETE statement /////////////////////////////
//
cmd ::= with(C) DELETE FROM fullname(X) indexed_opt(I) where_opt(W). {
  sqlWithPush(pParse, C, 1);
  sqlSrcListIndexedBy(X, &I);
  sqlSubProgramsRemaining = SQL_MAX_COMPILING_TRIGGERS;
  /* Instruct SQL to initate Tarantool's transaction.  */
  pParse->initiateTTrans = true;
  sql_table_delete_from(pParse,X,W);
}

/////////////////////////// The TRUNCATE statement /////////////////////////////
//
cmd ::= TRUNCATE TABLE fullname(X). {
  pParse->initiateTTrans = true;
  sql_table_truncate(pParse, X);
}

%type where_opt {Expr*}
%destructor where_opt {sql_expr_delete($$);}

where_opt(A) ::= .                    {A = 0;}
where_opt(A) ::= WHERE expr(X).       {A = X;}

////////////////////////// The UPDATE command ////////////////////////////////
//
cmd ::= with(C) UPDATE orconf(R) fullname(X) indexed_opt(I) SET setlist(Y)
        where_opt(W).  {
  sqlWithPush(pParse, C, 1);
  sqlSrcListIndexedBy(X, &I);
  if (Y != NULL && Y->nExpr > SQL_MAX_COLUMN) {
    diag_set(ClientError, ER_SQL_PARSER_LIMIT, "The number of columns in set "\
             "list", Y->nExpr, SQL_MAX_COLUMN);
    pParse->is_aborted = true;
  }
  sqlSubProgramsRemaining = SQL_MAX_COMPILING_TRIGGERS;
  /* Instruct SQL to initate Tarantool's transaction.  */
  pParse->initiateTTrans = true;
  sqlUpdate(pParse,X,Y,W,R);
}

%type setlist {ExprList*}
%destructor setlist {sql_expr_list_delete($$);}

setlist(A) ::= setlist(A) COMMA nm(X) EQ expr(Y). {
  A = sql_expr_list_append(A, Y);
  sqlExprListSetName(pParse, A, &X, 1);
}
setlist(A) ::= setlist(A) COMMA LP idlist(X) RP EQ expr(Y). {
  A = sqlExprListAppendVector(pParse, A, X, Y);
}
setlist(A) ::= nm(X) EQ expr(Y). {
  A = sql_expr_list_append(NULL, Y);
  sqlExprListSetName(pParse, A, &X, 1);
}
setlist(A) ::= LP idlist(X) RP EQ expr(Y). {
  A = sqlExprListAppendVector(pParse, 0, X, Y);
}

////////////////////////// The INSERT command /////////////////////////////////
//
cmd ::= with(W) insert_cmd(R) INTO fullname(X) idlist_opt(F) select(S). {
  sqlWithPush(pParse, W, 1);
  sqlSubProgramsRemaining = SQL_MAX_COMPILING_TRIGGERS;
  /* Instruct SQL to initate Tarantool's transaction.  */
  pParse->initiateTTrans = true;
  sqlInsert(pParse, X, S, F, R);
}
cmd ::= with(W) insert_cmd(R) INTO fullname(X) idlist_opt(F) DEFAULT VALUES.
{
  sqlWithPush(pParse, W, 1);
  sqlSubProgramsRemaining = SQL_MAX_COMPILING_TRIGGERS;
  /* Instruct SQL to initate Tarantool's transaction.  */
  pParse->initiateTTrans = true;
  sqlInsert(pParse, X, 0, F, R);
}

%type insert_cmd {int}
insert_cmd(A) ::= INSERT orconf(R).   {A = R;}
insert_cmd(A) ::= REPLACE.            {A = ON_CONFLICT_ACTION_REPLACE;}

%type idlist_opt {IdList*}
%destructor idlist_opt {sqlIdListDelete($$);}
%type idlist {IdList*}
%destructor idlist {sqlIdListDelete($$);}

idlist_opt(A) ::= .                       {A = 0;}
idlist_opt(A) ::= LP idlist(X) RP.    {A = X;}
idlist(A) ::= idlist(A) COMMA nm(Y). {
  A = sql_id_list_append(A, &Y);
}
idlist(A) ::= nm(Y). {
  /* A-overwrites-Y. */
  A = sql_id_list_append(NULL, &Y);
}

/////////////////////////// Expression Processing /////////////////////////////
//

%type expr {Expr*}
%destructor expr {sql_expr_delete($$);}
%type term {Expr*}
%destructor term {sql_expr_delete($$);}

%include {
  /* Construct a new Expr object from a single token. */
  static Expr *tokenExpr(int op, Token t){
    struct Expr *p = NULL;
    int name_sz = t.n + 1;
    p = sql_xmalloc(sizeof(Expr) + name_sz);
    memset(p, 0, sizeof(Expr));
    switch (op) {
    case TK_STRING:
      p->type = FIELD_TYPE_STRING;
      break;
    case TK_BLOB:
      p->type = FIELD_TYPE_VARBINARY;
      break;
    case TK_INTEGER:
      p->type = FIELD_TYPE_INTEGER;
      break;
    case TK_FLOAT:
      p->type = FIELD_TYPE_DOUBLE;
      break;
    case TK_DECIMAL:
      p->type = FIELD_TYPE_DECIMAL;
      break;
    case TK_TRUE:
    case TK_FALSE:
    case TK_UNKNOWN:
      p->type = FIELD_TYPE_BOOLEAN;
      break;
    default:
      p->type = FIELD_TYPE_SCALAR;
      break;
    }
    p->op = (u8)op;
    p->flags = EP_Leaf;
    p->iAgg = -1;
    p->u.zToken = (char*)&p[1];
    int rc = sql_normalize_name(p->u.zToken, name_sz, t.z, t.n);
    if (rc > name_sz) {
      name_sz = rc;
      p = sql_xrealloc(p, sizeof(*p) + name_sz);
      p->u.zToken = (char *)&p[1];
      sql_normalize_name(p->u.zToken, name_sz, t.z, t.n);
    }
#if SQL_MAX_EXPR_DEPTH>0
    p->nHeight = 1;
#endif  
    return p;
  }
}

expr(A) ::= term(A).
expr(A) ::= LP expr(X) RP. {A = X;}
term(A) ::= NULL(X).        {A = tokenExpr(@X, X);/*A-overwrites-X*/}
expr(A) ::= id(X).          {A = tokenExpr(TK_ID, X); /*A-overwrites-X*/}
expr(A) ::= JOIN_KW(X).     {A = tokenExpr(TK_ID, X); /*A-overwrites-X*/}
expr(A) ::= nm(X) DOT nm(Y). {
  struct Expr *temp1 = sql_expr_new_dequoted(TK_ID, &X);
  struct Expr *temp2 = sql_expr_new_dequoted(TK_ID, &Y);
  A = sqlPExpr(pParse, TK_DOT, temp1, temp2);
}
term(A) ::= FLOAT|BLOB(X). {A = tokenExpr(@X, X);/*A-overwrites-X*/}
term(A) ::= STRING(X).     {A = tokenExpr(@X, X);/*A-overwrites-X*/}
term(A) ::= FALSE(X) . {A = tokenExpr(@X, X);/*A-overwrites-X*/}
term(A) ::= TRUE(X) . {A = tokenExpr(@X, X);/*A-overwrites-X*/}
term(A) ::= UNKNOWN(X) . {A = tokenExpr(@X, X);/*A-overwrites-X*/}
term(A) ::= DECIMAL(X) . {A = tokenExpr(@X, X);/*A-overwrites-X*/}

term(A) ::= INTEGER(X). {
  A = sql_expr_new_dequoted(TK_INTEGER, &X);
  A->type = FIELD_TYPE_INTEGER;
  if( A ) A->flags |= EP_Leaf|EP_Resolved;
}
expr(A) ::= VARNUM(X). {
  A = expr_new_variable(pParse, &X, NULL);
}
expr(A) ::= COLON|VARIABLE(X) id(Y).     {
  A = expr_new_variable(pParse, &X, &Y);
}
expr(A) ::= COLON|VARIABLE(X) INTEGER(Y).     {
  A = expr_new_variable(pParse, &X, &Y);
}
expr(A) ::= expr(A) COLLATE id(C). {
  A = sqlExprAddCollateToken(A, &C, 1);
  sqlExprSetHeightAndFlags(pParse, A);
}

expr(A) ::= CAST LP expr(E) AS typedef(T) RP. {
  A = sqlPExpr(pParse, TK_CAST, E, NULL);
  A->type = T.type;
}

// The PostgreSQL-style cast: `expr::type` is the same as
// `CAST(expr AS type)`. The operator binds tighter than all other
// operators, the unary ones included: `-a::INT` is `-(a::INT)`.
expr(A) ::= expr(A) DCOLON typedef(T). {
  A = sqlPExpr(pParse, TK_CAST, A, NULL);
  A->type = T.type;
}

expr(A) ::= expr(X) LB getlist(Y) RB. {
  struct Expr *expr = sql_expr_new_anon(TK_GETITEM);
  Y = sql_expr_list_append(Y, X);
  expr->x.pList = Y;
  expr->type = FIELD_TYPE_ANY;
  sqlExprSetHeightAndFlags(pParse, expr);
  A = expr;
}

getlist(A) ::= getlist(A) RB LB expr(X). {
  A = sql_expr_list_append(A, X);
}
getlist(A) ::= expr(X). {
  A = sql_expr_list_append(NULL, X);
}

%type getlist {ExprList *}
%destructor getlist {sql_expr_list_delete($$);}

expr(A) ::= LB exprlist(Y) RB. {
  struct Expr *expr = sql_expr_new_anon(TK_ARRAY);
  expr->x.pList = Y;
  expr->type = FIELD_TYPE_ARRAY;
  sqlExprSetHeightAndFlags(pParse, expr);
  A = expr;
}

expr(A) ::= LCB maplist(Y) RCB. {
  struct Expr *expr = sql_expr_new_anon(TK_MAP);
  expr->x.pList = Y;
  expr->type = FIELD_TYPE_MAP;
  sqlExprSetHeightAndFlags(pParse, expr);
  A = expr;
}

maplist(A) ::= nmaplist(A).
maplist(A) ::= . {
  A = NULL;
}
nmaplist(A) ::= nmaplist(A) COMMA expr(X) COLON expr(Y). {
  A = sql_expr_list_append(A, X);
  A = sql_expr_list_append(A, Y);
}
nmaplist(A) ::= expr(X) COLON expr(Y). {
  A = sql_expr_list_append(NULL, X);
  A = sql_expr_list_append(A, Y);
}

%type maplist {ExprList *}
%destructor maplist {sql_expr_list_delete($$);}
%type nmaplist {ExprList *}
%destructor nmaplist {sql_expr_list_delete($$);}

expr(A) ::= TRIM(X) LP trim_operands(Y) RP. {
  A = sqlExprFunction(pParse, Y, &X);
}

%type trim_operands {struct ExprList *}
%destructor trim_operands {sql_expr_list_delete($$);}

trim_operands(A) ::= trim_specification(N) expr(Z) FROM expr(Y). {
  A = sql_expr_list_append(NULL, Y);
  struct Expr *p = sql_expr_new_dequoted(TK_INTEGER, &sqlIntTokens[N]);
  A = sql_expr_list_append(A, p);
  A = sql_expr_list_append(A, Z);
}

trim_operands(A) ::= trim_specification(N) FROM expr(Y). {
  A = sql_expr_list_append(NULL, Y);
  struct Expr *p = sql_expr_new_dequoted(TK_INTEGER, &sqlIntTokens[N]);
  A = sql_expr_list_append(A, p);
}

trim_operands(A) ::= expr(Z) FROM expr(Y). {
  A = sql_expr_list_append(NULL, Y);
  struct Expr *p = sql_expr_new_dequoted(TK_INTEGER, &sqlIntTokens[TRIM_BOTH]);
  A = sql_expr_list_append(A, p);
  A = sql_expr_list_append(A, Z);
}

trim_operands(A) ::= expr(Y). {
  A = sql_expr_list_append(NULL, Y);
  struct Expr *p = sql_expr_new_dequoted(TK_INTEGER, &sqlIntTokens[TRIM_BOTH]);
  A = sql_expr_list_append(A, p);
}

%type expr_optional {struct Expr *}
%destructor expr_optional {sql_expr_delete($$);}

expr_optional(A) ::= .        { A = NULL; }
expr_optional(A) ::= expr(X). { A = X; }

%type trim_specification {enum trim_side_mask}

trim_specification(A) ::= LEADING.  { A = TRIM_LEADING; }
trim_specification(A) ::= TRAILING. { A = TRIM_TRAILING; }
trim_specification(A) ::= BOTH.     { A = TRIM_BOTH; }

expr(A) ::= id(X) LP distinct(D) exprlist(Y) RP over_opt(Z). {
  if (Y != NULL && Y->nExpr > SQL_MAX_FUNCTION_ARG){
    const char *err =
      tt_sprintf("Number of arguments to function %.*s", X.n, X.z);
    diag_set(ClientError, ER_SQL_PARSER_LIMIT, err, Y->nExpr,
             SQL_MAX_FUNCTION_ARG);
    pParse->is_aborted = true;
  }
  A = sqlExprFunction(pParse, Y, &X);
  if (D == SF_Distinct && A) {
    A->flags |= EP_Distinct;
  }
  sqlWindowAttach(pParse, A, Z);
}

/*
 * type_func(A) ::= DATE(A) .
 * type_func(A) ::= DATETIME(A) .
 */
type_func(A) ::= CHAR(A) .
expr(A) ::= type_func(X) LP distinct(D) exprlist(Y) RP over_opt(Z). {
  if (Y != NULL && Y->nExpr > SQL_MAX_FUNCTION_ARG){
    const char *err =
      tt_sprintf("Number of arguments to function %.*s", X.n, X.z);
    diag_set(ClientError, ER_SQL_PARSER_LIMIT, err, Y->nExpr,
             SQL_MAX_FUNCTION_ARG);
    pParse->is_aborted = true;
  }
  A = sqlExprFunction(pParse, Y, &X);
  if (D == SF_Distinct && A) {
    A->flags |= EP_Distinct;
  }
  sqlWindowAttach(pParse, A, Z);
}

expr(A) ::= id(X) LP STAR RP over_opt(Z). {
  A = sqlExprFunction(pParse, 0, &X);
  sqlWindowAttach(pParse, A, Z);
}
/*
 * term(A) ::= CTIME_KW(OP). {
 *   A = sqlExprFunction(pParse, 0, &OP);
 * }
 */

expr(A) ::= LP nexprlist(X) COMMA expr(Y) RP. {
  ExprList *pList = sql_expr_list_append(X, Y);
  A = sqlPExpr(pParse, TK_VECTOR, 0, 0);
  if( A ){
    A->x.pList = pList;
  }else{
    sql_expr_list_delete(pList);
  }
}

expr(A) ::= expr(A) AND(OP) expr(Y).    {A=sqlPExpr(pParse,@OP,A,Y);}
expr(A) ::= expr(A) OR(OP) expr(Y).     {A=sqlPExpr(pParse,@OP,A,Y);}
expr(A) ::= expr(A) LT|GT|GE|LE(OP) expr(Y).
                                        {A=sqlPExpr(pParse,@OP,A,Y);}
expr(A) ::= expr(A) EQ|NE(OP) expr(Y).  {A=sqlPExpr(pParse,@OP,A,Y);}
expr(A) ::= expr(A) BITAND|BITOR|LSHIFT|RSHIFT(OP) expr(Y).
                                        {A=sqlPExpr(pParse,@OP,A,Y);}
expr(A) ::= expr(A) PLUS|MINUS(OP) expr(Y).
                                        {A=sqlPExpr(pParse,@OP,A,Y);}
expr(A) ::= expr(A) STAR|SLASH|REM(OP) expr(Y).
                                        {A=sqlPExpr(pParse,@OP,A,Y);}
expr(A) ::= expr(A) CONCAT(OP) expr(Y). {A=sqlPExpr(pParse,@OP,A,Y);}
%type likeop {Token}
likeop(A) ::= LIKE_KW|MATCH(X).     {A=X;/*A-overwrites-X*/}
likeop(A) ::= NOT LIKE_KW|MATCH(X). {A=X; A.n|=0x80000000; /*A-overwrite-X*/}
expr(A) ::= expr(A) likeop(OP) expr(Y).  [LIKE_KW]  {
  ExprList *pList;
  int bNot = OP.n & 0x80000000;
  OP.n &= 0x7fffffff;
  pList = sql_expr_list_append(NULL, Y);
  pList = sql_expr_list_append(pList, A);
  A = sqlExprFunction(pParse, pList, &OP);
  if( bNot ) A = sqlPExpr(pParse, TK_NOT, A, 0);
  if( A ) A->flags |= EP_InfixFunc;
}
expr(A) ::= expr(A) likeop(OP) expr(Y) ESCAPE expr(E).  [LIKE_KW]  {
  ExprList *pList;
  int bNot = OP.n & 0x80000000;
  OP.n &= 0x7fffffff;
  pList = sql_expr_list_append(NULL, Y);
  pList = sql_expr_list_append(pList, A);
  pList = sql_expr_list_append(pList, E);
  A = sqlExprFunction(pParse, pList, &OP);
  if( bNot ) A = sqlPExpr(pParse, TK_NOT, A, 0);
  if( A ) A->flags |= EP_InfixFunc;
}

// Tokens TK_ISNULL and TK_NOTNULL defined in extra tokens and are identifiers
// for operations IS NULL and IS NOT NULL.

expr(A) ::= expr(A) IS NULL.   {A = sqlPExpr(pParse,TK_ISNULL,A,0);}
expr(A) ::= expr(A) IS NOT NULL.   {A = sqlPExpr(pParse,TK_NOTNULL,A,0);}

expr(A) ::= NOT(B) expr(X).  
              {A = sqlPExpr(pParse, @B, X, 0);/*A-overwrites-B*/}
expr(A) ::= BITNOT(B) expr(X).
              {A = sqlPExpr(pParse, @B, X, 0);/*A-overwrites-B*/}
expr(A) ::= MINUS expr(X). [BITNOT]
              {A = sqlPExpr(pParse, TK_UMINUS, X, 0);}
expr(A) ::= PLUS expr(X). [BITNOT]
              {A = sqlPExpr(pParse, TK_UPLUS, X, 0);}

%type between_op {int}
between_op(A) ::= BETWEEN.     {A = 0;}
between_op(A) ::= NOT BETWEEN. {A = 1;}
expr(A) ::= expr(A) between_op(N) expr(X) AND expr(Y). [BETWEEN] {
  ExprList *pList = sql_expr_list_append(NULL, X);
  pList = sql_expr_list_append(pList, Y);
  A = sqlPExpr(pParse, TK_BETWEEN, A, 0);
  if( A ){
    A->x.pList = pList;
  }else{
    sql_expr_list_delete(pList);
  } 
  if( N ) A = sqlPExpr(pParse, TK_NOT, A, 0);
}
%type in_op {int}
in_op(A) ::= IN.      {A = 0;}
in_op(A) ::= NOT IN.  {A = 1;}
expr(A) ::= expr(A) in_op(N) LP exprlist(Y) RP. [IN] {
  if( Y==0 ){
    /* Expressions of the form
    **
    **      expr1 IN ()
    **      expr1 NOT IN ()
    **
    ** simplify to constants 0 (false) and 1 (true), respectively,
    ** regardless of the value of expr1.
    */
    sql_expr_delete(A);
    int tk = N == 0 ? TK_FALSE : TK_TRUE;
    A = sql_expr_new_anon(tk);
    A->type = FIELD_TYPE_BOOLEAN;
  }else if( Y->nExpr==1 ){
    /* Expressions of the form:
    **
    **      expr1 IN (?1)
    **      expr1 NOT IN (?2)
    **
    ** with exactly one value on the RHS can be simplified to something
    ** like this:
    **
    **      expr1 == ?1
    **      expr1 <> ?2
    */
    Expr *pRHS = Y->a[0].pExpr;
    Y->a[0].pExpr = 0;
    sql_expr_list_delete(Y);
    A = sqlPExpr(pParse, N ? TK_NE : TK_EQ, A, pRHS);
  }else{
    A = sqlPExpr(pParse, TK_IN, A, 0);
    if( A ){
      A->x.pList = Y;
      sqlExprSetHeightAndFlags(pParse, A);
    }else{
      sql_expr_list_delete(Y);
    }
    if( N ) A = sqlPExpr(pParse, TK_NOT, A, 0);
  }
}
expr(A) ::= LP select(X) RP. {
  A = sqlPExpr(pParse, TK_SELECT, 0, 0);
  sqlPExprAddSelect(pParse, A, X);
}
expr(A) ::= expr(A) in_op(N) LP select(Y) RP.  [IN] {
  A = sqlPExpr(pParse, TK_IN, A, 0);
  sqlPExprAddSelect(pParse, A, Y);
  if( N ) A = sqlPExpr(pParse, TK_NOT, A, 0);
}
expr(A) ::= expr(A) in_op(N) nm(Y) paren_exprlist(E). [IN] {
  struct SrcList *pSrc = sql_src_list_append(NULL, &Y);
  Select *pSelect = sqlSelectNew(pParse, 0,pSrc,0,0,0,0,0,0,0);
  if(E != NULL)
    sqlSrcListFuncArgs(pSelect != NULL ? pSrc : NULL, E);
  A = sqlPExpr(pParse, TK_IN, A, 0);
  sqlPExprAddSelect(pParse, A, pSelect);
  if( N ) A = sqlPExpr(pParse, TK_NOT, A, 0);
}
expr(A) ::= EXISTS LP select(Y) RP. {
  Expr *p;
  p = A = sqlPExpr(pParse, TK_EXISTS, 0, 0);
  sqlPExprAddSelect(pParse, p, Y);
}

/* CASE expressions */
expr(A) ::= CASE expr_optional(X) case_exprlist(Y) case_else(Z) END. {
  A = sqlPExpr(pParse, TK_CASE, X, 0);
  if( A ){
    A->x.pList = Z ? sql_expr_list_append(Y, Z) : Y;
    sqlExprSetHeightAndFlags(pParse, A);
  }else{
    sql_expr_list_delete(Y);
    sql_expr_delete(Z);
  }
}
%type case_exprlist {ExprList*}
%destructor case_exprlist {sql_expr_list_delete($$);}
case_exprlist(A) ::= case_exprlist(A) WHEN expr(Y) THEN expr(Z). {
  A = sql_expr_list_append(A, Y);
  A = sql_expr_list_append(A, Z);
}
case_exprlist(A) ::= WHEN expr(Y) THEN expr(Z). {
  A = sql_expr_list_append(NULL, Y);
  A = sql_expr_list_append(A, Z);
}
%type case_else {Expr*}
%destructor case_else {sql_expr_delete($$);}
case_else(A) ::=  ELSE expr(X).         {A = X;}
case_else(A) ::=  .                     {A = 0;} 

%type exprlist {ExprList*}
%destructor exprlist {sql_expr_list_delete($$);}
%type nexprlist {ExprList*}
%destructor nexprlist {sql_expr_list_delete($$);}

exprlist(A) ::= nexprlist(A).
exprlist(A) ::= .                            {A = 0;}
nexprlist(A) ::= nexprlist(A) COMMA expr(Y).
    {A = sql_expr_list_append(A, Y);}
nexprlist(A) ::= expr(Y).
    {A = sql_expr_list_append(NULL, Y); /*A-overwrites-Y*/}

/* A paren_exprlist is an optional expression list contained inside
** of parenthesis */
%type paren_exprlist {ExprList*}
%destructor paren_exprlist {sql_expr_list_delete($$);}
paren_exprlist(A) ::= .   {A = 0;}
paren_exprlist(A) ::= LP exprlist(X) RP.  {A = X;}


///////////////////////////// The CREATE INDEX command ///////////////////////
//
ddl_cmd ::= createkw uniqueflag(U) INDEX ifnotexists(NE) nm(X)
        ON nm(Y) LP sortlist(Z) RP. {
  struct SrcList *src_list = sql_src_list_append(NULL ,&Y);
  create_index_def_init(&pParse->create_index_def, src_list, &X, Z, U,
                        SORT_ORDER_ASC, NE);
  pParse->initiateTTrans = true;
  sql_create_index(pParse);
}

%type uniqueflag {int}
uniqueflag(A) ::= UNIQUE.  {A = SQL_INDEX_TYPE_UNIQUE;}
uniqueflag(A) ::= .        {A = SQL_INDEX_TYPE_NON_UNIQUE;}


// The eidlist non-terminal (Expression Id List) generates an ExprList
// from a list of identifiers.  The identifier names are in ExprList.a[].zEName.
// This list is stored in an ExprList rather than an IdList so that it
// can be easily sent to sqlColumnsExprList().
//
// eidlist is grouped with CREATE INDEX because it used to be the non-terminal
// used for the arguments to an index.  That is just an historical accident.
//
%type eidlist {ExprList*}
%destructor eidlist {sql_expr_list_delete($$);}
%type eidlist_opt {ExprList*}
%destructor eidlist_opt {sql_expr_list_delete($$);}

%include {
  /* Add a single new term to an ExprList that is used to store a
  ** list of identifiers.  Report an error if the ID list contains
  ** a COLLATE clause or an ASC or DESC keyword, except ignore the
  ** error while parsing a legacy schema.
  */
  static ExprList *parserAddExprIdListTerm(
    Parse *pParse,
    ExprList *pPrior,
    Token *pIdToken
  ){
    ExprList *p = sql_expr_list_append(pPrior, NULL);
    sqlExprListSetName(pParse, p, pIdToken, 1);
    return p;
  }
} // end %include

eidlist_opt(A) ::= .                         {A = 0;}
eidlist_opt(A) ::= LP eidlist(X) RP.         {A = X;}
eidlist(A) ::= eidlist(A) COMMA nm(Y).  {
  A = parserAddExprIdListTerm(pParse, A, &Y);
}
eidlist(A) ::= nm(Y). {
  A = parserAddExprIdListTerm(pParse, 0, &Y); /*A-overwrites-Y*/
}


///////////////////////////// The DROP INDEX command /////////////////////////
//
ddl_cmd ::= DROP INDEX ifexists(E) nm(X) ON fullname(Y).   {
  drop_index_def_init(&pParse->drop_index_def, Y, &X, E);
  pParse->initiateTTrans = true;
  sql_drop_index(pParse);
}

///////////////////////////// The SET SESSION command ////////////////////////
//
ctl_cmd ::= SET SESSION nm(X) EQ term(Y).  {
    sql_setting_set(pParse,&X,Y);
}

///////////////////////////// The PRAGMA command /////////////////////////////
//
cmd ::= PRAGMA nm(X).                        {
    sqlPragma(pParse,&X,0,0);
}
cmd ::= PRAGMA nm(X) LP nm(Y) RP.         {
    sqlPragma(pParse,&X,&Y,0);
}
cmd ::= PRAGMA nm(X) LP nm(Z) DOT nm(Y) RP.  {
    sqlPragma(pParse,&X,&Y,&Z);
}
cmd ::= FUNCTION_KW(T) expr(E). {
  if (!pParse->is_expr) {
    diag_set(ClientError, ER_SQL_SYNTAX_NEAR_TOKEN, pParse->line_count, T.n,
             T.z);
    pParse->is_aborted = true;
    return;
  }
  pParse->parsed_ast_type = AST_TYPE_EXPR;
  pParse->parsed_ast.expr = E;
}
//////////////////////////// The CREATE TRIGGER command /////////////////////

ddl_cmd ::= createkw trigger_decl(A) BEGIN trigger_cmd_list(S) END(Z). {
  Token all;
  all.z = A.z;
  all.n = (int)(Z.z - A.z) + Z.n;
  pParse->initiateTTrans = true;
  sql_trigger_finish(pParse, S, &all);
}

trigger_decl(A) ::= TRIGGER ifnotexists(NOERR) nm(B)
                    trigger_time(C) trigger_event(D)
                    ON fullname(E) foreach_clause when_clause(G). {
  create_trigger_def_init(&pParse->create_trigger_def, E, &B, C, D.a, D.b, G,
                          NOERR);
  sql_trigger_begin(pParse);
  A = B; /*A-overwrites-T*/
}

%type trigger_time {int}
trigger_time(A) ::= BEFORE.      { A = TK_BEFORE; }
trigger_time(A) ::= AFTER.       { A = TK_AFTER;  }
trigger_time(A) ::= INSTEAD OF.  { A = TK_INSTEAD;}
trigger_time(A) ::= .            { A = TK_BEFORE; }

%type trigger_event {struct TrigEvent}
%destructor trigger_event {sqlIdListDelete($$.b);}
trigger_event(A) ::= DELETE|INSERT(X).   {A.a = @X; /*A-overwrites-X*/ A.b = 0;}
trigger_event(A) ::= UPDATE(X).          {A.a = @X; /*A-overwrites-X*/ A.b = 0;}
trigger_event(A) ::= UPDATE OF idlist(X).{A.a = TK_UPDATE; A.b = X;}

foreach_clause ::= . {
  diag_set(ClientError, ER_SQL_PARSER_GENERIC_WITH_POS, pParse->line_count,
           pParse->line_pos, "FOR EACH STATEMENT triggers are not implemented, "
           "please supply FOR EACH ROW clause");
  pParse->is_aborted = true;
}
foreach_clause ::= FOR EACH ROW.

%type when_clause {Expr*}
%destructor when_clause {sql_expr_delete($$);}
when_clause(A) ::= .             { A = 0; }
when_clause(A) ::= WHEN expr(X). { A = X; }

%type trigger_cmd_list {TriggerStep*}
%destructor trigger_cmd_list {sqlDeleteTriggerStep($$);}
trigger_cmd_list(A) ::= trigger_cmd_list(A) trigger_cmd(X) SEMI. {
  assert( A!=0 );
  A->pLast->pNext = X;
  A->pLast = X;
}
trigger_cmd_list(A) ::= trigger_cmd(A) SEMI. { 
  assert( A!=0 );
  A->pLast = A;
}

// Disallow qualified table names on INSERT, UPDATE, and DELETE statements
// within a trigger.  The table to INSERT, UPDATE, or DELETE is always in 
// the same database as the table that the trigger fires on.
//
%type trnm {Token}
trnm(A) ::= nm(A).
trnm(A) ::= nm DOT nm(X). {
  A = X;
  diag_set(ClientError, ER_SQL_PARSER_GENERIC_WITH_POS, pParse->line_count,
           pParse->line_pos, "qualified table names are not allowed on INSERT, "
           "UPDATE, and DELETE statements within triggers");
  pParse->is_aborted = true;
}

// Disallow the INDEX BY and NOT INDEXED clauses on UPDATE and DELETE
// statements within triggers.  We make a specific error message for this
// since it is an exception to the default grammar rules.
//
tridxby ::= .
tridxby ::= INDEXED BY nm. {
  diag_set(ClientError, ER_SQL_SYNTAX_WITH_POS, pParse->line_count,
           pParse->line_pos, "the INDEXED BY clause is not allowed on UPDATE "\
           "or DELETE statements within triggers");
  pParse->is_aborted = true;
}
tridxby ::= NOT INDEXED. {
  diag_set(ClientError, ER_SQL_SYNTAX_WITH_POS, pParse->line_count,
           pParse->line_pos, "the NOT INDEXED BY clause is not allowed on "\
           "UPDATE or DELETE statements within triggers");
  pParse->is_aborted = true;
}



%type trigger_cmd {TriggerStep*}
%destructor trigger_cmd {sqlDeleteTriggerStep($$);}
// UPDATE 
trigger_cmd(A) ::=
   UPDATE orconf(R) trnm(X) tridxby SET setlist(Y) where_opt(Z). {
     A = sql_trigger_update_step(&X, Y, Z, R);
     if (A == NULL) {
        pParse->is_aborted = true;
        return;
     }
   }

// INSERT
trigger_cmd(A) ::= insert_cmd(R) INTO trnm(X) idlist_opt(F) select(S). {
  /*A-overwrites-R. */
  A = sql_trigger_insert_step(&X, F, S, R);
}

// DELETE
trigger_cmd(A) ::= DELETE FROM trnm(X) tridxby where_opt(Y). {
  A = sql_trigger_delete_step(&X, Y);
}

// SELECT
trigger_cmd(A) ::= select(X). {
  /* A-overwrites-X. */
  A = sql_trigger_select_step(X);
}

// The special RAISE expression that may occur in trigger programs
expr(A) ::= RAISE LP IGNORE RP.  {
  A = sqlPExpr(pParse, TK_RAISE, 0, 0);
  if( A ){
    A->on_conflict_action = ON_CONFLICT_ACTION_IGNORE;
  }
}
expr(A) ::= RAISE LP raisetype(T) COMMA STRING(Z) RP.  {
  A = sql_expr_new_dequoted(TK_RAISE, &Z);
  A->on_conflict_action = (enum on_conflict_action) T;
}

%type raisetype {int}
raisetype(A) ::= ROLLBACK.  {A = ON_CONFLICT_ACTION_ROLLBACK;}
raisetype(A) ::= ABORT.     {A = ON_CONFLICT_ACTION_ABORT;}
raisetype(A) ::= FAIL.      {A = ON_CONFLICT_ACTION_FAIL;}


////////////////////////  DROP TRIGGER statement //////////////////////////////
ddl_cmd ::= DROP TRIGGER ifexists(NOERR) fullname(X). {
  struct Token t = Token_nil;
  drop_trigger_def_init(&pParse->drop_trigger_def, X, &t, NOERR);
  pParse->initiateTTrans = true;
  sql_drop_trigger(pParse);
}

//////////////////////// ALTER TABLE table ... ////////////////////////////////
%include {
  struct alter_args {
    struct SrcList *table_name;
    /** Name of constraint OR new name of table in case of RENAME. */
    struct Token name;
  };
}

%type alter_table_start {struct SrcList *}
alter_table_start(A) ::= ALTER TABLE fullname(T) . { A = T; }

%type alter_add_constraint {struct alter_args}
alter_add_constraint(A) ::= alter_table_start(T) ADD CONSTRAINT nm(N). {
   A.table_name = T;
   A.name = N;
   pParse->initiateTTrans = true;
 }

%type alter_add_column {struct alter_args}
alter_add_column(A) ::= alter_table_start(T) ADD column_name(N). {
  A.table_name = T;
  A.name = N;
  pParse->initiateTTrans = true;
}

column_name(N) ::= COLUMN nm(A). { N = A; }
column_name(N) ::= nm(A). { N = A; }

ddl_cmd ::= alter_column_def carglist create_column_end.

alter_column_def ::= alter_add_column(N) typedef(Y). {
  create_column_def_init(&pParse->create_column_def, N.table_name, &N.name, &Y);
  create_ck_constraint_parse_def_init(&pParse->create_ck_constraint_parse_def);
  create_fk_constraint_parse_def_init(&pParse->create_fk_constraint_parse_def);
  sql_create_column_start(pParse);
}

ddl_cmd ::= alter_add_constraint(N) FOREIGN KEY LP eidlist(FA) RP REFERENCES
        nm(T) eidlist_opt(TA). {
  create_fk_def_init(&pParse->create_fk_def, N.table_name, &N.name, FA, &T, TA);
  sql_create_foreign_key(pParse);
}

ddl_cmd ::= alter_add_constraint(N) CHECK LP scanpt(A) expr(X) RP(Z). {
    create_ck_def_init(&pParse->create_ck_def, N.table_name, &N.name, X,
                       A, Z.z);
    sql_create_check_contraint(pParse, false);
}

ddl_cmd ::= alter_add_constraint(N) unique_spec(U) LP sortlist(X) RP. {
  create_index_def_init(&pParse->create_index_def, N.table_name, &N.name, X, U,
                        SORT_ORDER_ASC, false);
  sql_create_index(pParse);
}

%type unique_spec {int}
unique_spec(U) ::= UNIQUE.      { U = SQL_INDEX_TYPE_CONSTRAINT_UNIQUE; }
unique_spec(U) ::= PRIMARY KEY. { U = SQL_INDEX_TYPE_CONSTRAINT_PK; }

ddl_cmd ::= alter_table_start(A) RENAME TO nm(N). {
    rename_entity_def_init(&pParse->rename_entity_def, A, &N);
    pParse->initiateTTrans = true;
    sql_alter_table_rename(pParse);
}

ddl_cmd ::= ALTER TABLE fullname(X) DROP CONSTRAINT nm(Z). {
  drop_constraint_def_init(&pParse->drop_constraint_def, X, &Z, false);
  pParse->initiateTTrans = true;
  sql_drop_constraint(pParse);
}

//////////////////////// COMMON TABLE EXPRESSIONS ////////////////////////////
%type with {With*}
%type wqlist {With*}
%destructor with {sqlWithDelete($$);}
%destructor wqlist {sqlWithDelete($$);}

with(A) ::= . {A = 0;}
with(A) ::= WITH wqlist(W).              { A = W; }
with(A) ::= WITH RECURSIVE wqlist(W).    { A = W; }

wqlist(A) ::= nm(X) eidlist_opt(Y) AS LP select(Z) RP. {
  A = sqlWithAdd(pParse, 0, &X, Y, Z); /*A-overwrites-X*/
}
wqlist(A) ::= wqlist(A) COMMA nm(X) eidlist_opt(Y) AS LP select(Z) RP. {
  A = sqlWithAdd(pParse, A, &X, Y, Z);
}

////////////////////////////// TYPE DECLARATION ///////////////////////////////
%type typedef {struct type_def}
typedef(A) ::= TEXT . { A.type = FIELD_TYPE_STRING; }
typedef(A) ::= STRING_KW . { A.type = FIELD_TYPE_STRING; }
typedef(A) ::= SCALAR . { A.type = FIELD_TYPE_SCALAR; }
/** BOOL | BOOLEAN is not used due to possible bug in Lemon. */
typedef(A) ::= BOOL . { A.type = FIELD_TYPE_BOOLEAN; }
typedef(A) ::= BOOLEAN . { A.type = FIELD_TYPE_BOOLEAN; }
typedef(A) ::= VARBINARY . { A.type = FIELD_TYPE_VARBINARY; }
typedef(A) ::= UUID . { A.type = FIELD_TYPE_UUID; }
typedef(A) ::= JSON . { A.type = FIELD_TYPE_JSON; }
typedef(A) ::= ANY . { A.type = FIELD_TYPE_ANY; }
typedef(A) ::= ARRAY . { A.type = FIELD_TYPE_ARRAY; }
typedef(A) ::= MAP . { A.type = FIELD_TYPE_MAP; }
typedef(A) ::= DATETIME . { A.type = FIELD_TYPE_DATETIME; }
typedef(A) ::= INTERVAL . { A.type = FIELD_TYPE_INTERVAL; }

/**
 * Time-like types are temporary disabled, until they are
 * implemented as a native Tarantool types (gh-3694).
 *
 typedef(A) ::= DATE . { A.type = FIELD_TYPE_NUMBER; }
 typedef(A) ::= TIME . { A.type = FIELD_TYPE_NUMBER; }
 typedef(A) ::= DATETIME . { A.type = FIELD_TYPE_NUMBER; }
*/


char_len(A) ::= LP INTEGER(B) RP . {
  (void) A;
  (void) B;
}

%type char_len {int}
typedef(A) ::= VARCHAR char_len(B) . {
  A.type = FIELD_TYPE_STRING;
  (void) B;
}

%type number_typedef {struct type_def}
typedef(A) ::= number_typedef(A) .
number_typedef(A) ::= NUMBER . { A.type = FIELD_TYPE_NUMBER; }
number_typedef(A) ::= DOUBLE . { A.type = FIELD_TYPE_DOUBLE; }
number_typedef(A) ::= INT|INTEGER_KW . { A.type = FIELD_TYPE_INTEGER; }
number_typedef(A) ::= UNSIGNED . { A.type = FIELD_TYPE_UNSIGNED; }
number_typedef(A) ::= DECIMAL . { A.type = FIELD_TYPE_DECIMAL; }

/**
 * NUMERIC type is temporary disabled. To be enabled when
 * it will be implemented as native Tarantool type.
 *
 * %type number_len_typedef {struct type_def}
 * number_typedef(A) ::= DECIMAL|NUMERIC|NUM number_len_typedef(B) . {
 *   A.type = FIELD_TYPE_NUMBER;
 *   (void) B;
 * }
 *
 *
 * number_len_typedef(A) ::= . { (void) A; }
 * number_len_typedef(A) ::= LP INTEGER(B) RP . {
 *   (void) A;
 *   (void) B;
 * }
 *
 * number_len_typedef(A) ::= LP INTEGER(B) COMMA INTEGER(C) RP . {
 *   (void) A;
 *   (void) B;
 *   (void) C;
 *}
 */

//////////////////////// WINDOW FUNCTION EXPRESSIONS /////////////////////////
// These must be at the end of this file. Specifically, the rules that
// introduce tokens WINDOW, OVER and FILTER must appear last. This causes
// the integer values assigned to these tokens to be larger than all other
// tokens that may be output by the tokenizer except TK_SPACE, TK_LINEFEED and
// TK_ILLEGAL.
//
%type windowdefn_list {Window*}
%destructor windowdefn_list {sqlWindowListDelete($$);}
windowdefn_list(A) ::= windowdefn(Z). { A = Z; }
windowdefn_list(A) ::= windowdefn_list(Y) COMMA windowdefn(Z). {
  assert (Z != 0);
  sqlWindowChain(pParse, Z, Y);
  Z->pNextWin = Y;
  A = Z;
}

%type windowdefn {Window*}
%destructor windowdefn {sqlWindowDelete($$);}
windowdefn(A) ::= nm(X) AS LP window(Y) RP. {
  if (ALWAYS(Y)) {
    Y->zName = sql_name_from_token(&X);
  }
  A = Y;
}

%type window {Window*}
%destructor window {sqlWindowDelete($$);}
window(A) ::= PARTITION BY nexprlist(X) orderby_opt(Y) frame_opt(Z). {
  A = sqlWindowAssemble(Z, X, Y, 0);
}
window(A) ::= nm(W) PARTITION BY nexprlist(X) orderby_opt(Y) frame_opt(Z). {
  A = sqlWindowAssemble(Z, X, Y, &W);
}
window(A) ::= ORDER BY sortlist(Y) frame_opt(Z). {
  A = sqlWindowAssemble(Z, 0, Y, 0);
}
window(A) ::= nm(W) ORDER BY sortlist(Y) frame_opt(Z). {
  A = sqlWindowAssemble(Z, 0, Y, &W);
}
window(A) ::= frame_opt(Z). {
  A = Z;
}

%type part_opt {ExprList*}
%destructor part_opt {sql_expr_list_delete($$);}
window(A) ::= nm(W) frame_opt(Z). {
  A = sqlWindowAssemble(Z, 0, 0, &W);
}

%type frame_opt {Window*}
%destructor frame_opt {sqlWindowDelete($$);}
frame_opt(A) ::= .                             {
  A = sqlWindowAlloc(pParse, 0, TK_UNBOUNDED, 0, TK_CURRENT, 0);
}
frame_opt(A) ::= range_or_rows(X) frame_bound_s(Y). {
  A = sqlWindowAlloc(pParse, X, Y.eType, Y.pExpr, TK_CURRENT, 0);
}
frame_opt(A) ::= range_or_rows(X) BETWEEN frame_bound_s(Y) AND frame_bound_e(Z). {
  A = sqlWindowAlloc(pParse, X, Y.eType, Y.pExpr, Z.eType, Z.pExpr);
}

%type range_or_rows {int}
range_or_rows(A) ::= RANGE.   { A = TK_RANGE; }
range_or_rows(A) ::= ROWS.    { A = TK_ROWS;  }

%type frame_bound {struct FrameBound}
%destructor frame_bound {sql_expr_delete($$.pExpr);}
frame_bound(A) ::= expr(X) PRECEDING(Y). { A.eType = @Y; A.pExpr = X; }
frame_bound(A) ::= expr(X) FOLLOWING(Y). { A.eType = @Y; A.pExpr = X; }
frame_bound(A) ::= CURRENT(Y) ROW.       { A.eType = @Y; A.pExpr = 0; }

%type frame_bound_s {struct FrameBound}
%destructor frame_bound_s {sql_expr_delete($$.pExpr);}
frame_bound_s(A) ::= UNBOUNDED(Y) PRECEDING. { A.eType = @Y; A.pExpr = 0; }
frame_bound_s(A) ::= frame_bound(Z).         { A = Z; }

%type frame_bound_e {struct FrameBound}
%destructor frame_bound_e {sql_expr_delete($$.pExpr);}
frame_bound_e(A) ::= UNBOUNDED(Y) FOLLOWING. { A.eType = @Y; A.pExpr = 0; }
frame_bound_e(A) ::= frame_bound(Z).         { A = Z; }

%type windowdefn_opt {Window*}
%destructor windowdefn_opt {sqlWindowListDelete($$);}
windowdefn_opt(A) ::= . { A = 0; }
windowdefn_opt(A) ::= WINDOW windowdefn_list(B). { A = B; }

%type over_opt {Window*}
%destructor over_opt {sqlWindowDelete($$);}
over_opt(A) ::= . { A = 0; }
over_opt(A) ::= filter_opt(W) OVER LP window(Z) RP. {
  A = Z;
  assert (A != 0);
  A->pFilter = W;
}

over_opt(A) ::= filter_opt(W) OVER nm(Z). {
  A = (Window *)sql_xmalloc0(sizeof(Window));
  if (A) {
    A->zName = sql_name_from_token(&Z);
    A->pFilter = W;
  } else {
    sql_expr_delete(W);
  }
}

%type filter_opt {Expr*}
%destructor filter_opt {sql_expr_delete($$);}
filter_opt(A) ::= .                            { A = 0; }
filter_opt(A) ::= FILTER LP WHERE expr(X) RP.  { A = X; }

//////////////////////// EXPLAIN (facet, ...) /////////////////////////////
//
// These rules are at the end of the file: Lemon numbers the tokens in the
// order they first appear, and some opcodes depend on these numbers.
//
explain ::= EXPLAIN LP explain_facets RP. {
  pParse->explain = EXPLAIN_MODE_PROGRAM;
  sql_explain_check_facets(pParse);
}
explain ::= EXPLAIN ANALYZE. {
  pParse->explain = EXPLAIN_MODE_PROGRAM;
  pParse->explain_opts.facets = EXPLAIN_FACET_ANALYZE |
                                EXPLAIN_FACET_PSEUDOCODE;
}
explain_facets ::= explain_facet.
explain_facets ::= explain_facets COMMA explain_facet.
explain_facet ::= nm(X). { sql_explain_add_facet(pParse, &X, false); }
// ANALYZE is a reserved keyword, so it is not an nm.
explain_facet ::= ANALYZE(X). { sql_explain_add_facet(pParse, &X, false); }
explain_facet ::= nm(X) LB explain_lines RB. {
  sql_explain_add_facet(pParse, &X, true);
}
explain_facet ::= nm(X) LB RB. { sql_explain_add_facet(pParse, &X, true); }
explain_lines ::= explain_line.
explain_lines ::= explain_lines COMMA explain_line.
explain_line ::= INTEGER(X). { sql_explain_add_line(pParse, &X); }
// The options of ANALYZE have the syntax of a map: {'freq': 99}. A number
// with a minus sign is in the grammar to report it with a clear error.
// The value of an option can be a list of strings: {'mode': ['hits']}.
explain_facet ::= ANALYZE(X) LCB explain_options RCB. {
  sql_explain_add_facet(pParse, &X, false);
}
explain_options ::= .
explain_options ::= explain_option_list.
explain_option_list ::= explain_option.
explain_option_list ::= explain_option_list COMMA explain_option.
explain_option ::= STRING(X) COLON
                   INTEGER|FLOAT|DECIMAL|STRING|TRUE|FALSE(Y). {
  sql_explain_set_option(pParse, &X, &Y, @Y, false);
}
explain_option ::= STRING(X) COLON MINUS INTEGER|FLOAT|DECIMAL(Y). {
  sql_explain_set_option(pParse, &X, &Y, @Y, true);
}
explain_option ::= explain_option_list_start explain_option_items RB.
explain_option_list_start ::= STRING(X) COLON LB. {
  sql_explain_begin_option_list(pParse, &X);
}
explain_option_items ::= explain_option_item.
explain_option_items ::= explain_option_items COMMA explain_option_item.
explain_option_item ::= STRING(X). {
  sql_explain_add_option_item(pParse, &X);
}
// A list after ANALYZE is the list of its modes: (analyze ['hits']) is
// (analyze {'mode': ['hits']}).
explain_facet ::= explain_modes_start explain_option_items RB.
explain_modes_start ::= ANALYZE(X) LB. {
  sql_explain_add_facet(pParse, &X, false);
  sql_explain_begin_option_list(pParse, NULL);
}
