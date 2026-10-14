"""Pure verify.py checks: no SSH, VM, build, Macarchy execution or special files."""
import io
import json
from pathlib import Path
import shlex
import signal
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

import guest
import lab
import verify

SESSION = "verify-0123456789ab"
RUN = "setup-0123456789ab"
REMOTE = "/Users/omarchy/macarchy-" + SESSION
VERSION = {"schema_version": 1, "version": "0.12.3-dev", "revision": "unknown",
           "platform": "macos-arm64", "installation": "development"}
RECORD = {"tool": "verify.py", "session": SESSION, "run": RUN,
          "status": "ready", "host_source": {"snapshot_sha256": "b" * 64},
          "guest": {"source": REMOTE, "binary": REMOTE + "/.build/debug/macarchy",
                    "binary_sha256": "a" * 64, "version": VERSION}}
INPUTS = {"macos": {"build": "25A354"}}
INACTIVE = json.dumps({"active": False, "operation": "theme_status", "outcome": "inactive",
                       "schema_version": 1}, indent=2, sort_keys=True)
SNAPSHOT = "/bin/bash -euo pipefail"
WATCHED = ("Directory\t40700\t96\t11\t1760000000\t1760000000\t.config\n"
           "Regular File\t100644\t20\t12\t1760000000\t1760000000\t.zshrc\n")


def result(stdout="", returncode=0, stderr=""):
    return Mock(stdout=stdout, stderr=stderr, returncode=returncode)


class FakeGuest:
    """Answers guest commands by first matching substring; a list answers in order."""

    def __init__(self, answers):
        self.answers = [(needle, list(answer) if isinstance(answer, list) else answer)
                        for needle, answer in answers]
        self.commands = []

    def command(self, command, check=True, data=None, timeout=30):
        self.commands.append(command)
        for needle, answer in self.answers:
            if needle in command:
                if isinstance(answer, list):
                    answer = answer.pop(0)
                if isinstance(answer, BaseException):
                    raise answer
                if check and answer.returncode:
                    raise lab.LabError("Guest SSH command failed.")
                return answer
        raise AssertionError("unexpected guest command: " + command)


def theme_toml(theme, name, appearance, backgrounds=()):
    lines = [f"id = {json.dumps(theme)}", f"display_name = {json.dumps(name)}",
             f"appearance = {json.dumps(appearance)}"]
    for identifier, path in backgrounds:
        lines += ["[[backgrounds]]", f"id = {json.dumps(identifier)}", f"path = {json.dumps(path)}"]
    return "\n".join(lines) + "\n"


def write_snapshot(directory):
    themes = {"alpha": theme_toml("alpha", "Alpha", "dark", [("default", "wallpapers/a.webp"),
                                                             ("two", "wallpapers/b.jpg")]),
              "beta": theme_toml("beta", "Beta Light", "light")}
    with tarfile.open(directory / "source.tar.gz", "w:gz") as bundle:
        for theme, text in themes.items():
            data = text.encode()
            member = tarfile.TarInfo(f"Themes/{theme}/theme.toml")
            member.size = len(data)
            bundle.addfile(member, io.BytesIO(data))


def fresh_guest(**overrides):
    answers = {
        ".verify-owner": result(SESSION + "\n"),
        "shasum -a 256": result("a" * 64 + "  binary\n"),
        "/bin/test -e /Users/omarchy/.config/macarchy": result(returncode=1),
        SNAPSHOT: [result(WATCHED), result(WATCHED)],
        " version --json": result(json.dumps(VERSION)),
        " theme list": result("alpha\tdark\tAlpha\nbeta\tlight\tBeta Light\n"),
        "background list alpha": result("two\tjpg\twallpapers/b.jpg\ndefault\twebp\twallpapers/a.webp\n"),
        "background list beta": result(""),
        "theme status --json": result(INACTIVE + "\n", 1),
    }
    answers.update(overrides)
    return FakeGuest(answers.items())


def drive_theme(client):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_snapshot(root)
        evidence = root / "drive-theme-01"
        evidence.mkdir()
        report = {"steps": []}
        with patch.object(verify.time, "sleep"):
            status = verify.run_journey(client, RECORD, "theme", root, evidence, report)
        return status, report, {path.name: path.read_text() for path in evidence.iterdir()}


def product_commands(client):
    return [command for command in client.commands if "/usr/bin/env -i" in command]


class JourneyTests(unittest.TestCase):
    def test_theme_journey_passes_on_grounded_fresh_guest_outputs(self):
        client = fresh_guest()
        status, report, files = drive_theme(client)
        self.assertEqual(status, "passed", report.get("failures"))
        self.assertEqual([step["step"] for step in report["steps"]], [
            "version", "theme-list", "backgrounds-alpha", "backgrounds-beta", "theme-status"])
        effects = report["side_effects"]
        self.assertEqual((effects["created"], effects["deleted"], effects["modified"]), ([], [], []))
        self.assertEqual(effects["entries_before"], 2)
        self.assertEqual(files["watched-before.tsv"], WATCHED)
        self.assertIn("watched-after.stderr", files)
        self.assertIn("05-theme-status.stderr", files)
        self.assertEqual(len(product_commands(client)), 5)
        for command in product_commands(client):  # Clean environment, from the guest home.
            self.assertTrue(command.startswith("cd /Users/omarchy && /usr/bin/env -i "), command)
            self.assertIn("MACARCHY_DISABLE_UPDATE_CHECKS=1", command)
        self.assertFalse(any("--dry-run" in command for command in client.commands))

    def test_created_deleted_or_changed_watched_paths_fail(self):
        after = ("Directory\t40700\t128\t11\t1760000002\t1760000002\t.config\n"
                 "Directory\t40700\t64\t13\t1760000002\t1760000002\t.config/macarchy\n")
        status, report, files = drive_theme(fresh_guest(**{
            SNAPSHOT: [result(WATCHED), result(after)]}))
        self.assertEqual(status, "failed")
        effects = report["side_effects"]
        self.assertEqual(effects["created"], [".config/macarchy"])
        self.assertEqual(effects["deleted"], [".zshrc"])  # Deletion, not just newer nodes.
        self.assertEqual(effects["modified"], [".config"])
        self.assertTrue(effects["state_root_created"])
        self.assertEqual(files["watched-after.tsv"], after)
        self.assertEqual(report["failures"], [
            "Read-only journey created, deleted or changed watched guest paths; see side_effects."])

    def test_removed_watched_root_is_a_deletion(self):
        status, report, _ = drive_theme(fresh_guest(**{SNAPSHOT: [result(WATCHED), result("")]}))
        self.assertEqual(status, "failed")
        self.assertEqual(report["side_effects"]["deleted"], [".config", ".zshrc"])

    def test_failed_bounded_or_unparseable_snapshots_block_without_a_verdict(self):
        cases = [([result(stderr="find: .cache: Permission denied", returncode=4)], "exit 4"),
                 ([result(WATCHED), result(returncode=255)], "exit 255"),
                 ([result(returncode=3)], "exceed 50000"),
                 ([result("no tabs here\n")], "Unparseable"),
                 ([result(WATCHED + WATCHED)], "Unparseable"),
                 ([result(WATCHED), subprocess.TimeoutExpired("ssh", 120)], "exceeded 120s")]
        for answers, message in cases:
            with self.subTest(message=message):
                client = fresh_guest(**{SNAPSHOT: answers})
                with self.assertRaisesRegex(verify.Blocked, message):
                    drive_theme(client)
                if len(answers) == 1:  # A failed baseline snapshot runs no product command.
                    self.assertEqual(product_commands(client), [])

    def test_snapshot_command_is_strict_bounded_native_bash(self):
        argv = shlex.split(verify.snapshot_command())
        self.assertEqual(argv[:4], ["/bin/bash", "-euo", "pipefail", "-c"])
        script = argv[4]
        for fragment in ("/usr/bin/find", "-exec /usr/bin/stat -f", "|| exit 4", "-v limit=50000",
                         "NR > limit { exit 3 }", "Library/Application Support/Macarchy"):
            self.assertIn(fragment, script)
        self.assertNotIn("head", script)
        self.assertNotIn("-newer", script)
        syntax = subprocess.run(["/bin/bash", "-n", "-c", script], capture_output=True, text=True)
        self.assertEqual((syntax.returncode, syntax.stderr), (0, ""))

    def test_theme_list_background_or_status_mismatch_fails(self):
        status, report, _ = drive_theme(fresh_guest(**{
            " theme list": result("alpha\tdark\tAlpha\n"),
            "background list beta": result("extra\twebp\twallpapers/x.webp\n")}))
        self.assertEqual(status, "failed")
        self.assertEqual(len(report["failures"]), 2)
        listed_twice = "alpha\tdark\tAlpha\nalpha\tdark\tAlpha\nbeta\tlight\tBeta Light\n"
        self.assertEqual(drive_theme(fresh_guest(**{" theme list": result(listed_twice)}))[0],
                         "failed")

    def test_status_must_be_the_exact_inactive_report_with_exit_one(self):
        extra = json.dumps({**json.loads(INACTIVE), "error": "unreadable"})
        for answer in (result("garbage", 1), result("", 1), result(INACTIVE, 0),
                       result(INACTIVE, -9), result(INACTIVE, 134), result(extra, 1)):
            with self.subTest(code=answer.returncode, stdout=answer.stdout[:20]):
                status, report, _ = drive_theme(fresh_guest(**{"theme status --json": answer}))
                self.assertEqual(status, "failed")
                self.assertEqual(report["failures"], [
                    "theme status did not exit 1 with exactly the inactive report"])

    def test_only_grounded_journeys_are_exposed(self):
        self.assertEqual(set(verify.JOURNEYS), {"theme", "borders"})
        self.assertFalse(hasattr(verify, "assess_inspection"))
        steps = [arguments for _, arguments, _ in verify.theme_steps({"alpha": {}})]
        self.assertFalse(any("set" in arguments for arguments in steps))
        for name in ("keybindings", "setup"):
            with self.subTest(name=name), patch("sys.stderr", io.StringIO()), \
                    self.assertRaises(SystemExit):
                verify.build_parser().parse_args(["drive", "--run", RUN, "--session", SESSION,
                                                  "--journey", name])

    def test_foreign_session_changed_binary_or_existing_state_block_before_driving(self):
        for override in ({".verify-owner": result("verify-ffffffffffff\n")},
                         {"shasum -a 256": result("c" * 64 + "  binary\n")},
                         {"/bin/test -e /Users/omarchy/.config/macarchy": result()},
                         {"/bin/test -e /Users/omarchy/.config/macarchy": result(returncode=255)}):
            with self.subTest(override=override):
                client = fresh_guest(**override)
                with self.assertRaises(verify.Blocked):
                    drive_theme(client)
                self.assertEqual(product_commands(client), [])
                self.assertFalse(any(SNAPSHOT in command for command in client.commands))

    def test_timeout_is_blocked_and_stops_the_journey(self):
        client = fresh_guest(**{" theme list": subprocess.TimeoutExpired("ssh", 60)})
        with self.assertRaisesRegex(verify.Blocked, "may still run"):
            drive_theme(client)
        self.assertFalse(any("theme status" in command for command in client.commands))


def baseline_guest(user="omarchy", build="25A354"):
    return FakeGuest([("/usr/bin/id -un", result(user + "\n")),
                      ("sw_vers -buildVersion", result(build + "\n"))])


class BaselineTests(unittest.TestCase):
    def test_drive_refuses_a_wrong_account_or_os_before_any_guest_step(self):
        for client in (baseline_guest(user="admin"), baseline_guest(build="24G90")):
            with self.subTest(client=client), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary) / RUN
                (directory / SESSION).mkdir(parents=True)
                with patch.object(verify, "test_clone", return_value=directory), \
                        patch.object(verify, "session_ready", return_value=RECORD), \
                        patch.object(verify, "connect", return_value=client), \
                        patch.object(verify.lab, "STATE", Path(temporary)), \
                        patch.object(verify, "run_journey") as journey, \
                        patch("sys.stdout", io.StringIO()):
                    report = verify.drive(INPUTS, RUN, SESSION, "theme")
                journey.assert_not_called()
                self.assertEqual(report["status"], "blocked")
                self.assertIn("prepared baseline", report["reason"])

    def test_launch_refuses_a_wrong_account_or_os_before_upload_or_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / RUN
            directory.mkdir()
            client = baseline_guest(user="admin")
            with patch.object(verify, "test_clone", return_value=directory), \
                    patch.object(verify, "wait_for_guest", return_value=client), \
                    patch.object(verify, "host_source") as source, \
                    patch.object(verify.lab, "STATE", Path(temporary)), \
                    patch("sys.stdout", io.StringIO()), \
                    self.assertRaisesRegex(verify.Blocked, "prepared baseline"):
                verify.launch(INPUTS, RUN, 30)
            source.assert_not_called()
            self.assertEqual(len(client.commands), 2)  # Only the account and build reads.
            session = next(directory.glob("verify-*"))
            self.assertEqual(json.loads((session / "session.json").read_text())["status"], "blocked")


class DoctorTests(unittest.TestCase):
    def doctor(self, state_probe, session=SESSION):
        client = FakeGuest([("/bin/test -e /Users/omarchy/.config/macarchy", state_probe)])
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "known_hosts").write_text("")
            with patch.object(verify, "read_pins", return_value=INPUTS), \
                    patch.object(verify, "test_clone", return_value=directory), \
                    patch.object(verify, "verify_tart", return_value="2.0"), \
                    patch.object(verify, "require_running", return_value="running"), \
                    patch.object(verify, "tart_ownership", return_value="owned"), \
                    patch.object(verify, "require_idle", return_value="idle"), \
                    patch.object(verify, "session_ready", return_value=RECORD), \
                    patch.object(verify, "connect", return_value=client), \
                    patch.object(verify, "guest_baseline", return_value="omarchy"), \
                    patch.object(verify, "guest_identity", return_value={}), \
                    patch("sys.stdout", io.StringIO()):
                return verify.doctor(RUN, session)

    def test_existing_or_unreadable_state_root_blocks_readiness(self):
        self.assertEqual(self.doctor(result(returncode=1))["status"], "ready")
        for probe in (result(), result(returncode=255)):
            for session in (SESSION, None):
                with self.subTest(code=probe.returncode, session=session):
                    report = self.doctor(probe, session)
                    self.assertEqual(report["status"], "blocked")
                    check = report["checks"][-1]
                    self.assertEqual((check["check"], check["status"]),
                                     ("fresh-state precondition", "fail"))

    def test_vm_only_doctor_says_it_did_not_check_session_readiness(self):
        self.assertTrue(self.doctor(result(returncode=1), None)["scope"].startswith("vm only"))


class LifecycleTests(unittest.TestCase):
    def start(self, directory, **failures):
        process = Mock(pid=4242)
        process.poll.return_value = None
        identity = f"Tue Oct 13 10:00:00 2026 tart run {RUN} --no-clipboard --no-audio"
        mocks = {"vm_state": Mock(return_value="running"),
                 "process_identity": Mock(return_value=identity), "audit": Mock()}
        mocks.update(failures)
        with patch.object(verify, "test_clone", return_value=directory), \
                patch.object(verify.lab, "require_stopped"), \
                patch.object(verify.lab, "binary", return_value=Path("tart")), \
                patch.object(verify.subprocess, "Popen", return_value=process), \
                patch.object(verify.lab, "stop_owned_process", return_value="stopped") as stop, \
                patch.object(verify, "vm_state", mocks["vm_state"]), \
                patch.object(verify, "process_identity", mocks["process_identity"]), \
                patch.object(verify.lab, "audit_no_listener", mocks["audit"]), \
                patch.object(verify.time, "sleep"):
            try:
                return verify.start({}, RUN), stop, mocks["audit"], None
            except BaseException as error:
                return None, stop, mocks["audit"], error

    def test_start_audits_listeners_and_records_a_running_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            record, stop, audit, error = self.start(Path(temporary))
            self.assertIsNone(error)
            audit.assert_called_once_with(4242)
            stop.assert_not_called()
            saved = json.loads((Path(temporary) / "verify-tart.json").read_text())
            self.assertEqual((saved["status"], saved["tcp_listeners"]), ("running", "none"))

    def test_start_stops_the_exact_child_on_any_startup_failure(self):
        failures = {"audit": Mock(side_effect=lab.LabError("Unexpected TCP listener")),
                    "vm_state": Mock(side_effect=subprocess.CalledProcessError(1, "tart")),
                    "process_identity": Mock(return_value="unrelated process")}
        expected = {"audit": "Unexpected TCP listener", "vm_state": "CalledProcessError",
                    "process_identity": "Could not record"}
        for name, failure in failures.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                record, stop, _, error = self.start(Path(temporary), **{name: failure})
                self.assertIsNone(record)
                self.assertIn(expected[name], verify.describe(error))  # Original reason kept.
                stop.assert_called_once()
                saved = json.loads((Path(temporary) / "verify-tart.json").read_text())
                self.assertEqual(saved["status"], "stopped_after_failure: stopped")
                self.assertIn(expected[name], saved["reason"])

    def test_start_never_adopts_a_running_vm(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(verify, "test_clone", return_value=directory), \
                    patch.object(verify.lab, "require_stopped", side_effect=lab.LabError("live")), \
                    patch.object(verify.subprocess, "Popen") as popen, \
                    self.assertRaisesRegex(lab.LabError, "live"):
                verify.start({}, RUN)
            popen.assert_not_called()
            self.assertFalse((directory / "verify-tart.json").exists())

    def test_hung_guest_shutdown_still_stops_the_owned_tart_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            owned = {"pid": 4242, "identity": "Tue Oct 13 10:00:00 2026 tart run " + RUN}
            lab.write_json(directory / "verify-tart.json", owned)
            with patch.object(verify, "vm_state", side_effect=["running", "running", "stopped"]), \
                    patch.object(verify.subprocess, "run",
                                 side_effect=subprocess.TimeoutExpired("guest.py", 180)), \
                    patch.object(verify, "stop_owned", return_value="stopped_owned_process") as stop, \
                    patch.object(verify, "owned_tart", return_value=False):
                outcome = verify.shutdown_vm({}, RUN, directory)
            stop.assert_called_once()
            self.assertEqual(outcome["guest_shutdown"]["error"], "TimeoutExpired")
            self.assertEqual((outcome["owned_process"], outcome["result"]),
                             ("stopped_owned_process", "stopped"))

    def test_unknown_vm_state_attempts_no_stop_without_recorded_ownership(self):
        failure = subprocess.CalledProcessError(1, "tart")
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(verify, "vm_state", side_effect=[failure, failure]), \
                patch.object(verify.subprocess, "run") as run, \
                patch.object(verify, "stop_owned") as stop, \
                self.assertRaisesRegex(verify.Blocked, "not started by verify.py"):
            verify.shutdown_vm({}, RUN, Path(temporary))
        run.assert_not_called()
        stop.assert_not_called()


class BoundaryTests(unittest.TestCase):
    def test_session_names_and_guest_paths_are_strict(self):
        self.assertEqual(verify.guest_directory(SESSION), REMOTE)
        for name in ("verify-0123", "setup-0123456789ab", "verify-0123456789ab/..", None,
                     "../verify-0123456789ab"):
            with self.subTest(name=name), self.assertRaises(verify.Blocked):
                verify.guest_directory(name)

    def test_cli_exposes_only_closed_journeys_and_no_command_passthrough(self):
        parser = verify.build_parser()
        drive = parser._subparsers._group_actions[0].choices["drive"]
        self.assertEqual({action.dest for action in drive._actions},
                         {"help", "run", "session", "journey", "border_count",
                          "candidate_session", "border_motion"})
        with patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(["drive", "--run", "setup-0123456789ab", "--session", SESSION,
                               "--journey", "/bin/sh"])

    def test_non_vm_target_is_refused_before_any_other_command(self):
        client = FakeGuest([("kern.hv_vmm_present", result("0\n"))])
        with patch.object(verify.guest, "Guest", return_value=client), \
                self.assertRaisesRegex(verify.Blocked, "not a virtual machine"):
            verify.connect({}, "setup-0123456789ab", Path("/absent"))
        self.assertEqual(len(client.commands), 1)

    def test_read_only_connections_never_trust_new_host_keys(self):
        client = FakeGuest([("kern.hv_vmm_present", result("1\n"))])
        client.argv = guest.ssh_arguments("192.168.64.9", "setup-0123456789ab", Path("/run"))
        with patch.object(verify.guest, "Guest", return_value=client):
            verify.connect({}, "setup-0123456789ab", Path("/absent"), strict=True)
        self.assertIn("StrictHostKeyChecking=yes", client.argv)
        self.assertNotIn("StrictHostKeyChecking=accept-new", client.argv)

    def test_run_lock_refuses_double_driving_and_busy_check_creates_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.assertFalse(verify.lock_busy(directory))
            self.assertFalse((directory / "verify.lock").exists())
            with verify.RunLock(directory):
                self.assertTrue(verify.lock_busy(directory))
                with self.assertRaisesRegex(verify.Blocked, "Another"):
                    verify.RunLock(directory).__enter__()
            self.assertFalse(verify.lock_busy(directory))

    def test_cleanup_removes_only_the_marked_session_directory(self):
        foreign = FakeGuest([(".verify-owner", result("verify-ffffffffffff\n"))])
        with self.assertRaises(verify.Blocked):
            verify.remove_guest_directory(foreign, SESSION)
        self.assertFalse(any("/bin/rm" in command for command in foreign.commands))
        owned = FakeGuest([(".verify-owner", result(SESSION + "\n")), ("/bin/rm", result())])
        self.assertEqual(verify.remove_guest_directory(owned, SESSION), "removed")
        self.assertEqual(owned.commands[-1], f"/bin/test -d {REMOTE} -a ! -L {REMOTE} && "
                                             f"/bin/rm -rf -- {REMOTE}")
        absent = FakeGuest([(".verify-owner", result(returncode=1)), ("/bin/test", result())])
        self.assertEqual(verify.remove_guest_directory(absent, SESSION), "already_absent")
        source = Path(verify.__file__).read_text()
        for forbidden in ("pkill", "killall", "pgrep"):
            self.assertNotIn(forbidden, source)

    def test_owned_stop_requires_the_exact_recorded_process_identity(self):
        record = {"pid": 4242, "identity": "Tue Oct 13 10:00:00 2026 tart run setup-0123456789ab"}
        with patch.object(verify, "process_identity", return_value="other process"), \
                patch.object(verify.os, "kill") as kill:
            self.assertEqual(verify.stop_owned(record), "owned_process_not_running")
        kill.assert_not_called()
        identities = [record["identity"], record["identity"], None, None]
        with patch.object(verify, "process_identity", side_effect=identities), \
                patch.object(verify.os, "kill") as kill, patch.object(verify.time, "sleep"):
            self.assertEqual(verify.stop_owned(record), "stopped_owned_process")
        kill.assert_called_once_with(4242, signal.SIGINT)

    def test_launch_requires_a_guest_built_development_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            archive = evidence / "source.tar.gz"
            archive.write_bytes(b"archive")
            homebrew = dict(VERSION, installation="homebrew", version="0.12.3")
            client = FakeGuest([
                ("/bin/mkdir", result()), ("/usr/bin/base64", result()),
                ("--show-bin-path", result(REMOTE + "/.build/arm64-apple-macosx/debug\n")),
                ("swift build --product macarchy", result("Build complete!")),
                ("shasum -a 256", result("d" * 64 + "  binary\n")),
                ("version --json", result(json.dumps(homebrew)))])
            with self.assertRaisesRegex(verify.Failed, "development source build"):
                verify.build_in_guest(client, SESSION, archive, evidence)
            self.assertEqual((evidence / "build.log").read_text(), "Build complete!")

    def test_cleanup_still_shuts_down_after_a_failed_step_and_keeps_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "setup-0123456789ab"
            session = directory / SESSION
            session.mkdir(parents=True)
            lab.write_json(session / "session.json", RECORD)
            (session / "source.tar.gz").write_bytes(b"proof")
            with patch.object(verify, "test_clone", return_value=directory), \
                    patch.object(verify, "vm_state", return_value="running"), \
                    patch.object(verify, "connect", side_effect=lab.LabError("ssh down")), \
                    patch.object(verify, "shutdown_vm", return_value={"result": "stopped"}) as stop, \
                    patch.object(verify.lab, "STATE", Path(temporary)), \
                    patch("sys.stdout", io.StringIO()):
                report = verify.cleanup({}, "setup-0123456789ab", SESSION, True)
            stop.assert_called_once()
            self.assertEqual(report["status"], "blocked")
            self.assertIn("guest directory: ssh down", report["reason"])
            self.assertEqual(report["actions"]["shutdown"], {"result": "stopped"})
            self.assertEqual(json.loads((session / "session.json").read_text())["status"], "ready")
            self.assertEqual((session / "source.tar.gz").read_bytes(), b"proof")
            self.assertEqual(json.loads((session / "cleanup.json").read_text())["status"], "blocked")


if __name__ == "__main__":
    unittest.main()
