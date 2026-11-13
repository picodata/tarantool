local fio = require('fio')
local server = require('luatest.server')
local t = require('luatest')

-- A yield inside a before_replace or on_replace trigger of a memtx
-- transaction without MVCC panics. Each case stops the server, so each
-- case gets its own server.
local g = t.group('space_trigger_yield_panic')

g.before_each(function(cg)
    cg.server = server:new({box_cfg = {memtx_use_mvcc_engine = false}})
    cg.server:start()
end)

g.after_each(function(cg)
    cg.server:drop()
end)

local function check_panic(cg, f)
    local s = cg.server
    -- The connection closes when the server stops.
    t.assert_not(pcall(s.exec, s, f))
    local log = fio.pathjoin(s.workdir, s.alias .. '.log')
    -- ASAN can take some time to write its report.
    t.helpers.retrying({timeout = 60}, function()
        t.assert(s:grep_log('yield in a before_replace or on_replace ' ..
                            'trigger', nil, {filename = log}))
        t.assert_not(s.process:is_alive())
    end)
end

g.test_on_replace = function(cg)
    check_panic(cg, function()
        local fiber = require('fiber')
        local s = box.schema.space.create('test')
        s:create_index('pk')
        s:on_replace(function() fiber.sleep(0) end)
        s:insert{1}
    end)
end

g.test_before_replace = function(cg)
    check_panic(cg, function()
        local fiber = require('fiber')
        local s = box.schema.space.create('test')
        s:create_index('pk')
        s:before_replace(function(_, new)
            fiber.sleep(0)
            return new
        end)
        s:insert{1}
    end)
end

-- A yield in a trigger after the triggers of a nested statement ended.
g.test_nested = function(cg)
    check_panic(cg, function()
        local fiber = require('fiber')
        local s1 = box.schema.space.create('test1')
        s1:create_index('pk')
        local s2 = box.schema.space.create('test2')
        s2:create_index('pk')
        s2:on_replace(function() end)
        s1:on_replace(function(_, new)
            s2:insert(new)
            fiber.sleep(0)
        end)
        s1:insert{1}
    end)
end
