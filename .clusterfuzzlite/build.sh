#!/bin/bash

# Clean up potentially persistent build directory.
[[ -e $SRC/tarantool/build ]] && rm -rf $SRC/tarantool/build

# Build ICU for linking statically.
mkdir -p $SRC/tarantool/build/icu && cd $SRC/tarantool/build/icu

[ ! -e config.status ] && LDFLAGS="-lpthread" CXXFLAGS="$CXXFLAGS -lpthread" \
  $SRC/icu/source/configure --disable-shared --enable-static --disable-layoutex \
  --disable-tests --disable-samples --with-data-packaging=static
make install -j$(nproc)

# For fuzz-introspector, exclude all functions in the tests directory,
# libprotobuf-mutator and protobuf source code.
# See https://github.com/ossf/fuzz-introspector/blob/main/doc/Config.md#code-exclusion-from-the-report
export FUZZ_INTROSPECTOR_CONFIG=$SRC/fuzz_introspector_exclusion.config
cat > $FUZZ_INTROSPECTOR_CONFIG <<EOF
FILES_TO_AVOID
icu/
tarantool/build/test
EOF

cd $SRC/tarantool

case $SANITIZER in
  address) SANITIZERS_ARGS="-DENABLE_ASAN=ON" ;;
  undefined) SANITIZERS_ARGS="-DENABLE_UB_SANITIZER=ON" ;;
  *) SANITIZERS_ARGS="" ;;
esac

: ${LD:="${CXX}"}
: ${LDFLAGS:="${CXXFLAGS}"}  # to make sure we link with sanitizer runtime

cmake_args=(
    # Specific to Tarantool
    -DENABLE_FUZZER=ON
    -DOSS_FUZZ=ON
    -DLUA_USE_APICHECK=ON
    -DLUA_USE_ASSERT=ON
    -DLUAJIT_USE_SYSMALLOC=ON
    -DLUAJIT_ENABLE_GC64=ON
    $SANITIZERS_ARGS

    # C compiler
    -DCMAKE_C_COMPILER="${CC}"
    -DCMAKE_C_FLAGS="${CFLAGS} -Wno-error=unused-command-line-argument -fuse-ld=lld"

    # C++ compiler
    -DCMAKE_CXX_COMPILER="${CXX}"
    -DCMAKE_CXX_FLAGS="${CXXFLAGS} -Wno-error=unused-command-line-argument -fuse-ld=lld"

    # Linker
    -DCMAKE_LINKER="${LD}"
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_MODULE_LINKER_FLAGS="${LDFLAGS}"
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}"

    # Dependencies
    -DENABLE_BUNDLED_ZSTD=OFF
)

# To deal with a host filesystem from inside of container.
git config --global --add safe.directory '*'

# Build the project and fuzzers.
[[ -e build ]] && rm -rf build
cmake "${cmake_args[@]}" -S . -B build -G Ninja
cmake --build build --target fuzzers --parallel

# Archive and copy to $OUT seed corpus if the build succeeded.
for f in $(find build/test/fuzz/ -name '*_fuzzer' -type f);
do
  name=$(basename $f);
  module=$(echo $name | sed 's/_fuzzer//')
  corpus_dir="test/static/corpus/$module"
  echo "Copying for $module";
  cp $f $OUT/
  dict_path="test/static/$name.dict"
  if [ -e "$dict_path" ]; then
    cp $dict_path $OUT/
  fi
  if [ -e "$corpus_dir" ]; then
    zip -j $OUT/"$name"_seed_corpus.zip $corpus_dir/*
  fi
done
