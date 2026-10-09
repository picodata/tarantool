# SQL skip-scan

Skip-scan lets SQL search a composite TREE index by its later parts, even when
the query says nothing about the first ones. You turn it on per query with
`INDEXED BY`.

## The problem

A composite index keeps rows sorted by its first part, then by the second, and
so on. In an index on `(bucket, k)`, rows with the same `bucket` sit together:

```text
bucket=1: k=2, 5, 9
bucket=2: k=1, 3, 5
bucket=3: k=2, 8
```

For `bucket = 2 AND k = 5` the index jumps straight to the row. For `k = 5`
alone it cannot: the matches are spread over every `bucket` group. Without
skip-scan SQL reads the whole index, or the whole table, and checks `k` on
every row.

## The idea

Instead of reading every row, skip-scan visits the groups one by one:

1. Find the first group and read its `bucket`.
2. Search for `k = 5` inside that group and return the matches.
3. Jump to the next `bucket` value and repeat.

Rows with the wrong `k` are skipped rather than read. This pays off when there
are few groups and many rows in each. When most groups hold one row, a search
per group is more work than a plain scan.

## Turning it on

Name the index with `INDEXED BY`:

```sql
CREATE INDEX bucket_k ON t (bucket, k);
SELECT * FROM t INDEXED BY bucket_k WHERE k = 5;
```

Without `INDEXED BY` the planner never picks skip-scan, so existing queries are
not affected. Removing `INDEXED BY` turns it off for that query.

## Which parts are skipped

Take an index on `(tenant, bucket, k)` and the condition
`tenant = 7 AND k = 5`. The index parts split into three roles:

| Part | Role |
| --- | --- |
| `tenant` | Fixed prefix: known from the query, `tenant = 7`. |
| `bucket` | Skipped block: every value is visited. |
| `k` | Suffix: searched inside each group, `k = 5`. |

The search walks the groups `(7, 1)`, `(7, 2)` and so on, and never leaves
`tenant = 7`. The rules are:

- The skipped block either starts at the first index part or right after a
  fixed prefix.
- The block may span several parts. Then every distinct combination of their
  values is visited.
- The block must be followed by a search condition: an equality or a range.
- There is only one block. For an index on `(a, b, c, d, e)` and
  `c = 5 AND e = 9`, skip-scan visits every `(a, b)`, searches for `c = 5`,
  and checks `e = 9` on the rows it finds.

## How the plan is chosen

With `INDEXED BY`, SQL must use the named index for a search if it can:

| What the index can do | Plan |
| --- | --- |
| Only a skip-scan search | Skip-scan. |
| A normal search and a skip-scan | The cheaper one by cost estimate. |
| No search at all | A full scan of the named index. |

A normal search is one over the leading parts, for example a range such as
`bucket > 10`. A full scan is never compared with a search: if any search is
possible, a search is used.

In a join, a condition such as `t.k = u.x` can drive a search only when `u` is
read before `t`. If the planner reads `t` first, the value is not yet known,
and that join order falls back to a full scan.

`sql_seq_scan = false` forbids full scans but not skip-scan, so a skip-scan
query still runs with this setting.

## Seeing it in the plan

`EXPLAIN QUERY PLAN` shows skip-scan as `SEARCH`, with `ANY(...)` around each
skipped part (row estimates omitted):

```text
SELECT * FROM t INDEXED BY bucket_k WHERE k = 5
SEARCH TABLE T USING COVERING INDEX BUCKET_K (ANY(BUCKET) AND K=?)

SELECT * FROM t INDEXED BY tenant_bucket_k WHERE tenant = 7 AND k = 5
SEARCH TABLE T USING COVERING INDEX TENANT_BUCKET_K (TENANT=? AND ANY(BUCKET) AND K=?)

SELECT * FROM f INDEXED BY abcde WHERE c = 5 AND e = 9
SEARCH TABLE F USING COVERING INDEX ABCDE (ANY(A) AND ANY(B) AND C=?)
```

`ANY(BUCKET)` means "every value of `bucket` is visited". A condition that is
only checked on found rows, such as `e = 9` above, does not appear in the
search key.

## IN lists

For `k IN (5, 9)` there are two ways to walk:

- **Inside each group:** search for 5 and then 9 in a group, then move on.
  The groups are walked once.
- **Outside the groups:** walk all groups looking for 5, then walk them again
  for 9.

A constant list, or a subquery that does not depend on the outer row, is
walked inside each group when its values come in index order. Other lists are
walked outside: lists of pairs such as `(tenant, k) IN (...)`, lists rebuilt
for every outer row, and lists in a different order. The cost estimate counts
the extra walks, so with a long outer list a normal search may win.

An `IN` whose comparison rules differ from the index, for example
`COLLATE "unicode_ci"` over a binary index, is not used for the search at all.
It stays a filter, so no matching rows are lost.

## Cheap moves

Each new index search costs an iterator and a lookup of the start position.
When the next target is close to the current position, a few steps forward
are cheaper. So before a new search the cursor checks the current row and
takes up to 8 steps. If that misses, it does a real search and stops trying
steps for a while. The pause grows after each miss, up to 63 searches, and
resets after a successful step. Results are the same either way.

## Limits

- Only TREE indexes. Indexes with `exclude_null` are not used for skip-scan,
  and `INDEXED BY` refuses indexes with functional parts, JSON paths or
  multikey parts. The skipped parts must be fields declared in the space
  format.
- No automatic choice: skip-scan needs `INDEXED BY`, and there are no new
  statistics behind the cost estimate.
- One skipped block per search.
- A range on a skipped part only filters. If skip-scan wins for
  `bucket > 10 AND k = 5`, it still visits every `bucket` and drops the rows
  with `bucket <= 10` afterwards.
- Rows come out ordered by the whole index, not by the suffix alone, so an
  `ORDER BY k` still sorts. An `IN` walked outside the groups repeats the
  walk for each value, and only each walk is in index order, so then even
  `ORDER BY bucket, k` sorts.
- The cost estimate is rough. Skip-scan is not guaranteed to be faster on any
  given data; check it on yours.

## Transaction conflicts

The steps between groups may read rows that are not in the result. The engine
records these reads to detect conflicts with other transactions, so vinyl and
memtx MVCC may report more conflicts than the same query without skip-scan.
This is expected: hiding the reads from the engine would break isolation.
