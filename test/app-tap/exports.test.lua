#!/usr/bin/env tarantool

local tap = require('tap')
local ffi = require('ffi')
ffi.cdef([[
    void *dlsym(void *handle, const char *symbol);
]])

local test = tap.test('exports')

-- See `man 3 dlsym`:
-- RTLD_DEFAULT
--   Find the first occurrence of the desired symbol using the default
--   shared object search order. The search will include global symbols
--   in the executable and its dependencies, as well as symbols in shared
--   objects that were dynamically loaded with the RTLD_GLOBAL flag.
local RTLD_DEFAULT = ffi.cast("void *", jit.os == "OSX" and -2LL or 0LL)

local function check_symbol(sym)
    test:ok(ffi.C.dlsym(RTLD_DEFAULT, sym) ~= nil, ('Symbol %q found'):format(sym))
end

local check_symbols = {
    -- FFI

    'guava',
    'base64_decode',
    'base64_encode',
    'cord_ibuf_drop',
    'cord_ibuf_put',
    'cord_ibuf_take',
    'random_bytes',
    'fiber_time',
    'ibuf_create',
    'ibuf_destroy',
    'port_destroy',
    'csv_create',
    'csv_destroy',
    'title_get',
    'title_update',
    'tnt_iconv',
    'tnt_iconv_open',
    'tnt_iconv_close',
    'tnt_mp_decode_double',
    'tnt_mp_decode_extl',
    'tnt_mp_decode_float',
    'tnt_mp_encode_decimal',
    'tnt_mp_encode_double',
    'tnt_mp_encode_error',
    'tnt_mp_encode_float',
    'tnt_mp_encode_uuid',
    'tnt_mp_sizeof_error',
    'tnt_mp_sizeof_decimal',
    'tnt_mp_sizeof_uuid',
    'tnt_mp_snprint_json',
    'tnt_mp_compare_json',

    'uuid_nil',
    'tt_uuid_create',
    'tt_uuid_is_equal',
    'tt_uuid_is_nil',
    'tt_uuid_bswap',
    'tt_uuid_from_string',
    'tt_uuid_to_string',
    'log_level',
    'log_format',
    'uri_destroy',
    'uri_format',
    'uri_set_destroy',
    'PMurHash32',
    'PMurHash32_Process',
    'PMurHash32_Result',
    'crc32_calc',
    'decimal_unpack',

    'say_set_log_level',
    'say_logrotate',
    'say_set_log_format',
    'tarantool_uptime',
    'tarantool_exit',
    'tarantool_version',
    'log_pid',
    'space_by_id',
    'space_run_triggers',
    'space_bsize',
    'box_schema_version',

    -- Trigger API (picodata connector)
    'box_trigger_create',
    'box_trigger_add',
    'box_trigger_clear',
    'box_space_on_replace',
    'box_space_before_replace',
    'box_txn_on_commit',
    'box_txn_on_rollback',
    'box_txn_on_wal_write',
    'box_txn_current_stmt',
    'box_txn_stmt_old_tuple',
    'box_txn_stmt_new_tuple',
    'tnt_json_parse',

    'crypto_ERR_error_string',
    'crypto_ERR_get_error',
    'crypto_EVP_DigestInit_ex',
    'crypto_EVP_DigestUpdate',
    'crypto_EVP_DigestFinal_ex',
    'crypto_EVP_get_digestbyname',
    'crypto_EVP_MD_CTX_new',
    'crypto_EVP_MD_CTX_free',
    'crypto_HMAC_CTX_new',
    'crypto_HMAC_CTX_free',
    'crypto_HMAC_Init_ex',
    'crypto_HMAC_Update',
    'crypto_HMAC_Final',
    'crypto_stream_new',
    'crypto_stream_begin',
    'crypto_stream_append',
    'crypto_stream_commit',
    'crypto_stream_delete',

    -- Module API

    '_say',
    'swim_cfg',
    'swim_quit',
    'fiber_new',
    'fiber_cancel',
    'coio_wait',
    'coio_close',
    'coio_call',
    'coio_getaddrinfo',
    'luaT_call',
    'box_txn',
    'clock_realtime',
    'string_strip_helper',

    -- Lua / LuaJIT

    'lua_newstate',
    'lua_close',
    'luaL_loadstring',
    'luaJIT_profile_start',
    'luaJIT_profile_stop',
    'luaJIT_profile_dumpstack',
}

-- TODO gh-7640 LuaJIT: ffi.C.dlsym() doesn't work on FreeBSD
jit.off()

-- tnt_json_parse() (box/sql/json_parse.h) is exported for Picodata but ships
-- no installed header, so its consumer has to hand-write the prototype. This
-- cdef is that prototype, kept in the same tree as json_parse.h so the two
-- go stale together rather than silently: a signature change here that
-- doesn't match the C declaration fails to compile below.
ffi.cdef([[
    char *tnt_json_parse(const char *text, uint32_t len, uint32_t *out_len);
    size_t box_region_used(void);
    void box_region_truncate(size_t size);
]])

local function test_tnt_json_parse(test)
    test:plan(2)

    local out_len = ffi.new('uint32_t[1]')

    -- json_parse.h mandates a region savepoint around every call, taken
    -- before and reclaimed after, whether or not the parse succeeds.
    local svp = ffi.C.box_region_used()
    local mp = ffi.C.tnt_json_parse('[1,2,3]', 7, out_len)
    test:ok(mp ~= nil and out_len[0] > 0, 'valid document parses')
    ffi.C.box_region_truncate(svp)

    svp = ffi.C.box_region_used()
    mp = ffi.C.tnt_json_parse('not json', 8, out_len)
    test:ok(mp == nil, 'malformed document is rejected')
    ffi.C.box_region_truncate(svp)
end

test:plan(#check_symbols + 1)
for _, sym in ipairs(check_symbols) do
    check_symbol(sym)
end
test:test('tnt_json_parse', test_tnt_json_parse)

os.exit(test:check() and 0 or 1)
