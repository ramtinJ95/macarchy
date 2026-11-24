#!/usr/bin/env python3
"""Bootstrap contract tests: inert executable fixtures, no Homebrew/network/Swift.

Each case owns its files and PTY; no process-wide activation state or mutex.
"""
import errno
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
FORMULA = "ramtinj95/tap/macarchy"
CONTROLS = ("HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_AUTOREMOVE",
            "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_INSTALL_UPGRADE",
            "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK", "HOMEBREW_NO_ANALYTICS")
STUB = '''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get("CASE", "fresh")
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps([name, args, {k:v for k,v in os.environ.items()
                                    if k.startswith("HOMEBREW_")}]) + "\\n")
if name == "uname":
    print("Linux" if mode == "linux" else
          ("Darwin" if args == ["-s"] else ("x86_64" if mode == "intel" else "arm64")))
elif name == "sw_vers": print("27.0" if mode == "old-os" else "26.6.2")
elif name in ("xcode-select", "xcrun"):
    sys.exit(1 if mode == "no-clt" else 0)
elif name == "brew":
    stage = args[0]
    if mode == "fail-" + stage: sys.exit(42)
    if stage == "list":
        if mode in ("existing", "broken-existing"): print("ramtinj95/tap/macarchy")
        elif mode == "foreign": print("other/tap/macarchy")
    elif stage in ("--prefix", "--repository"): print(os.environ["PREFIX"])
    elif stage == "test" and mode == "broken-existing": sys.exit(42)
elif name == "macarchy":
    if args == ["version", "--json"]:
        if mode == "bad-version": sys.exit(42)
        print('{"version":"0.17.0","installation":"homebrew"}')
    else:
        print("REAL GUIDED HANDOFF FIXTURE")
        if mode == "guided-failure": sys.exit(7)
elif name == "mktemp":
    path = pathlib.Path(os.environ["PREFIX"]) / "download"
    path.write_text("")
    print(path)
elif name == "curl":
    path = pathlib.Path(args[args.index("-o") + 1])
    path.write_text("echo BOOTSTRAP_EXECUTED\\n")
    if mode == "download-failure": sys.exit(22)
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="macarchy-installer-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.prefix = self.root / "prefix with spaces"
        (self.prefix / "bin").mkdir(parents=True)
        (self.prefix / "Formula").mkdir()
        (self.prefix / "Formula/macarchy.rb").write_text("FORMULA REVIEW: release URL + sha256 + install + tests\n")
        for name in ("uname", "sw_vers", "brew", "xcode-select", "xcrun", "curl", "mktemp"):
            self.fixture(self.bin / name)
        self.fixture(self.prefix / "bin/macarchy")
        self.calls = self.root / "calls.jsonl"

    def fixture(self, path):
        path.write_text(f"#!{sys.executable}\n" + STUB)
        path.chmod(0o755)

    def run_case(self, mode="fresh", answers=b"y\ny\n", terminal=True, command=None):
        env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", CASE=mode,
                   PREFIX=str(self.prefix), CALLS=str(self.calls))
        command = command or ["/bin/bash", str(ROOT / "Scripts/install.sh")]
        if terminal:
            pid, master = pty.fork()
            if pid == 0:
                os.execve(command[0], command, env)
            output = bytearray()
            deadline = time.monotonic() + 10
            try:
                os.write(master, answers)
                while time.monotonic() < deadline:
                    if not select.select([master], [], [], 0.1)[0]:
                        continue
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
                else:
                    os.killpg(pid, signal.SIGKILL)
                    self.fail("Installer fixture timed out")
            finally:
                os.close(master)
                _, status = os.waitpid(pid, 0)
            code = os.waitstatus_to_exitcode(status)
            output = output.decode()
        else:
            result = subprocess.run(command, env=env, input=answers, capture_output=True, timeout=10)
            code, output = result.returncode, (result.stdout + result.stderr).decode()
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return code, output, calls

    def test_fresh_path_orders_review_exact_consent_install_test_and_guided(self):
        code, output, calls = self.run_case()
        self.assertEqual(code, 0, output)
        commands = [args for name, args, _ in calls if name in ("brew", "macarchy")]
        self.assertEqual(commands, [["--version"], ["list", "--formula", "--full-name"],
            ["tap", "ramtinj95/tap"], ["--repository", "ramtinj95/tap"],
            ["trust", "--formula", FORMULA], ["install", "--formula", "--no-ask", FORMULA],
            ["--prefix", FORMULA], ["test", FORMULA], ["version", "--json"], ["setup", "guided"]])
        self.assertLess(output.index("FORMULA REVIEW"), output.index("Trust and install"))
        for name, args, environment in calls:
            if name == "brew" and args[0] != "--version":
                for key in CONTROLS:
                    self.assertEqual(environment.get(key), "1", (args, key))
                if args[0] == "test":
                    self.assertEqual(environment.get("HOMEBREW_DEVELOPER"), "1")

    def test_prerequisites_fail_before_mutation(self):
        for mode, message in (("linux", "Apple Silicon"), ("intel", "Rosetta"),
                              ("old-os", "macOS 26"), ("no-clt", "xcode-select --install"),
                              ("fail---version", "Homebrew cannot run")):
            with self.subTest(mode=mode):
                self.calls.unlink(missing_ok=True)
                code, output, calls = self.run_case(mode)
                self.assertNotEqual(code, 0, output)
                self.assertIn(message, output)
                self.assertFalse(any(n == "brew" and a[0] != "--version" for n, a, _ in calls))

    def test_missing_homebrew_is_actionable(self):
        (self.bin / "brew").unlink()
        code, output, _ = self.run_case()
        self.assertNotEqual(code, 0)
        self.assertIn("Homebrew is missing from PATH", output)
        self.assertIn("https://brew.sh/", output)
        self.assertIn("shellenv", output)

    def test_noninteractive_is_not_an_approval(self):
        code, output, calls = self.run_case(terminal=False)
        self.assertNotEqual(code, 0)
        self.assertIn("interactive terminal", output)
        self.assertFalse(any(n == "brew" and a[0] == "tap" for n, a, _ in calls))

    def test_default_no_before_tap_and_after_review(self):
        for answers, allowed in ((b"\n", ["--version", "list"]),
                                 (b"y\n\n", ["--version", "list", "tap", "--repository"])):
            with self.subTest(answers=answers):
                self.calls.unlink(missing_ok=True)
                code, output, calls = self.run_case(answers=answers)
                self.assertEqual(code, 0, output)
                self.assertIn("Cancelled", output)
                self.assertEqual([a[0] for n, a, _ in calls if n == "brew"], allowed)

    def test_failures_stop_without_fallback_or_setup(self):
        stages = ["list", "tap", "--repository", "trust", "install", "--prefix", "test"]
        for stage in stages:
            with self.subTest(stage=stage):
                self.calls.unlink(missing_ok=True)
                code, output, calls = self.run_case("fail-" + stage)
                self.assertNotEqual(code, 0, output)
                self.assertIn("Macarchy installer:", output)
                self.assertFalse(any(n == "macarchy" for n, _, _ in calls))
                self.assertEqual([a[0] for n, a, _ in calls if n == "brew"][-1], stage)
                if stage == "install":
                    self.assertIn("partial", output)
                    self.assertIn("No rollback", output)

    def test_missing_review_file_cannot_authorize_trust(self):
        (self.prefix / "Formula/macarchy.rb").unlink()
        code, output, calls = self.run_case()
        self.assertNotEqual(code, 0, output)
        self.assertIn("Formula review failed", output)
        self.assertFalse(any(n == "brew" and a[0] in ("trust", "install", "cat") for n, a, _ in calls))

    def test_existing_install_never_trusts_installs_upgrades_or_starts_setup(self):
        code, output, calls = self.run_case("existing")
        self.assertEqual(code, 0, output)
        self.assertIn("macarchy update", output)
        self.assertIn("macarchy setup guided --resume", output)
        self.assertEqual([a[0] for n, a, _ in calls if n == "brew"],
                         ["--version", "list", "--prefix", "test"])
        self.assertFalse(any(n == "macarchy" and a[0] == "setup" for n, a, _ in calls))

    def test_broken_existing_and_foreign_installs_are_not_repaired(self):
        for mode, message in (("broken-existing", "verification failed"),
                              ("foreign", "ownership"), ("bad-version", "version reporting failed")):
            with self.subTest(mode=mode):
                self.calls.unlink(missing_ok=True)
                code, output, calls = self.run_case(mode)
                self.assertNotEqual(code, 0, output)
                self.assertIn(message, output)
                self.assertFalse(any(n == "macarchy" and a[0] == "setup" for n, a, _ in calls))
                self.assertFalse(any(n == "brew" and a[0] in ("reinstall", "upgrade", "cleanup") for n, a, _ in calls))

    def test_unmanaged_path_is_not_overlaid(self):
        self.fixture(self.bin / "macarchy")
        code, output, calls = self.run_case()
        self.assertNotEqual(code, 0, output)
        self.assertIn("not owned", output)
        self.assertFalse(any(n == "brew" and a[0] == "tap" for n, a, _ in calls))

    def test_guided_failure_preserves_exit_and_recovery(self):
        code, output, _ = self.run_case("guided-failure")
        self.assertEqual(code, 7, output)
        self.assertIn("remains installed", output)
        self.assertIn("macarchy setup guided --resume", output)

    def test_documented_download_is_complete_before_execution_and_cleans_up(self):
        command = (ROOT / "Documentation/install.md").read_text().split("```sh\n", 1)[1].split("\n```", 1)[0]
        for mode, expected in (("fresh", 0), ("download-failure", 22)):
            with self.subTest(mode=mode):
                code, output, _ = self.run_case(mode, command=["/bin/bash", "-c", command])
                self.assertEqual(code, expected, output)
                self.assertEqual("BOOTSTRAP_EXECUTED" in output, expected == 0)
                self.assertFalse((self.prefix / "download").exists())


if __name__ == "__main__":
    unittest.main()
