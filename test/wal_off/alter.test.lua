-- wal is off, good opportunity to test something more CPU intensive:
env = require('test_run')
test_run = env.new()
-- need a clean server to count the number of tuple formats
test_run:cmd('restart server default with cleanup=1')
spaces = {}
box.schema.FORMAT_ID_MAX
test_run:cmd("setopt delimiter ';'")
-- too many formats
for k = 1, box.schema.FORMAT_ID_MAX, 1 do
    local s = box.schema.space.create('space'..k)
    table.insert(spaces, s)
end;
#spaces;
-- cleanup
for k, v in pairs(spaces) do
    v:drop()
end;
test_run:cmd("setopt delimiter ''");

--
-- gh-3408: space drop frees tuples asynchronously.
--
fiber = require('fiber')

function mem_used() local info = box.info.memory() return info.data + info.index end

s1 = box.schema.space.create('test1')
_ = s1:create_index('pk', {type = 'tree'})
s2 = box.schema.space.create('test2')
_ = s2:create_index('pk', {type = 'hash'})

box.begin() for i = 1, 10000 do s1:insert{i} s2:insert{i} end box.commit()

mem_before = mem_used()

-- Space drop doesn't yield because WAL is off so memory won't
-- be freed until we yield.
test_run:cmd("setopt delimiter ';'")
s1:drop()
s2:drop()
mem_after = mem_used()
_ = collectgarbage('collect')
test_run:cmd("setopt delimiter ''");

mem_after >= mem_before -- due to async cleanup and system_space dml on drop

-- Check that async cleanup doesn't leave garbage behind.
for i = 1, 100 do mem_after = mem_used() if mem_after <= mem_before then break end fiber.sleep(0.01) end
mem_after <= mem_before
