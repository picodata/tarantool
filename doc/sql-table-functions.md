# SQL table functions

A table function turns a value into rows that a SQL query can read in `FROM`.
You can filter these rows, join them with tables, or use them in a subquery,
CTE, or view.

Picodata system tables contain a lot of JSON. To build a PostgreSQL-compatible
system catalog, views need to turn JSON arrays and objects into rows and join
them with other data. Table functions provide these building blocks. The
catalog views themselves are separate work.

SQL prepares a table function in three steps: resolve its arguments, determine
its output columns, and estimate its row count. At runtime, a cursor reads
rows from an iterator. The iterator does not collect the whole result in
memory, so a large range can be read with `LIMIT`.

## Functions and result rows

| Call | Result |
|---|---|
| `GENERATE_SERIES(start, stop)` | `VALUE`, a range with a step of 1 |
| `GENERATE_SERIES(start, stop, step)` | `VALUE`, a range with a step |
| `UNNEST(array)` | `VALUE`, elements of a SQL or JSON array |
| `JSON_EACH(object)` | `KEY STRING`, `VALUE JSON`, pairs from a JSON object |

`GENERATE_SERIES` gives an `INTEGER` or a `DECIMAL` series. An `INTEGER`
series takes two integers that fit in `int64` and includes both bounds. For
example, `(1, 3)` gives `1, 2, 3`, and `(3, 1)` gives no rows. A range
containing only `INT64_MAX` returns that value without overflowing.

If an argument has the `DECIMAL` type, the result is a `DECIMAL` series. It
starts at `start` and adds 1 while the value is not greater than `stop`. For
example, `(1.5, 4)` gives `1.5, 2.5, 3.5`, and `(1, 2.5)` gives `1, 2` as
`DECIMAL` values. The first value has the scale of `start`. Each next value
is a sum, as for `+`, with the larger of the scales of the previous value and
the step: `(1.50, 3)` gives `1.50, 2.50`, and `(0, 1, 0.25)` gives
`0, 0.25, 0.50, 0.75, 1.00`. A series that reaches the largest `DECIMAL` value
ends there without an error.

With a third argument, each value is the previous one plus `step`. The series
includes `stop` only if a step gives exactly that value: `(1, 10, 3)` gives
`1, 4, 7, 10`, and `(1, 9, 3)` gives `1, 4, 7`. A negative step gives a series
that decreases to `stop`: `(10, 1, -3)` gives `10, 7, 4, 1`. If the step goes
away from `stop`, the series is empty. A zero step is an error. A series that
reaches a limit of its type ends there without an error.

A step that does not change a value of the series is an error when the series
needs the next value. A `DECIMAL` step that is too small for the precision of
the value has this effect: `GENERATE_SERIES(1.0, 2, 1e-38)`, with the step
written as a decimal literal, gives the row `1.0` and then the error.

A `DECIMAL` value has no more than 38 digits. If the sum of a value and the
step needs more digits, it is rounded, as the result of `+` is. The series
continues from the rounded value, so the difference of two adjacent values can
then be different from the step, and the series can have fewer values than
the bounds and the step give. For example, from
`9999999999999999999999999999999999990.5` with a step of `0.25` the next
values end with `990.8` and `991.1`. There is no error in this case.

`UNNEST` reads the top-level elements in array order. It does not recursively
expand nested arrays or objects: `[[1], [2]]` produces two array values.
`JSON_EACH` reads the top-level key-value pairs of a JSON object. A SQL `MAP`
requires an explicit `CAST(... AS JSON)` before passing it to `JSON_EACH`.
Wrong container types and scalar arguments produce a SQL type error.

The final query result follows the usual SQL ordering rules. Use `ORDER BY`
when its order matters, including when reading a JSON object.

`WITH ORDINALITY` adds an `ORDINALITY UNSIGNED` column. It numbers the
iterator's rows from 1 before filtering and starts over whenever the iterator
opens:

```sql
SELECT * FROM UNNEST([10, 20]) WITH ORDINALITY WHERE VALUE = 20;
-- VALUE = 20, ORDINALITY = 2
```

If an empty result is on the right of a `LEFT JOIN`, the left row is kept.
All function columns, including `ORDINALITY`, are then SQL `NULL`.

### Empty results and NULL

An empty container produces no rows. SQL `NULL` as an argument also produces
no rows if the other arguments have valid types. For example,
`GENERATE_SERIES(NULL, 1)`, `(1, NULL)`, and `(NULL, NULL)` are empty.

Type errors take precedence over an empty result caused by SQL `NULL`:
`GENERATE_SERIES(NULL, 'x')` and `GENERATE_SERIES('x', NULL)` both fail.
Errors while evaluating an argument are also preserved. The function checks
the types of non-NULL values before deciding that SQL `NULL` makes it empty.

`GENERATE_SERIES` checks and casts its arguments as a built-in scalar function
does. The types of the arguments at the preparation of the statement select
the type of the series:

- With a `DECIMAL` argument, the arguments are cast to `DECIMAL`. An
  `INTEGER` or a `DOUBLE` value is cast: `GENERATE_SERIES(1.5, 25e-1)` gives
  `1.5, 2.5`. A `DECIMAL` step makes a `DECIMAL` series too:
  `GENERATE_SERIES(0, 1, 0.5)` gives `0, 0.5, 1.0`.
- In all other cases, the arguments are cast to `INTEGER`. A `DOUBLE` value
  with an exact integer value is cast: `GENERATE_SERIES(1e0, 3)` gives three
  rows. The bounds and the step must be in the range of a signed 64-bit
  integer.

A bound parameter has no type at the preparation, so it does not select
a `DECIMAL` series: `GENERATE_SERIES(?, ?)` is an `INTEGER` series for all
values. Use `CAST(? AS DECIMAL)` for one of the arguments to get a `DECIMAL`
series.

A type that cannot be a number, such as `STRING`, is an error when the
statement is prepared. A value whose type is known only at execution, such as
a bound parameter, gives a type mismatch then.

JSON `null` is a JSON value, not SQL `NULL`. It is invalid where an array or
object is required, but remains a value when read from a container.
`COUNT(VALUE)` counts JSON `null` and skips SQL `NULL`:

| Argument to `UNNEST` | `COUNT(*)` | `COUNT(VALUE)` |
|---|---:|---:|
| SQL `NULL` or `[]` | 0 | 0 |
| `[NULL]` | 1 | 0 |
| `[1, NULL]` | 2 | 1 |
| SQL array with SQL `NULL` and JSON `null` | 2 | 1 |
| JSON array `[1, null]` | 2 | 2 |

## Names, aliases, and views

In `FROM`, a name followed by a parenthesized argument list always means a
table function. A name without parentheses means a table, view, or CTE. A table or
CTE named `UNNEST` does not hide `UNNEST(...)`. This also applies to
`INSERT ... SELECT` and calls inside a CTE with the same name: such a call
does not make the CTE recursive.

An unknown function, a wrong argument count, or a table function used as a
scalar expression is rejected when preparing the query.

Parentheses around a source preserve the call, its alias, and ordinality:

```sql
SELECT u.VALUE AS x FROM (UNNEST([1]) WITH ORDINALITY) AS u;
```

Output aliases such as `AS x` and CTE column lists such as `WITH c(x)` work as
usual. Renaming columns with a source alias, as in `AS u(x)`, is not supported.

A view can read table functions. Its dependencies include actual tables,
including those used by subqueries in function arguments. Those tables cannot
be dropped while the view exists. A call to `UNNEST(...)` creates no dependency
on a table named `UNNEST`; creating or dropping the view does not change that
table's reference count.

Table functions can be read with `sql_seq_scan = false`, without `SEQSCAN`:
their rows are only available through an iterator. The setting still applies
to ordinary tables in the same query.

## Which sources arguments can read

Arguments can read sources to their left in the same `FROM`: tables, views,
CTEs, subqueries, and other table functions. Sources are resolved from left
to right, so one function's result is available to the next:

```sql
SELECT a.VALUE, b.VALUE
FROM UNNEST([1, 2]) a, UNNEST([a.VALUE]) b;
-- (1, 1), (2, 2)
```

Arguments cannot read a source to the right, the function's own result, or a
`SELECT` output alias. An output alias is unavailable even if it stands for a
constant. Aggregate and window expressions at the current query level are
also rejected.

A function in a subquery can read the columns of an outer `SELECT`, as any
expression of a correlated subquery can. The function starts again for each
outer row:

```sql
SELECT t.id FROM t WHERE EXISTS (SELECT 1 FROM UNNEST(t.arr));
```

The output aliases of an outer `SELECT` are not visible.

An independent subquery is allowed: `UNNEST((SELECT [1, 2]))`. A subquery
inside an argument cannot read rows outside that subquery. For example,
`FROM t, UNNEST(t.a)` is valid, but `FROM t, UNNEST((SELECT t.a))` is not.

Parentheses around a join do not create a new scope for arguments. In
`FROM t, (UNNEST(t.a) u JOIN x ON true)`, the function can read the current
row of `t`. The group runs again when that row changes. The same rule applies
to a group on the right of a `LEFT JOIN`.

Simple dependent join groups return rows as the outer query requests them.
For example, this query stops after the first row `(1, 1, 10)` without
storing the group's full result in a temporary table:

```sql
SELECT a.VALUE, b.VALUE, c.VALUE
FROM GENERATE_SERIES(1, 1) a,
     (GENERATE_SERIES(1, 100000 + a.VALUE) b
      JOIN UNNEST([10]) c ON true)
LIMIT 1;
```

An outer filter may require more rows before `LIMIT` is satisfied. Sorting,
aggregation, and other operations that need the entire input still read it.

This access to sources on the left belongs only to table function arguments.
It does not extend the scope of `ON` conditions or explicit subqueries inside
the group. In particular, parentheses do not turn an ordinary subquery into a
`LATERAL` subquery.

## When arguments are evaluated

A call is dependent if any argument reads a source to its left. Otherwise,
it is independent. This distinction applies to the whole call, not individual
arguments.

For an independent call, arguments are evaluated once each time the explicit
`SELECT` containing it is entered. A top-level `SELECT` is entered once per
query execution; a correlated inner `SELECT` can be entered for each outer
row. Reopening the function's iterator uses the saved arguments and reads its
rows again. The rows themselves are not cached by the function cursor.

Grouping parentheses do not create another entry. For example, an independent
`UNNEST([counter()])` next to a dependent `GENERATE_SERIES(1, t.n)` keeps its
saved argument while the group runs for different rows of `t`. Adding or
removing parentheses, including on the right of `LEFT JOIN`, does not add
calls to `counter()`.

For a dependent call, all arguments are evaluated whenever its cursor opens.
In `GENERATE_SERIES(counter(), t.n)`, this includes `counter()`, even though
that expression does not read `t`. Independent parts of a dependent call are
not saved separately.

The plan determines how many times a dependent cursor opens. There is no
fixed number of evaluations per source row. If an argument returns a new
value on each evaluation, the query's result can depend on the plan too.

An independent subquery inside an argument uses the normal SQL cache for one
execution of the query program (`Vdbe`). Evaluating an argument can therefore
reuse the subquery's result. For a correlated `SELECT` entered for three outer
rows, `UNNEST([counter()])` calls the counter three times, while
`UNNEST([(SELECT counter())])` calls it once. Running the `Vdbe` again resets
this cache and evaluates the subquery again.

## UNNEST result type

`UNNEST` preserves SQL values without JSON wrapping, automatic numeric casts,
or a check that every element has the same type. A broad output type describes
the original values; it does not convert them.

For an array constructor, SQL uses the known types of its element expressions
to choose the first matching rule:

| Elements | `VALUE` type |
|---|---|
| One specific type | That type |
| `INTEGER` and `UNSIGNED` | `INTEGER` |
| Different numeric types | `NUMBER` |
| Different types that fit in `SCALAR` | `SCALAR` |
| Other combinations or an unknown type | `ANY` |

The first rule includes `ARRAY`, `MAP`, `JSON`, `UUID`, `DATETIME`, and
`INTERVAL`. For example, `[1, 2]` gives `INTEGER`, `[1, 1.5]` and `[1, 2e0]`
give `NUMBER`, `[1, 'x']` gives `SCALAR`, and `[1, [2]]` gives `ANY`.

An untyped `NULL` does not widen the type: `[NULL, 1]` gives `INTEGER`.
An empty array or one containing only untyped `NULL` values gives `ANY`.
A typed NULL does count: `[CAST(NULL AS DOUBLE)]` gives `DOUBLE`.

A statically known JSON argument gives `JSON`. An `ARRAY` column or an
expression with unknown element types gives `ANY`. A parameter also gives
`ANY`, whether it supplies the whole array or an element. This applies to
`?`, `:a`, `$1`, `@a`, and `#a`, including under unary `+` or `-`.
An explicit `CAST` keeps its specified type: `UNNEST([-@a])` gives `ANY`, but
`UNNEST([-CAST(@a AS INTEGER)])` gives `INTEGER`.

If the type of a column from a CTE, view, or subquery to the left is not yet
known, the result can be `ANY`. SQL does not change the order of type inference
for these sources. Cast the element to set its type explicitly:
`UNNEST([CAST(s.a AS INTEGER)])`.

The type is fixed when SQL prepares the query, without reading data or bound
parameters. Reusing a `Vdbe` with different arrays preserves its column
metadata, including through `net.box`. For example, `UNNEST(?)` stays `ANY`
when the parameter changes from an array of numbers to an array of strings.
Each call has its own type: `UNNEST([1])` and `UNNEST(['x'])` can have
`INTEGER` and `STRING` columns in the same query.

`CASE`, `COALESCE`, and `IFNULL` use their ordinary SQL expression metadata;
their branches are not analyzed separately. That metadata can differ from
the actual numeric value. For example, `UNNEST([COALESCE(1.5, 2e0)])` has
`DOUBLE` metadata, but `COALESCE` produces a decimal. Reading it produces a
normal SQL type error, not an internal assertion failure. Use an explicit
cast before `UNNEST` to resolve the mismatch:
`UNNEST([CAST(COALESCE(1.5, 2e0) AS NUMBER)])`.

### Values in temporary tables

Materialization means storing a query's rows in a temporary table. Existing
format rules still apply: an `ANY` column can receive a `SCALAR` format,
which rejects nested arrays and objects. Such a query can fail even though
the function itself can return those values.

Cast the value in the inner query, before it is stored. A cast in the outer
query is too late. For example:

```sql
SELECT ALL s.v
FROM (SELECT CAST(VALUE AS ARRAY) v, ORDINALITY n
      FROM UNNEST(CAST([[1], [2]] AS ARRAY)) WITH ORDINALITY LIMIT 2) s,
     GENERATE_SERIES(1, 1) g
ORDER BY s.n;
```

The same approach works for `MAP`, `JSON`, and specific scalar types, including
in CTEs and views. Existing limits on comparison, grouping, and `UNION` also
apply to function results.

## Implementation

### Registry and call schemas

The C interface is defined in [table_func.h](../src/box/sql/table_func.h).
A definition contains the function name, argument count, output fields, and
five required methods. Registration checks that every method is present.

| Method | Contract |
|---|---|
| `resolve_schema` | Sets types and nullability from argument expressions |
| `estimate_rows` | Returns a `uint64_t` without evaluating expressions |
| `open` | Takes a MessagePack argument array; returns state in `ctx` |
| `next` | Returns a MessagePack row array; `row == NULL` marks the end |
| `close` | Frees the state after a successful `open` |

The registry is filled at process startup and then closed to changes.
Definitions must outlive all SQL queries. No registry version or cache
invalidation is needed: a restart also discards every old `Vdbe`.

Compiling SQL creates a `Vdbe`, the instruction program that runs the query.
For each function call, it owns a separate schema: column names, types, and
whether SQL `NULL` is allowed. The cursor refers to that schema. Resolving
one call does not change the shared function definition, and the schema is
freed with the `Vdbe`.

`UNNEST` uses `field_type1_contains_type2()` to find the narrowest type that
contains the element types. The ordinary `sql_expr_list_type()` helper is
not suitable here: it chooses `DOUBLE` for `DECIMAL` mixed with `DOUBLE`,
while preserving both values requires `NUMBER`.

### Parsing and name resolution

Each `FROM` source has a `SrcItem` in the query tree. For a table function it
stores the call arguments, alias, `isTabFunc` flag, and ordinality flag.
When removing grouping parentheses rebuilds a `SrcItem`, these fields must
survive. The flag also keeps function calls out of recursive CTE detection
and the direct table-copy optimization for `INSERT ... SELECT`.

Arguments use a separate chain of name contexts (`NameContext`). It contains
the preceding sources in the current `FROM` and any enclosing join groups.
At an explicit `SELECT` it continues with the name contexts of the outer
queries, with their output aliases hidden. A column of an outer query does
not make the call depend on the sources of the current `FROM`.
After resolving arguments, SQL resolves the call's schema and exposes its
columns to later sources.

The parser can represent a parenthesized join as a generated `SELECT` marked
`SF_NestedFrom`. This is an implementation detail, not a new SQL scope or a
new entry for argument evaluation. A group that reads sources in the parent
`FROM` must run for their current rows. Independent arguments inside it are
saved outside the group's restart path.

The same query tree can be compiled into several places in a `Vdbe`, for
example in separate index scans for an `OR` condition. Each generated entry
must initialize the saved argument registers it uses. Copying a register
number without its initialization is unsafe: the first branch may find no
rows and never run. Reused group subroutines need the same guarantee, also
when executing the `Vdbe` again.

A correlated `SF_NestedFrom` group, including one that reads sources through
several enclosing groups, gets its own body in each of these places. That
body uses the cursors of its calling branch.

### Planning without changing behavior

The planner records which left sources a call depends on. It cannot move the
call before those sources. Several other optimizations need restrictions to
preserve argument values, calls, and errors:

- A subquery whose columns are used in function arguments is not flattened.
  Flattening means replacing a source with its expressions in the outer
  query. For `(SELECT next_n() AS n FROM t) s, GENERATE_SERIES(1, s.n)`,
  `s.n` must remain a row value. Substituting `next_n()` could make the
  generator appear independent and change the number of evaluations.
- No automatic indexes are built directly on table functions. An index built
  once could retain rows for old arguments when a left source moves on.
- Removing an unused right side of a `LEFT JOIN` under `DISTINCT` must keep
  table function calls. For example, selecting only `t.id` still reports
  the argument error in `t LEFT JOIN UNNEST(1) u ON true`. The same applies
  to functions inside dependent join groups, including nested groups;
  checking only the outer source's `isTabFunc` flag is not enough.
- An `OR` condition may read a left table through different indexes in
  separate scans. Replacing table reads with index reads must stay within
  the instructions for that scan, including its own copy of a correlated
  group's body.

These rules preserve existing behavior for ordinary subqueries. A subquery
that depends only on an outer `SELECT` does not need to be materialized again
when an unrelated source beside it advances. That outer dependency alone
also does not prevent flattening a parenthesized join. The planner must
distinguish it from a dependency on sources in the current `FROM`.

A dependent `SF_NestedFrom` group runs as a coroutine, even inside another
loop and under `SELECT ALL`. Each entry of that loop restarts the coroutine
for the current left row. Its output lives in registers, so `LEFT JOIN` sets
them to SQL `NULL` for an unmatched row.

### Row estimates

Every function supplies a row estimate for one iterator run, before filters.
There is no separate flag for an exact estimate. Preparing or explaining a
query does not evaluate arguments, open iterators, or read data for estimates.

An array constructor's length is known without evaluating its elements:
`[t.a, t.b]` has two elements. A range size is calculated for integer and
decimal literals, including their sign and a literal step. When the size is
unknown, the estimate is 100 rows for `UNNEST` and `JSON_EACH`, and 1000 for
`GENERATE_SERIES`. Even a constant JSON `CAST` uses the default estimate,
since the cast is not evaluated at this stage.

```sql
EXPLAIN QUERY PLAN SELECT * FROM GENERATE_SERIES(1, 2);
-- SCAN TABLE GENERATE_SERIES (~2 rows)
EXPLAIN QUERY PLAN SELECT * FROM UNNEST(CAST('[1,2,3]' AS JSON));
-- SCAN TABLE UNNEST (~96 rows)
```

The plan shows a rounded estimate. A known empty result has an estimate of
zero; logarithmic cost calculations use at least one. Counts too large for
`uint64_t` are capped at its maximum without overflowing.

An estimate guides plan selection, not execution. Zero does not allow the
function to be skipped, and one is not a guarantee of at most one row. A full
scan still returns every row or reports the iterator's error. Preparation
does not invoke a user function in an argument or suppress its runtime error.

### Iterators and memory ownership

The cursor owns the iterator state, current row, and row number. It passes
`open` a copy of the evaluated arguments as a trusted MessagePack array.
Those bytes remain valid until `close`. Saved arguments for an independent
call live across cursor restarts until the explicit `SELECT` finishes.

When opened, `UNNEST` checks the argument count, SQL type, and container kind
without walking the whole array. Reading and copying the argument still
depend on its size, so `LIMIT 1` does not imply constant time for the whole
query.

`open` and `next` return 0 on success, or -1 with an error in the diagnostics
area on failure. If `open` fails, it frees any partially created state and
leaves `ctx` NULL. The cursor calls `close` only after a successful `open`.

`next` returns one MessagePack array matching the call's output fields. Its
buffer stays valid until the next `next` or `close`; the cursor copies it
before further processing. Incompatible field values produce SQL type errors.
The cursor adds `ORDINALITY`, so the iterator does not include it in the row.

SQL array elements are copied unchanged. JSON subtrees are wrapped through
`json_norm` without normalizing them again: a subtree of normalized JSON is
already normalized. The trust rules are described in
[JSON perimeter](json-perimeter.md#table-function-iterators).

Reopening closes the previous iterator and resets the row number. Normal
completion, `LIMIT`, cancellation, and errors release the remaining state
and buffers. A later query must work normally after any of these exits.
Iterator memory depends on the arguments and current row, not the total
number of rows produced. The surrounding SQL plan can still use temporary
tables where ordinary query execution requires them.

## EXPLAIN and execution counters

EXPLAIN ANALYZE can show instruction names, pseudocode, a jump
graph, and exact execution counts together:

```sql
EXPLAIN (analyze {'mode': 'hits', 'round': false},
         graph, opcode, pseudocode)
SELECT * FROM GENERATE_SERIES(1, 3);
```

`TFuncOpen` creates the cursor and saves its arguments. `TFuncRewind` calls
the iterator's `open` method and reads its first row; `TFuncNext` asks for
another row. Pseudocode describes both reads and their conditional jumps.
The loop body is indented, including nested loops of table functions.

For one execution, the counts are:

| Query | `TFuncRewind` | `TFuncNext` | `ResultRow` |
|---|---:|---:|---:|
| All three rows | 1 | 3 | 3 |
| The same query with `LIMIT 1` | 1 | 0 | 1 |
| An empty range | 1 | 0 | 0 |

`hits` counts instruction executions. The final `TFuncNext` of a full scan
detects the end of the range; it does not produce a row. A zero `TFuncNext`
count does not mean that obtaining the first row was cheap: work inside
`TFuncRewind`, argument evaluation, and copying have already happened.

`runs` adds the counts of its executions. For example, `runs: 3` with
`LIMIT 1` gives `3`, `0`, `3`. Executing the same prepared EXPLAIN again
starts new counts. `round: false` keeps exact values. The graph shows static
jumps; the hits of a conditional instruction are not taken-edge counts.

CPU `samples` are statistical observations inside an instruction and its
callees, not an exact duration or a breakdown of those callees. They require
Linux with `ENABLE_BACKTRACE`; elsewhere sample values are `NULL`, which does
not mean zero CPU cost.

## Scope and limits

The names of the table functions are case-sensitive, as the names of the
built-in scalar functions are: `unnest` and `UNNEST` find the function, and
`"unnest"` does not. The names are not reserved. A user function can have the
name of a table function; SQL calls it in an expression, and the `FROM` clause
uses the table function. No data migration is needed.

This feature uses existing SQL and JSON types. It does not introduce typed
arrays such as `ARRAY<T>`, enforce homogeneous arrays, or add public
registration of user-defined table functions. Full `LATERAL`, correlated
subqueries in arguments, and multi-array `UNNEST` are outside its scope. JSON
string conversion and string extraction keep their existing rules. Cache
invalidation when replacing a scalar function used in an argument is also a
separate concern.

Filters are not pushed into the generator, and its natural order is not
used to eliminate an `ORDER BY`, so a full scan or sort in such a plan is
expected.
