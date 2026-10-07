## feature/box

* `box.malloc.info()` now reports the memory of jemalloc if jemalloc serves
  `malloc` in the process, e.g. it is linked into the executable or loaded
  with `LD_PRELOAD`. Before, it reported the glibc heap, which is empty in
  this case.
* `box.malloc.info()` now has the field `allocator`: `glibc`, `jemalloc`,
  `mimalloc`, `asan` or `unknown`. A preloaded mimalloc is only named, its
  size and used memory are 0.
