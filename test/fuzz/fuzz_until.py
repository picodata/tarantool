import time
import subprocess
from argparse import ArgumentParser
from enum import Enum, auto
from dataclasses import dataclass
from pathlib import Path


class MsgType(Enum):
    """Type of libfuzzer log message"""

    READ = auto()
    INITED = auto()
    NEW = auto()
    REDUCE = auto()
    pulse = auto()
    DONE = auto()
    RELOAD = auto()


@dataclass(repr=True)
class Msg:
    """Libfuzzer log message contents"""

    ty: MsgType
    n_inputs: int
    cov: int | None
    ft: int | None


# See libfuzzer output format: https://llvm.org/docs/LibFuzzer.html#output
def parse_line(line: str) -> Msg | None:
    """Parse libfuzzer log message"""

    line = line.split()

    msg_ty = None
    for ty in MsgType:
        if ty.name in line:
            msg_ty = ty
            break
    if not msg_ty:
        return None

    n_inputs = 0
    if line[0][0] == "#":
        n_inputs = int(line[0][1:])

    cov = None
    if "cov:" in line:
        cov_i = line.index("cov:")
        cov = int(line[cov_i + 1])

    ft = None
    if "ft:" in line:
        ft_i = line.index("ft:")
        ft = int(line[ft_i + 1])

    return Msg(msg_ty, n_inputs, cov, ft)


class Supervisor:
    """A wrapper to run the fuzzer until stopping criteria are satisfied
    or an error is encountered"""

    def __init__(self, fuzzer_name: str, libfuzzer_log: Path, corpus_dir: Path, wait_2x_cov: bool):
        self.fuzzer_name = fuzzer_name
        self.libfuzzer_log = libfuzzer_log
        self.corpus_dir = corpus_dir
        self.wait_2x_cov = self.wait_2x_cov
        self.start_time = time.monotonic()
        self.init_cov = None
        self.latest_cov = None
        self.init_ft = None
        self.latest_ft = None
        self.latest_n_inputs = 0
        self.latest_new_path = self.start_time

    def criteria_satisfied(self) -> bool:
        """Indicates whether stopping criteria of the corresponding fuzzer
        are satisfied. E.g. it was running long enough and covered enough paths."""

        # Coverage increased at least twice in comparison with corpus
        cov = False
        if self.init_cov:
            cov = self.latest_cov >= self.init_cov * 2

        # Number of unique paths (features) increased at least twice
        # in comparison with corpus
        ft = False
        if self.init_ft:
            ft = self.latest_ft >= self.init_ft * 2

        # At least 100_000 fuzzer test runs
        n_inputs = self.latest_n_inputs > 100_000

        # Last new path was discovered 2 hours ago
        new_path = (time.monotonic() - self.latest_new_path) > 2 * 60 * 60

        return (cov or ft or not self.wait_2x_cov) and n_inputs and new_path

    def update_stats(self, msg: Msg):
        self.latest_n_inputs = msg.n_inputs
        if msg.cov:
            self.latest_cov = msg.cov
        if msg.ft:
            self.latest_ft = msg.ft

        if msg.ty == MsgType.INITED:
            self.init_cov = msg.cov
            self.init_ft = msg.ft

        if msg.ty == MsgType.NEW:
            self.latest_new_path = time.monotonic()

    def run(self):
        """Run the corresponding fuzzer until either stopping criteria are
        satisfied or fuzzing fails with an error indicating that some problem
        was detected."""

        print(f"Running {self.fuzzer_name}")
        proc = subprocess.Popen(
            [
                "python3",
                "oss-fuzz/infra/helper.py",
                "run_fuzzer",
                "--external",
                ".",
                "--corpus-dir",
                self.corpus_dir.resolve(),
                self.fuzzer_name,
                # after this all options go directly to the fuzzer
                "--",
                # reduction might slow down both fuzzer and superviser
                "-reduce_inputs=0",
                # By default address sanitizer is used
                # By default corpus {fuzzer_name}_corpus will be loaded from oss-fuzz build directory
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        with self.libfuzzer_log.open("w") as libfuzzer_log:
            for line in proc.stdout:
                msg = parse_line(line)
                # Add timestamp in seconds relative to the starting time of a fuzzer
                line = f"{time.monotonic() - self.start_time}s {line}"
                libfuzzer_log.write(line)
                # if it is not a conventional log message print and continue
                if not msg:
                    print(line.strip("\n"), end="\r\n")
                    continue

                # On pulse print the current state
                if msg.ty == MsgType.pulse:
                    print(vars(self), end="\r\n")

                self.update_stats(msg)
                if self.criteria_satisfied():
                    print(f"Fuzzer {self.fuzzer_name} satisfied criteria")
                    proc.kill()
                    return

        outs, errs = proc.communicate(timeout=15)
        print(outs)
        print(errs)
        code = proc.poll()
        if code != 0 and (not self.criteria_satisfied()):
            raise Exception(
                f"Fuzzer {self.fuzzer_name} stopped without satisfying criteria. Exit code: {code}"
            )


# The script takes the fuzzing target name as the first argument.
# Then it runs the fuzzing target until either stopping criteria are satisfied
# or fuzzer detects a bug and fails.
if __name__ == "__main__":
    parser = ArgumentParser(
        prog="Fuzzer Supervisor",
        description="Runs a supplied fuzzer target until either stopping criteria\
 are satisfied or fuzzer detects a bug and fails",
    )
    parser.add_argument("fuzzer_target_name")
    parser.add_argument(
        "--libfuzzer-log",
        required=True,
        type=Path,
        help="File where libfuzzer log will be written",
    )
    parser.add_argument(
        "--corpus-dir",
        required=True,
        type=Path,
        help="Directory where libuzzer generated corpus will be stored",
    )
    parser.add_argument(
        "--wait-2x-cov",
        action="store_true",
        help="Enables 'coverage increased at least twice' criteria",
    )
    args = parser.parse_args()
    Supervisor(args.fuzzer_target_name, args.libfuzzer_log, args.corpus_dir, args.wait_2x_cov).run()
