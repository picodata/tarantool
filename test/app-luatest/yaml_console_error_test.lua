local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_each(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
end)

g.after_each(function(cg)
    require('test.lsan').stop(cg.server,
                             {'third_party/libyaml/', 'third_party/lua-yaml/'})
end)

g.test_console_errors = function(cg)
    cg.server:exec(function()
        local ffi = require('ffi')
        ffi.cdef('int box_session_push(const char *data, const char *end);')
        rawset(_G, 'push_raw', function(bytes)
            local data = ffi.cast('const char *', bytes)
            if ffi.C.box_session_push(data, data + #bytes) ~= 0 then
                error(box.error.last())
            end
            return true
        end)
        local listener = require('console').listen('127.0.0.1:0')
        local client = require('socket').tcp_connect('127.0.0.1',
                                                      listener:name().port)
        t.assert(client:read({chunk = 128}, 5))
        local function command(text)
            t.assert(client:write(text .. '\n'))
            return client:read('\n...\n', 5)
        end
        local response = command([[push_raw('\xD5\x14\xC4\x00')]])
        t.assert_str_contains(response, 'Invalid JSON value')
        t.assert_not_str_contains(response, '(null)')
        t.assert_equals(command('1 + 1'), '---\n- 2\n...\n')
        -- A regular Lua error from a deeply nested MessagePack value.
        response = command([[push_raw(('\x91'):rep(130) .. '\x01')]])
        t.assert_str_contains(response, 'Too high nest level')
        response = command([[require('yaml').decode(('['):rep(1000) .. ]] ..
                           [['0' .. (']'):rep(1000))]])
        t.assert_str_contains(response, 'Too high nest level')
        t.assert_equals(command('1 + 1'), '---\n- 2\n...\n')
        t.assert_equals(command([[push_raw('\xa2ok')]]),
                        '%TAG !push! tag:tarantool.io/push,2018\n--- ok\n...\n')
        t.assert_equals(client:read('\n...\n', 5), '---\n- true\n...\n')
        client:close()
        listener:close()
        rawset(_G, 'push_raw', nil)
    end)
end
