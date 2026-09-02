local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

-- REPLACE() allocates a result buffer as large as its first argument, so an
-- argument longer than a lookaside slot (LOOKASIDE_SLOT_SIZE == 512, see
-- src/box/sql/main.c) bypasses the SQL lookaside pool and every statement
-- leaks a chunk LSan can see. A slot leaked from the pool is invisible to
-- LSan, since the pool itself is one big allocation that stays reachable.
local BIG = string.rep('a', 1024)

g.before_all(function()
    g.server = server:new({alias = 'master'})
    g.server:start()
end)

-- Server:stop() fails on any LeakSanitizer report in the instance stderr.
-- Until the instance shutdown is complete (see the lj_BC_FUNCC comment in
-- asan/lsan.supp), an ASAN build running with the SQL LSan profile reports
-- unrelated leaks as well, so only the SQL ones are checked here.
g.after_all(function()
    local ok, err = pcall(g.server.stop, g.server)
    if ok then
        return
    end
    err = tostring(err)
    if not err:find('Memory leak during process execution', 1, true) then
        error(err)
    end
    g.server:save_artifacts()
    t.assert_not_str_contains(err, 'src/box/sql/', false,
                              'LSan reported a leak in SQL')
end)

-- mem_set_str_allocated() with a zero length leaves szMalloc at 0 while
-- zMalloc still points to an allocated buffer, and mem_destroy() used to
-- free the buffer by szMalloc.
g.test_empty_string_result = function()
    g.server:exec(function(str)
        for _ = 1, 20 do
            local res = box.execute([[SELECT replace(?, ?, '');]],
                                    {str, str})
            t.assert_equals(res.rows, {{''}})
        end
    end, {BIG})
end

-- Same ownership model in mem_set_bin_allocated().
g.test_empty_varbinary_result = function()
    g.server:exec(function(str)
        local sql = [[SELECT replace(CAST(? AS VARBINARY),
                                     CAST(? AS VARBINARY), x'');]]
        for _ = 1, 20 do
            local res = box.execute(sql, {str, str})
            t.assert_equals(#res.rows[1][1], 0)
        end
    end, {BIG})
end

-- PRINTF() with a single non-string argument goes through mem_strdup() and
-- mem_set_str0_allocated(). The leaked buffer is a single byte, that is a
-- lookaside slot, so the iteration count is kept well above
-- LOOKASIDE_SLOT_NUMBER (125): until the pool is exhausted the leak is
-- invisible to LSan.
g.test_empty_printf_result = function()
    g.server:exec(function()
        for _ = 1, 1000 do
            local res = box.execute([[SELECT printf(x'');]])
            t.assert_equals(res.rows, {{''}})
        end
    end)
end
