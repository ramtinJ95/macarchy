#!/usr/bin/env python3
"""Validate changelog.d fragments and fold them into CHANGELOG.md at release.

Each user-facing change adds one changelog.d/<any-name>.md fragment: a single
Keep a Changelog section heading followed by one or more bullets in the
CHANGELOG.md style (continuation lines indented by two spaces):

    ### Fixed

    - Setup apply no longer rolls back when the song title contains a quote.

Usage:
    python3 -B Scripts/changelog.py check
    python3 -B Scripts/changelog.py release 1.2.3 2026-10-20 [--pr name=123 ...]

release inserts "## [1.2.3] - 2026-10-20" under "## [Unreleased]", merges any
bullets already there with the fragments by section, and deletes the consumed
fragments. --pr appends "(#123)" to every bullet of fragment <name>.
"""

import argparse
import datetime
import os
from pathlib import Path
import re
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
# Keep a Changelog order, then this project's own trailing section.
SECTIONS = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security",
            "Known limitations")
UNRELEASED = "## [Unreleased]"
# Keeps the directory, and with it the CI cache context, stable between releases.
FORMAT_NOTE = "README.md"


class ChangelogError(Exception):
    pass


def parse_entries(text, source, single_section):
    """Return ({section: [bullet, ...]}, [error, ...]) for fragment-style text."""
    entries, errors = {}, []
    current, continuing = None, False
    for number, line in enumerate(text.splitlines(), 1):
        where = f"{source}:{number}"
        if not line.strip():
            continuing = False
        elif line.startswith("### "):
            name, current, continuing = line[4:].strip(), None, False
            if name not in SECTIONS:
                errors.append(f"{where}: unknown section {name!r}; use one of "
                              + ", ".join(SECTIONS))
            elif name in entries:
                errors.append(f"{where}: duplicate section {name!r}")
            elif single_section and entries:
                errors.append(f"{where}: a fragment holds exactly one section")
            else:
                current = entries[name] = []
        elif line.startswith("- ") and line[2:].strip():
            if current is None:
                errors.append(f"{where}: bullet outside a known section")
            else:
                current.append(line.rstrip())
                continuing = True
        elif line.startswith("  ") and continuing:
            current[-1] += "\n" + line.rstrip()
        else:
            continuing = False
            errors.append(f"{where}: stray text {line.strip()!r}; "
                          "only a section heading and '- ' bullets are allowed")
    for name, items in entries.items():
        if not items:
            errors.append(f"{source}: section {name!r} has no bullets")
    if single_section and not entries and not errors:
        errors.append(f"{source}: empty fragment")
    return entries, errors


def fragment_paths(root):
    directory = root / "changelog.d"
    if not directory.exists():
        return [], []
    paths, errors = [], []
    for path in sorted(directory.iterdir()):
        if path.name == FORMAT_NOTE:
            continue
        if path.suffix != ".md" or not path.is_file() or path.is_symlink():
            errors.append(f"{path.relative_to(root)}: fragments must be regular .md files")
        else:
            paths.append(path)
    return paths, errors


def unreleased_bounds(lines):
    starts = [index for index, line in enumerate(lines) if line == UNRELEASED]
    if len(starts) != 1:
        raise ChangelogError(f"CHANGELOG.md needs exactly one '{UNRELEASED}' heading")
    start = starts[0]
    end = next((index for index in range(start + 1, len(lines))
                if lines[index].startswith("## ")), len(lines))
    return start, end


def load(root):
    """Parse CHANGELOG.md's Unreleased bullets and every fragment, or raise."""
    changelog = (root / "CHANGELOG.md").read_text()
    lines = changelog.splitlines()
    start, end = unreleased_bounds(lines)
    unreleased, errors = parse_entries(
        "\n".join(lines[start + 1:end]), f"CHANGELOG.md {UNRELEASED}", False)
    paths, path_errors = fragment_paths(root)
    errors += path_errors
    fragments = []
    for path in paths:
        entries, fragment_errors = parse_entries(
            path.read_text(), str(path.relative_to(root)), True)
        errors += fragment_errors
        fragments.append((path, entries))
    if errors:
        raise ChangelogError("\n".join(errors))
    return lines, unreleased, fragments


def with_pr(bullet, number):
    head, _, last = bullet.rpartition("\n")
    last = last[:-1] + f" (#{number})." if last.endswith(".") else last + f" (#{number})"
    return f"{head}\n{last}" if head else last


def render_release(lines, unreleased, fragments, version, date, prs):
    """Return the new CHANGELOG.md text; fragments is [(name, entries)]."""
    if any(line.startswith(f"## [{version}]") for line in lines):
        raise ChangelogError(f"CHANGELOG.md already has a {version} section")
    names = {name for name, _ in fragments}
    unknown = sorted(set(prs) - names)
    if unknown:
        raise ChangelogError("--pr names no fragment: " + ", ".join(unknown))
    merged = {section: list(bullets) for section, bullets in unreleased.items()}
    for name, entries in fragments:
        for section, bullets in entries.items():
            merged.setdefault(section, []).extend(
                with_pr(bullet, prs[name]) if name in prs else bullet
                for bullet in bullets)
    if not merged:
        raise ChangelogError("nothing to release: no fragments or Unreleased bullets")
    body = []
    for section in SECTIONS:
        if section in merged:
            body += [f"### {section}", "", *merged[section], ""]
    start, end = unreleased_bounds(lines)
    released = lines[:start + 1] + ["", f"## [{version}] - {date}", ""] + body + lines[end:]
    return "\n".join(released) + "\n"


def write_atomically(path, text):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False,
                                     prefix=f".{path.name}.") as temporary:
        temporary.write(text)
    os.replace(temporary.name, path)


def release(root, version, date, prs):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ChangelogError(f"version must be MAJOR.MINOR.PATCH, not {version!r}")
    try:
        datetime.date.fromisoformat(date)
    except ValueError:
        raise ChangelogError(f"date must be YYYY-MM-DD, not {date!r}") from None
    lines, unreleased, fragments = load(root)
    named = [(path.stem, entries) for path, entries in fragments]
    prs = {name.removesuffix(".md"): number for name, number in prs.items()}
    write_atomically(root / "CHANGELOG.md",
                     render_release(lines, unreleased, named, version, date, prs))
    for path, _ in fragments:
        path.unlink()


def pr_argument(value):
    name, separator, number = value.partition("=")
    if not separator or not name or not re.fullmatch(r"[1-9][0-9]*", number):
        raise argparse.ArgumentTypeError("expected <fragment>=<pr-number>")
    return name, int(number)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="validate CHANGELOG.md Unreleased and fragments")
    release_parser = commands.add_parser("release", help="fold fragments into a release")
    release_parser.add_argument("version")
    release_parser.add_argument("date")
    release_parser.add_argument("--pr", type=pr_argument, action="append", default=[])
    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            _, _, fragments = load(args.root)
            print(f"changelog fragments valid ({len(fragments)})")
        else:
            release(args.root, args.version, args.date, dict(args.pr))
            print(f"CHANGELOG.md: released {args.version}")
    except (ChangelogError, OSError) as error:
        sys.exit(f"changelog: {error}")


if __name__ == "__main__":
    main()
