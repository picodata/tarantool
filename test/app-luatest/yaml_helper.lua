local fio = require('fio')

local M = {}

local TRUE_VALUES = {ON = true, TRUE = true, YES = true, Y = true}

-- Whether Tarantool is built with the bundled libyaml. Only the bundled
-- library guarantees the nesting depth limit: a system one may have none,
-- e.g. 0.2.5. The mode is taken from the CMake cache of the build directory
-- that test-run passes in BUILDDIR.
function M.is_bundled_libyaml()
    local builddir = os.getenv('BUILDDIR')
    if builddir == nil then
        error('BUILDDIR is not set: run the test with test-run or set ' ..
              'BUILDDIR to the build directory', 2)
    end
    local path = fio.pathjoin(builddir, 'CMakeCache.txt')
    local f = io.open(path)
    if f == nil then
        error(path .. ' is not found: set BUILDDIR to the build directory',
              2)
    end
    local cache = f:read('*a')
    f:close()
    local value = ('\n' .. cache):match('\nENABLE_BUNDLED_LIBYAML:BOOL=(%w*)')
    if value == nil then
        error('ENABLE_BUNDLED_LIBYAML is not found in ' .. path ..
              ': set BUILDDIR to the build directory', 2)
    end
    local number = tonumber(value)
    return TRUE_VALUES[value:upper()] ~= nil or
           (number ~= nil and number ~= 0)
end

return M
