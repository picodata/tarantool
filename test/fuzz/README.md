## Running Fuzzers Locally

To check that fuzzing works locally first clone the **oss-fuzz** tools.

```bash
git clone https://github.com/google/oss-fuzz.git

cd oss-fuzz
```

Build the docker image, which is used to build fuzzers.
Then build the actual fuzz targets.
`<path-to-tarantool>` is the path to the root of this repository.

```bash
python3 infra/helper.py build_image --external <path-to-tarantool>

python3 infra/helper.py build_fuzzers --external <path-to-tarantool> --sanitizer=address
```

Run all fuzzers for a short period of time to check that they were built correctly.

```bash
python3 infra/helper.py check_build --external <path-to-tarantool> --sanitizer=address
```

To run a specific fuzzer execute the following command.
Replace `<fuzz-target>` with any fuzzer in the `test/fuzz` directory. Example: `uri_fuzzer`

```bash
python3 infra/helper.py run_fuzzer --external <path-to-tarantool> <fuzzer-target>
```

For more information on fuzzing see [ClusterFuzzLite docs](https://google.github.io/clusterfuzzlite/build-integration/#testing-locally).

### fuzz_until.py script

It is also possible to run fuzzers until they satisfy all of the following stopping criteria:
1. At least 100 000 inputs were generated and passed to the fuzzing target
2. (Optional, enabled via flag) coverage increased at least twice compared to the initial corpus
3. Last coverage increase was detected at least 2 hours ago

For this run `fuzz_until.py` script from the tarantool repository root.
The script requires the target to be already built with `oss-fuzz/infra/helper.py build_fuzzers`.

```bash
mkdir new_corpus
python3 test/fuzz/fuzz_until.py <fuzzer-target> --libfuzzer-log my_target.log --corpus-dir new_corpus
```
