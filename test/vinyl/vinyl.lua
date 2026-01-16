#!/usr/bin/env tarantool
--
-- The compaction scheduler sometimes randomly pessimises
-- the compaction rules based on slice->seed, which is generated
-- using rand() for each slice. Set the random seed to ensure the
-- randomness kicks in exactly the same slices from run to run.
-- Run *before* box.cfg{} to ensure slice->rand is correct
-- even after server restart.
--
local ffi = require('ffi')
ffi.cdef('void srand(unsigned int seed);')
ffi.C.srand(1)

box.cfg {
    listen            = os.getenv("LISTEN"),
    memtx_memory      = 512 * 1024 * 1024,
    memtx_max_tuple_size = 4 * 1024 * 1024,
    vinyl_read_threads = 2,
    vinyl_write_threads = 3,
    vinyl_memory = 512 * 1024 * 1024,
    vinyl_range_size = 1024 * 64,
    vinyl_page_size = 1024,
    vinyl_run_count_per_level = 1,
    vinyl_run_size_ratio = 2,
    vinyl_cache = 10240, -- 10kB
    vinyl_max_tuple_size = 1024 * 1024 * 6,
    --
    -- While the default checkpoint interval is 1 hour,
    -- it is still possible that a checkpoint happens quickly
    -- after the server starts. This will increase the number
    -- of dumps, may lead to an extra compaction and impact
    -- metrics.
    checkpoint_interval=0,
}

--
-- The test generates random data. The data is then
-- compressed and compression rate differs from seed to seed.
-- This may impact the compaction scheduler, which is based
-- on compressed size, not binary size.
--
math.randomseed(1)

require('console').listen(os.getenv('ADMIN'))
