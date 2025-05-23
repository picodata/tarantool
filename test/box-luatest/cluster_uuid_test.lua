local server = require('luatest.server')
local t = require('luatest')
local g = t.group()

g.before_all(function()
    local ffi_init = [[
        int tt_uuid_from_string(const char *in, struct tt_uuid *uu);
        void tt_uuid_to_string(const struct tt_uuid *uu, char *out);
        int iproto_set_cluster_uuid(const struct tt_uuid *cluster_uuid);
        const struct tt_uuid *iproto_get_cluster_uuid(void);
    ]]
    g.server = server:new({alias = 'cluster_uuid'})
    g.server:start()
    g.server:exec(function(cfg)
        local ffi = require('ffi')
        ffi.cdef(cfg)
    end, {ffi_init})
end)

g.after_all(function()
    g.server:stop()
end)

g.test_cluster_uuid_api = function()
    g.server:exec(function()
        local ffi = require('ffi')

        -- Create a test UUID using tt_uuid_from_string
        local test_uuid = ffi.new("struct tt_uuid")
        local uuid_str = "12345678-1234-5678-9abc-123456789012"
        local rc = ffi.C.tt_uuid_from_string(uuid_str, test_uuid)
        t.assert_equals(rc, 0, "tt_uuid_from_string should succeed")

        -- Test setting cluster UUID
        local res = ffi.C.iproto_set_cluster_uuid(test_uuid)
        t.assert_equals(res, 0, "iproto_set_cluster_uuid should succeed")

        -- Test getting cluster UUID
        local result_uuid_str = box.info.cluster.picodata_uuid
        t.assert_equals(result_uuid_str, uuid_str, "UUID strings should match")
    end)
end
