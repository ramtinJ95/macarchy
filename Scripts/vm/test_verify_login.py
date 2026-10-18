"""Pure unit tests for verify.py login; no SSH, VM, window input or special files."""
import json
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

import lab
import verify
from test_verify import FakeGuest, RECORD, RUN, SESSION, result

WINDOW = {"bounds": [0, 0, 1440, 900], "window_id": 7, "pid": 42}
INPUTS = {"macos": {"build": "25A354"}}


class LoginTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.dir = root / RUN
        (self.dir / SESSION).mkdir(parents=True)
        (self.dir / SESSION / "session.json").write_text(json.dumps(RECORD))
        (self.dir / "verify-tart.json").write_text(json.dumps({"pid": 42, "identity": "tart"}))
        (root / "tools").mkdir()
        (root / "tools/window-control").write_text("")
        self.calls = []
        stack = ExitStack()
        self.addCleanup(stack.close)

        def patch(target, name, **kwargs):
            return stack.enter_context(mock.patch.object(target, name, **kwargs))

        def record(name, value=None):
            def call(*args, **kwargs):
                self.calls.append((name, args[-1] if args else None))
                return value
            return call

        patch(verify, "test_clone", return_value=self.dir)
        patch(verify, "owned_tart", return_value=True)
        patch(verify, "guest_baseline")
        patch(verify, "guest_identity")
        patch(verify, "LOGIN_WAIT", new=0)
        patch(verify.time, "sleep")
        patch(lab, "STATE", new=root)
        patch(lab, "guest_password")
        patch(lab, "audit_no_listener")
        patch(lab, "checked_capture", side_effect=record("capture", WINDOW))
        self.anchor = patch(lab, "text_anchor", return_value={"text": verify.LOGIN_PROMPT})
        self.window = patch(lab, "control", side_effect=self.control)
        self.typed = patch(lab, "type_guest_password", side_effect=record("type"))
        self.current = WINDOW
        self.key_error = None

    def control(self, helper, action, *args):
        self.calls.append((action, args[-1] if action == "key" else None))
        if action == "key" and self.key_error:
            raise self.key_error
        return self.current if action == "window" else None

    def run_login(self, *owners):
        answers = [owner if isinstance(owner, tuple) else (owner, 0) for owner in owners]
        client = FakeGuest([(verify.CONSOLE_OWNER,
                             [result(owner, returncode) for owner, returncode in answers])])
        with mock.patch.object(verify, "connect", return_value=client):
            report = verify.login(INPUTS, RUN, SESSION)
        saved = json.loads((self.dir / SESSION / "login-01/report.json").read_text())
        self.assertEqual(saved["status"], report["status"])
        return report

    def actions(self):
        return [name for name, _ in self.calls]

    def test_already_logged_in_sends_nothing(self):
        report = self.run_login("omarchy")
        self.assertEqual((report["status"], report["credential"]), ("ready", "not_sent"))
        self.assertEqual(self.calls, [])

    def test_one_submission_reaches_the_console(self):
        with mock.patch.object(verify, "LOGIN_WAIT", 5):
            report = self.run_login("root", "root", "omarchy")
        self.assertEqual((report["status"], report["credential"]), ("ready", "submitted"))
        self.assertEqual(report["console_after"], "omarchy")
        self.assertEqual(self.actions(), ["capture", "window", "type", "key", "capture"])
        self.assertIn(("key", {"key": "return"}), self.calls)
        self.assertEqual(self.typed.call_args.kwargs, {"create": False})

    def test_missing_prompt_sends_no_credential(self):
        self.anchor.return_value = None
        report = self.run_login("root")
        self.assertEqual((report["status"], report["credential"]), ("blocked", "not_sent"))
        self.assertNotIn("type", self.actions())

    def test_moved_window_sends_no_credential(self):
        self.current = dict(WINDOW, window_id=8)
        report = self.run_login("root")
        self.assertEqual((report["status"], report["credential"]), ("blocked", "not_sent"))
        self.assertNotIn("type", self.actions())

    def test_failed_login_is_not_retried(self):
        report = self.run_login("root", "root")
        self.assertEqual((report["status"], report["credential"]), ("blocked", "submitted"))
        self.assertEqual(self.actions().count("type"), 1)
        self.assertIn("not retrying", report["reason"])

    def test_input_failure_after_typing_is_uncertain(self):
        self.key_error = lab.LabError("Window control failed: foreground changed")
        report = self.run_login("root")
        self.assertEqual((report["status"], report["credential"]), ("blocked", "uncertain"))
        self.assertEqual(self.actions().count("type"), 1)

    def test_failed_console_observation_is_not_success(self):
        report = self.run_login("root", ("omarchy", 255))
        self.assertEqual(report["status"], "blocked")
        self.assertIsNone(report["console_after"])

    def test_requires_a_verify_owned_vm(self):
        (self.dir / "verify-tart.json").unlink()
        with self.assertRaisesRegex(verify.Blocked, "start or restart"):
            verify.login(INPUTS, RUN, SESSION)

    def test_parser_requires_a_session(self):
        args = verify.build_parser().parse_args(["login", "--run", RUN, "--session", SESSION])
        self.assertEqual((args.operation, args.run, args.session), ("login", RUN, SESSION))
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            verify.build_parser().parse_args(["login", "--run", RUN])


if __name__ == "__main__":
    unittest.main()
