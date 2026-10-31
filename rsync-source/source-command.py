#!/usr/bin/env python3
"""Allow rsync downloads, with optional removal of copied source files."""

import os
import re
import sys


def fail(message):
    print(f"rsync-source: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("true", "false"):
        fail("invalid source deletion policy")

    command = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    # Match the sender prefix used by rrsync itself. Never execute the SSH
    # command through a shell; rrsync validates all remaining options and paths.
    if not command.startswith("rsync --server --sender "):
        fail("only rsync pulls are allowed")

    # A sender can also write log/batch files. Forbid those side effects even
    # when source removal is allowed. Tokenize escapes the same way as rrsync.
    # Check every token: a dot can be an option's value, not the path separator.
    for option in re.findall(r"(?:[^\s\\]+|\\.[^\s\\]*)+", command.split(" ", 2)[2]):
        name = option.split("=", 1)[0]
        if name in ("--log-file", "--only-write-batch"):
            fail("server-side log and batch files are not allowed")

    mode = "-no-lock" if sys.argv[1] == "true" else "-ro"
    os.execv("/usr/bin/rrsync", ["/usr/bin/rrsync", mode, "/data"])


if __name__ == "__main__":
    main()
