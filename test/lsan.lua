local t = require('luatest')

local M = {}

-- Incomplete instance shutdown can leave unrelated allocations alive.
-- Keep the report, but fail only for the paths covered by this test.
function M.stop(server, paths)
    -- Finalize Lua error objects before checking allocations at process exit.
    server:exec(function() collectgarbage('collect') end)
    local ok, err = pcall(server.stop, server)
    if ok then
        return
    end
    local message = tostring(err)
    if not message:find('Memory leak during process execution', 1, true) then
        error(err)
    end
    server:save_artifacts()
    for _, path in ipairs(paths) do
        t.assert_not_str_contains(message, path, false,
                                  'LSan reported a leak in ' .. path)
    end
end

return M
