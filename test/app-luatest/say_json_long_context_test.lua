local fio = require('fio')
local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new({box_cfg = {log_format = 'json'}})
    --
    -- Log into a file rather than into the pipe of the unified logging: a pipe
    -- logger is non-blocking, and safe_write() does a single write(), so once
    -- the reader falls behind, the tail of an entry is dropped and entries run
    -- into each other regardless of the formatter.
    --
    cg.log_file = fio.pathjoin(cg.server.workdir, 'say_json_long_context.log')
    cg.server.box_cfg.log = cg.log_file
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

--
-- The context of a json log entry is bounded only by the length of the module
-- name, so a long enough one overflows the 16 KiB log buffer. Such an entry
-- has to be truncated to a single line instead of crashing the instance.
--
g.test_long_module_name = function(cg)
    local res = cg.server:exec(function(path)
        local fio = require('fio')
        local log = require('log')

        local marker = string.rep('A', 15000)
        local expected = 0
        -- Sweep the module name length across the buffer boundary.
        for i = 16000, 16400 do
            log.new(string.rep('A', i)).error('hello %s', 'world')
            expected = expected + 1
        end
        -- A module name several times longer than the buffer.
        log.new(string.rep('A', 40000)).error('hello')
        expected = expected + 1

        local fh = fio.open(path, {'O_RDONLY'})
        local data = fh:read()
        fh:close()

        local seen = 0
        local too_long = 0
        for line in data:gmatch('[^\n]+') do
            if line:find(marker, 1, true) ~= nil then
                seen = seen + 1
            end
            if #line >= 16 * 1024 then
                too_long = too_long + 1
            end
        end
        return {expected = expected, seen = seen, too_long = too_long}
    end, {cg.log_file})
    -- Every entry made it to the log as a line of its own.
    t.assert_equals(res.seen, res.expected)
    t.assert_equals(res.too_long, 0)

    -- The instance is still alive and logging.
    cg.server:exec(function() require('log').error('still alive') end)
    t.assert(cg.server:grep_log('still alive', nil, {filename = cg.log_file}))
end
