"""Pure runner checks: no SSH, VM execution or special-file creation."""
import importlib.util
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

import lab

spec = importlib.util.spec_from_file_location("run_tests", Path(__file__).with_name("run-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class TestRunner(unittest.TestCase):
    def test_snapshot_preserves_packaged_resources_and_excludes_local_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True)
            resources = {
                "Desktop/yabai/defaults.toml": b"yabai defaults",
                "Desktop/sketchybar/defaults.toml": b"bar defaults",
                "Keybindings/defaults.toml": b"keybinding defaults",
                "Themes/example/theme.json": b"theme palette",
                "Environment/Brewfile": b"package catalog",
            }
            for name, data in {
                **resources,
                "docs/internal.md": b"private notes",
                ".build/cache": b"host build state",
            }.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            subprocess.run(
                ["git", "-C", str(root), "add", "Desktop/yabai/defaults.toml"],
                check=True, capture_output=True)
            resources["Desktop/yabai/defaults.toml"] = b"dirty yabai defaults"
            (root / "Desktop/yabai/defaults.toml").write_bytes(
                resources["Desktop/yabai/defaults.toml"])
            archive = root / "snapshot.tar.gz"
            runner.snapshot(root, archive)
            with tarfile.open(archive) as package:
                self.assertEqual(set(package.getnames()), set(resources))
                for name, data in resources.items():
                    self.assertEqual(package.extractfile(name).read(), data)

    def test_remote_command_preserves_filter_as_one_argument(self):
        pattern = "a test; not a shell command"
        command = runner.test_command("/Users/omarchy/source", pattern, True)
        self.assertEqual(shlex.split(command), [
            "/bin/zsh", "/Users/omarchy/source/Scripts/vm/test-guest.sh",
            "--filter", pattern, "--portability"])

    def test_wrong_target_stops_before_upload_or_test_execution(self):
        client = Mock()
        client.command.side_effect = lab.LabError("not a guest")
        with self.assertRaises(lab.LabError):
            runner.run_tests(client, Path("/absent"), Path("/absent"))
        self.assertEqual(client.command.call_count, 1)
        self.assertIn("kern.hv_vmm_present", client.command.call_args.args[0])

    def test_guest_failure_is_reported_and_never_retried_on_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "snapshot"
            archive.write_bytes(b"archive")
            client = Mock()
            client.command.side_effect = [
                Mock(), Mock(), Mock(),
                Mock(returncode=1, stdout="test failed", stderr="details"),
            ]
            with self.assertRaisesRegex(lab.LabError, "no host fallback"):
                runner.run_tests(client, archive, root, "riskyTest", True)
            self.assertEqual(client.command.call_count, 4)
            self.assertEqual((root / "tests.log").read_text(), "test faileddetails")

    def test_snapshot_includes_dirty_sources_but_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "Package.swift"
            source.write_text("current uncommitted contents")
            archive = root / "snapshot.tar.gz"
            with patch.object(subprocess, "run", return_value=Mock(stdout=b"Package.swift\0")):
                self.assertEqual(len(runner.snapshot(root, archive)), 64)
            with tarfile.open(archive) as package:
                self.assertEqual(package.extractfile("Package.swift").read(),
                                 b"current uncommitted contents")
            source.unlink()
            source.symlink_to("/etc/hosts")
            with patch.object(subprocess, "run", return_value=Mock(stdout=b"Package.swift\0")), \
                    self.assertRaisesRegex(lab.LabError, "nonregular"):
                runner.snapshot(root, archive)


if __name__ == "__main__":
    unittest.main()
