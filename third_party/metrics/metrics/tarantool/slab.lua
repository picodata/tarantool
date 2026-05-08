local utils = require('metrics.utils')

local collectors_list = {}

local function register_slab_info(prefix, description_prefix, slab_info)
    for k, v in pairs(slab_info) do
        local metric_name = prefix .. '_' .. k
        local description = description_prefix .. ' ' .. k .. ' info'
        if not k:match('_ratio$') then
            collectors_list[metric_name] = utils.set_gauge(metric_name,
                description, v, nil, nil, {default = true})
        else
            collectors_list[metric_name] =
                utils.set_gauge(metric_name, description,
                    tonumber(v:match('^([0-9%.]+)%%?$')),
                nil, nil, {default = true})
        end
    end
end

local function update_slab_metrics()
    if not utils.box_is_configured() then
        return
    end

    register_slab_info('slab', 'Slab', box.slab.info())

    if box.slab.system_info ~= nil then
        register_slab_info('slab_system', 'Slab system', box.slab.system_info())
    end
end

return {
    update = update_slab_metrics,
    list = collectors_list,
}
