local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_each(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
    local path = require('fio').pathjoin(os.getenv('BUILDDIR'),
                                         'test/app-luatest/lib')
    cg.server:exec(function(path)
        package.cpath = path .. '/?.so;' .. path .. '/?.dylib;' .. package.cpath
    end, {path})
end)

g.after_each(function(cg)
    require('test.lsan').stop(cg.server,
                             {'third_party/libyaml/', 'third_party/lua-yaml/'})
end)

g.test_output_buffer = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        local oom = require('libyaml_oom')
        local chunks = {}
        for i = 1, 10000 do
            chunks[i] = ('x%08x'):format(i)
        end
        local value = table.concat(chunks)
        local result, status, failed, sizes = oom.call(yaml.encode, value, 0)
        t.assert_equals(status, 0)
        t.assert_not(failed)
        t.assert_equals(result, '--- ' .. value .. '\n...\n')
        local result_size = #result + oom.string_overhead
        result = nil -- luacheck: ignore (let GC remove the interned result)
        local fill, finish
        for i, size in ipairs(sizes) do
            if size == oom.buffer_size + oom.string_overhead then
                fill = i
            elseif size == result_size then
                finish = i
            end
        end
        t.assert(fill, 'found an allocation while filling the buffer')
        t.assert(finish, 'found an allocation while finalizing the buffer')
        for _, index in ipairs({fill, finish}) do
            for _ = 1, 20 do
                collectgarbage('collect')
                result, status, failed = oom.call(yaml.encode, value, 0,
                                                  sizes[index])
                t.assert(failed)
                t.assert_not_equals(status, 0)
                t.assert_str_contains(result, 'memory')
                t.assert_equals(yaml.decode(yaml.encode({1, 2})), {1, 2})
            end
        end
    end)
end

g.test_other_allocations = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        local oom = require('libyaml_oom')
        local function tagged(doc)
            return yaml.decode(doc, {tag_only = true})
        end
        for _, case in ipairs({
            {yaml.encode, {a = {1, 2}, b = require('varbinary').new('abc')}},
            {yaml.decode, 'a: [1, 2]\nb: !!binary YWJj\n'},
            {tagged, '%TAG !foo! tag:example.com,2026:\n--- 1\n'},
        }) do
            collectgarbage('collect')
            local result, status, failed, sizes = oom.call(case[1], case[2], 0)
            t.assert_equals(status, 0)
            t.assert_not(failed)
            t.assert_not_equals(result, nil)
            result = nil -- luacheck: ignore (release the successful result)
            for index = 1, #sizes do
                collectgarbage('collect')
                result, status, failed = oom.call(case[1], case[2], index)
                if failed then
                    t.assert_not_equals(status, 0)
                    t.assert_str_contains(tostring(result), 'memory')
                end
                result = nil -- luacheck: ignore (release the error before GC)
                t.assert_equals(yaml.decode(yaml.encode({1, 2})), {1, 2})
            end
        end
    end)
end

local function test_binary_result(cg, mode)
    cg.server:exec(function(mode)
        local yaml = require('yaml')
        local oom = require('libyaml_oom')
        local compat = require('compat')
        local varbinary = require('varbinary')
        local saved = compat.binary_data_decoding.current
        compat.binary_data_decoding = mode
        local ok, err = pcall(function()
            local doc = '!!binary ' .. ('YWJj'):rep(1000)
            local overhead = mode == 'old' and oom.string_overhead or
                             oom.varbinary_overhead
            local result_size = 3000 + overhead
            local function check_result(result)
                if mode == 'old' then
                    t.assert_equals(type(result), 'string')
                else
                    t.assert(varbinary.is(result))
                end
                t.assert_equals(tostring(result), ('abc'):rep(1000))
            end
            local result, status, failed, sizes = oom.call(yaml.decode, doc, 0)
            t.assert_equals(status, 0)
            t.assert_not(failed)
            check_result(result)
            local matches = 0
            for _, size in ipairs(sizes) do
                if size == result_size then
                    matches = matches + 1
                end
            end
            t.assert_equals(matches, 1, 'one allocation for the binary result')
            result = nil -- luacheck: ignore (release the interned string)
            for _ = 1, 20 do
                collectgarbage('collect')
                result, status, failed = oom.call(yaml.decode, doc, 0,
                                                  result_size)
                t.assert(failed, 'failed the binary result allocation')
                t.assert_not_equals(status, 0)
                t.assert_str_contains(tostring(result), 'memory')
                check_result(yaml.decode(doc))
                t.assert_equals(yaml.decode(yaml.encode({1, 2})), {1, 2})
            end
        end)
        compat.binary_data_decoding = saved
        t.assert(ok, err)
    end, {mode})
end

g.test_binary_string_result = function(cg)
    test_binary_result(cg, 'old')
end

g.test_binary_varbinary_result = function(cg)
    test_binary_result(cg, 'new')
end
