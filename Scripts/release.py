#!/usr/bin/env python3
"""Prepare, publish and install a stable Macarchy release.

Usage:
    python3 -B Scripts/release.py prepare 1.2.3 [--pr fragment=123 ...]
    python3 -B Scripts/release.py publish 1.2.3
    python3 -B Scripts/release.py finish 1.2.3
    python3 -B Scripts/release.py upgrade [--expect 1.2.3]

prepare   On the last PR branch of a batch: fold changelog.d into CHANGELOG.md,
          bump VERSION.txt and RuntimeEnvironment.sourceVersion, and commit
          "chore(release): prepare v1.2.3".
publish   After that PR merged: require origin/main at 1.2.3 with a green CI push
          run, tag v1.2.3 on it and dispatch release.yml. A person approves the
          protected stable-release environment; this script never does.
finish    Wait for the release run, verify the published archive (checksum,
          attestation, bin/macarchy --version) and land the Homebrew tap update,
          which may change only the formula url and sha256.
upgrade   On a machine: upgrade the formula, apply setup only when the plan needs
          no package installs, adoptions or approvals, then run doctor.

Every step is safe to rerun: completed work is detected and skipped.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

import changelog


ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "ramtinJ95/macarchy"
TAP_REPOSITORY = "ramtinJ95/homebrew-tap"
TAP_FORMULA = "Formula/macarchy.rb"
FORMULA = "ramtinj95/tap/macarchy"
BREW = "/opt/homebrew/bin/brew"
MACARCHY = "/opt/homebrew/bin/macarchy"
SOURCE_VERSION = Path("Sources/MacarchyCLI/App/RuntimeEnvironment.swift")
# Same environment as `macarchy update` (HomebrewUpdateRunner).
HOMEBREW_ENVIRONMENT = {
    "HOMEBREW_NO_ANALYTICS": "1",
    "HOMEBREW_NO_AUTOREMOVE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
}
RUN_FIELDS = "databaseId,status,conclusion,url,headSha"
# Explicit prefixes: user diff settings such as mnemonicPrefix change the header.
TAP_DIFF = ("diff", "--no-ext-diff", "--no-color", "--no-renames", "-U0",
            "--src-prefix=a/", "--dst-prefix=b/")


class ReleaseError(Exception):
    pass


def run(arguments, timeout, cwd=ROOT, env=None, check=True):
    """Run with captured output; failures carry the verbatim output."""
    command = shlex.join(str(argument) for argument in arguments)
    try:
        result = subprocess.run([str(argument) for argument in arguments], cwd=cwd,
                                env=env, timeout=timeout, capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        raise ReleaseError(f"timed out after {timeout}s: {command}") from None
    if check and result.returncode:
        raise ReleaseError(f"{command} exited {result.returncode}:\n"
                           f"{result.stdout}{result.stderr}")
    return result


def stream(arguments, timeout, env=None):
    """Run with output on the terminal, for long or interactive steps."""
    command = shlex.join(str(argument) for argument in arguments)
    print(f"$ {command}", flush=True)
    try:
        code = subprocess.run([str(argument) for argument in arguments], cwd=ROOT,
                              env=env, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        raise ReleaseError(f"timed out after {timeout}s: {command}") from None
    if code:
        raise ReleaseError(f"{command} exited {code} (output above)")


def parse_version(text):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", text):
        raise argparse.ArgumentTypeError(f"version must be MAJOR.MINOR.PATCH, not {text!r}")
    return text


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def archive_name(version):
    return f"macarchy-{version}-arm64-apple-darwin.tar.gz"


def archive_url(version):
    return (f"https://github.com/{REPOSITORY}/releases/download/"
            f"v{version}/{archive_name(version)}")


def bump_source_version(swift, version):
    pattern = r'(static let sourceVersion = ")[0-9]+\.[0-9]+\.[0-9]+(")'
    updated, count = re.subn(pattern, rf"\g<1>{version}\g<2>", swift)
    if count != 1:
        raise ReleaseError(f"expected one sourceVersion declaration, found {count}")
    return updated


def remote_tag_commit(ls_remote, tag):
    """The commit a remote tag names, from `git ls-remote` output, or None."""
    refs = {name: sha for sha, name in
            (line.split("\t", 1) for line in ls_remote.splitlines() if line)}
    return refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")


def ci_state(runs, sha):
    """('success' | 'pending' | 'failed' | 'missing', run) for a commit's CI runs."""
    runs = [entry for entry in runs if entry.get("headSha") == sha]
    for state, matches in (("success", lambda r: r.get("conclusion") == "success"),
                           ("pending", lambda r: r.get("status") != "completed")):
        found = next((entry for entry in runs if matches(entry)), None)
        if found:
            return state, found
    return ("failed", runs[0]) if runs else ("missing", None)


def parse_checksum(record, name):
    match = re.fullmatch(r"([0-9a-f]{64})  (\S+)\n", record)
    if not match or match.group(2) != name:
        raise ReleaseError(f"malformed checksum record for {name}: {record!r}")
    return match.group(1)


def rewrite_formula(formula, url, sha256):
    """Point the formula's top-level url and sha256 at a new archive."""
    lines = formula.splitlines(keepends=True)
    for field, value in (("url", url), ("sha256", sha256)):
        indices = [index for index, line in enumerate(lines)
                   if re.fullmatch(rf'  {field} "[^"]*"\n', line)]
        if len(indices) != 1:
            raise ReleaseError(f"expected one top-level {field} in the formula, "
                               f"found {len(indices)}")
        lines[indices[0]] = f'  {field} "{value}"\n'
    return "".join(lines)


def formula_version(formula):
    """The version in the formula's top-level release archive url."""
    match = re.search(r'^  url "[^"]*/releases/download/v(\d+\.\d+\.\d+)/[^"]*"$',
                      formula, re.MULTILINE)
    if not match:
        raise ReleaseError("cannot read the release version from the formula url")
    return match.group(1)


def check_tap_diff(diff):
    """Refuse a `git diff -U0` that changes anything but the formula url/sha256."""
    files = re.findall(r"^diff --git a/(\S+) b/", diff, re.MULTILINE)
    changes = [line for line in diff.splitlines()
               if line[:1] in ("+", "-") and not line.startswith(("+++ ", "--- "))]
    fields = sorted(line[0] + match.group(1) for line in changes
                    if (match := re.fullmatch(r'[+-]  (url|sha256) "[^"]*"', line)))
    if (files != [TAP_FORMULA] or len(fields) != len(changes)
            or fields != ["+sha256", "+url", "-sha256", "-url"]):
        raise ReleaseError(f"tap diff must change only the formula url and sha256:\n{diff}")


def plan_step(report):
    """('skip' | 'apply' | 'stop', reasons) for a `setup plan --json` report."""
    if report.get("schema_version") != 1 or report.get("operation") != "setup_plan":
        return "stop", ["unrecognized setup plan schema"]
    outcome = report.get("outcome")
    if outcome == "no_change":
        return "skip", []
    if outcome != "ready":
        return "stop", [f"plan outcome is {outcome!r}"]
    stages = {action.get("stage") for action in report.get("actions", [])}
    preferences = (report.get("components") or {}).get("preferences") or {}
    reasons = [reason for reason, applies in (
        ("installs Homebrew packages",
         "packages" in stages or "package_installation" in report),
        ("has external prerequisites", "prerequisites" in stages),
        ("needs adoption approval: "
         + ", ".join(entry.get("id", "?") for entry in report.get("adoption", [])),
         bool(report.get("adoption"))),
        ("changes native preferences (needs --approve-preferences)",
         bool((preferences.get("report") or {}).get("approval_digest"))),
        ("writes native starter files (needs guided setup approval)",
         bool(report.get("native_starters"))),
    ) if applies]
    return ("stop", reasons) if reasons else ("apply", [])


def git(*arguments, cwd=ROOT, timeout=60, check=True):
    return run(["git", *arguments], timeout, cwd=cwd, check=check).stdout.strip()


def gh_json(*arguments, timeout=60):
    return json.loads(run(["gh", *arguments], timeout).stdout or "null")


def prepare(version, prs, root=ROOT, today=None):
    subject = f"chore(release): prepare v{version}"
    current = (root / "VERSION.txt").read_text().strip()
    if git("status", "--porcelain", cwd=root):
        raise ReleaseError("working tree is not clean; commit or stash first")
    if current == version:
        if git("log", "-1", "--format=%s", cwd=root) == subject:
            print(f"v{version} already prepared at HEAD")
            return
        raise ReleaseError(f"VERSION.txt is already {version} but HEAD is not "
                           f"'{subject}'")
    if version_key(version) <= version_key(current):
        raise ReleaseError(f"{version} is not newer than VERSION.txt {current}")
    if git("rev-parse", "--abbrev-ref", "HEAD", cwd=root) in {"main", "HEAD"}:
        raise ReleaseError("prepare on the batch's last PR branch, not main or a "
                           "detached HEAD")
    try:
        changelog.release(root, version, (today or datetime.date.today()).isoformat(),
                          prs)
    except changelog.ChangelogError as error:
        raise ReleaseError(str(error)) from None
    (root / "VERSION.txt").write_text(version + "\n")
    source = root / SOURCE_VERSION
    source.write_text(bump_source_version(source.read_text(), version))
    git("add", "--all", "--", "CHANGELOG.md", "changelog.d", "VERSION.txt",
        str(SOURCE_VERSION), cwd=root)
    git("commit", "--quiet", "-m", subject, cwd=root)
    print(f"Committed '{subject}'. Push it with the batch's last PR.")


def wait_for_run(run_id, timeout):
    stream(["gh", "run", "watch", str(run_id), "--repo", REPOSITORY, "--exit-status",
            "--interval", "30"], timeout)


def require_green_ci(sha):
    query = ["run", "list", "--repo", REPOSITORY, "--workflow", "ci.yml", "--event",
             "push", "--commit", sha, "--json", RUN_FIELDS]
    state, found = ci_state(gh_json(*query), sha)
    if state == "pending":
        print(f"Waiting for main CI: {found['url']}")
        wait_for_run(found["databaseId"], 3600)
        state, found = ci_state(gh_json(*query), sha)
    if state != "success":
        detail = f": {found['url']}" if found else ""
        raise ReleaseError(f"no successful CI push run for {sha} ({state}){detail}")
    print(f"Main CI passed for {sha}: {found['url']}")


def release_runs(tag):
    return gh_json("run", "list", "--repo", REPOSITORY, "--workflow", "release.yml",
                   "--branch", tag, "--event", "workflow_dispatch", "--json", RUN_FIELDS)


def published(tag):
    return run(["gh", "release", "view", tag, "--repo", REPOSITORY, "--json", "url"],
               60, check=False).returncode == 0


def ensure_tag(tag, sha):
    remote = remote_tag_commit(
        git("ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}",
            timeout=120), tag)
    if remote == sha:
        print(f"{tag} already on origin at {sha}")
        return
    if remote:
        raise ReleaseError(f"origin's {tag} points at {remote}, not {sha}; "
                           "release tags are immutable")
    local = git("rev-parse", "-q", "--verify", f"refs/tags/{tag}^{{commit}}", check=False)
    if local and local != sha:
        raise ReleaseError(f"local {tag} points at {local}, not {sha}; delete it first")
    if not local:
        git("tag", "--annotate", tag, "--message", f"Macarchy {tag}", sha)
    git("push", "origin", f"refs/tags/{tag}", timeout=120)
    print(f"Pushed {tag} at {sha}")


def publish(version):
    tag = f"v{version}"
    git("fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main",
        timeout=120)
    sha = git("rev-parse", "refs/remotes/origin/main")
    main_version = git("show", f"{sha}:VERSION.txt")
    if main_version != version:
        raise ReleaseError(f"origin/main ({sha}) is at {main_version}, not {version}; "
                           "merge the prepare commit first")
    require_green_ci(sha)
    ensure_tag(tag, sha)
    if published(tag):
        print(f"{tag} is already published; run finish {version}")
        return
    active = next((entry for entry in release_runs(tag)
                   if entry["status"] != "completed" or entry["conclusion"] == "success"),
                  None)
    if not active:
        before = {entry["databaseId"] for entry in release_runs(tag)}
        run(["gh", "workflow", "run", "release.yml", "--repo", REPOSITORY, "--ref", tag],
            60)
        for _ in range(24):
            active = next((entry for entry in release_runs(tag)
                           if entry["databaseId"] not in before), None)
            if active:
                break
            time.sleep(5)
        else:
            raise ReleaseError(f"dispatched release.yml for {tag} but found no run; "
                               "check the Actions tab")
    print(f"Release run: {active['url']}\n"
          f"Approve the stable-release environment there, then run: "
          f"Scripts/release.py finish {version}")


def verify_archive(version, directory):
    tag, name = f"v{version}", archive_name(version)
    run(["gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", directory,
         "--pattern", name, "--pattern", f"{name}.sha256"], 600)
    archive = directory / name
    expected = parse_checksum((directory / f"{name}.sha256").read_text(), name)
    actual = run(["/usr/bin/shasum", "-a", "256", archive], 120).stdout.split()[0]
    if actual != expected:
        raise ReleaseError(f"{name} checksum {actual} does not match {expected}")
    for subject in (archive, directory / f"{name}.sha256"):
        run(["gh", "attestation", "verify", subject, "--repo", REPOSITORY], 300)
    extracted = directory / "extracted"
    extracted.mkdir()
    run(["/usr/bin/tar", "-xzf", archive, "-C", extracted], 300)
    binary = extracted / name.removesuffix(".tar.gz") / "bin/macarchy"
    reported = run([binary, "--version"], 60).stdout.strip()
    if reported != version:
        raise ReleaseError(f"archive's bin/macarchy reports {reported!r}, not {version}")
    print(f"Verified {name}: checksum, attestations and --version {version}")
    return expected


def remote_tap_attempt(clone, branch, subject):
    """The tip of an earlier attempt to replace ("" when none), or refuse others' work."""
    listed = git("ls-remote", "origin", f"refs/heads/{branch}", cwd=clone, timeout=60)
    if not listed:
        return ""
    tip = listed.split()[0]
    git("fetch", "--quiet", "--depth", "2", "origin", f"refs/heads/{branch}", cwd=clone,
        timeout=120)
    if (git("log", "-1", "--format=%s", tip, cwd=clone) != subject
            or git("rev-list", "--count", f"HEAD..{tip}", cwd=clone) != "1"):
        raise ReleaseError(f"{TAP_REPOSITORY} branch {branch} holds commits this script "
                           "did not make; resolve it by hand")
    check_tap_diff(git(*TAP_DIFF, f"{tip}^", tip, "--", cwd=clone))
    return tip


def update_tap(version, sha256, directory):
    clone = directory / "tap"
    run(["gh", "repo", "clone", TAP_REPOSITORY, clone, "--", "--depth", "1", "--quiet"],
        300)
    formula = clone / TAP_FORMULA
    current = formula.read_text()
    installed = formula_version(current)
    if version_key(installed) > version_key(version):
        raise ReleaseError(f"{TAP_REPOSITORY} already installs v{installed}; "
                           f"refusing to downgrade it to v{version}")
    updated = rewrite_formula(current, archive_url(version), sha256)
    if updated == current:
        print(f"{TAP_REPOSITORY} already installs v{version}")
        return
    branch, subject = f"macarchy-v{version}", f"chore(macarchy): update to v{version}"
    previous = remote_tap_attempt(clone, branch, subject)
    git("switch", "--quiet", "-c", branch, cwd=clone)
    formula.write_text(updated)
    check_tap_diff(git(*TAP_DIFF, cwd=clone))
    git("commit", "--quiet", "--all", "-m", subject, cwd=clone)
    git("push", "--quiet", f"--force-with-lease=refs/heads/{branch}:{previous}",
        "origin", f"HEAD:refs/heads/{branch}", cwd=clone, timeout=120)
    existing = gh_json("pr", "list", "--repo", TAP_REPOSITORY, "--head", branch,
                       "--state", "open", "--json", "url")
    url = existing[0]["url"] if existing else run(
        ["gh", "pr", "create", "--repo", TAP_REPOSITORY, "--base", "main", "--head",
         branch, "--title", subject, "--body",
         f"Install Macarchy v{version}: changes only the formula url and sha256."],
        120).stdout.strip()
    run(["gh", "pr", "merge", url, "--repo", TAP_REPOSITORY, "--rebase",
         "--delete-branch"], 120)
    print(f"Merged {url}")


def finish(version):
    tag = f"v{version}"
    if not published(tag):
        runs = release_runs(tag)
        if not runs:
            raise ReleaseError(f"no release.yml run for {tag}; run publish {version}")
        if runs[0]["status"] != "completed":
            print(f"Waiting for {runs[0]['url']} (approve stable-release if pending)")
            wait_for_run(runs[0]["databaseId"], 7200)
        if not published(tag):
            raise ReleaseError(f"{tag} was not published: {runs[0]['url']}")
    with tempfile.TemporaryDirectory(prefix="macarchy-release-") as temporary:
        downloads = Path(temporary) / "download"
        downloads.mkdir()
        sha256 = verify_archive(version, downloads)
        update_tap(version, sha256, Path(temporary))
    print(f"Done. On each machine run: Scripts/release.py upgrade --expect {version}")


def upgrade(expect):
    environment = os.environ | HOMEBREW_ENVIRONMENT
    stream([BREW, "update"], 900, env=environment)
    stream([BREW, "upgrade", "--formula", "--no-ask", FORMULA], 1800,
           env=environment | {"HOMEBREW_NO_AUTO_UPDATE": "1"})
    installed = run([MACARCHY, "--version"], 60).stdout.strip()
    if expect and installed != expect:
        raise ReleaseError(f"installed macarchy is {installed}, expected {expect}")
    print(f"macarchy {installed}")
    plan = run([MACARCHY, "setup", "plan", "--json"], 600, check=False)
    try:
        step, reasons = plan_step(json.loads(plan.stdout))
    except ValueError:
        step, reasons = "stop", ["setup plan output is not JSON"]
    if plan.returncode:
        step, reasons = "stop", [f"setup plan exited {plan.returncode}", *reasons]
    if step == "stop":
        raise ReleaseError("setup plan needs a person (" + "; ".join(reasons)
                           + "):\n" + plan.stdout + plan.stderr)
    if step == "apply":
        stream([MACARCHY, "setup", "apply"], 1800)
    else:
        print("Setup plan: no change")
    stream([MACARCHY, "doctor"], 600)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("version", type=parse_version)
    prepare_parser.add_argument("--pr", type=changelog.pr_argument, action="append",
                                default=[])
    for name in ("publish", "finish"):
        commands.add_parser(name).add_argument("version", type=parse_version)
    upgrade_parser = commands.add_parser("upgrade")
    upgrade_parser.add_argument("--expect", type=parse_version)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            prepare(args.version, dict(args.pr))
        elif args.command == "publish":
            publish(args.version)
        elif args.command == "finish":
            finish(args.version)
        else:
            upgrade(args.expect)
    except (ReleaseError, OSError) as error:
        sys.exit(f"release: {error}")


if __name__ == "__main__":
    main()
