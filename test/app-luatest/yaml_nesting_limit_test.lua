local server = require('luatest.server')
local t = require('luatest')
local yaml_helper = require('test.app-luatest.yaml_helper')

local g = t.group()

-- The bundled libyaml limits the sum of the flow level and the indentation
-- stack to 1000, so the number of nested collections it accepts depends on
-- the form of the document. Documents are decoded and checked inside the
-- instance on the default fiber stack of the build, and only a short
-- result is returned. Encoding has its own encode_max_depth limit.

g.before_all(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

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
    yaml_helper.skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        return ('['):rep(n) .. '0' .. (']'):rep(n)
    end, {999, 1000, 1001})
    t.assert_equals(res[1], {depth = 999, value = 0})
    t.assert_equals(res[2], {depth = 1000, value = 0})
    assert_depth_error(res[3])
end

-- Nested block sequences: every '- ' adds an indentation level.
g.test_block_sequences = function(cg)
    yaml_helper.skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        return ('- '):rep(n) .. '0'
    end, {999, 1000})
    t.assert_equals(res[1], {depth = 999, value = 0})
    assert_depth_error(res[2])
end

-- Block and flow levels are counted together.
g.test_mixed_levels = function(cg)
    yaml_helper.skip_if_not_bundled()
    local res = decode_depth(cg, function(n)
        return ('- '):rep(500) .. ('['):rep(n) .. '0' .. (']'):rep(n)
    end, {500, 501})
    t.assert_equals(res[1], {depth = 1000, value = 0})
    assert_depth_error(res[2])
end

-- A flow mapping in every flow sequence: [a: [a: 0]]. A mapping doesn't
-- add a level here, so 1000 levels hold 2000 nested collections.
g.test_flow_pairs = function(cg)
    yaml_helper.skip_if_not_bundled()
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
    yaml_helper.skip_if_not_bundled()
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
    yaml_helper.skip_if_not_bundled()
    cg.server:exec(function()
        local yaml = require('yaml')
        local old = yaml.cfg.decode_max_depth
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
        yaml.cfg{decode_max_depth = old}
    end)
end

local g_deep = t.group('yaml_nesting_limit_deep')

g.test_encode_depth = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml').new()
        local function chain(depth, kind)
            local value = 1
            for i = 1, depth do
                if kind == 'map' or (kind == 'mixed' and i % 2 == 0) then
                    value = {a = value}
                else
                    value = {value}
                end
            end
            return value
        end
        t.assert_equals(yaml.cfg.encode_max_depth, 128)
        for _, limit in ipairs({128, 2}) do
            yaml.cfg{encode_max_depth = limit, encode_deep_as_nil = false}
            for _, kind in ipairs({'array', 'map', 'mixed'}) do
                local value = chain(limit, kind)
                t.assert_equals(yaml.decode(yaml.encode(value)), value)
                t.assert_error_msg_contains('Too high nest level', yaml.encode,
                                            chain(limit + 1, kind))
            end
        end
        yaml.cfg{encode_deep_as_nil = true}
        t.assert_equals(yaml.decode(yaml.encode({{{1}}, 2})), {{box.NULL}, 2})
        t.assert_equals(yaml.decode(yaml.encode({a = {b = {c = 1}}, d = 2})),
                        {a = {b = box.NULL}, d = 2})
        local flat = {}
        for i = 1, 5000 do
            flat[i] = i
        end
        t.assert_equals(yaml.decode(yaml.encode(flat)), flat)
        local converted = setmetatable({}, {__serialize = function()
            return {{{1}}}
        end})
        t.assert_equals(yaml.decode(yaml.encode(converted)), {{box.NULL}})
        yaml.cfg{encode_deep_as_nil = false}
        t.assert_error_msg_contains('Too high nest level', yaml.encode,
                                    converted)
    end)
end

g.test_encode_alias_depth = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml').new()
        yaml.cfg{encode_max_depth = 2, encode_deep_as_nil = true}
        local shared = {1}
        local r = yaml.decode(yaml.encode({{shared}, shared}))
        t.assert_equals(r, {{box.NULL}, {1}})
        for _, as_nil in ipairs({false, true}) do
            yaml.cfg{encode_deep_as_nil = as_nil}
            r = yaml.decode(yaml.encode({shared, {shared}}))
            t.assert_is(r[1], r[2][1])
            t.assert_equals(r[1][1], 1)
            local cyc = {}
            cyc.self = cyc
            r = yaml.decode(yaml.encode({cyc}))
            t.assert_is(r[1].self, r[1])
        end
    end)
end

g.test_encode_complete_subtree = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        local shared = {{1}}
        local deep_first = yaml.encode({{shared}, shared})
        local shallow_first = yaml.encode({shared, {shared}})
        t.assert_equals(deep_first,
                        '---\n- - &0\n    - - 1\n- *0\n...\n')
        t.assert_equals(shallow_first,
                        '---\n- &0\n  - - 1\n- - *0\n...\n')
        local r = yaml.decode(deep_first)
        t.assert_is(r[1][1], r[2])
        t.assert_equals(r[2], shared)
        r = yaml.decode(shallow_first)
        t.assert_is(r[1], r[2][1])
        t.assert_equals(r[1], shared)
    end)
end

g.test_encode_revisit_cycle = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml').new()
        yaml.cfg{encode_max_depth = 6, encode_deep_as_nil = true}
        local a, b = {}, {}
        local calls = 0
        local child = setmetatable({}, {__serialize = function()
            calls = calls + 1
            return {42}
        end})
        a[1], a[2], b[1] = b, {{{child}}}, a
        -- b depends on a's truncated second child, through the cycle.
        local r = yaml.decode(yaml.encode({{{a}}, b}))
        t.assert_equals(r[1][1][1][2], {{box.NULL}})
        t.assert_is(r[2][1], r[1][1][1])
        t.assert_equals(calls, 1)
    end)
end

g.test_encode_revisit_subtree = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml').new()
        yaml.cfg{encode_max_depth = 4, encode_deep_as_nil = true}
        for _, converted in ipairs({false, true}) do
            for _, shallow_first in ipairs({false, true}) do
                local inner = {}
                inner.me = inner
                local shared = {inner}
                local calls = 0
                local object = shared
                if converted then
                    object = setmetatable({}, {__serialize = function()
                        calls = calls + 1
                        return shared
                    end})
                end
                local deep = {{{object}}}
                local value = shallow_first and {object, deep} or {deep, object}
                local r = yaml.decode(yaml.encode(value))
                if shallow_first then
                    t.assert_is(r[2][1][1][1], r[1])
                    t.assert_is(r[1][1].me, r[1][1])
                else
                    t.assert_equals(r[1][1][1][1], box.NULL)
                    t.assert_is(r[2][1].me, r[2][1])
                end
                t.assert_equals(calls, converted and 1 or 0)
            end
        end
    end)
end

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
    yaml_helper.skip_if_not_bundled()
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

g_deep.test_encode_decoded_document = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        local value = yaml.decode(('['):rep(1000) .. '0' .. (']'):rep(1000))
        t.assert_error_msg_contains('Too high nest level', yaml.encode, value)
        t.assert_equals(yaml.decode(yaml.encode({1})), {1})
    end)
    t.assert_equals(cg.server:exec(function() return 1 + 1 end), 2)
end
