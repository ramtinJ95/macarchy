"""No downloads, VMs, permission prompts, or host configuration changes."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import lab


class ListenerTests(unittest.TestCase):
    def test_no_tcp_listener(self):
        with patch.object(lab.subprocess, "run", return_value=Mock(returncode=1, stdout="", stderr="")):
            lab.audit_no_listener(123)

    def test_any_listener_or_inspection_error_blocks(self):
        for code, output, error in ((0, "n*:5950\n", ""), (0, "n127.0.0.1:5950\n", ""),
                                    (1, "", "permission denied"), (2, "", "")):
            with self.subTest(code=code, output=output, error=error), \
                    patch.object(lab.subprocess, "run", return_value=Mock(
                        returncode=code, stdout=output, stderr=error)), self.assertRaises(lab.LabError):
                lab.audit_no_listener(123)


class IsolationTests(unittest.TestCase):
    def test_environment_uses_only_lab_store_and_no_inherited_tracing_or_agent(self):
        source = {
            "PATH": "/usr/bin", "HOME": "/Users/test", "TART_HOME": "/personal",
            "TART_OTHER": "unexpected", "TRACEPARENT": "secret", "TRACESTATE": "secret",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://example.invalid", "SSH_AUTH_SOCK": "/agent",
        }
        result = lab.lab_environment(Path("/lab"), source)
        self.assertEqual(result, {
            "PATH": "/usr/bin", "HOME": "/Users/test", "TART_HOME": "/lab/tart",
            "TART_NO_AUTO_PRUNE": "1", "CI": "true",
        })
        self.assertEqual(source["TART_HOME"], "/personal")

    def test_inputs_have_pinned_digests_and_versions(self):
        inputs = json.loads((lab.HERE / "inputs.json").read_text())
        self.assertTrue(inputs["macos"]["version"].startswith("26."))
        for key in ("tart", "macos"):
            self.assertRegex(inputs[key]["sha256"], "^[a-f0-9]{64}$")
            self.assertNotIn("latest", inputs[key]["url"])
            self.assertTrue(inputs[key]["url"].startswith("https://"))

    def test_hash_mismatch_is_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "artifact"
            path.write_bytes(b"expected")
            lab.verify_hash(path, hashlib.sha256(b"expected").hexdigest())
            with self.assertRaises(lab.LabError):
                lab.verify_hash(path, "0" * 64)

    def test_prepare_required_before_any_create_or_clone(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(lab, "STATE", Path(temporary)), \
                patch.object(lab, "run_tart") as tart, self.assertRaises(lab.LabError):
            lab.ensure_base({}, io.StringIO())
        tart.assert_not_called()

    def test_unsafe_listener_stops_owned_guest_and_never_captures(self):
        process = Mock(pid=123)
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(lab, "STATE", Path(temporary)), \
                patch.object(lab, "build_controller", return_value=Path("/helper")), \
                patch.object(lab, "control", side_effect=[
                    {"accessibility": True, "screen_recording": True}, {"window_id": 123}]), \
                patch.object(lab, "ensure_base"), patch.object(lab, "run_tart"), \
                patch.object(lab.subprocess, "Popen", return_value=process) as spawn, \
                patch.object(lab, "audit_no_listener", side_effect=lab.LabError("Unexpected listener")), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            result = lab.probe({"tart": {"version": "test"}})
            report = json.loads(next(Path(temporary).glob("runs/*/report.json")).read_text())
            self.assertEqual(result, 1)
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["shutdown"], "stopped")
            self.assertEqual(list(Path(temporary).glob("runs/*/*.png")), [])
            command = spawn.call_args.args[0]
            self.assertNotIn("--vnc-experimental", command)
            self.assertNotIn("--vnc", command)
            self.assertIn("--no-clipboard", command)
            # This flag removes the emulated USB mouse; it is not host passthrough isolation.
            self.assertNotIn("--no-usb-accessories", command)
            self.assertNotIn("--dir", command)
            self.assertNotIn("--net-bridged", command)
        process.send_signal.assert_called_once_with(signal.SIGINT)

    def test_missing_host_permission_blocks_before_vm_startup(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(lab, "STATE", Path(temporary)), \
                patch.object(lab, "build_controller", return_value=Path("/helper")), \
                patch.object(lab, "control", return_value={"accessibility": False, "screen_recording": True}), \
                patch.object(lab.subprocess, "Popen") as spawn, \
                patch.object(lab, "ensure_base") as base, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lab.probe({"tart": {"version": "2.39.0"}}), 1)
        spawn.assert_not_called()
        base.assert_not_called()

    def test_missing_window_never_falls_back_to_desktop_capture(self):
        with patch.object(lab, "control", return_value=None), \
                patch.object(lab.subprocess, "run") as run, self.assertRaises(lab.LabError):
            lab.capture(Path("/helper"), Mock(), {}, "guest", Path("unused.png"))
        run.assert_not_called()

    def test_capture_is_exact_window_without_clipboard_or_interactive_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "guest.png"
            def capture_image(*args, **kwargs):
                image.write_bytes(b"\x89PNG\r\n\x1a\n")
            with patch.object(lab, "control", return_value={"window_id": 123}), \
                    patch.object(lab.subprocess, "run", side_effect=capture_image) as run:
                lab.capture(Path("/helper"), Mock(), {}, "guest", image)
                self.assertEqual(run.call_args.args[0], ["/usr/sbin/screencapture", "-x", "-o",
                                                        "-l", "123", "-t", "png", str(image)])

    def test_exited_process_blocks_before_targeted_control(self):
        process = Mock()
        process.poll.return_value = 0
        with patch.object(lab.subprocess, "run") as run, self.assertRaises(lab.LabError):
            lab.control(Path("/helper"), "space", process, {}, "guest")
        run.assert_not_called()

    def test_forced_shutdown_is_disclosed(self):
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("tart", 20), 0]
        self.assertEqual(lab.stop_owned_process(process), "force_stopped_after_timeout")
        process.kill.assert_called_once()


class SessionTests(unittest.TestCase):
    def test_native_helper_never_activates_or_posts_global_input(self):
        source = (lab.HERE / "window-control.swift").read_text()
        for forbidden in (".activate(", ".post(tap:", "CGWarpMouseCursorPosition",
                          "kAXRaiseAction", "optionOnScreenOnly"):
            self.assertNotIn(forbidden, source)
        self.assertIn(".postToPid(pid)", source)

    def test_action_validation_is_closed_and_bounded(self):
        for request in ({"action": "capture"}, {"action": "stop"},
                        {"action": "key", "key": "return"},
                        {"action": "key", "key": "backtab"},
                        {"action": "key", "key": "keyboard-navigation"},
                        {"action": "key", "key": "spotlight"},
                        {"action": "wait", "seconds": 10},
                        {"action": "click-text", "text": "English"},
                        {"action": "expect-text", "text": "English"},
                        {"action": "type", "text": "united states"},
                        {"action": "type-secret", "secret": "guest-password"},
                        {"action": "click", "x": 0.2, "y": 0.8}):
            self.assertEqual(lab.validate_action(request), request["action"])
        for request in ([], {"action": []}, {"action": "shell"},
                        {"action": "stop", "extra": 1}, {"action": "key", "key": "command"},
                        {"action": "click", "x": float("nan"), "y": 0.5},
                        {"action": "click", "x": True, "y": 0.5},
                        {"action": "wait", "seconds": 61},
                        {"action": "wait", "seconds": True},
                        {"action": "click-text", "text": ""},
                        {"action": "type", "text": "host\ncommand"},
                        {"action": "type", "text": "CAPITALS"},
                        {"action": "type-secret", "secret": "../../host-password"},
                        {"action": "type-secret", "secret": "guest-password", "text": "secret"},
                        {"action": "click", "x": 1.1, "y": 0.5}):
            with self.subTest(request=request), self.assertRaises(lab.LabError):
                lab.validate_action(request)

    def test_click_requires_screenshot_before_any_input(self):
        with patch.object(lab.sys, "stdin", io.StringIO('{"action":"click","x":0.5,"y":0.5}\n')), \
                patch.object(lab.select, "select", return_value=([1], [], [])), \
                patch.object(lab, "write_json"), \
                patch.object(lab, "settle_window"), \
                patch.object(lab, "audit_no_listener"), patch.object(lab, "control") as control, \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(lab.LabError):
            lab.session(Path("/helper"), Mock(), {}, "test", Path("/unused"), {})
        control.assert_not_called()

    def test_session_uses_last_capture_geometry_and_records_actions(self):
        target = {"window_id": 5, "bounds": [10, 20, 800, 600]}
        commands = '{"action":"capture"}\n{"action":"click","x":0.5,"y":0.6}\n{"action":"stop"}\n'
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(lab.sys, "stdin", io.StringIO(commands)), \
                patch.object(lab.select, "select", return_value=([1], [], [])), \
                patch.object(lab, "audit_no_listener"), patch.object(lab.time, "sleep"), \
                patch.object(lab, "capture", return_value=target), \
                patch.object(lab, "control", return_value=target) as control, \
                contextlib.redirect_stdout(io.StringIO()):
            report = {}
            lab.session(Path("/helper"), Mock(), {}, "test", Path(temporary), report)
            click = [call for call in control.call_args_list if call.args[1] == "click"][0]
            self.assertEqual(click.args[-1], {"x": 0.5, "y": 0.6, **target})
            self.assertEqual([entry["action"] for entry in report["actions"]], ["capture", "click"])

    def test_window_change_during_capture_blocks(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(lab.sys, "stdin", io.StringIO('{"action":"capture"}\n')), \
                patch.object(lab.select, "select", return_value=([1], [], [])), \
                patch.object(lab, "settle_window"), \
                patch.object(lab, "audit_no_listener"), \
                patch.object(lab, "capture", return_value={"window_id": 1, "bounds": [0, 0, 800, 600]}), \
                patch.object(lab, "control", return_value={"window_id": 2, "bounds": [0, 0, 800, 600]}), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(lab.LabError):
            lab.session(Path("/helper"), Mock(), {}, "test", Path(temporary), {})

    def test_initial_geometry_wait_is_bounded_and_never_sends_input(self):
        with patch.object(lab, "control", return_value=None) as control, \
                patch.object(lab.time, "sleep"), self.assertRaises(lab.LabError):
            lab.settle_window(Path("/helper"), Mock(), {}, "test")
        self.assertEqual(control.call_count, 25)
        self.assertEqual({call.args[1] for call in control.call_args_list}, {"window"})

    def test_text_anchor_requires_exact_unique_label_and_keeps_score(self):
        english = {"text": "English", "confidence": 0.5, "x": 0.5, "y": 0.4}
        for lines, expected in (([], None), ([{**english, "text": "English (UK)"}], None),
                                ([english], english)):
            with patch.object(lab.subprocess, "run", return_value=Mock(stdout=json.dumps({"lines": lines}))):
                self.assertEqual(lab.text_anchor(Path("/helper"), Path("/guest.png"), "English"), expected)
        with patch.object(lab.subprocess, "run", return_value=Mock(stdout=json.dumps({"lines": [english, english]}))), \
                self.assertRaises(lab.LabError):
            lab.text_anchor(Path("/helper"), Path("/guest.png"), "English")

    def test_missing_text_anchor_times_out_without_clicking(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(lab.sys, "stdin", io.StringIO('{"action":"click-text","text":"English"}\n')), \
                patch.object(lab.select, "select", return_value=([1], [], [])), \
                patch.object(lab, "settle_window"), patch.object(lab, "audit_no_listener"), \
                patch.object(lab.time, "monotonic", side_effect=[0, 1, 61]), \
                patch.object(lab.time, "sleep"), patch.object(lab, "checked_capture"), \
                patch.object(lab, "text_anchor", return_value=None), \
                patch.object(lab, "control") as control, contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaises(lab.LabError):
            lab.session(Path("/helper"), Mock(), {}, "test", Path(temporary), {})
        control.assert_not_called()

    def test_expect_text_does_not_inject_input(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(lab.sys, "stdin", io.StringIO('{"action":"expect-text","text":"English"}\n{"action":"stop"}\n')), \
                patch.object(lab.select, "select", return_value=([1], [], [])), \
                patch.object(lab, "settle_window"), patch.object(lab, "audit_no_listener"), \
                patch.object(lab.time, "sleep"), patch.object(lab, "checked_capture", return_value={}), \
                patch.object(lab, "text_anchor", return_value={"text": "English"}), \
                patch.object(lab, "control") as control, contextlib.redirect_stdout(io.StringIO()):
            report = {}
            lab.session(Path("/helper"), Mock(), {}, "test", Path(temporary), report)
        control.assert_not_called()
        self.assertNotIn("pending_action", report)


class CredentialTests(unittest.TestCase):
    def test_existing_account_never_gets_an_invented_password(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(FileNotFoundError):
                lab.guest_password(directory, create=False)
            path = directory / "guest-password"
            self.assertFalse(path.exists())
            path.touch(mode=0o600)
            with self.assertRaises(lab.LabError):
                lab.guest_password(directory, create=False)
            self.assertEqual(path.read_text(), "")

    def test_credential_is_generated_once_and_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            password = lab.guest_password(directory)
            self.assertRegex(password, "^[a-z0-9]{24}$")
            self.assertEqual(lab.guest_password(directory), password)
            self.assertEqual((directory / "guest-password").stat().st_mode & 0o777, 0o600)

    def test_unsafe_or_corrupt_credential_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "guest-password"
            path.symlink_to(directory / "outside")
            with self.assertRaises(OSError):
                lab.guest_password(directory)
            self.assertFalse((directory / "outside").exists())
            path.unlink()
            path.write_text("invalid\n")
            for mode in (0o644, 0o600):
                path.chmod(mode)
                with self.assertRaises(lab.LabError):
                    lab.guest_password(directory)
                self.assertEqual(path.read_text(), "invalid\n")

    def test_explicit_disposable_password_is_retained_with_bounded_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "guest-password"
            for value, valid in (("test42", True), ("abc", False), ("a" * 100, True),
                                 ("a" * 101, False)):
                path.write_text(value)
                path.chmod(0o600)
                if valid:
                    self.assertEqual(lab.guest_password(directory), value)
                else:
                    with self.assertRaises(lab.LabError):
                        lab.guest_password(directory)
                self.assertEqual(path.read_text(), value)

    def test_secret_uses_stdin_not_argv_and_failure_diagnostics_are_redacted(self):
        process = Mock(pid=123)
        process.poll.return_value = None
        secret = "a" * 24
        with patch.object(lab, "guest_password", return_value=secret), \
                patch.object(lab.subprocess, "run", return_value=Mock(
                    returncode=1, stdout=secret, stderr=secret)) as run:
            with self.assertRaises(lab.LabError) as error:
                lab.type_guest_password(Path("/helper"), process, {"tart": {"version": "test"}},
                                        "guest", Path("/run"))
        self.assertNotIn(secret, str(error.exception))
        self.assertNotIn(secret, " ".join(run.call_args.args[0]))
        self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"text": secret})

    def test_secret_requires_capture_and_reports_only_reference(self):
        target = {"window_id": 5, "bounds": [10, 20, 800, 600]}
        request = '{"action":"type-secret","secret":"guest-password"}\n'
        for captured in (False, True):
            commands = ('{"action":"capture"}\n' if captured else '') + request
            with tempfile.TemporaryDirectory() as temporary, \
                    patch.object(lab.sys, "stdin", io.StringIO(commands)), \
                    patch.object(lab.select, "select", return_value=([1], [], [])), \
                    patch.object(lab, "audit_no_listener"), patch.object(lab.time, "sleep"), \
                    patch.object(lab, "checked_capture", return_value=target), \
                    patch.object(lab, "control", return_value=target), \
                    patch.object(lab, "type_guest_password") as type_secret, \
                    contextlib.redirect_stdout(io.StringIO()):
                report = {}
                if captured:
                    lab.session(Path("/helper"), Mock(), {}, "guest", Path(temporary), report)
                    type_secret.assert_called_once()
                    entry = report["actions"][-1]
                    self.assertEqual(entry["secret"], "guest-password")
                    self.assertNotIn("text", entry)
                    self.assertNotIn("pending_action", report)
                else:
                    with self.assertRaises(lab.LabError):
                        lab.session(Path("/helper"), Mock(), {}, "guest", Path(temporary), report)
                    type_secret.assert_not_called()


if __name__ == "__main__":
    unittest.main()
