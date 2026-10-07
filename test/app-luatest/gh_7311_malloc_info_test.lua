local tarantool = require('tarantool')

local ffi = require('ffi')
ffi.cdef([[
    void *malloc(size_t size);
    void free(void *p);
    int mallctl(const char *name, void *oldp, size_t *oldlenp,
                void *newp, size_t newlen);
    int mi_version(void);
]])
local malloc = ffi.C.malloc
local free = ffi.C.free

local t = require('luatest')
local g = t.group()

local ALLOC_SIZE = 10 * 1000 * 1000
local MARGIN = ALLOC_SIZE * 0.05

-- The allocator which serves malloc in the process.
local function expected_allocator()
    -- If ASAN is enabled, malloc_info() exists but it is not implemented
    -- (all counters in the returned document are set to zeros).
    if tarantool.build.asan then
        return 'asan'
    end
    if pcall(function() return ffi.C.mallctl end) then
        return 'jemalloc'
    end
    if pcall(function() return ffi.C.mi_version end) then
        return 'mimalloc'
    end
    -- malloc_info() is a GNU extension available only on Linux.
    if jit.os ~= 'Linux' then
        return 'unknown'
    end
    return 'glibc'
end

-- The memory usage is reported only for these allocators. A preloaded
-- mimalloc is only named.
local function is_supported()
    local allocator = expected_allocator()
    return allocator == 'glibc' or allocator == 'jemalloc'
end

local function skip_if_supported()
    t.skip_if(is_supported(), 'malloc info is supported')
end

local function skip_if_unsupported()
    t.skip_if(not is_supported(), 'malloc info is not supported')
end

-- The start argument is the info at the start of the test.
local function check_malloc_info(info, start)
    t.assert_ge(info.used, 0)
    t.assert_ge(info.size, info.used)
    -- It's totally up to the malloc implementation whether to release memory
    -- to the system on free() immediately or keep it for future allocations.
    -- Still, it's reasonable to assume that a repetitive allocation and
    -- freeing of an object of the same size won't result in growing total
    -- memory usage infinitely. So we check that the system memory usage never
    -- exceeds the allocated memory usage by more than the test allocation size
    -- plus an overhead for internal housekeeping and fragmentation.
    if info.allocator == 'glibc' then
        t.assert_le(info.size, info.used + 1.1 * ALLOC_SIZE)
    elseif info.allocator == 'jemalloc' then
        -- jemalloc keeps freed pages for dirty_decay_ms (10 s by default,
        -- forever if it is -1), and the size includes its metadata. Thus the
        -- size also has the memory which the previous tests freed, and the
        -- limit is relative to size - used at the start of the test.
        t.assert_le(info.size - info.used,
                    start.size - start.used + 1.5 * ALLOC_SIZE)
    else
        t.fail('unexpected allocator ' .. tostring(info.allocator))
    end
end

g.test_malloc_info = function()
    t.assert_type(box.malloc, 'table')
    t.assert_type(box.malloc.info, 'function')
    t.assert_type(box.malloc.info(), 'table')
    t.assert_type(box.malloc.info().allocator, 'string')
    t.assert_type(box.malloc.internal, 'table')
    t.assert_type(box.malloc.internal.info, 'function')
    t.assert_type(box.malloc.internal.info(), 'table')
end

g.test_unsupported = function()
    skip_if_supported()

    t.assert_equals(box.malloc.info(),
                    {size = 0, used = 0, allocator = expected_allocator()})
end

g.test_allocator = function()
    t.assert_equals(box.malloc.info().allocator, expected_allocator())
end

g.test_malloc_small = function()
    skip_if_unsupported()

    local p = {}
    local count = 10000
    local size = ALLOC_SIZE / count
    t.assert_ge(size, 100)

    local info1 = box.malloc.info()
    for i = 1, count do
        p[i] = malloc(size)
        t.assert_not_equals(p[i], nil)
    end
    local info2 = box.malloc.info()
    for i = 1, count, 2 do
        free(p[i])
    end
    local info3 = box.malloc.info()
    for i = 2, count, 2 do
        free(p[i])
    end
    local info4 = box.malloc.info()

    check_malloc_info(info1, info1)
    check_malloc_info(info2, info1)
    check_malloc_info(info3, info1)
    check_malloc_info(info4, info1)

    t.assert_almost_equals(info2.used - info1.used, ALLOC_SIZE, MARGIN)
    t.assert_almost_equals(info2.used - info3.used, ALLOC_SIZE / 2, MARGIN)
    t.assert_almost_equals(info4.used, info1.used, MARGIN)
end

g.test_malloc_huge = function()
    skip_if_unsupported()

    local info1 = box.malloc.info()
    local p = malloc(ALLOC_SIZE)
    t.assert_not_equals(p, nil)
    local info2 = box.malloc.info()
    free(p)
    local info3 = box.malloc.info()

    check_malloc_info(info1, info1)
    check_malloc_info(info2, info1)
    check_malloc_info(info3, info1)

    t.assert_almost_equals(info2.used - info1.used, ALLOC_SIZE, MARGIN)
    t.assert_almost_equals(info3.used, info1.used, MARGIN)
end
