local t = require('luatest')

local M = {}

-- A system libyaml may have no nesting limit (for example, 0.2.5).
function M.is_bundled_libyaml()
    local options = require('tarantool').build.options
    local value = options:match('%-DENABLE_BUNDLED_LIBYAML=(%u+)')
    assert(value == 'TRUE' or value == 'FALSE',
           'ENABLE_BUNDLED_LIBYAML is missing or invalid in build.options')
    return value == 'TRUE'
end

function M.skip_if_not_bundled()
    t.skip_if(not M.is_bundled_libyaml(),
              'the depth limit is a feature of the bundled libyaml')
end

return M
