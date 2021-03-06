env = require('test_run')
test_run = env.new()

s = box.schema.space.create('test', {engine = 'memtx'})
test_run:cmd("setopt delimiter ';'")
function test()
    local t = {}
    local k = {}
    for i = 1,128 do
        local parts = {}
        for j = 0,127 do
            table.insert(parts, {i * 128 - j, 'uint'})
            table.insert(t, 1)
        end
        if i == 1 then k = table.deepcopy(t) end
        s:create_index('test'..i, {parts = parts})
        if i % 16 == 0 then
            s:replace(t)
            s:delete(k)
        end
    end
end;
test_run:cmd("setopt delimiter ''");

pcall(test) -- must fail but not crash

test = nil
s:drop()