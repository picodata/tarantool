local server = require('luatest.server')
local t = require('luatest')
local yaml_helper = require('test.app-luatest.yaml_helper')

local g = t.group()

-- The bundled libyaml limits the sum of the flow level and the indentation
-- stack to 1000, so the number of nested collections it accepts depends on
-- the form of the document. Documents are decoded and checked inside the
-- instance on the default fiber stack of the build, and only a short
-- result is returned: encoding a deep table to pass it back is a different
-- matter, the limit protects only decoding.

g.before_all(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

local function skip_if_not_bundled()
    t.skip_if(not yaml_helper.is_bundled_libyaml(),
              'the depth limit is a feature of the bundled libyaml')
end

-- Decodes the document built by the generator for each count and returns
-- either the number of nested collections and the innermost value or the
-- error. Every collection of these documents has exactly one entry.
local function decode_depth(cg, gen, counts)
    local docs = {}
    for i, n in ipairs(counts) do
        docs[i] = gen(n)
    end
    return cg.server:exec(function(docs)
        local yaml = require('yaml')
        local res = {}
        for i, doc in ipairs(docs) do
            local ok, v = pcall(yaml.decode, doc)
            if ok then
                local depth = 0
                while type(v) == 'table' do
                    depth = depth + 1
                    local _, child = next(v)
                    v = child
                end
                res[i] = {depth = depth, value = v}
            else
                res[i] = {error = tostring(v)}
            end
        end
        return res
    end, {docs})
end

local function assert_depth_error(res)
    t.assert_str_contains(res.error or '', 'exceeded maximum nesting depth')
end

-- Nested flow sequences: [[[0]]].
g.test_flow_sequences = function(cg)
    skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        return ('['):rep(n) .. '0' .. (']'):rep(n)
    end, {999, 1000, 1001})
    t.assert_equals(res[1], {depth = 999, value = 0})
    t.assert_equals(res[2], {depth = 1000, value = 0})
    assert_depth_error(res[3])
end

-- Nested block sequences: every '- ' adds an indentation level.
g.test_block_sequences = function(cg)
    skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        return ('- '):rep(n) .. '0'
    end, {999, 1000})
    t.assert_equals(res[1], {depth = 999, value = 0})
    assert_depth_error(res[2])
end

-- Block and flow levels are counted together.
g.test_mixed_levels = function(cg)
    skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        return ('- '):rep(500) .. ('['):rep(n) .. '0' .. (']'):rep(n)
    end, {500, 501})
    t.assert_equals(res[1], {depth = 1000, value = 0})
    assert_depth_error(res[2])
end

-- A flow mapping in every flow sequence: [a: [a: 0]]. A mapping doesn't
-- add a level here, so 1000 levels hold 2000 nested collections.
g.test_flow_pairs = function(cg)
    skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        return ('[a: '):rep(n) .. '0' .. (']'):rep(n)
    end, {1000, 1001})
    t.assert_equals(res[1], {depth = 2000, value = 0})
    assert_depth_error(res[2])
end

-- Block mappings and sequences without an extra indentation:
--
-- a:
-- - a:
--   - a:
--     - 0
g.test_block_pairs = function(cg)
    skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        local lines = {'a:\n'}
        for i = 0, n - 2 do
            table.insert(lines, ('  '):rep(i) .. '- a:\n')
        end
        table.insert(lines, ('  '):rep(n - 1) .. '- 0\n')
        return table.concat(lines)
    end, {999, 1000})
    t.assert_equals(res[1], {depth = 1998, value = 0})
    assert_depth_error(res[2])
end

-- The limit is about nesting, not about the number of elements.
g.test_long_flat_sequence = function(cg)
    local n = cg.server:exec(function()
        local yaml = require('yaml')
        local items = {}
        for i = 1, 5000 do
            items[i] = tostring(i)
        end
        local res = yaml.decode('[' .. table.concat(items, ', ') .. ']')
        t.assert_equals(res[5000], 5000)
        return #res
    end)
    t.assert_equals(n, 5000)
end

g.test_several_documents = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        t.assert_equals({yaml.decode('--- [1]\n--- {a: 2}\n--- 3\n')},
                        {{1}, {a = 2}, 3})
    end)
end

-- decode_max_depth belongs to the common serializer options and doesn't
-- change the limit of libyaml.
g.test_decode_max_depth = function(cg)
    skip_if_not_bundled()
    cg.server:exec(function()
        -- A private instance keeps the shared server's yaml.cfg intact.
        local yaml = require('yaml').new()
        local function doc(n)
            return ('['):rep(n) .. '0' .. (']'):rep(n)
        end
        for _, max_depth in ipairs({32, 5000}) do
            yaml.cfg{decode_max_depth = max_depth}
            local msg = 'decode_max_depth = ' .. max_depth
            t.assert((pcall(yaml.decode, doc(1000))), msg)
            local ok, err = pcall(yaml.decode, doc(1001))
            t.assert_not(ok, msg)
            t.assert_str_contains(tostring(err),
                                  'exceeded maximum nesting depth')
        end
    end)
end

local g_deep = t.group('yaml_nesting_limit_deep')

g_deep.before_each(function(cg)
    cg.server = server:new({alias = 'deep'})
    cg.server:start()
end)

g_deep.after_each(function(cg)
    cg.server:drop()
end)

-- A document far beyond the limit is rejected with an error that can be
-- caught, and the instance keeps working.
g_deep.test_too_deep = function(cg)
    skip_if_not_bundled()
    cg.server:exec(function()
        local yaml = require('yaml')
        local doc = ('['):rep(10000) .. '0' .. (']'):rep(10000)
        local ok, err = pcall(yaml.decode, doc)
        t.assert_not(ok)
        t.assert_str_contains(tostring(err), 'exceeded maximum nesting depth')
        t.assert_equals(yaml.decode('a: [1, 2]'), {a = {1, 2}})
    end)
    t.assert_equals(cg.server:exec(function() return 1 + 1 end), 2)
end
