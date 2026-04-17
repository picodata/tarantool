local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    -- Several tests rely on all writes staying in memory until
    -- an explicit box.snapshot(); disable the checkpoint daemon
    -- so it cannot trigger an asynchronous dump mid-test.
    cg.server = server:new({
        box_cfg = {
            checkpoint_interval = 0,
        },
    })
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then
            box.space.test:drop()
        end
    end)
end)

--
-- Random mixed-DML workload on a space with a secondary index.
-- Run a sequence of insert/replace/update/upsert/delete against
-- a Lua oracle and confirm len() matches after every tenth op
-- and at the end. No snapshot is taken, so the workload stays
-- in memory and exercises the accounting path directly.
--
g.test_exact_count_with_secondary_index = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        local seed = fiber.time() * 1e6
        local log = require('log')
        log.info('space_len_test: seed = %d', seed)
        math.randomseed(seed)

        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            page_size = 512,
        })
        s:create_index('sk', {
            parts = {2, 'unsigned'},
            unique = false,
            page_size = 512,
        })

        local oracle = {} -- key -> true
        local oracle_count = 0

        -- Exercise all DML types in memory (no snapshot) so
        -- there are no cross-level duplicates.
        for i = 1, 500 do
            local key = math.random(1, 100)
            local op = math.random(1, 5)
            if op == 1 then
                -- insert (only if key is new)
                if oracle[key] == nil then
                    s:insert{key, key * 10}
                    oracle[key] = true
                    oracle_count = oracle_count + 1
                end
            elseif op == 2 then
                -- replace
                s:replace{key, key * 10}
                if oracle[key] == nil then
                    oracle[key] = true
                    oracle_count = oracle_count + 1
                end
            elseif op == 3 then
                -- update (only if key exists)
                if oracle[key] ~= nil then
                    s:update(key, {{'+', 2, 1}})
                end
            elseif op == 4 then
                -- upsert
                s:upsert({key, 0}, {{'+', 2, 1}})
                if oracle[key] == nil then
                    oracle[key] = true
                    oracle_count = oracle_count + 1
                end
            else
                -- delete
                s:delete{key}
                if oracle[key] ~= nil then
                    oracle_count = oracle_count - 1
                end
                oracle[key] = nil
            end

            if i % 10 == 0 then
                t.assert_equals(s:len(), oracle_count,
                    string.format('mismatch at op %d', i))
            end
        end

        t.assert_equals(s:len(), oracle_count, 'final count')
    end)
end

--
-- Insert keys, delete some, force a major compaction, and check
-- that len() is exact afterwards. A major compaction resolves
-- every version of every key down to at most one tuple, so the
-- count has to match the number of surviving keys.
--
g.test_exact_count_survives_compaction = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 1,
            page_size = 512,
        })
        s:create_index('sk', {
            parts = {2, 'unsigned'},
            unique = false,
            run_count_per_level = 1,
            page_size = 512,
        })

        for i = 1, 200 do
            s:replace{i, i * 10}
        end
        box.snapshot()

        for i = 1, 100 do
            s:delete{i}
        end
        box.snapshot()

        s.index.pk:compact()
        t.helpers.retrying({timeout = 5}, function()
            t.assert_ge(s.index.pk:stat().disk.compaction.count, 1)
        end)

        t.assert_equals(s:len(), 100)
    end)
end

--
-- Write a set of keys, dump, overwrite the same keys, dump
-- again, then force compaction. Exactly one tuple per key
-- survives on disk, and len() must report that count regardless
-- of how the individual writes were classified internally.
--
g.test_overwrite_compaction_with_sk = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 1,
            page_size = 512,
        })
        s:create_index('sk', {
            parts = {2, 'unsigned'},
            unique = false,
            run_count_per_level = 1,
            page_size = 512,
        })

        -- Initial write of 100 new keys, then dump.
        for i = 1, 100 do
            s:replace{i, i * 10}
        end
        t.assert_equals(s:len(), 100, 'after initial insert')
        box.snapshot()

        -- Overwrite all 100 keys, then dump again.
        for i = 1, 100 do
            s:replace{i, i * 20}
        end
        t.assert_equals(s:len(), 100, 'after overwrite')
        box.snapshot()

        -- Major compaction collapses each key to its newest
        -- surviving tuple. The count must still be 100.
        s.index.pk:compact()
        t.helpers.retrying({timeout = 5}, function()
            t.assert_ge(s.index.pk:stat().disk.compaction.count, 1)
        end)
        t.assert_equals(s:len(), 100, 'after compaction')
    end)
end

--
-- Insert keys on a primary-key-only space, delete some, and
-- verify len() before and after a snapshot. The count stays
-- exact because every operation has an unambiguous effect on
-- the live key set.
--
g.test_pk_only_insert_delete = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            page_size = 512,
        })

        -- Insert 100 keys.
        for i = 1, 100 do
            s:insert{i, i * 10}
        end
        t.assert_equals(s:len(), 100)

        -- Delete 25 keys. Count should be 75.
        for i = 1, 25 do
            s:delete{i}
        end
        t.assert_equals(s:len(), 75)

        -- Snapshot and verify the count persists.
        box.snapshot()
        t.assert_equals(s:len(), 75)
    end)
end

--
-- An empty space reports len() == 0. Inserting N keys and then
-- deleting them returns to 0, both in memory and across a
-- snapshot boundary.
--
g.test_edge_cases = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            page_size = 512,
        })

        -- Empty space.
        t.assert_equals(s:len(), 0)

        -- Insert N, delete N.
        local N = 50
        for i = 1, N do
            s:insert{i}
        end
        t.assert_equals(s:len(), N)

        for i = 1, N do
            s:delete{i}
        end
        t.assert_equals(s:len(), 0)

        -- Same across snapshot boundary.
        for i = 1, N do
            s:insert{i}
        end
        box.snapshot()
        for i = 1, N do
            s:delete{i}
        end
        t.assert_equals(s:len(), 0)

        box.snapshot()
        t.assert_equals(s:len(), 0)
    end)
end

--
-- Exercise every DML type (insert, replace, update, upsert,
-- delete) on a space with a secondary index and defer_deletes
-- off. len() should track the visible key count exactly at
-- each step and remain exact after a dump+compaction cycle.
--
g.test_sk_strict_all_ops = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 1,
            page_size = 512,
        })
        s:create_index('sk', {
            parts = {2, 'unsigned'},
            unique = false,
            run_count_per_level = 1,
            page_size = 512,
        })

        -- insert 50 keys
        for i = 1, 50 do
            s:insert{i, i * 10}
        end
        t.assert_equals(s:len(), 50, 'after inserts')

        -- replace 50 new keys
        for i = 51, 100 do
            s:replace{i, i * 10}
        end
        t.assert_equals(s:len(), 100, 'after replaces')

        -- update 20 keys (count unchanged)
        for i = 1, 20 do
            s:update(i, {{'+', 2, 1}})
        end
        t.assert_equals(s:len(), 100, 'after updates')

        -- upsert 20 new keys + 20 existing
        for i = 81, 120 do
            s:upsert({i, 0}, {{'+', 2, 1}})
        end
        t.assert_equals(s:len(), 120, 'after upserts')

        -- delete 30 keys
        for i = 1, 30 do
            s:delete{i}
        end
        t.assert_equals(s:len(), 90, 'after deletes')

        -- Verify across snapshot + compaction.
        box.snapshot()
        for i = 31, 50 do
            s:delete{i}
        end
        box.snapshot()
        s.index.pk:compact()
        t.helpers.retrying({timeout = 5}, function()
            t.assert_ge(s.index.pk:stat().disk.compaction.count, 1)
        end)
        t.assert_equals(s:len(), 70, 'exact after compaction')
    end)
end

--
-- Space with a secondary index and defer_deletes on. Before
-- major compaction, len() is approximate and may overcount, so
-- intermediate checks only assert non-negative lower bounds.
-- Once major compaction runs, the count has to equal the true
-- number of surviving keys.
--
g.test_sk_defer_deletes = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {
            engine = 'vinyl',
            defer_deletes = true,
        })
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 1,
            page_size = 512,
        })
        s:create_index('sk', {
            parts = {2, 'unsigned'},
            unique = false,
            run_count_per_level = 1,
            page_size = 512,
        })

        -- Replace 100 new keys and dump.
        for i = 1, 100 do
            s:replace{i, i * 10}
        end
        t.assert_ge(s:len(), 100, 'at least 100 after replaces')
        box.snapshot()

        -- Delete 50 keys and dump again to create a second run.
        for i = 1, 50 do
            s:delete{i}
        end
        t.assert_ge(s:len(), 0, 'non-negative')
        box.snapshot()

        -- After full compaction, count is exact.
        s.index.pk:compact()
        s.index.sk:compact()
        t.helpers.retrying({timeout = 5}, function()
            t.assert_ge(s.index.pk:stat().disk.compaction.count, 1)
        end)
        t.assert_equals(s:len(), 50, 'exact after compaction')
    end)
end

--
-- Primary-key-only space. Replace and upsert here don't read
-- the prior tuple, so len() before major compaction is an
-- estimate with a clamp-at-zero lower bound. Intermediate
-- checks only assert non-negative lower bounds; the exact
-- value is verified after major compaction.
--
g.test_pk_only_blind_all_ops = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 1,
            page_size = 512,
        })

        -- insert 30 keys
        for i = 1, 30 do
            s:insert{i, i * 10}
        end
        t.assert_ge(s:len(), 30, 'after inserts')

        -- replace 70 new keys (no old-tuple lookup)
        for i = 31, 100 do
            s:replace{i, i * 10}
        end
        t.assert_ge(s:len(), 100, 'after replaces')
        -- Must NOT be negative (the old bug).
        t.assert_ge(s:len(), 0, 'non-negative')

        -- update 20 keys (count unchanged)
        for i = 1, 20 do
            s:update(i, {{'+', 2, 1}})
        end
        t.assert_ge(s:len(), 100, 'after updates')

        -- upsert 50 new keys
        for i = 101, 150 do
            s:upsert({i, 0}, {{'+', 2, 1}})
        end
        t.assert_ge(s:len(), 150, 'after upserts')
        box.snapshot()

        -- delete 50 keys and dump for compaction.
        for i = 1, 50 do
            s:delete{i}
        end
        t.assert_ge(s:len(), 0, 'non-negative after deletes')
        box.snapshot()

        -- After full compaction, count is exact.
        s.index.pk:compact()
        t.helpers.retrying({timeout = 5}, function()
            t.assert_ge(s.index.pk:stat().disk.compaction.count, 1)
        end)
        t.assert_equals(s:len(), 100, 'exact after compaction')
    end)
end

--
-- After a major compaction has flushed a set of blind writes to
-- the bottom level, installing an on_replace trigger (which
-- changes how future writes are classified) must not disturb
-- len() for the historical data. The count should remain
-- exact regardless of the trigger.
--
g.test_last_level_converts_blind_writes = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        -- Blind writes on a PK-only space.
        for i = 1, 100 do
            s:replace{i, i}
        end
        -- Dump to let the writes settle on disk.
        box.snapshot()
        t.assert_equals(s:len(), 100)

        -- Install an on_replace trigger. The presence of the
        -- trigger changes how future writes are classified, so
        -- len() must fall back to an exact accounting of the
        -- on-disk data rather than a blind-write estimate.
        -- Historical writes that have been dumped must remain
        -- correctly counted.
        s:on_replace(function() end)
        t.assert_equals(s:len(), 100, 'after trigger install')
    end)
end

--
-- Rewriting the same key many times across separate
-- auto-commit transactions must leave len() equal to the
-- number of distinct live keys, not the number of writes.
-- Covers overwrite, upsert, delete-and-recreate, and mixed
-- sequences on multiple keys.
--
g.test_cross_txn_dedup = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        -- 1000 replaces on the same key: len must be 1.
        for i = 1, 1000 do
            s:replace{1, i}
        end
        t.assert_equals(s:len(), 1, 'replace overwrite dedup')

        -- 100 upserts on the same key: len stays 1.
        for _ = 1, 100 do
            s:upsert({1, 0}, {{'+', 2, 1}})
        end
        t.assert_equals(s:len(), 1, 'upsert overwrite dedup')

        -- Delete then recreate: len stays 1.
        s:delete{1}
        t.assert_equals(s:len(), 0, 'after delete')
        s:replace{1, 1}
        t.assert_equals(s:len(), 1, 'delete then recreate')

        -- Multiple keys with mixed ops.
        s:replace{2, 1}
        s:upsert({3, 0}, {{'+', 2, 1}})
        s:replace{2, 2} -- overwrite
        s:upsert({3, 0}, {{'+', 2, 1}}) -- overwrite
        t.assert_equals(s:len(), 3, 'mixed ops dedup')

        -- Delete a key, replace another: net -1.
        s:delete{2}
        t.assert_equals(s:len(), 2, 'after delete of key 2')
    end)
end

--
-- One transaction commits a write to a key; a second transaction
-- rewrites the same key and then fails at commit. After the
-- rollback the first write must still be visible and len() must
-- report one live key.
--
g.test_rollback_cross_txn_overwrite = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        -- T1 commits replace(1).
        s:replace{1, 10}
        t.assert_equals(s:len(), 1)

        -- T2 starts replace(1), WAL fails on commit -> rollback.
        box.begin()
        s:replace{1, 20}
        box.error.injection.set('ERRINJ_WAL_WRITE', true)
        t.assert_error_covers({
            type = 'ClientError',
            code = box.error.WAL_IO,
        }, box.commit)
        box.error.injection.set('ERRINJ_WAL_WRITE', false)

        -- T1's entry is still in the mem, so len() is 1.
        t.assert_equals(s:len(), 1, 'after cross-txn rollback')
    end)
end

g.after_test('test_rollback_cross_txn_overwrite', function(cg)
    cg.server:exec(function()
        box.error.injection.set('ERRINJ_WAL_WRITE', false)
    end)
end)

--
-- Multiple writes to the same key within a single transaction
-- collapse to a single effect at commit. len() must reflect
-- that, both for brand-new keys and for keys that already
-- existed, and must survive a snapshot.
--
g.test_same_txn_overwrite = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk')
        s:create_index('sk', {
            parts = {2, 'unsigned'},
            unique = false,
        })

        -- Two replaces on a new key in one txn.
        box.begin()
        s:replace{1, 10}
        s:replace{1, 20}
        box.commit()
        t.assert_equals(s:len(), 1, 'insert+overwrite in same txn')

        -- Replace then delete in one txn.
        box.begin()
        s:replace{2, 30}
        s:delete{2}
        box.commit()
        t.assert_equals(s:len(), 1, 'insert+delete in same txn')

        -- Overwrite existing key in one txn.
        box.begin()
        s:replace{1, 40}
        s:replace{1, 50}
        box.commit()
        t.assert_equals(s:len(), 1, 'overwrite existing in same txn')

        -- Insert then upsert in one txn (INSERT stays INSERT).
        box.begin()
        s:replace{3, 70}
        s:upsert({3, 70}, {{'+', 2, 1}})
        box.commit()
        t.assert_equals(s:len(), 2, 'insert+upsert in same txn')

        -- Delete existing then re-insert in one txn.
        box.begin()
        s:delete{1}
        s:replace{1, 60}
        box.commit()
        t.assert_equals(s:len(), 2, 'delete+reinsert in same txn')

        -- Verify across snapshot.
        box.snapshot()
        t.assert_equals(s:len(), 2, 'after snapshot')
    end)
end

--
-- Deleting the same key repeatedly without a read-before-write
-- must not cause len() to drift below the true number of live
-- keys. Only the first delete has an effect; the rest are no-ops.
--
g.test_double_blind_delete = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        -- Baseline: two live keys.
        s:replace{1, 10}
        s:replace{2, 20}
        t.assert_equals(s:len(), 2)

        -- Delete key 1, twice (second is blind redundant).
        s:delete{1}
        t.assert_equals(s:len(), 1, 'after first delete')
        s:delete{1}
        t.assert_equals(s:len(), 1, 'after redundant blind re-delete')
        s:delete{1}
        t.assert_equals(s:len(), 1, 'after another redundant blind re-delete')

        -- Key 2 must still be counted.
        t.assert_equals(s:get{2}, {2, 20})
    end)
end

--
-- Committed insert, then a delete that fails at commit. After
-- the rollback the inserted key is still live and len() must
-- remain at one.
--
g.test_rollback_delete_preserves_count = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        s:insert{1, 10}
        t.assert_equals(s:len(), 1)

        box.begin()
        s:delete{1}
        box.error.injection.set('ERRINJ_WAL_WRITE', true)
        t.assert_error_covers({
            type = 'ClientError',
            code = box.error.WAL_IO,
        }, box.commit)
        box.error.injection.set('ERRINJ_WAL_WRITE', false)

        t.assert_equals(s:len(), 1, 'live INSERT survives DELETE rollback')
    end)
end

g.after_test('test_rollback_delete_preserves_count', function(cg)
    cg.server:exec(function()
        box.error.injection.set('ERRINJ_WAL_WRITE', false)
    end)
end)

--
-- Committed insert-then-delete leaves the key gone. A later
-- insert that fails at commit must not leak anything into
-- len(), which has to stay at zero.
--
g.test_rollback_insert_preserves_count = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        s:insert{1, 10}
        s:delete{1}
        t.assert_equals(s:len(), 0, 'key removed')

        box.begin()
        s:insert{1, 20}
        box.error.injection.set('ERRINJ_WAL_WRITE', true)
        t.assert_error_covers({
            type = 'ClientError',
            code = box.error.WAL_IO,
        }, box.commit)
        box.error.injection.set('ERRINJ_WAL_WRITE', false)

        t.assert_equals(s:len(), 0, 'deleted state restored after rollback')
    end)
end

g.after_test('test_rollback_insert_preserves_count', function(cg)
    cg.server:exec(function()
        box.error.injection.set('ERRINJ_WAL_WRITE', false)
    end)
end)

--
-- A major compaction reshapes the disk layout that len() uses
-- to estimate blind-write accuracy. Statistics accumulated
-- against the pre-compaction layout must be dropped; otherwise
-- a subsequent batch of blind writes would be weighted by
-- stale signal and len() would drift. Verify that after major
-- compaction, a fresh batch of blind writes lands in len()
-- close to their true count.
--
g.test_blind_stats_reset_on_last_level_compaction = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 1,
            page_size = 512,
        })

        -- Phase 1: populate 1000 keys and dump.
        for i = 1, 1000 do
            s:replace{i, i}
        end
        box.snapshot()

        -- Phase 2: overwrite the same 1000 keys and dump again.
        -- These writes land against a disk layout that already
        -- has those keys, producing a signal of "overwrites
        -- dominate."
        for i = 1, 1000 do
            s:replace{i, i + 1000}
        end
        box.snapshot()

        -- Major compaction. The signal from the previous disk
        -- layout no longer describes what's on disk and must be
        -- discarded.
        s.index.pk:compact()
        t.helpers.retrying({timeout = 5}, function()
            t.assert_ge(s.index.pk:stat().disk.compaction.count, 1)
        end)

        -- Phase 3: add 1000 brand-new keys. These are genuinely
        -- new, so len() should grow by ~1000 and reach ~2000.
        -- If the pre-compaction "overwrites dominate" signal
        -- lingered, len() would instead weight these writes as
        -- partial overwrites and drift well below 2000.
        for i = 1001, 2000 do
            s:replace{i, i}
        end
        t.assert_ge(s:len(), 1900, 'len close to true count')
    end)
end

--
-- Probe accuracy: success path. Writes at every tier target
-- disjoint key ranges (bottom, interim, memory). No overlap
-- between tiers, so the probe's observed rate of "already
-- present" is 0, and the formula is expected to count every
-- tier's contribution at full strength.
--
g.test_probe_uniform_all_new = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 500

        -- Bottom: keys 1..K. First dump of a fresh space.
        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- Interim: keys K+1..2K, disjoint from the bottom.
        for i = K + 1, 2 * K do s:replace{i, i} end
        box.snapshot()

        -- Memory: keys 2K+1..3K, disjoint from both tiers.
        for i = 2 * K + 1, 3 * K do s:replace{i, i} end

        -- Bloom false positives pull the weight slightly below
        -- 1.0, so the count lands within a few percent of the
        -- true value.
        local observed = s:len()
        t.assert_ge(observed, 3 * K * 0.95, 'close to true count')
        t.assert_le(observed, 3 * K, 'does not exceed true count')
    end)
end

--
-- Probe accuracy: success path. Every tier writes the same
-- key range (hot-key overwrite pattern). The probe's observed
-- rate of "already present" approaches 1, and the formula is
-- expected to return the size of one tier's key set.
--
g.test_probe_uniform_all_overlap = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 500

        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        for i = 1, K do s:replace{i, i + K} end
        box.snapshot()

        for i = 1, K do s:replace{i, i + 2 * K} end

        t.assert_equals(s:len(), K, 'hot-key overwrite stays at one tier size')
    end)
end

--
-- Probe accuracy: known gap. The interim level contains keys
-- disjoint from the bottom level, and memory overwrites the
-- interim-level keys. The probe samples against the bottom
-- bloom, which sees neither the interim nor the memory writes,
-- so every probe reports "new" and the formula counts both
-- the interim run and the memory overlap at full strength --
-- doubling the interim contribution.
--
-- True count: 2K (bottom's K + interim's K, memory overlaps).
-- Current formula: ~3K (interim counted twice).
--
g.test_probe_interim_disjoint_mem_overwrites_interim = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 500

        -- Bottom: keys 1..K.
        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- Interim: keys K+1..2K, disjoint from the bottom.
        for i = K + 1, 2 * K do s:replace{i, i} end
        box.snapshot()

        -- Memory: overwrite the interim keys.
        for i = K + 1, 2 * K do s:replace{i, i + K} end

        -- True value is 2K. Current formula overcounts because
        -- the probe cannot observe that mem writes overlap with
        -- the interim level.
        local observed = tonumber(s:len())
        log.info('probe_gap interim_disjoint_mem_overwrites: ' ..
                 'observed=%d, true=%d', observed, 2 * K)
        t.assert_ge(observed, 2 * K, 'at least true count')
        t.assert_le(observed, 3 * K, 'bounded overcount')
    end)
end

--
-- Probe accuracy: known gap, mirror of the above. The interim
-- level overlaps with the bottom (heavy overwrites) and memory
-- writes are brand-new keys. Probes sample against the bottom
-- bloom and see a mix of hits (interim overwrites) and misses
-- (memory writes), yielding an intermediate weight. The
-- formula's single weight applied to the whole blind bucket
-- can drift in either direction depending on the exact split.
--
g.test_probe_interim_overlap_mem_new = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 2000

        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- Interim: same key range as the bottom (all overwrite).
        for i = 1, K do s:replace{i, i + K} end
        box.snapshot()

        -- Memory: brand-new keys.
        for i = K + 1, 2 * K do s:replace{i, i} end

        local observed = tonumber(s:len())
        log.info('probe_gap interim_overlap_mem_new: ' ..
                 'observed=%d, true=%d', observed, 2 * K)
        t.assert_ge(observed, K, 'lower bound: at least the bottom tier')
        t.assert_le(observed, 3 * K, 'bounded overcount')
    end)
end

--
-- Probe accuracy: UPSERT analog of the REPLACE interim-disjoint
-- case. Same structural mismatch between the probe's view and
-- the actual tier layout.
--
g.test_probe_upsert_interim_disjoint_mem_overwrites_interim = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 500

        for i = 1, K do s:upsert({i, 0}, {{'+', 2, 1}}) end
        box.snapshot()

        for i = K + 1, 2 * K do s:upsert({i, 0}, {{'+', 2, 1}}) end
        box.snapshot()

        for i = K + 1, 2 * K do s:upsert({i, 0}, {{'+', 2, 1}}) end

        local observed = tonumber(s:len())
        log.info('probe_gap upsert_interim_disjoint_mem_overwrites: ' ..
                 'observed=%d, true=%d', observed, 2 * K)
        t.assert_ge(observed, 2 * K, 'at least true count')
        t.assert_le(observed, 3 * K, 'bounded overcount')
    end)
end

--
-- Blind deletes on non-existent keys. With no read-before-write,
-- the mem tree records a tombstone for each phantom delete and
-- the baseline formula treats each as subtracting a live key.
-- The true count is unchanged, but the formula undercounts by
-- the number of phantom deletes.
--
-- This is the test case that motivates probing the delete path:
-- a hit-rate estimate would let us weight each mem.delete by
-- its probability of actually having removed a live key.
--
g.test_probe_delete_phantom_undercount = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 500
        local M = 500

        -- Populate K keys and dump so they land on disk.
        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- Blind-delete M keys that never existed.
        for i = K + 1, K + M do s:delete{i} end

        local observed = tonumber(s:len())
        log.info('probe_delete_phantom: observed=%d, true=%d', observed, K)
        -- Bloom false-positive noise pulls the count slightly
        -- below the true value.
        t.assert_ge(observed, K * 0.95, 'close to true count')
        t.assert_le(observed, K, 'does not exceed true count')
    end)
end

--
-- Mixed deletes: half hit live keys on disk, half are phantoms
-- on non-existent keys. The real len drops by K/2 but the
-- formula drops it by K (both halves subtract). Documents the
-- partial drift for delete-heavy workloads mixing real and
-- phantom deletes.
--
g.test_probe_delete_mixed = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 2000

        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- First half: real deletes of live keys 1..K/2.
        for i = 1, K / 2 do s:delete{i} end
        -- Second half: phantom deletes of non-existent keys.
        for i = K + 1, K + K / 2 do s:delete{i} end

        local observed = tonumber(s:len())
        log.info('probe_delete_mixed: observed=%d, true=%d', observed, K / 2)
        -- FPR correction slightly overshoots when the real miss
        -- rate is partial, so allow a two-sided window.
        t.assert_ge(observed, K / 2 * 0.95, 'close to true count')
        t.assert_le(observed, K / 2 * 1.05, 'close to true count')
    end)
end

--
-- Mixed workload with divergent per-population miss rates:
-- REPLACEs overlap existing data 90% of the time (10% miss),
-- DELETEs overlap only 10% (90% miss). Guards that the single
-- combined hit/miss counter still produces the right answer
-- when the two populations behave very differently. The
-- correction (N_R + N_D) * (M_R + M_D) / (N_R + N_D) reduces
-- to M_R + M_D, i.e. exactly the sum of per-population
-- corrections; remaining error comes from probe sampling and
-- bloom-FPR variance.
--
g.test_probe_mixed_replace_delete_divergent_rates = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 2000
        local hi = K * 9 / 10  -- 1800 (overlap portion)
        local lo = K / 10       -- 200 (non-overlap portion)

        -- Bottom: keys 1..K.
        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- Phase 2 REPLACE: 90% overwrite bottom (keys 1..hi),
        -- 10% brand-new (keys K+1..K+lo).
        for i = 1, hi do s:replace{i, i + K} end
        for i = K + 1, K + lo do s:replace{i, i} end

        -- Phase 3 DELETE: 10% real (keys hi+1..K, the bottom
        -- keys phase 2 did not touch), 90% phantom (keys
        -- K+lo+1..K+lo+hi, beyond phase 2's new range).
        for i = hi + 1, K do s:delete{i} end
        for i = K + lo + 1, K + lo + hi do s:delete{i} end

        -- Live keys after the workload:
        --   bottom 1..hi: live, updated by phase 2.
        --   bottom hi+1..K: deleted by phase 3.
        --   phase 2 new K+1..K+lo: live.
        -- Total: hi + lo = K.
        local observed = tonumber(s:len())
        log.info('probe_gap mixed_divergent_rates: ' ..
                 'observed=%d, true=%d', observed, K)
        t.assert_ge(observed, K * 0.8, 'within 20% of true count')
        t.assert_le(observed, K * 1.2, 'within 20% of true count')
    end)
end

--
-- Asymmetric mixed workload: ten times more deletes than
-- replaces, so the combined hit/miss counter is dominated by
-- delete samples. Guards that the estimator stays accurate
-- when one population overwhelms the other in sample weight.
-- Same algebraic identity as the divergent-rates case applies:
-- the combined correction equals the sum of per-population
-- corrections, so sample skew alone cannot bias the result.
--
g.test_probe_mixed_asymmetric_counts = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 2000
        local R = K / 10  -- 200 replaces (small)
        local D = K       -- 2000 deletes (large)
        -- Replaces: 90% overwrite bottom, 10% new.
        local R_over = R * 9 / 10  -- 180
        local R_new = R - R_over   -- 20
        -- Deletes: 10% real, 90% phantom.
        local D_real = D / 10      -- 200
        local D_phantom = D - D_real  -- 1800

        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        for i = 1, R_over do s:replace{i, i + K} end
        for i = K + 1, K + R_new do s:replace{i, i} end

        -- Real: last D_real warm-up keys, untouched by phase 2.
        for i = K - D_real + 1, K do s:delete{i} end
        for i = K + R_new + 1, K + R_new + D_phantom do
            s:delete{i}
        end

        -- Live keys:
        --   bottom 1..(K - D_real): live (overwrites don't change count).
        --   phase 2 new: K+1..K+R_new live.
        -- Total: (K - D_real) + R_new = K - 200 + 20 = K - 180.
        local true_count = K - D_real + R_new
        local observed = tonumber(s:len())
        log.info('probe_gap mixed_asymmetric_counts: ' ..
                 'observed=%d, true=%d', observed, true_count)
        t.assert_ge(observed, true_count * 0.8, 'within 20%')
        t.assert_le(observed, true_count * 1.2, 'within 20%')
    end)
end

--
-- After DDL changes the blind-write classification (installing
-- an on_replace trigger, adding a secondary index), statements
-- already on disk that were typed under the previous rules are
-- temporarily miscounted. A major compaction rewrites those
-- statements to their canonical inserts-delete form and the
-- count returns to exact.
--
--
-- Phantom deletes that get flushed to disk. After a dump, the
-- phantom tombstones carry over into the on-disk statement
-- counts. Without a correction that covers disk deletes too,
-- the baseline stays depressed for as long as those tombstones
-- live on disk; the formula must compensate symmetrically for
-- both memory and disk deletes.
--
g.test_probe_phantom_delete_survives_dump = function(cg)
    cg.server:exec(function()
        local log = require('log')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 500
        local M = 500

        -- Populate K keys on disk.
        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- Blind-delete M non-existent keys.
        for i = K + 1, K + M do s:delete{i} end

        -- Dump so the phantom tombstones leave memory and land
        -- on disk. Without a correction that also weights disk
        -- tombstones, len() would permanently drop by M until a
        -- last-level compaction drops orphan deletes.
        box.snapshot()

        local observed = tonumber(s:len())
        log.info('probe_phantom_delete_survives_dump: ' ..
                 'observed=%d, true=%d', observed, K)
        t.assert_ge(observed, K * 0.95, 'close to true count')
        t.assert_le(observed, K, 'does not exceed true count')
    end)
end

g.test_blind_mask_change_heals_after_compaction = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {1, 'unsigned'},
            run_count_per_level = 20,
            page_size = 512,
        })
        local K = 1000

        -- First dump is last-level, so these land as inserts on
        -- disk.
        for i = 1, K do s:replace{i, i} end
        box.snapshot()

        -- Second dump is not last-level. It covers the existing
        -- K keys plus another K brand-new keys; the whole batch
        -- lands as replaces on disk. The true live key count is
        -- now 2K.
        for i = 1, 2 * K do s:replace{i, i + K} end
        box.snapshot()

        -- Installing a trigger turns off the blind-write mask,
        -- so the formula falls back to a baseline that does not
        -- include the historical replaces. The count drops well
        -- below the true value while the historical statements
        -- still carry their old typing.
        s:on_replace(function() end)
        t.assert_lt(s:len(), K * 3 / 2, 'undercount under mask = 0')

        -- Major compaction rewrites the historical replaces to
        -- inserts at the last level, which the baseline fully
        -- accounts for. The count is exact again.
        s.index.pk:compact()
        t.helpers.retrying({timeout = 5}, function()
            t.assert_ge(s.index.pk:stat().disk.compaction.count, 1)
        end)
        t.assert_equals(s:len(), 2 * K, 'exact after compaction')
    end)
end

--
-- Many same-key UPSERTs trigger the squash fiber, which replaces
-- the topmost committed UPSERT with a squashed REPLACE at the same
-- (key, lsn). The accounting path must tolerate the BPS-tree
-- replacement and keep len() stable.
--
g.test_upsert_squash_preserves_count = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {parts = {1, 'unsigned'}})

        s:replace{1, 0}
        t.assert_equals(s:len(), 1)

        -- Well above VY_UPSERT_THRESHOLD (128) so the squash fiber
        -- is scheduled and given ample chain to process.
        for _ = 1, 2000 do
            s:upsert({1, 0}, {{'+', 2, 1}})
        end

        -- Drain any scheduled squash work before sampling len().
        t.helpers.retrying({timeout = 5}, function()
            fiber.yield()
            local st = s.index.pk:stat().upsert
            t.assert_ge(st.squashed + st.applied, 1,
                        'squash or apply must run')
        end)
        t.assert_equals(s:len(), 1, 'len stays 1 across upsert squash')
        t.assert_equals(s:get{1}[2], 2000, 'upserts applied correctly')
    end)
end
