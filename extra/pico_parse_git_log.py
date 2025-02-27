#!/usr/bin/env python3

import sys
import argparse

def main():
    parser = argparse.ArgumentParser(usage=f"""
pipe the git log on stdin:

    git log end_commit...start_commit | {sys.argv[0]}

or pass in a range of commits:

    {sys.argv[0]} --git end_commit...start_commit

""")
    parser.add_argument("--git", nargs=1)
    args = parser.parse_args()

    # Read the commit messages
    if args.git:
        git_log = run_git_for_range(args.git[0])
    elif not sys.stdin.isatty():
        git_log = sys.stdin.buffer.read()
    else:
        print("Not enough arguments!", file=sys.stderr)
        parser.print_usage(file=sys.stderr)
        sys.exit(1)

    # NOTE: working with `bytes` instead of `str` for increased robustness so as
    # not to unexpectedly crash on a stray non-utf8 character
    checkpatch_ignore_types: list[bytes] = []

    # Parse the commit messages
    for line in git_log.splitlines():
        line = line.strip()

        prefix = b"CHECKPATCH_IGNORE="
        if not line.startswith(prefix):
            continue

        tail = line[len(prefix):]
        types = tail.split(b",")
        checkpatch_ignore_types.extend(t.strip() for t in types)

    if checkpatch_ignore_types:
        # Output ignored types
        output = bytes.join(b',', checkpatch_ignore_types)
        sys.stdout.buffer.write(output)
        print()
    else:
        print("input did not contain any `CHECKPATCH_IGNORE=` markings", file=sys.stderr)


def run_git_for_range(range: str) -> bytes:
    import subprocess
    output = subprocess.check_output(["git", "log", range])
    return output


if __name__ == "__main__":
    main()
