# The JSON perimeter

A JSON value is the one Tarantool type where the exact bytes matter and not
only the content. It is stored in one spelling, its normal form, and the
comparator and the renderers read it assuming that spelling. So every place a
JSON value can enter this process has to decide what to do about its bytes:
check them, produce them, or take them as they are because somebody upstream
already did one of the first two.

This document is the one place those decisions and their reasons are written
down. Code that takes a JSON value in, builds one, or deliberately does not
look at one carries a one-line comment pointing here, for example:

```c
/* JSON is taken as is, see doc/json-perimeter.md#space-dml. */
```

If you are changing one of those sites, read its entry below and the contract
it links to. If you are adding a new way for JSON to get in, read
[Changing the perimeter](#changing-the-perimeter) first.

## Normal form

A JSON value travels as an `MP_EXT` of subtype `MP_JSON` (20) wrapping one
plain MessagePack value, the inner value. The inner value is in normal form
when:

- every element is written in the shortest MessagePack encoding of its value;
- object keys are strings and ascend strictly by (length, bytes), so no key
  repeats;
- number kinds are never folded into one another, and a non-negative integer
  is always `MP_UINT`;
- every string and key is valid UTF-8 (RFC 3629);
- nesting is no deeper than `JSON_MAX_NESTING_DEPTH`.

The authoritative statement of the rule is in `src/lib/core/mp_json_norm.h`,
and the checks are `json_verify()` for one value and `mp_verify_json()` for a
MessagePack range holding any number of them, at any depth, including inside
the payload fields of an `MP_ERROR`.

In C, a value known to be in normal form is a `struct json_norm`
(`src/lib/core/mp_json.h`). A `const char *` does not convert to it on its
own, so code that needs normal form cannot be handed raw bytes by accident.

## The rule

Every site does exactly one of three things.

- **Reject.** The site is the first thing in this process to see the bytes,
  and they came from someone who could have got them wrong. It verifies, and
  on a value not in normal form it raises an error naming the offset. It
  never repairs: whoever spelled the value has a bug, and quietly fixing it
  would hide the bug from them.
- **Normalize.** The site builds JSON out of something that was not JSON yet
  and whose key order nobody chose for us: JSON text, or a SQL `MAP` or
  `ARRAY` (built from a Lua table, whose key order is unspecified). Producing
  normal form is the whole job there, not a repair.
- **Accept as is.** The bytes were judged before they got here, or were built
  from parts that were. The site does not walk them. Instead it names the
  contract it relies on, and a debug build asserts normal form where that is
  cheap.

Everything that arrives as a finished `MP_JSON` envelope was spelled by
somebody, so it is either rejected or accepted, never normalized.

## Contracts

The "accept as is" sites all rest on one of these. Each says who keeps the
promise and what happens when it is broken.

<a id="storage-invariant"></a>
### Storage holds only normal form

Every tuple in memtx or vinyl, every row in the WAL and snapshots, and every
statement in a vinyl run holds JSON in normal form only. It holds because
everything that puts bytes into storage crossed one of the rejecting or
normalizing entry points below, or was built under [closure](#closure) from
parts that did.

This is what lets `mp_compare_json()` compare object keys by position,
assert its depth limit instead of checking it, and have no way to report an
error; and it is what lets every read out of storage (a Lua field read, a SQL
column, recovery, replication) take the bytes as they are.

<a id="closure"></a>
### Normal form is closed under composition

Normal form is defined element by element, so every subtree of a value in
normal form is in normal form, and splicing whole values in normal form into
a tuple leaves them in normal form. No update operation rewrites the bytes of
an `MP_JSON` value. So:

- an update or upsert result built from a stored tuple and operands that were
  judged with the request is in normal form;
- a SQL subscript into a JSON value can re-wrap the subtree without looking
  at it.

<a id="module-contract"></a>
### Modules hand over normal form

An in-process C or Rust module that passes MessagePack into the box C API
must put every `MP_JSON` value in it, at any depth, into normal form first,
for example with `tnt_json_normalize()` or `tnt_json_parse()`. This is written
in the public headers next to each function it covers:

- `box_insert()`, `box_replace()`, `box_update()`, `box_upsert()` (`box.h`);
- `box_tuple_new()`, `box_tuple_update()`, `box_tuple_upsert()` (`tuple.h`);
- `box_return_mp()` when the result goes back into SQL (`box.h`);
- the `sql_*_ext()` and `sql_*_into_port()` execution functions, for
  `mp_params` (`execute.h`);
- `tnt_mp_snprint_json()` and `tnt_mp_compare_json()` (`tnt_msgpuck.h`).

Nothing checks this in a release build. A debug build asserts it where the
bytes are consumed, which is the intended signal for a module under
development. Checking in a release build would walk every tuple a module
builds, and a module builds every one of its tuples through
`box_tuple_new()`.

This is an external API contract with no compile-time signal, and the MR that
introduced the JSON type is where it changed.

<a id="peer-contract"></a>
### Peers run the same perimeter

A cluster member or a net.box peer running this same code checked every JSON
value when it first came in there, so its rows and its responses hold normal
form. Checking them again here would catch only a peer running a different
build or one that has been compromised, and one walk answers neither. The
same goes for this instance's own files on disk.

In a release build, bytes that reached a peer's storage out of contract
propagate. The fix for that is at the perimeter that let them in.

<a id="cdata-contract"></a>
### The Lua JSON cdata

A JSON value in Lua is a cdata (`struct mp_json`) holding the raw inner
value, not a decoded struct like the other extension types. A consumer that
splices one into MessagePack has no field to re-encode from, only a range to
copy, so it cannot judge the value the way an encoder can. What a consumer
may assume about those bytes is agreed up front:

**These make a cdata and vouch for it:**

- `msgpack.decode()` and `msgpack.object_from_raw()`, which walk the bytes
  with the strict hook before handing them over ([lua-decode](#lua-decode));
- `luamp_push()`, which wraps bytes this process already has: a request that
  [iproto-request](#iproto-request) walked, or a net.box response that the
  peer vouches for ([netbox-response](#netbox-response));
- a field read out of a tuple ([lua-tuple-field](#lua-tuple-field)), by the
  [storage invariant](#storage-invariant);
- a payload field of an error, which `error.lua` decodes unchecked but which
  every way in for an error walked along with the error.

**These make one and do not:**

- `msgpack.decode_unchecked()`;
- the whole `msgpackffi` module, whose `decode` is `decode_unchecked`;
- `ffi.new('struct mp_json', n)`.

Passing a cdata from the second group into a consumer breaks the deal, much
like casting a bad pointer over a tuple with `ffi.cast()`. What keeps such a
cdata out of storage is one check on the way out, not a check at every
consumer: both Lua encoders refuse it ([lua-c-encoder](#lua-c-encoder),
[lua-ffi-encoder](#lua-ffi-encoder)), and every Lua value bound for box
passes through one of them. The consumers that read a cdata without encoding
it (a SQL bind, a Lua function's return into SQL, the renderers) believe the
deal.

<a id="msgpack-object"></a>
### msgpack.object holds judged bytes

`luamp_get()` returns the bytes an `msgpack.object` holds, and every caller
copies them straight through, so it is the one way MessagePack gets into an
encoder without being encoded. Only three things make an `msgpack.object`,
and each one checks first or wraps bytes somebody already vouched for:

- `msgpack.object(value)` encodes through `luamp_encode()`, the same path as
  `msgpack.encode()`;
- `msgpack.object_from_raw(str)` walks the bytes with `luamp_check_or_raise()`
  before the object exists;
- `luamp_push()`, as in the [cdata contract](#cdata-contract).

The places that splice a copied range without checking it (the `MAP`/`ARRAY`
bind in `box/lua/execute.c`, the `MAP`/`ARRAY` Lua function return in
`box/sql/mem.c`, `luaT_tuple_new()`) count on this. Add a fourth way to make
an `msgpack.object` that neither checks nor wraps vouched bytes, and they all
break.

<a id="mem-invariant"></a>
### A SQL MEM holds normal form

A MEM only becomes `MEM_TYPE_JSON`, or holds a `MAP` or `ARRAY` with JSON
inside, through a producer that normalizes ([sql-json-text](#sql-json-text),
[sql-cast-container](#sql-cast-container)) or one that copies a value already
in normal form (a bind, a tuple field, a function return, a subscript). There
is no other way to set it, and `set_msgpack_value()` in `sql/mem.c` asserts
normal form on every MessagePack MEM in a debug build. So everything the VDBE
builds out of MEMs, a tuple for storage or a row for a port, is in normal
form.

<a id="trusted-builders"></a>
### Saying "trusted" in C

Two things in C claim bytes are in normal form without proving it, and they
are the places to audit:

- `json_norm_from_trusted()` (`mp_json.h`) wraps bytes into a
  `struct json_norm`;
- `tuple_new()` (`tuple.h`) builds a tuple asserting, not checking, normal
  form. Its checking twin is `tuple_new_checked()`, and which one a caller
  uses is the whole statement of whether it trusts the bytes.

Every call to either must say why it may, normally by pointing at an entry
or a contract in this document.

## Entry points

Ordered by how the bytes travel: in off the network, in from Lua, built out
of SQL text, in from a compiled module, back off disk or from a peer, composed
inside storage, and out through a renderer. Tests are in
`test/sql-luatest/json_test.lua` unless another file is named.

| Entry | Action | Site | Reached by |
|---|---|---|---|
| [iproto-request](#iproto-request) | reject | `iproto_msg_prepare()` | anyone with a socket |
| [netbox-response](#netbox-response) | accept | `netbox_transport_send_and_recv()` | the peer the operator dialed |
| [sql-bind-module](#sql-bind-module) | accept | `sql_bind_decode()` | iproto `EXECUTE`, a module |
| [lua-decode](#lua-decode) | reject | `luamp_check_ext_data()` | Lua, on bytes from anywhere |
| [lua-c-encoder](#lua-c-encoder) | reject | `luamp_encode_with_translation_r()` | Lua, stored function returns |
| [lua-ffi-encoder](#lua-ffi-encoder) | reject | `msgpackffi` `encode_json` | Lua, every memtx index key |
| [sql-bind-lua](#sql-bind-lua) | accept | `lua_sql_bind_decode()` | Lua |
| [lua-return](#lua-return) | accept | `port_lua_get_vdbemem()` | a stored Lua function |
| [key-def-key](#key-def-key) | accept | `lbox_key_def_compare_with_key()` | Lua |
| [lua-tuple-field](#lua-tuple-field) | accept | `msgpackffi` `ext_decoder[MP_JSON]` | anyone who can read a tuple |
| [lua-decode-unchecked](#lua-decode-unchecked) | accept | `msgpack.decode_unchecked()`, `msgpackffi.decode()` | Lua, unguarded by name |
| [sql-json-text](#sql-json-text) | normalize | `tnt_json_parse()`, `mem_set_json_text()` | anyone who can run SQL |
| [sql-cast-container](#sql-cast-container) | normalize | `mem_set_json_normalized()` | anyone who can run SQL |
| [c-return](#c-return) | accept | `port_c_get_vdbemem()` | a module |
| [tuple-from-raw-bytes](#tuple-from-raw-bytes) | reject | `tuple_new_checked()` | Lua, through merger or xlog |
| [field-default](#field-default) | accept | `tuple_format` field defaults | a module, or recovery |
| [box-c-api](#box-c-api) | accept | `box_insert()` and friends | a module |
| [recovery](#recovery) | accept | `xlog_tx_cursor_next_row()` | this instance, off its own disk |
| [applier](#applier) | accept | `coio_read_xrow()` | a cluster member |
| [vinyl-run-read](#vinyl-run-read) | accept | `vy_page_xrow()`, `vy_stmt_decode()` | this instance, reader thread |
| [space-dml](#space-dml) | accept | memtx, vinyl and space DML | anyone who can write |
| [vdbe-tuple](#vdbe-tuple) | accept | `sql.c`, `OP_MakeRecord` | anyone who can run SQL |
| [functional-index-key](#functional-index-key) | accept | `key_list_iterator_next()` | an operator |
| [renderers](#renderers) | accept | `luaT_json_tostring()` and its callers | Lua, the console |
| [external-renderer](#external-renderer) | accept | `tnt_mp_snprint_json()` | a module |
| [external-comparator](#external-comparator) | accept | `tnt_mp_compare_json()` | a module |

### From the network

<a id="iproto-request"></a>
#### iproto-request: an iproto request

**Reject.** `iproto_msg_prepare()` in `src/box/iproto.cc` hands
`msgpack_check_ext_data_strict()` (`src/box/msgpack.c`) to
`xrow_header_decode()`, so the header and the body are judged in the walk
that decode runs anyway: the tuple, the key, the update operands and the SQL
bind list, at any depth, and the payload fields of an error value inside any
of them.

The network is where we stop trusting anyone. The walk runs in the iproto
thread before the message is routed to tx, so before authentication and any
access check: an unprivileged guest is told its JSON is wrong. Rejecting
rather than repairing keeps the iproto thread free of allocations, and it is
the only honest answer to a client that chose the bytes itself. Every box
check below it can then be an assert.

The strict hook walks an error's payload fields with itself before
`mp_validate_error()` sees them, because `error:unpack()` hands those fields
out unchecked. The header is walked strictly because
`box.iproto.override()` hands a handler the whole header as an
`msgpack.object`.

Tests: `json_perimeter` group, `test_perimeter_iproto_request`,
`test_perimeter_iproto_error_field`, `test_perimeter_iproto_header`,
`test_perimeter_container_rejects_invalid_json`,
`test_perimeter_utf8_iproto`.

<a id="netbox-response"></a>
#### netbox-response: a net.box response

**Accept**, on the [peer contract](#peer-contract).
`netbox_transport_send_and_recv()` in `src/box/lua/net_box.c` passes `NULL`
to `xrow_header_decode()`, as the applier does, so every other extension type
is still checked by the process-wide hook and an `MP_JSON` payload is taken as
it is.

Who the peer is was decided by the operator: nothing a client sends over
iproto points this instance at an address. What comes out of a response
therefore holds what the peer sent: a JSON cdata in a call's result, a tuple
net.box builds with `box_tuple_new()`, and an `msgpack.object` from
`return_raw = true`. A debug build aborts on a peer out of contract, in
`luamp_push_with_translation()` or `box_tuple_new()`. A release build takes
the bytes, and so does whatever this instance builds from them; a cdata sent
on is still refused by [lua-c-encoder](#lua-c-encoder).

It used to take the strict hook. The review on MR 408 asked to drop the check
until there is a reason to have one.

Tests: `json_perimeter` group, `test_perimeter_net_box_response`.

<a id="sql-bind-module"></a>
#### sql-bind-module: SQL parameters from iproto or a module

**Accept.** `sql_bind_decode()` in `src/box/bind.c` takes an `MP_JSON` bind,
bare or inside a `MAP` or `ARRAY`, as it is, and asserts normal form.

It has two callers and both vouch for their bytes. An iproto `EXECUTE`, whose
body [iproto-request](#iproto-request) has walked, bind list included. And a
module calling `sql_*_ext()` or `sql_*_into_port()`, on the
[module contract](#module-contract). A module may run every statement
through `sql_stmt_execute_into_port_ext()` with parameters sliced out of a
request body iproto has just walked, so a check here would walk the same
bytes twice on every statement.

Tests: `test/sql-luatest/sql_api_test.lua`,
`test_sql_api_bind_takes_json_as_is`; `json_perimeter` group,
`test_perimeter_sql_bind_container`, `test_perimeter_utf8_sql`.

### From Lua

<a id="lua-decode"></a>
#### lua-decode: msgpack.decode() and msgpack.object_from_raw()

**Reject.** `luamp_check_ext_data()` in `src/lua/msgpack.c` chains through the
process-wide hook and adds the strict `MP_JSON` case, reaching into an
error's payload fields too. `luamp_check_or_raise()` raises what it names,
and a successful decode leaves `box.error.last()` alone.

Calling it needs Lua, but the bytes can be as untrusted as a request's:
`src/lua/httpc.lua` decodes remote `application/msgpack` bodies through it.
These two functions start the [cdata contract](#cdata-contract) and the
[msgpack.object](#msgpack-object) one. An `object_from_raw()` result is
spliced into a tuple untouched, so for it this is the last look.

Tests: `json_perimeter` group, `test_perimeter_lua_decode`,
`test_perimeter_lua_decode_error_field`,
`test_perimeter_lua_decode_keeps_last_error`, `test_perimeter_utf8_lua`.

<a id="lua-c-encoder"></a>
#### lua-c-encoder: the Lua C encoder

**Reject.** The `MP_JSON` arm of `luamp_encode_with_translation_r()` in
`src/lua/msgpack.c`
emits the cdata's bytes if `luaT_json_check()` says they are in normal form,
and raises otherwise. It is reached by `msgpack.encode()`,
`box.tuple.new()`, every `space:` write, every net.box request, and every
stored function or `eval` return value (`src/box/lua/call.c`), so a client
with `execute` on a single function reaches it on the response path.

The encoder is not a producer: it re-emits what it was handed, so repairing
here would repair on the producer's behalf. And every Lua value on its way to
becoming MessagePack for box passes here while `box_insert()` only asserts,
so this is the check that keeps a cdata out of contract away from the WAL.
`luaT_tuple_new()` builds with `box_tuple_new()` on the strength of it.

Tests: `json_perimeter` group, `test_perimeter_lua_cdata`,
`test_perimeter_raft_dml_apply_shape`,
`test_perimeter_container_rejects_invalid_json`.

<a id="lua-ffi-encoder"></a>
#### lua-ffi-encoder: the Lua FFI encoder

**Reject.** `encode_json` in `src/lua/msgpackffi.lua`, through the
`tnt_mp_verify_json()` shim, with the same answer as
[lua-c-encoder](#lua-c-encoder).

It is not opt-in: every memtx index gets the `_ffi` methods, so `index:get()`,
`select()`, `min()`, `max()`, `count()`, `pairs()` and `tuple_pos()` keys
encode here, while a vinyl index uses the C encoder. The two have to agree
because which one runs is invisible to the caller. This is also the last
look for `tuple:update()`, whose result is spliced into a tuple.

Tests: `json_perimeter` group, `test_perimeter_lua_cdata`.

<a id="sql-bind-lua"></a>
#### sql-bind-lua: a JSON cdata bound into box.execute()

**Accept**, on the [cdata contract](#cdata-contract). The `MP_JSON` arm of
`lua_sql_bind_decode()` in `src/box/lua/execute.c` re-emits the cdata's bytes
with `mp_encode_json()`, and the `MAP`/`ARRAY` arm copies a range out of an
`msgpack.object` or a tuple ([msgpack.object](#msgpack-object)).

The site never encodes the cdata, so it could only walk it a second time.
What stands in for that is [lua-decode](#lua-decode) on the way in and the
encoders on any path that encodes rather than splices. A release build
stores a cdata out of contract bound into SQL; a debug build stops at the
assert in `set_msgpack_value()`.

Tests: `json_perimeter` group, `test_perimeter_sql_bind_container_lua`.

<a id="lua-return"></a>
#### lua-return: a Lua function's return into SQL

**Accept**, on the [cdata contract](#cdata-contract). The `MP_JSON` arm of
`port_lua_get_vdbemem()` in `src/box/sql/mem.c` takes the cdata's bytes, and
its `MAP`/`ARRAY` sibling copies a range out of an `msgpack.object` or a
tuple.

A stored Lua function that has a JSON cdata to return got it from one of the
places the contract names. If it got it from `decode_unchecked()` and passed
it on, the mistake is in the function body, where its author can see it.

Tests: `json_perimeter` group, `test_perimeter_stored_function_return`,
`test_perimeter_stored_function_container`.

<a id="key-def-key"></a>
#### key-def-key: a key_def comparison key

**Accept.** `lbox_key_def_compare_with_key()` in `src/box/lua/key_def.c`
takes the key as `luaT_tuple_encode()` wrote it. That leaves three
provenances, each judged elsewhere: a cdata, which
[lua-c-encoder](#lua-c-encoder) judged as it emitted it; a tuple, by the
[storage invariant](#storage-invariant); an `msgpack.object`, by
[msgpack.object](#msgpack-object). A forged cdata is refused by the encoder
before this file sees it.

This is the one way a JSON value reaches the comparator without having been a
tuple field first.

Tests: `json_perimeter` group, `test_perimeter_key_def_compare_key`.

<a id="lua-tuple-field"></a>
#### lua-tuple-field: reading a JSON field in Lua

**Accept**, on the [storage invariant](#storage-invariant).
`ext_decoder[MP_JSON]` in `src/lua/msgpackffi.lua` copies the payload into a
cdata. It backs `tuple[n]`, `tuple:totable()`, `tuple:pairs()` and
`tuple:next()`, and the decoding of an error's payload in `error.lua`.

This is the hottest path on the map, so it is where accepting is worth the
most: a walk here measured 698 ns/op against 192 ns/op without, on a debug
build.

<a id="lua-decode-unchecked"></a>
#### lua-decode-unchecked: msgpack.decode_unchecked() and msgpackffi.decode()

**Accept**, and says so in its name. Its cdata form takes a bare `char *`
with no length, so it cannot be made to check: nothing bounds a walk.
`msgpackffi.decode` is and always was an alias for it. It heads the second
list of the [cdata contract](#cdata-contract); what keeps its output out of
storage is the encoders.

### From SQL text

<a id="sql-json-text"></a>
#### sql-json-text: JSON text, as CAST(text AS JSON) and JSON_PARSE()

**Normalize.** `tnt_json_parse()` in `src/box/sql/json_parse.c` parses the
text and writes normal form directly, checking that every string and key is
valid UTF-8 (the lexer does not). `mem_set_json_text()` in `sql/mem.c` is
the one helper both the cast and `JSON_PARSE()` go through, so the two cannot
disagree about a string.

The key order in text is the author's, chosen for a human reader, and no
client could have been asked to sort it.

Tests: `json_perimeter` group, `test_perimeter_sql_text`; `json_parse` and
`json_cast` groups; `test/unit/json_parse.c`.

<a id="sql-cast-container"></a>
#### sql-cast-container: CAST(map or array AS JSON)

**Normalize.** `mem_set_json_normalized()` in `src/box/sql/mem.c` rewrites a
SQL `MAP` or `ARRAY` into normal form with `mp_encode_json_normalized()`,
refusing anything that is not a JSON value.

A SQL `MAP` is built from a Lua table, whose key order is unspecified, so
there is no author's order to keep and no caller who could have sorted it.

Tests: `json_cast` group.

### From a compiled module

<a id="c-return"></a>
#### c-return: a C function's return into SQL

**Accept**, on the [module contract](#module-contract). `port_c_get_vdbemem()`
in `src/box/sql/mem.c` takes an `MP_JSON` value, or a `MAP` or `ARRAY` holding
one, as the module returned it through `box_return_mp()`.
`mem_set_json()`, `mem_copy_map()` and `mem_copy_array()` assert normal form.

It is the same caller as [box-c-api](#box-c-api) and
[sql-bind-module](#sql-bind-module), and a tuple returned with
`box_return_tuple()` was already built through `box_tuple_new()` on trust.

Tests: `json_c_function` group,
`test_json_c_function_return_takes_json_as_is`,
`test_json_c_function_container_takes_json_as_is`.

<a id="tuple-from-raw-bytes"></a>
#### tuple-from-raw-bytes: a tuple from raw bytes

**Reject.** `tuple_new_checked()` in `src/box/tuple.c` walks the whole tuple
with `tuple_validate_json()` and names a bad field by its format path. Its
callers are the ones whose bytes can come from anywhere:

- the merger's buffer source (`src/box/lua/merger.c`), which builds tuples
  out of an ibuf any Lua caller can fill with `ffi.copy()`;
- the Lua xlog reader (`src/box/lua/xlog.c`), which reads whatever file it is
  given, not only our own;
- `tuple:transform()` and `key_def:extract_key()`, which could name a proof
  about a producer in another subsystem and do not, because that kind of
  proof rots without a compile error.

Naming the field costs a second walk, so it happens on the failure path only.

Tests: `json_perimeter` group, `test_perimeter_merger_error_field`,
`test_perimeter_utf8_merger`.

<a id="field-default"></a>
#### field-default: a JSON field default

**Accept.** Building a tuple format in `src/box/tuple_format.c` asserts that
the default for a JSON field is in normal form. The default travels inside a
`_space` tuple, so it was judged with that write, or it comes from our own
snapshot ([recovery](#recovery)), or from a `box_insert()` caller on the
[module contract](#module-contract).

Rejecting here did harm in the one place it bit: the format is built inside
the `_space` replace trigger, so a snapshot holding a default this build
would not have written kept the instance from starting. The default is never
rewritten either, or the format's copy would differ from the `_space` tuple
it was read from.

Tests: `json_perimeter` group, `test_perimeter_field_default`.

<a id="box-c-api"></a>
#### box-c-api: the box C API

**Accept**, on the [module contract](#module-contract). `box_insert()`,
`box_replace()`, `box_update()`, `box_upsert()` (`box.h`) and
`box_tuple_new()`, `box_tuple_update()`, `box_tuple_upsert()` (`tuple.h`) do
not walk. `tuple_new()` asserts in a debug build.

Every Lua route to them passes an encoder first, and a module normalizes on
its own side. The `*_as_is` variants that used to exist beside them are gone.

Tests: `json_perimeter` group, `test_perimeter_no_as_is_dml_entry_points`.

### From disk or a cluster peer

<a id="recovery"></a>
#### recovery: snapshot and WAL replay

**Accept**, on the [peer contract](#peer-contract).
`xlog_tx_cursor_next_row()` in `src/box/xlog.c` decodes rows with no strict
hook. Every row crossed a perimeter on the way in, and a walk here would be
paid on every row of every restart.

<a id="applier"></a>
#### applier: rows from a cluster member

**Accept**, on the [peer contract](#peer-contract). `coio_read_xrow()` and
`coio_read_xrow_timeout_xc()` in `src/box/xrow_io.cc` decode with no strict
hook. Checking would double the cost of replication.

Tests: `json_replication` group.

<a id="vinyl-run-read"></a>
#### vinyl-run-read: vinyl run files

**Accept**, on the [storage invariant](#storage-invariant). `vy_page_xrow()`
in `src/box/vy_run.c` and `vy_stmt_decode()` in `src/box/vy_stmt.c` take the
bytes as they are. They run in a reader thread too, where a check would have
no diag or region to report through.

### Inside storage and the VDBE

<a id="space-dml"></a>
#### space-dml: memtx, vinyl and generic space DML

**Accept.** `src/box/memtx_space.c`, `src/box/vinyl.c` and `src/box/space.c`
build the result of a DML with `tuple_new()`. A replace, an insert and an
upsert that turns into an insert store `request->tuple`, which was judged at
its entry point. An update or upsert composes the stored tuple
([storage invariant](#storage-invariant)) with operands judged along with the
request, and the result is normal by [closure](#closure). The same holds for
`box_tuple_update()` and `box_tuple_upsert()` in `src/box/tuple.c`, whose
operands are on the [module contract](#module-contract).

Tests: `json_perimeter` group, `test_perimeter_update_operands`;
`json_update_ops` group.

<a id="vdbe-tuple"></a>
#### vdbe-tuple: tuples and rows built by the VDBE

**Accept**, on the [MEM invariant](#mem-invariant). The VDBE builds a tuple
out of MEMs and hands it to `box_process1()` in `src/box/sql.c` behind
`mp_tuple_assert()`. An ephemeral space is filled from `OP_MakeRecord`
(`memtx_space.c`), and a port row is turned into a tuple in
`src/box/execute.c`, on the same grounds.

<a id="functional-index-key"></a>
#### functional-index-key: a functional index key

**Accept.** `key_list_iterator_next()` in `src/box/key_list.c` builds the key
with `tuple_new()`. A functional index function is sandboxed persistent Lua
(`func_index_check_func()`), so its key was written by
[lua-c-encoder](#lua-c-encoder), which checks every JSON value it writes and
copies raw bytes only out of a tuple. The sandbox has no `ffi`, `msgpack` or
`box`, so nothing inside it can get hold of a JSON cdata any other way.

This is the one interior site that takes the asserting builder on a proof
about a producer in another subsystem, and it can because the sandbox that
makes the proof hold is enforced in code.

### On the way out

<a id="renderers"></a>
#### renderers: tostring, yaml, json and the Lua console

**Accept**, on the [cdata contract](#cdata-contract). `luaT_json_tostring()`
in `src/lua/utils.c` renders the bytes with no walk for normal form, and the
cdata `__tostring`, the yaml serializer (`third_party/lua-yaml/lyaml.cc`), the
json serializer (`third_party/lua-cjson/lua_cjson.c`) and the Lua console
serializer (`src/box/lua/serialize_lua.c`) all come through it.

It is safe without the walk: `mp_snprint_json()` bounds every decode by the
length and stops at the depth limit, so malformed bytes are an error and
never a read past the cdata. A cdata out of contract prints in the spelling
it holds.

<a id="external-renderer"></a>
#### external-renderer: tnt_mp_snprint_json()

**Accept**, on the [module contract](#module-contract).
`tnt_mp_snprint_json()` in `src/lua/tnt_msgpuck.c` is exported so that a
module can render JSON cells of a result through it. A typical caller does so
twice per value (once to size, once to write), on values straight out of
storage. A check would be two walks per cell for safety the renderer already
has, as in [renderers](#renderers). It asserts in a debug build.

<a id="external-comparator"></a>
#### external-comparator: tnt_mp_compare_json()

**Accept**, on the [module contract](#module-contract).
`tnt_mp_compare_json()` in `src/lua/tnt_msgpuck.c` is exported so that a
module can compare and order JSON values exactly as storage does, with
`mp_compare_json()` itself, instead of keeping a second comparator of its own
that would drift from this one. Its operands are values the module put in
normal form or read from storage. The comparator relies on sorted keys and on
the depth bound, so a check here would be a walk of both operands per
comparison. It asserts in a debug build.

## What breaking a contract costs

| Contract broken by | Debug build | Release build |
|---|---|---|
| a module, into box or SQL | aborts on an assert | stores the bytes |
| a peer or a file on disk | aborts where the bytes are consumed | stores or propagates the bytes |
| a Lua script, with a forged cdata | refused by the encoders; aborts in SQL | refused by the encoders; stored if bound into SQL |
| anyone, into a renderer | prints the spelling, or an error if malformed | the same |

No contract break can make the comparator or a renderer read past a buffer:
both are bounded by the value's length. What a stored value out of normal
form costs is wrong ordering, for as long as it stays in storage.

## Changing the perimeter

When you add a way for a JSON value to get into this process, or change what
an existing site does:

1. Decide which of the three actions it takes by [the rule](#the-rule): the
   first thing to see bytes someone else spelled rejects; something building
   JSON out of non-JSON normalizes; anything else accepts and names its
   contract.
2. Add or update its entry here, with its site, what it does, who reaches it,
   why, and the test that pins it.
3. Put a one-line comment at the site pointing to the entry:
   `JSON is checked here`, `JSON is normalized here` or
   `JSON is taken as is`, followed by `see doc/json-perimeter.md#<entry>`.
4. If it accepts, use `tuple_new()` or `json_norm_from_trusted()` and point
   the comment at the entry that says why; otherwise use
   `tuple_new_checked()`.
5. If it creates a new way to make a JSON cdata or an `msgpack.object`, update
   the [cdata contract](#cdata-contract) or the
   [msgpack.object](#msgpack-object) list, and check every consumer that
   relies on it.
