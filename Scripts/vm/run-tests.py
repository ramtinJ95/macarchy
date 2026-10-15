#!/usr/bin/env python3
"""Snapshot current sources into an owned disposable guest and run tests there.

Does not boot a VM, mount host directories, install software, or execute tests on
the host. Use lab.py clone --baseline test and the existing native Tart launch
procedure first. Results/source snapshot remain in the private run directory.
"""
import argparse
import hashlib
import json
import shlex
import stat
import subprocess
import tarfile
import tempfile
import uuid

import guest
import lab

SOURCE_ROOTS = ("Package.swift", "Package.resolved", "VERSION.txt", "LICENSE",
                "README.md", "AGENTS.md", "CHANGELOG.md", ".github", "Documentation",
                "Sources", "Tests", "Scripts", "Keybindings", "Desktop",
                "Themes", "Environment")


def snapshot(root, destination):
    listing = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
         "--", *SOURCE_ROOTS], cwd=root, check=True, capture_output=True).stdout
    paths = sorted(set(listing.decode().split("\0")) - {""})
    with tarfile.open(destination, "w:gz") as archive:
        for name in paths:
            path = root / name
            if not path.exists() and not path.is_symlink():
                continue  # An intentionally deleted tracked source stays deleted.
            if not stat.S_ISREG(path.lstat().st_mode) or not path.resolve().is_relative_to(root):
                raise lab.LabError(f"Snapshot refuses nonregular or external source: {name}")
            archive.add(path, arcname=name, recursive=False)
    return hashlib.sha256(destination.read_bytes()).hexdigest()


def test_command(remote, pattern=None, portability=False):
    arguments = ["/bin/zsh", remote + "/Scripts/vm/test-guest.sh"]
    if pattern is not None:
        arguments.extend(["--filter", pattern])
    if portability:
        arguments.append("--portability")
    return shlex.join(arguments)


def run_tests(client, archive, evidence, pattern=None, portability=False):
    # Even a misaddressed SSH connection cannot cause tests to run on this host.
    client.command('test "$(/usr/sbin/sysctl -n kern.hv_vmm_present)" = 1')
    remote = "/Users/omarchy/macarchy-tests-" + uuid.uuid4().hex
    client.command("umask 077; /bin/mkdir " + shlex.quote(remote))
    guest.upload_archive(client, archive, remote, timeout=120)
    result = client.command(test_command(remote, pattern, portability),
                            check=False, timeout=1800)
    (evidence / "tests.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise lab.LabError("Guest tests failed; inspect tests.log (no host fallback).")
    return {"guest_source": remote, "filter": pattern, "portability": portability,
            "exit_code": result.returncode, "log": "tests.log"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True)
    parser.add_argument("--filter")
    parser.add_argument("--portability", action="store_true")
    args = parser.parse_args()
    inputs = lab.initialize()
    lab.check_version(inputs)
    directory = guest.run_directory(args.run)
    evidence = directory / ("tests-" + uuid.uuid4().hex[:12])
    evidence.mkdir(mode=0o700)
    report = {"run": args.run, "status": "in_progress"}
    lab.write_json(evidence / "report.json", report)
    try:
        archive = evidence / "source.tar.gz"
        report["source_sha256"] = snapshot(lab.ROOT, archive)
        with tempfile.TemporaryDirectory(prefix="ssh-tests-", dir=lab.STATE) as temporary:
            client = guest.Guest(inputs, args.run, guest.write_askpass(temporary))
            report["evidence"] = run_tests(
                client, archive, evidence, args.filter, args.portability)
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "blocked"
        report["reason"] = lab.describe(error)
        raise
    finally:
        lab.write_json(evidence / "report.json", report)
        print(json.dumps({"report": str(evidence / "report.json"), **report}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (lab.LabError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f"VM tests blocked: {error}") from None
