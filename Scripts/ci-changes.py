#!/usr/bin/env python3
"""Conservative PR classification; unknown or empty changes require full CI."""

import re
import subprocess
import sys


# Exact root files only. CHANGELOG, LICENSE and Documentation contain release
# inputs; Themes, Desktop, Environment and Keybindings are also test inputs.
LIGHTWEIGHT_PATHS = {b"README.md", b"AGENTS.md"}


def requires_full_checks(paths):
    return not paths or any(path not in LIGHTWEIGHT_PATHS for path in paths)


def classify(base, cwd=None):
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("base must be a full Git commit SHA")
    # Compare the event's base to the tested merge checkout, not just the latest
    # PR commit. Disable rename detection so both old and new paths participate.
    result = subprocess.run(
        ["git", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
         "--name-only", "-z", base, "HEAD", "--"],
        cwd=cwd, check=True, stdout=subprocess.PIPE,
    )
    paths = result.stdout.split(b"\0")[:-1]
    return requires_full_checks(paths)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: ci-changes.py <pull-request-base-sha>")
    try:
        full = classify(sys.argv[1])
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Cannot classify PR changes: {error}")
    print("true" if full else "false")
