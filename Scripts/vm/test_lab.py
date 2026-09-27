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


if __name__ == "__main__":
    unittest.main()
