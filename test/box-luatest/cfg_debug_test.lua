local server = require('luatest.server')
local t = require('luatest')

local g = t.group('read_only_wal_sync')

g.before_each(function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server = server:new({alias = 'master'})
    cg.server:start()
    cg.server:exec(function()
        box.schema.space.create('test')
        box.space.test:create_index('pk')
    end)
end)

g.after_each(function(cg)
    cg.server:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        box.error.injection.set('ERRINJ_WAL_WRITE', false)
        box.error.injection.set('ERRINJ_WAL_SYNC', false)
    end)
    cg.server:drop()
end)

-- A write submitted before the switch has reached WAL by the time
-- box.ctl.wait_ro() returns.
g.test_pending_write_is_waited = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        local lsn = box.info.lsn
        box.error.injection.set('ERRINJ_WAL_DELAY', true)
        fiber.create(function() box.space.test:replace{1} end)
        box.cfg{read_only = true}
        t.assert(box.info.ro)

        local lsn_on_return
        fiber.create(function()
            box.ctl.wait_ro()
            lsn_on_return = box.info.lsn
        end)
        t.assert_equals(lsn_on_return, nil, 'box.ctl.wait_ro waits for WAL')
        t.assert_equals(box.info.lsn, lsn)

        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        t.helpers.retrying({}, function()
            t.assert_not_equals(lsn_on_return, nil)
        end)
        t.assert_equals(lsn_on_return, lsn + 1,
                        'the pending write is in WAL when wait_ro returns')
        t.assert_equals(box.space.test:get(1), {1})
    end)
end

-- A write that fails while box.ctl.wait_ro() waits for it is rolled back,
-- and the wait succeeds without it.
g.test_failed_write_is_not_waited = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        local lsn = box.info.lsn
        box.error.injection.set('ERRINJ_WAL_DELAY', true)
        box.error.injection.set('ERRINJ_WAL_WRITE', true)
        fiber.create(function() box.space.test:replace{1} end)
        box.cfg{read_only = true}

        local ok, err
        fiber.create(function()
            ok, err = pcall(box.ctl.wait_ro)
        end)
        t.assert_equals(ok, nil, 'box.ctl.wait_ro waits for WAL')

        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        t.helpers.retrying({}, function()
            t.assert_not_equals(ok, nil)
        end)
        t.assert(ok, err)
        t.assert_equals(box.info.lsn, lsn, 'the failed write is not in WAL')
        t.assert_equals(box.space.test:get(1), nil)
    end)
end

-- With nothing in flight box.ctl.wait_ro() doesn't go to WAL. A failed wait
-- for WAL leaves the instance read-only, so the call can be retried.
g.test_failed_wait = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        box.cfg{read_only = true}
        box.error.injection.set('ERRINJ_WAL_SYNC', true)
        box.ctl.wait_ro()

        box.cfg{read_only = false}
        box.error.injection.set('ERRINJ_WAL_DELAY', true)
        fiber.create(function() box.space.test:replace{1} end)
        box.cfg{read_only = true}
        t.assert_error_covers({code = box.error.INJECTION}, box.ctl.wait_ro)
        t.assert(box.info.ro)
        t.assert_equals(box.cfg.read_only, true)

        box.error.injection.set('ERRINJ_WAL_SYNC', false)
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        box.ctl.wait_ro()
        t.assert_equals(box.space.test:get(1), {1})
    end)
end
