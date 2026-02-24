local t = require('luatest')

local g = t.group('sandbox_digest')

g.before_all(function(cg)
    local server = require('luatest.server')
    cg.server = server:new{alias = 'master'}
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test then box.space.test:drop() end
    end)
end)

g.test_md5_hex_in_func_index = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test')
        s:create_index('pk')
        box.schema.func.create('md5_hash', {
            body = [[function(tuple)
                return {digest.md5_hex(tuple[2])}
            end]],
            is_deterministic = true,
            is_sandboxed = true
        })
        s:create_index('hash_idx', {
            func = 'md5_hash',
            parts = {{1, 'string'}}
        })

        s:insert{1, 'test@example.com'}
        local expected = require('digest').md5_hex('test@example.com')
        t.assert_equals(s.index.hash_idx:select{expected},
                        {{1, 'test@example.com'}})
    end)
end

g.test_sha256_hex_in_func_index = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test')
        s:create_index('pk')
        box.schema.func.create('sha256_hash', {
            body = [[function(tuple)
                return {digest.sha256_hex(tuple[2])}
            end]],
            is_deterministic = true,
            is_sandboxed = true
        })
        s:create_index('hash_idx', {
            func = 'sha256_hash',
            parts = {{1, 'string'}}
        })

        s:insert{1, 'hello world'}
        local expected = require('digest').sha256_hex('hello world')
        t.assert_equals(s.index.hash_idx:select{expected},
                        {{1, 'hello world'}})
    end)
end

g.test_multiple_digest_functions = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test')
        s:create_index('pk')
        box.schema.func.create('multi_hash', {
            body = [[function(tuple)
                return {digest.md5_hex(tuple[2]), digest.sha256_hex(tuple[2])}
            end]],
            is_deterministic = true,
            is_sandboxed = true
        })
        s:create_index('multi_idx', {
            func = 'multi_hash',
            parts = {{1, 'string'}, {2, 'string'}}
        })

        s:insert{1, 'data'}
        local d = require('digest')
        local md5 = d.md5_hex('data')
        local sha256 = d.sha256_hex('data')
        t.assert_equals(s.index.multi_idx:select{md5, sha256}, {{1, 'data'}})
    end)
end
