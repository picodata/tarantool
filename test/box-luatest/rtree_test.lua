local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:stop()
    cg.server = nil
end)

g.test_rtree_with_nulls = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('nullable')
        s:create_index('primary', {type = 'tree', parts = {1, 'unsigned'}})

        -- (is_nullable=false, exclude_null=false): a plain non-nullable
        -- RTREE indexes the field and rejects a NULL in it.
        local plain = s:create_index('rtree',
            {type = 'rtree', parts = {2, 'array'}})
        s:insert{1, {1, 1}}
        t.assert_equals(plain:select(), {{1, {1, 1}}})
        t.assert_error(s.insert, s, {2, box.NULL})
        plain:drop()
        s:delete{1}

        -- For an RTREE index is_nullable and exclude_null must match:
        -- a nullable part must exclude nulls (their coordinates cannot
        -- be extracted), and a non-nullable part must not exclude them.
        t.assert_error_msg_contains(
            'RTREE nullable parts require exclude_null=true',
            s.create_index, s, 'rtree',
            {type = 'rtree',
             parts = {2, 'array', is_nullable = true, exclude_null = false}})
        t.assert_error_msg_contains(
            'exclude_null=true and is_nullable=false are incompatible',
            s.create_index, s, 'rtree',
            {type = 'rtree',
             parts = {2, 'array', is_nullable = false, exclude_null = true}})

        local i = s:create_index('rtree',
            {type = 'rtree',
             parts = {2, 'array', is_nullable = true, exclude_null = true}})
        s:insert{1, {1, 1}}
        s:insert{2, {2, 2}}
        s:insert{3, box.NULL}
        -- The space keeps the null tuple; the index skips it.
        t.assert_equals(s:select(), {{1, {1, 1}}, {2, {2, 2}}, {3, box.NULL}})
        t.assert_equals(i:select(), {{1, {1, 1}}, {2, {2, 2}}})
        -- Only a wholly-null field is excluded. A present array with a
        -- null coordinate, or a wrong-dimension array, is not "null", so
        -- it is still rejected rather than silently excluded.
        t.assert_error(s.insert, s, {6, {1, box.NULL}})
        t.assert_error(s.insert, s, {7, {1}})
        t.assert_equals(i:select(), {{1, {1, 1}}, {2, {2, 2}}})
        i:drop()

        -- The short form {exclude_null = true} sets is_nullable implicitly.
        i = s:create_index('rtree',
            {type = 'rtree', parts = {2, 'array', exclude_null = true}})
        s:insert{4, {4, 4}}
        s:insert{5, box.NULL}
        s:insert{6}    -- a short tuple: field 2 absent is treated as null
        t.assert_equals(i:select(), {{1, {1, 1}}, {2, {2, 2}}, {4, {4, 4}}})
        -- The index counts only the indexed (non-excluded) tuples, while
        -- the space keeps them all.
        t.assert_equals(i:count(), 3)
        t.assert_equals(s:count(), 6)
        s:drop()
    end)
end

-- The exclude_null logic lives in the index replace handler, which also
-- backs update/delete/replace/upsert. Exercise the field's null<->non-null
-- transitions through every command.
g.test_rtree_exclude_null_dml = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('dml')
        s:create_index('primary', {parts = {1, 'unsigned'}})
        local rt = s:create_index('rtree',
            {type = 'rtree', parts = {2, 'array', exclude_null = true}})

        -- insert: null excluded, non-null indexed.
        s:insert{1, {1, 1}}
        s:insert{2, box.NULL}
        t.assert_equals(rt:select(), {{1, {1, 1}}})

        -- update non-null -> null: the tuple leaves the index.
        s:update(1, {{'=', 2, box.NULL}})
        t.assert_equals(rt:select(), {})
        t.assert_equals(s:get(1), {1, box.NULL})

        -- update null -> non-null: the tuple enters the index.
        s:update(2, {{'=', 2, {2, 2}}})
        t.assert_equals(rt:select(), {{2, {2, 2}}})

        -- replace across nullness, both directions.
        s:replace{2, box.NULL}
        t.assert_equals(rt:select(), {})
        s:replace{2, {5, 5}}
        t.assert_equals(rt:select(), {{2, {5, 5}}})

        -- delete an excluded (null) tuple: succeeds and is a no-op for
        -- the rtree (the old tuple is excluded, so replace returns NULL).
        s:delete(1)
        t.assert_equals(s:get(1), nil)
        t.assert_equals(rt:select(), {{2, {5, 5}}})

        -- delete an indexed (non-null) tuple.
        s:delete(2)
        t.assert_equals(rt:select(), {})

        -- upsert: insert path (null excluded), then update path (-> null).
        s:upsert({3, {3, 3}}, {{'=', 2, {3, 3}}})
        t.assert_equals(rt:select(), {{3, {3, 3}}})
        s:upsert({3, box.NULL}, {{'=', 2, box.NULL}})
        t.assert_equals(rt:select(), {})
        s:upsert({4, box.NULL}, {{'=', 2, box.NULL}})
        t.assert_equals(rt:select(), {})
        t.assert_equals(s:get(4), {4, box.NULL})

        s:drop()
    end)
end

-- Index rebuilds (space:alter, recovery) go through the same exclude-aware
-- replace path. Check the nullable<->non-nullable transitions on a
-- non-empty space, with and without nulls in the data.
g.test_rtree_exclude_null_alter = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('alt')
        s:create_index('primary', {parts = {1, 'unsigned'}})

        local rt = s:create_index('rtree',
            {type = 'rtree', parts = {2, 'array', exclude_null = true}})
        s:insert{1, {1, 1}}
        s:insert{2, box.NULL}
        s:insert{3, {3, 3}}

        -- Rebuild the index on the non-empty, mixed space: the build path
        -- must skip the null tuple, not error.
        rt:drop()
        rt = s:create_index('rtree',
            {type = 'rtree', parts = {2, 'array', exclude_null = true}})
        t.assert_equals(rt:select(), {{1, {1, 1}}, {3, {3, 3}}})

        -- exclude_null -> non-nullable while a null tuple exists must be
        -- rejected (the null could not be indexed), leaving the index
        -- untouched.
        t.assert_error(rt.alter, rt, {parts = {2, 'array'}})
        t.assert_equals(rt:select(), {{1, {1, 1}}, {3, {3, 3}}})

        -- Once the null is gone, the non-nullable alter succeeds and a
        -- null is then rejected outright.
        s:delete(2)
        rt:alter({parts = {2, 'array'}})
        t.assert_error(s.insert, s, {4, box.NULL})

        -- Relaxing back to exclude_null lets nulls be excluded again.
        rt:alter({parts = {2, 'array', exclude_null = true}})
        s:insert{4, box.NULL}
        t.assert_equals(rt:select(), {{1, {1, 1}}, {3, {3, 3}}})

        s:drop()
    end)
end

-- Recovery rebuilds the index from the snapshot via the same
-- exclude-aware build path; nulls must stay excluded across a restart.
g.test_rtree_exclude_null_recovery = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('rec')
        s:create_index('primary', {parts = {1, 'unsigned'}})
        s:create_index('rtree',
            {type = 'rtree', parts = {2, 'array', exclude_null = true}})
        s:insert{1, {1, 1}}
        s:insert{2, box.NULL}
        s:insert{3, {3, 3}}
        box.snapshot()
    end)

    cg.server:restart()

    cg.server:exec(function()
        local rt = box.space.rec.index.rtree
        t.assert_equals(rt:select(), {{1, {1, 1}}, {3, {3, 3}}})
        t.assert_equals(rt:count(), 2)
        box.space.rec:drop()
    end)
end

-- The spatial iterators keep working and never surface an excluded tuple.
g.test_rtree_exclude_null_iterators = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('iter')
        s:create_index('primary', {parts = {1, 'unsigned'}})
        local rt = s:create_index('rtree',
            {type = 'rtree', parts = {2, 'array', exclude_null = true}})
        s:insert{1, {0, 0}}
        s:insert{2, {10, 10}}
        s:insert{3, {5, 5}}
        s:insert{4, box.NULL}   -- excluded
        s:insert{5}             -- short tuple, also excluded

        -- ALL and the index size see only the three indexed points.
        t.assert_equals(rt:count(), 3)
        t.assert_equals(#rt:select({}, {iterator = 'ALL'}), 3)
        -- NEIGHBOR returns every indexed tuple, nearest first -- proving
        -- both the ordering and that the excluded tuples are absent.
        t.assert_equals(rt:select({0, 0}, {iterator = 'NEIGHBOR'}),
                        {{1, {0, 0}}, {3, {5, 5}}, {2, {10, 10}}})
        -- EQ / OVERLAPS pick out the matching indexed tuple.
        t.assert_equals(rt:select({5, 5}, {iterator = 'EQ'}), {{3, {5, 5}}})
        t.assert_equals(rt:select({4, 4, 6, 6}, {iterator = 'OVERLAPS'}),
                        {{3, {5, 5}}})
        -- LE returns the points contained in the query rectangle.
        t.assert_equals(#rt:select({0, 0, 10, 10}, {iterator = 'LE'}), 3)

        s:drop()
    end)
end
