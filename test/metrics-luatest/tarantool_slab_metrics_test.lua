require('test.metrics-luatest.helper')

local t = require('luatest')
local g = t.group('slab_metric')
local utils = require('test.utils')

g.before_all(utils.create_server)

g.after_all(utils.drop_server)

g.before_each(function(cg)
    cg.server:exec(function() require('metrics').clear() end)
end)

g.test_slab = function(cg)
    cg.server:exec(function()
        local metrics = require('metrics')
        local slab = require('metrics.tarantool.slab')
        local utils = require('test.utils') -- luacheck: ignore 431

        metrics.enable_default_metrics()
        slab.update()
        local default_metrics = metrics.collect()
        local log = require('log')

        local user_metrics = {
            'tnt_slab_quota_size',
            'tnt_slab_quota_used',
            'tnt_slab_quota_used_ratio',
            'tnt_slab_arena_size',
            'tnt_slab_arena_used',
            'tnt_slab_arena_used_ratio',
            'tnt_slab_items_size',
            'tnt_slab_items_used',
            'tnt_slab_items_used_ratio',
        }

        for _, item in ipairs(user_metrics) do
            log.info('checking metric: ' .. item)
            local metric = utils.find_metric(item, default_metrics)
            t.assert(metric, item)
            t.assert_type(metric[1].value, 'number')
        end

        if box.slab.system_info ~= nil then
            local system_metrics = {
                'tnt_slab_system_quota_size',
                'tnt_slab_system_quota_used',
                'tnt_slab_system_quota_used_ratio',
                'tnt_slab_system_arena_size',
                'tnt_slab_system_arena_used',
                'tnt_slab_system_arena_used_ratio',
                'tnt_slab_system_items_size',
                'tnt_slab_system_items_used',
                'tnt_slab_system_items_used_ratio',
            }

            for _, item in ipairs(system_metrics) do
                log.info('checking metric: ' .. item)
                local metric = utils.find_metric(item, default_metrics)
                t.assert(metric, item)
                t.assert_type(metric[1].value, 'number')
            end
        end
    end)
end
