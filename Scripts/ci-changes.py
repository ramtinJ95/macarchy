#!/usr/bin/env python3
"""Conservative PR classification and committed build-cache compatibility."""

import hashlib
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


def cache_context(cwd=None):
    # New root headers can shadow SDK headers without invalidating cached native
    # objects (the historical VERSION/<version> collision). Everything outside
    # the incremental source trees and safe root docs belongs in BOTH cache
    # prefixes. Directory tree IDs also cover unknown future build-input roots.
    result = subprocess.run(
        ["git", "ls-tree", "-z", "HEAD"],
        cwd=cwd, check=True, stdout=subprocess.PIPE,
    )
    digest = hashlib.sha256()
    for entry in result.stdout.split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        kind = metadata.split(b" ")[1]
        if kind == b"tree" and path in {b"Sources", b"Tests"}:
            continue
        if kind == b"blob" and path in LIGHTWEIGHT_PATHS:
            continue
        digest.update(entry + b"\0")
    return digest.hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: ci-changes.py <pull-request-base-sha> | --cache-context")
    try:
        if sys.argv[1] == "--cache-context":
            output = cache_context()
        else:
            output = "true" if classify(sys.argv[1]) else "false"
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Cannot inspect CI inputs: {error}")
    print(output)
