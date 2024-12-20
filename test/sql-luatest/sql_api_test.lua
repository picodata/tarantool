local server = require('luatest.server')
local t = require('luatest')
local g = t.group()

g.before_all(function()
    local ffi_init = [[
        struct iovec_impl {
            void *   iov_base;
            size_t   iov_len;
        };

        struct obuf_impl
        {
                struct slab_cache *slabc;
                int pos;
                int n_iov;
                size_t used;
                size_t start_capacity;
                size_t capacity[32];
                struct iovec_impl iov[32];
                bool reserved;
        };

        struct slab_cache * cord_slab_cache(void);

        void obuf_create(
            struct obuf *buf,
            struct slab_cache *slabc,
            size_t start_capacity);

        void obuf_destroy(struct obuf *buf);

        int sql_prepare_and_execute_ext(
            const char *sql, int len, const char *mp_params,
            uint64_t vdbe_max_steps, struct obuf *out_buf);

        int sql_execute_prepared_ext(
            uint32_t stmt_id, const char *mp_params,
            uint64_t vdbe_max_steps, struct obuf *out_buf);

        int sql_prepare_ext(
            const char *sql, int len,
            uint32_t *stmt_id, uint64_t *sid);
        int sql_unprepare_ext(uint32_t stmt_id, uint64_t sid);
    ]]
    g.server = server:new({alias = 'sql_api'})
    g.server:start()
    g.server:exec(function(cfg)
        local ffi = require('ffi')
        ffi.cdef(cfg)
    end, {ffi_init})
end)

g.after_all(function()
    g.server:stop()
end)

g.before_each(function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t(a text NOT NULL PRIMARY KEY)]])
    end)
end)

g.after_each(function()
    g.server:exec(function()
        box.execute([[DROP TABLE t]])
    end)
end)

g.test_stmt_preparetion_and_execution = function()
    g.server:exec(function()
        local res, buf

        local ffi = require('ffi')
        local slab_cache = ffi.C.cord_slab_cache()
        t.assert_not_equals(slab_cache, ffi.NULL)
        local mem_chunk = ffi.new("struct obuf_impl[1]")
        local obuf = ffi.cast('struct obuf *', mem_chunk)
        ffi.C.obuf_create(obuf, slab_cache, 1024)

        -- Prepare and execute the statement with C API.
        -- '\x91\xd9\x01C' is a msgpack representation of ['A'].
        -- \x91 is an array of 1 element.
        -- \xd9 is a string with 1 byte length.
        -- \x01 is the length of the string 'A'.
        buf = ffi.cast('char *', '\x91\xd9\x01A')
        res = ffi.C.sql_prepare_and_execute_ext(
            'INSERT INTO t VALUES (?)', 24, buf, 1024, obuf)
        t.assert_equals(res, 0)

        -- Check the result.
        res = box.execute([[SELECT * FROM t WHERE a = 'A']])
        t.assert_equals(res.rows[1][1], 'A')

        ffi.C.obuf_destroy(obuf)
    end)
end

g.test_prepared_stmt_execution = function()
    g.server:exec(function()
        local res, buf

        local ffi = require('ffi')
        local slab_cache = ffi.C.cord_slab_cache()
        t.assert_not_equals(slab_cache, ffi.NULL)
        local mem_chunk = ffi.new("struct obuf_impl[1]")
        local obuf = ffi.cast('struct obuf *', mem_chunk)
        ffi.C.obuf_create(obuf, slab_cache, 1024)

        -- Prepare the statement.
        local s = box.prepare('INSERT INTO t VALUES (?)')

        -- Prepare and execute the statement with C API.
        buf = ffi.cast('char *', '\x91\xd9\x01B')
        res = ffi.C.sql_execute_prepared_ext(s.stmt_id, buf, 1024, obuf)
        t.assert_equals(res, 0)

        -- Check the result.
        res = box.execute([[SELECT * FROM t WHERE a = 'B']])
        t.assert_equals(res.rows[1][1], 'B')

        s:unprepare()
        ffi.C.obuf_destroy(obuf)
    end)
end

g.test_cross_session_stmt_execution = function()
    g.server:exec(function()
        local fiber = require('fiber')

        -- Prepare the statement in the current session.
        local s = box.prepare('INSERT INTO t VALUES (?)')

        local new_session = function(stmt_id)
            local ffi = require('ffi')
            local slab_cache = ffi.C.cord_slab_cache()
            local mem_chunk = ffi.new("struct obuf_impl[1]")
            local obuf = ffi.cast('struct obuf *', mem_chunk)
            ffi.C.obuf_create(obuf, slab_cache, 1024)

            -- Execute with C API the statement that was prepared
            -- in a parent session
            local buf = ffi.cast('char *', '\x91\xd9\x01C')
            local rc = ffi.C.sql_execute_prepared_ext(stmt_id, buf, 1024, obuf)
            t.assert_equals(rc, 0)

            ffi.C.obuf_destroy(obuf)
        end

        local f = fiber.new(new_session, s.stmt_id)
        f:set_joinable(true)
        f:join()

        -- Check the result.
        local res = box.execute([[SELECT * FROM t WHERE a = 'C']])
        t.assert_equals(res.rows[1][1], 'C')

        s:unprepare()
    end)
end

g.test_stmt_prepare = function()
    g.server:exec(function()
        local res

        local ffi = require('ffi')
        local stmt_id = ffi.new('uint32_t[1]')
        local session_id = ffi.new('uint64_t[1]')

        local initial_stmt_count = box.info.sql().cache.stmt_count
        local initial_cache_size = box.info.sql().cache.size

        -- Prepare the statement.
        res = ffi.C.sql_prepare_ext('VALUES (?)', 10, stmt_id, session_id)
        t.assert_equals(res, 0)

        -- Check the prepared statement.
        res = box.execute(tonumber(stmt_id[0]), {'ABC'})
        t.assert_equals(res.rows[1][1], 'ABC')

        -- Unprepare the statement
        res = ffi.C.sql_unprepare_ext(
            tonumber(stmt_id[0]), tonumber(session_id[0]))
        t.assert_equals(res, 0)

        t.assert_equals(box.info.sql().cache.stmt_count, initial_stmt_count)
        t.assert_equals(box.info.sql().cache.size, initial_cache_size)

        -- Calling unprepare again returns error
        res = ffi.C.sql_unprepare_ext(
            tonumber(stmt_id[0]), tonumber(session_id[0]))
        t.assert_not_equals(res, 0)
        local err = tostring(box.error.last())
        local s = string.format(
            "Prepared statement with id %u does not exist",
            tonumber(stmt_id[0]))
        t.assert_str_contains(err, s)

        -- Check unprepare from invalid session
        -- returns error
        local wrong_sid = tonumber(session_id[0]) + 1
        res = ffi.C.sql_unprepare_ext(tonumber(stmt_id[0]), wrong_sid)
        t.assert_not_equals(res, 0)
        err = tostring(box.error.last())
        s = string.format("Session %u does not exist", wrong_sid)
        t.assert_str_contains(err, s)

        -- Check statement was deleted
        res = box.execute(tonumber(stmt_id[0]), {'ABC'})
        t.assert_not_equals(res, 0)
    end)
end

g.test_unprepare_from_other_session = function()
    g.server:exec(function()
        local fiber = require('fiber')

        local res, err, ok

        local ffi = require('ffi')
        local stmt_id = ffi.new('uint32_t[1]')
        local session_id = ffi.new('uint64_t[1]')

        -- Prepare the statement.
        res = ffi.C.sql_prepare_ext('VALUES (?)', 10, stmt_id, session_id)
        t.assert_equals(res, 0)

        -- Check the prepared statement.
        res = box.execute(tonumber(stmt_id[0]), {'ABC'})
        t.assert_equals(res.rows[1][1], 'ABC')

        local new_session = function(stmt_id, session_id)
            local ffi = require('ffi')
            local id = tonumber(stmt_id[0])
            local sid = tonumber(session_id[0])

            -- Unprepare the statement
            res = ffi.C.sql_unprepare_ext(id, sid)
            t.assert_equals(res, 0)

            -- Check we get an error when trying to unprepare
            -- invalid statement from other session
            res = ffi.C.sql_unprepare_ext(id, sid)
            err = tostring(box.error.last())
            local s = string.format(
                "Prepared statement with id %u does not exist", id)
            t.assert_str_contains(err, s)
        end

        local f = fiber.new(new_session, stmt_id, session_id)
        f:set_joinable(true)
        ok, res = f:join()

        if not ok then
            error(res:unpack())
        end

        -- Check statement was deleted
        res = box.execute(tonumber(stmt_id[0]), {'ABC'})
        t.assert_not_equals(res, 0)
    end)
end

g.test_execution_references = function()
    g.server:exec(function()
        local res, buf
        local id, sid

        local ffi = require('ffi')
        local slab_cache = ffi.C.cord_slab_cache()
        local mem_chunk = ffi.new("struct obuf_impl[1]")
        local obuf = ffi.cast('struct obuf *', mem_chunk)
        ffi.C.obuf_create(obuf, slab_cache, 1024)
        local stmt_id = ffi.new('uint32_t[1]')
        local session_id = ffi.new('uint64_t[1]')
        local initial_stmt_count = box.info.sql().cache.stmt_count

        -- Prepare the statement.
        res = ffi.C.sql_prepare_ext('VALUES (?)', 10, stmt_id, session_id)
        t.assert_equals(res, 0)
        t.assert_equals(box.info.sql().cache.stmt_count, initial_stmt_count + 1)
        id = tonumber(stmt_id[0])
        sid = tonumber(session_id[0])

        -- Check that execution of the statement from the session where
        -- it was prepared, does not delete the statement from cache.
        buf = ffi.cast('char *', '\x91\xd9\x01A')
        res = ffi.C.sql_execute_prepared_ext(id, buf, 1024, obuf)
        t.assert_equals(res, 0)
        t.assert_equals(
            box.info.sql().cache.stmt_count,
            initial_stmt_count + 1
        )
        ffi.C.obuf_destroy(obuf)

        -- Unprepare the statement
        res = ffi.C.sql_unprepare_ext(id, sid)
        t.assert_equals(res, 0)
        t.assert_equals(box.info.sql().cache.stmt_count, initial_stmt_count)
    end)
end

g.test_execution_references_from_other_session = function()
    g.server:exec(function()
        local res, ok
        local fiber = require('fiber')
        local ffi = require('ffi')
        local stmt_id = ffi.new('uint32_t[1]')
        local session_id = ffi.new('uint64_t[1]')
        local initial_stmt_count = box.info.sql().cache.stmt_count

        -- Prepare the statement.
        t.assert_equals(box.info.sql().cache.stmt_count, initial_stmt_count)
        res = ffi.C.sql_prepare_ext('VALUES (?)', 10, stmt_id, session_id)
        t.assert_equals(res, 0)
        t.assert_equals(box.info.sql().cache.stmt_count, 1)

        local new_session = function(id)
            local buf
            local ffi = require('ffi')
            local slab_cache = ffi.C.cord_slab_cache()
            local mem_chunk = ffi.new("struct obuf_impl[1]")
            local obuf = ffi.cast('struct obuf *', mem_chunk)
            ffi.C.obuf_create(obuf, slab_cache, 1024)

            -- Check that execution of the statement from the session,
            -- different from the one where it was prepared, does not
            -- delete the statement from cache.
            buf = ffi.cast('char *', '\x91\xd9\x01A')
            res = ffi.C.sql_execute_prepared_ext(id, buf, 1024, obuf)
            t.assert_equals(res, 0)
            t.assert_equals(
                box.info.sql().cache.stmt_count,
                initial_stmt_count + 1
            )
            ffi.C.obuf_destroy(obuf)
        end

        local id = tonumber(stmt_id[0])
        local f = fiber.new(new_session, id)
        f:set_joinable(true)
        ok, res = f:join()

        if not ok then
            error(res:unpack())
        end

        -- Unprepare the statement
        local sid = tonumber(session_id[0])
        res = ffi.C.sql_unprepare_ext(id, sid)
        t.assert_equals(res, 0)
        t.assert_equals(box.info.sql().cache.stmt_count, initial_stmt_count)
    end)
end
