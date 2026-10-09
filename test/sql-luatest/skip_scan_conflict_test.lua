local t = require('luatest')
local server = require('luatest.server')

local g = t.group('skip_scan_conflict', t.helpers.matrix({
    engine = {'memtx', 'vinyl'},
}))

g.before_all(function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server = server:new({box_cfg = {memtx_use_mvcc_engine = true}})
    cg.server:start()
end)

g.after_all(function(cg)
    if cg.server then
        cg.server:drop()
    end
end)

g.test_probe_read_is_tracked = function(cg)
    cg.server:exec(function(engine)
        assert(box.execute(('SET SESSION "sql_default_engine"=\'%s\'')
                           :format(engine)))
        assert(box.execute([[CREATE TABLE t(id INTEGER PRIMARY KEY,
                             bucket INTEGER,k INTEGER,payload INTEGER)]]))
        assert(box.execute('CREATE INDEX bk ON t(bucket,k)'))
        assert(box.execute('INSERT INTO t VALUES(1,1,1,0),(2,1,2,0),(3,1,3,0),(4,1,4,0)'))
        local txn_proxy = require('test.box.lua.txn_proxy')
        for _, direct in ipairs({true, false}) do
            local tx = txn_proxy.new()
            tx:begin()
            -- T1 must be a writer before T2 commits, so memtx MVCC cannot
            -- move T1 to a read view and allow a read-only commit instead.
            tx('box.space.T:insert{10,10,10,0}')
            if direct then
                t.assert_equals(tx('box.space.T:get{3}'), {{3, 1, 3, 0}})
            else
                box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_TRACE', true)
                local result = tx([[box.execute('SELECT id FROM t ' ..
                    'INDEXED BY bk WHERE k IN (1,4) ORDER BY id')]])
                box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_TRACE', false)
                t.assert_equals(result[1].rows, {{1}, {4}})
            end
            -- R=3 is outside the SQL result but is visited while stepping
            -- from k=2 to k=4. Extra conflicts from such reads are allowed.
            box.space.T:update({3}, {{'+', 4, 1}})
            t.assert_equals(tx:commit(),
                {{error = 'Transaction has been aborted by conflict'}})
            tx:close()
        end
    end, {cg.params.engine})
    -- This trace is emitted only after a successful probe step returns a
    -- tuple. It records the primary key, not a seek or a SQL result row.
    t.assert(cg.server:grep_log('skip%-scan probe: space=T key=%[3%]'))
end
