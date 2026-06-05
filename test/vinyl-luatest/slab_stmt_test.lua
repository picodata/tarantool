-- Vinyl keeps statements in the slab allocator and the in-memory
-- tree references them directly. Two consequences are exercised
-- here:
--
--   reclaim -- when a key is overwritten or deleted, the memory its
--     old versions held must come back and the index must hold no
--     residue: a deleted key reads as gone in every index, and a
--     stale secondary-key value never returns a live tuple.
--
--   sharing -- one user statement is written to the primary key and
--     to every secondary key as the SAME slab tuple. Transaction
--     prepare may rewrite that tuple's INSERT/REPLACE type in place;
--     a rewrite done for one index must not corrupt the tuple the
--     other indexes already stored.

local server = require('luatest.server')
local t = require('luatest')

-- wait_compaction and compact_fully are installed into the server's _G
-- by before_all and called inside server:exec blocks.
-- luacheck: globals wait_compaction compact_fully

-- {{{ reclaim

local gr = t.group('slab_stmt.reclaim')

gr.before_all(function(cg)
    cg.server = server:new({
        box_cfg = {
            vinyl_memory = 64 * 1024 * 1024,
            vinyl_defer_deletes = true,
        },
    })
    cg.server:start()
    -- Install a server-side helper so each case can wait for the
    -- background scheduler to go idle without redefining it.
    cg.server:exec(function()
        rawset(_G, 'wait_compaction', function()
            t.helpers.retrying({timeout = 30}, function()
                t.assert_covers(box.stat.vinyl().scheduler,
                                {compaction_queue = 0, tasks_inprogress = 0})
            end)
        end)
        -- Snapshot, then compact every index a few times so that
        -- tombstones reach the last level and cancel.
        rawset(_G, 'compact_fully', function(s)
            box.snapshot()
            wait_compaction()
            for _ = 1, 3 do
                for _, idx in pairs(s.index) do
                    if type(idx) == 'table' then
                        idx:compact()
                        wait_compaction()
                    end
                end
                box.snapshot()
                wait_compaction()
            end
        end)
    end)
end)

gr.after_all(function(cg)
    cg.server:drop()
end)

gr.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then box.space.test:drop() end
    end)
end)

-- A key is on disk, then overwritten and deleted in memory. After
-- compaction nothing for that key may survive: the delete cancels
-- both the on-disk version and the in-memory overwrite.
gr.test_overwrite_then_delete_single_index = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        s:insert{1, 1}
        box.snapshot()
        wait_compaction()

        s:replace{1, 2}
        s:delete(1)

        compact_fully(s)
        t.assert_equals(s.index.pk:stat().rows, 0, 'pk empty')
    end)
end

-- Same shape, but the overwrite also moves the secondary-key value
-- (10 -> 20). The delete must clear the primary key and both the
-- old and new secondary entries.
gr.test_overwrite_then_delete_with_sk = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {unique = false, parts = {{2, 'unsigned'}}})

        s:insert{1, 10}
        box.snapshot()
        wait_compaction()

        s:replace{1, 20}
        s:delete(1)

        compact_fully(s)
        t.assert_equals(s.index.pk:stat().rows, 0, 'pk empty')
        t.assert_equals(s.index.sk:stat().rows, 0, 'sk empty')
    end)
end

-- A key inserted and re-written inside one transaction collapses to
-- a single in-memory version. A later delete must still erase it.
-- Covers both the REPLACE and the UPDATE form of the re-write.
gr.test_same_tx_write_then_delete = function(cg)
    cg.server:exec(function()
        for _, rewrite in ipairs({'replace', 'update'}) do
            local s = box.schema.create_space('test', {engine = 'vinyl'})
            s:create_index('pk', {parts = {1, 'unsigned'}})

            box.begin()
            s:insert{1, 1}
            if rewrite == 'replace' then
                s:replace{1, 2}
            else
                s:update(1, {{'=', 2, 2}})
            end
            box.commit()
            box.snapshot()
            wait_compaction()

            s:delete(1)
            compact_fully(s)
            t.assert_equals(s.index.pk:stat().rows, 0,
                            rewrite .. ': pk empty')
            s:drop()
        end
    end)
end

-- A delete in memory must erase a key that was overwritten in the
-- same memory generation, leaving both indexes empty after
-- compaction -- including the mixed case where an older version of
-- the key still lives on disk.
gr.test_delete_erases_in_memory_overwrite = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {unique = false,
            parts = {{2, 'unsigned'}, {3, 'unsigned'}}})

        -- Both writes in one generation, then delete.
        s:replace{1, 10, 20}
        s:replace{1, 11, 21}
        s:delete(1)
        compact_fully(s)
        t.assert_equals(s.index.pk:stat().rows, 0, 'pk empty')
        t.assert_equals(s.index.sk:stat().rows, 0, 'sk empty')
        s:truncate()

        -- First write on disk, second in memory, then delete.
        s:replace{1, 10, 20}
        box.snapshot()
        wait_compaction()
        s:replace{1, 11, 21}
        s:delete(1)
        compact_fully(s)
        t.assert_equals(s.index.pk:stat().rows, 0, 'pk empty (disk ancestor)')
        t.assert_equals(s.index.sk:stat().rows, 0, 'sk empty (disk ancestor)')
    end)
end

-- One primary key overwritten many times with a changing secondary
-- value. The primary keeps only the latest; a secondary lookup by
-- the current value finds the tuple, and a lookup by any stale
-- value returns nothing -- no phantom secondary entries linger.
gr.test_stale_secondary_values_are_not_returned = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {parts = {2, 'unsigned'}, unique = false})

        for v = 1, 50 do s:replace{1, v} end

        t.assert_equals(s:get{1}, {1, 50}, 'pk holds latest')
        t.assert_equals(s.index.sk:select{50}, {{1, 50}}, 'current sk found')
        for v = 1, 49 do
            t.assert_equals(#s.index.sk:select{v}, 0,
                            ('stale sk=%d returns nothing'):format(v))
        end
    end)
end

-- Many distinct keys, each written once: nothing is overwritten, so
-- every primary and secondary entry must survive. Control case.
gr.test_distinct_keys_all_survive = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {parts = {2, 'unsigned'}, unique = false})

        for k = 1, 100 do s:replace{k, k * 10} end

        t.assert_equals(s:len(), 100)
        for k = 1, 100 do
            t.assert_equals(s:get{k}, {k, k * 10})
            t.assert_equals(#s.index.sk:select{k * 10}, 1)
        end
    end)
end

-- Many keys, each overwritten across several rounds with a fresh
-- secondary value. Every key's current value resolves; every
-- superseded value is gone from the secondary index.
gr.test_interleaved_overwrites = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {parts = {2, 'unsigned'}, unique = false})

        local N, ROUNDS = 10, 10
        for round = 1, ROUNDS do
            for k = 1, N do s:replace{k, round * 100 + k} end
        end

        for k = 1, N do
            local cur = ROUNDS * 100 + k
            t.assert_equals(s:get{k}, {k, cur})
            t.assert_equals(#s.index.sk:select{cur}, 1)
            for round = 1, ROUNDS - 1 do
                t.assert_equals(#s.index.sk:select{round * 100 + k}, 0,
                    ('stale sk for k=%d'):format(k))
            end
        end
    end)
end

-- A non-trivial mix of inserts, replaces, upserts and updates is
-- dumped, then every key is deleted. After full compaction both
-- indexes must be empty -- every delete pairs with its tuple.
gr.test_mixed_write_sequence_then_delete_all = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:on_replace(function() end)
        s:create_index('pk')
        s:create_index('sk', {parts = {2, 'unsigned'}, unique = false})

        s:insert{1, 1}
        s:replace{2, 2}
        s:upsert({3, 3}, {{'!', 1, 1}})
        box.begin() s:insert{4, 4} s:delete(4) box.commit()
        box.begin() s:insert{5, 5} s:replace{5, 5, 5} box.commit()
        box.begin() s:insert{6, 6} s:update(6, {{'!', 2, 6}}) box.commit()
        s:insert{7, 7}
        s:insert{8, 8}
        box.snapshot()
        wait_compaction()

        s:delete{1} s:delete{2} s:delete{3} s:delete{4} s:delete{5}
        s:delete{6}
        s:update(7, {{'=', 2, 77}}) s:delete{7}
        s:upsert({8, 8}, {{'=', 2, 88}}) s:delete{8}

        compact_fully(s)
        t.assert_equals(s.index.pk:stat().rows, 0, 'pk empty')
        t.assert_equals(s.index.sk:stat().rows, 0, 'sk empty')
    end)
end

-- A large padding run keeps later compactions off the last level,
-- so a delete cannot be discarded by the simple last-level rule and
-- must instead cancel against its tuple directly. A key is updated
-- (moving its secondary value) and deleted; neither index may keep
-- a residual row for it.
gr.test_update_then_delete_non_last_level = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:on_replace(function() end)
        local pk = s:create_index('pk', {run_count_per_level = 1})
        local sk = s:create_index('sk',
            {run_count_per_level = 1, parts = {2, 'unsigned'},
             unique = false})

        for i = 1, 100 do s:replace{i + 1000, i + 1000} end
        box.snapshot()
        wait_compaction()

        s:insert{7, 7}
        box.snapshot()
        wait_compaction()

        s:update(7, {{'=', 2, 77}})
        s:delete{7}
        compact_fully(s)

        t.assert_equals(pk:select{7}, {}, 'pk has no key 7')
        t.assert_equals(sk:select{77}, {}, 'sk has no key 7 at 77')
        t.assert_equals(sk:select{7}, {}, 'sk has no key 7 at 7')
        for _, idx in ipairs({pk, sk}) do
            for _, tuple in idx:pairs() do
                t.assert(tuple[1] > 1000, 'only padding rows survive')
            end
        end
    end)
end

-- defer_deletes routes deletes through a compaction-time pipeline
-- that pairs a delete with the tuple it removes to invalidate that
-- tuple's secondary entries. Three same-key versions are layered
-- across disk and memory so the pipeline must pair correctly even
-- after the middle version is reclaimed; after deleting the key,
-- both indexes must be empty.
gr.test_deferred_delete_pairing_chain = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {unique = false,
            parts = {{2, 'unsigned'}, {3, 'unsigned'}}})

        s:replace{1, 10, 20}
        box.snapshot()
        wait_compaction()

        s:replace{1, 11, 21}
        s:replace{1, 12, 22}
        s:delete(1)

        compact_fully(s)
        t.assert_equals(s.index.pk:stat().rows, 0, 'pk empty')
        t.assert_equals(s.index.sk:stat().rows, 0, 'sk empty')
    end)
end

-- A multikey secondary index lists every array value of a tuple.
-- When the tuple is overwritten with a smaller array, the values it
-- still carries must keep their secondary entries; only the dropped
-- values lose theirs. Here {3,4} -> {3}: a lookup by 3 must still
-- find the live tuple, a lookup by 4 must not.
gr.test_multikey_overwrite_keeps_live_keys = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {unique = false,
            parts = {{'[3][*]', 'unsigned'}, {2, 'unsigned'}}})

        s:replace{1, 5, {3, 4}}
        s:replace{1, 5, {3}}

        box.snapshot()
        wait_compaction()
        s.index.pk:compact()
        wait_compaction()
        s.index.sk:compact()
        wait_compaction()

        t.assert_equals(s:get{1}, {1, 5, {3}}, 'live tuple intact')
        t.assert_equals(s.index.sk:select{3}, {{1, 5, {3}}},
                        'value 3 still indexed')
        t.assert_equals(#s.index.sk:select{4}, 0, 'value 4 dropped')
    end)
end

-- One tuple backs several entries of a multikey index -- one per
-- array value. When such a tuple is overwritten repeatedly under
-- deferred deletes, and open read views pin the older versions so
-- they reach compaction as separate outputs, every stale array
-- value must be invalidated. Invalidating one entry must not strip
-- the pending mark from the siblings that share the same tuple. The
-- read views are held in background transactions across the dump so
-- the older versions are not collapsed before compaction sees them.
gr.test_multikey_overwrite_invalidates_all_stale = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')

        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('mk', {unique = false,
            parts = {{'[2][*]', 'unsigned'}}})

        s:replace{1, {10, 11, 12}}
        box.snapshot()
        wait_compaction()

        local release = fiber.channel()
        local holders = {}
        local function hold()
            local opened = fiber.channel()
            local f = fiber.new(function()
                box.begin({txn_isolation = 'read-confirmed'})
                s:get{1}
                opened:put(true)
                release:get()
                pcall(box.commit)
            end)
            f:set_joinable(true)
            opened:get()
            table.insert(holders, f)
        end

        s:replace{1, {20, 21, 22}}; hold()
        s:replace{1, {30, 31, 32}}; hold()
        s:replace{1, {40, 41, 42}}

        box.snapshot()
        wait_compaction()

        for _ = 1, #holders do release:put(true) end
        for _, f in ipairs(holders) do f:join() end

        box.snapshot()
        wait_compaction()
        for _ = 1, 3 do
            s.index.pk:compact(); wait_compaction()
            s.index.mk:compact(); wait_compaction()
            box.snapshot(); wait_compaction()
        end

        t.assert_equals(s:get{1}, {1, {40, 41, 42}}, 'live tuple kept')
        for _, v in ipairs({10, 11, 12, 20, 21, 22, 30, 31, 32}) do
            t.assert_equals(#s.index.mk:select{v}, 0,
                            ('stale mk=%d gone'):format(v))
        end
        t.assert_equals(s.index.mk:stat().rows, 3, 'only live array kept')
    end)
end

-- }}} reclaim

-- {{{ sharing

local gs = t.group('slab_stmt.sharing')

gs.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

gs.after_all(function(cg)
    cg.server:drop()
end)

gs.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then box.space.test:drop() end
    end)
end)

--[[
A space with pk + sk stores one user statement as a single slab
tuple that both indexes reference. At prepare, vinyl may rewrite
that tuple's type in place to keep its INSERT/REPLACE accounting
exact:

    INSERT, but a prior version exists  ->  store as REPLACE
    REPLACE, but no prior version       ->  store as INSERT

The primary key is processed first and its rewrite is meant to be
seen by the secondaries. But a secondary's own rewrite, done on the
shared tuple, would reach back and change what the primary already
stored. Each case drives one (primary type, prior-version) combo
and asserts the per-index statement types that land in the dumped
runs -- the contract that holds regardless of which index the
shared tuple was rewritten for.
]]
local function run_case(case)
    local s = box.schema.space.create('test', {engine = 'vinyl'})
    local pk = s:create_index('pk',
        {parts = {{1, 'unsigned'}}, run_count_per_level = 100})
    local sk = s:create_index('sk',
        {parts = {{2, 'unsigned'}}, unique = false,
         run_count_per_level = 100})
    if case.setup == 'seed_1_10' then
        s:insert{1, 10}
        box.snapshot()
    elseif case.setup == 'seed_1_10_and_2_20' then
        s:insert{1, 10}
        s:insert{2, 20}
        box.snapshot()
    end
    local pk0 = pk:stat().disk.statement
    local sk0 = sk:stat().disk.statement
    box.begin()
    for _, op in ipairs(case.ops) do s[op[1]](s, unpack(op, 2)) end
    box.commit()
    box.snapshot()
    local function delta(idx, before)
        local a = idx:stat().disk.statement
        return {inserts = a.inserts - before.inserts,
                replaces = a.replaces - before.replaces,
                deletes = a.deletes - before.deletes}
    end
    t.assert_equals(delta(pk, pk0), case.expect_pk, case.name .. ': pk')
    t.assert_equals(delta(sk, sk0), case.expect_sk, case.name .. ': sk')
end

-- Fresh INSERT of a never-seen key: no prior version, so it stays
-- an INSERT in both indexes.
gs.test_insert_fresh_key = function(cg)
    cg.server:exec(run_case, {{
        name = 'insert fresh',
        ops = {{'insert', {1, 10}}},
        expect_pk = {inserts = 1, replaces = 0, deletes = 0},
        expect_sk = {inserts = 1, replaces = 0, deletes = 0}}})
end

-- DELETE then INSERT of an existing key, value changed. The INSERT
-- follows an in-tx delete so the primary stores it as a REPLACE;
-- the secondary, whose new key is fresh, keeps it an INSERT on its
-- own private copy without dragging the primary back to INSERT.
gs.test_tx_delete_insert_changed_value = function(cg)
    cg.server:exec(run_case, {{
        name = 'delete+insert changed value',
        setup = 'seed_1_10',
        ops = {{'delete', {1}}, {'insert', {1, 20}}},
        expect_pk = {inserts = 0, replaces = 1, deletes = 0},
        expect_sk = {inserts = 1, replaces = 0, deletes = 1}}})
end

-- INSERT then REPLACE of a fresh key in one tx: the primary folds
-- to a single INSERT; the secondary's intermediate entries cancel,
-- leaving one INSERT.
gs.test_tx_insert_replace_fresh = function(cg)
    cg.server:exec(run_case, {{
        name = 'insert+replace fresh',
        ops = {{'insert', {1, 10}}, {'replace', {1, 10}}},
        expect_pk = {inserts = 1, replaces = 0, deletes = 0},
        expect_sk = {inserts = 1, replaces = 0, deletes = 0}}})
end

-- Plain REPLACE over committed data: a prior version exists, no
-- rewrite fires, both indexes store REPLACE (the secondary also
-- emits a DELETE at the old secondary key).
gs.test_replace_existing = function(cg)
    cg.server:exec(run_case, {{
        name = 'replace existing',
        setup = 'seed_1_10',
        ops = {{'replace', {1, 20}}},
        expect_pk = {inserts = 0, replaces = 1, deletes = 0},
        expect_sk = {inserts = 0, replaces = 1, deletes = 1}}})
end

-- Fresh primary key whose secondary value is already bound to a
-- different key: the secondary write set keys on the full
-- (value, pk) pair, so this is an independent fresh INSERT.
gs.test_fresh_pk_reused_sk_value = function(cg)
    cg.server:exec(run_case, {{
        name = 'fresh pk, reused sk value',
        setup = 'seed_1_10_and_2_20',
        ops = {{'insert', {3, 10}}},
        expect_pk = {inserts = 1, replaces = 0, deletes = 0},
        expect_sk = {inserts = 1, replaces = 0, deletes = 0}}})
end

-- INSERT then REPLACE in one tx, secondary value changed. The
-- primary folds to INSERT (mutating the shared tuple); the
-- secondary, at its brand-new key, would rewrite the shared tuple
-- back to REPLACE. The guard keeps that rewrite on a private copy,
-- so the primary's INSERT is never downgraded. (On dump to an empty
-- run the secondary REPLACE may be upgraded to INSERT, which is
-- fine -- INSERT carries strictly more information.)
gs.test_tx_insert_replace_changed_value = function(cg)
    cg.server:exec(run_case, {{
        name = 'insert+replace changed value',
        ops = {{'insert', {1, 10}}, {'replace', {1, 20}}},
        expect_pk = {inserts = 1, replaces = 0, deletes = 0},
        expect_sk = {inserts = 1, replaces = 0, deletes = 0}}})
end

-- DELETE then INSERT of an existing key, value unchanged. The
-- secondary's delete and re-insert hit the same key and cancel, so
-- nothing lands in the secondary; the primary stores one REPLACE.
gs.test_tx_delete_insert_same_value = function(cg)
    cg.server:exec(run_case, {{
        name = 'delete+insert same value',
        setup = 'seed_1_10',
        ops = {{'delete', {1}}, {'insert', {1, 10}}},
        expect_pk = {inserts = 0, replaces = 1, deletes = 0},
        expect_sk = {inserts = 0, replaces = 0, deletes = 0}}})
end

-- }}} sharing
