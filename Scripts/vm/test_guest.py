"""Pure SSH boundary tests; no network, guest, install or reboot."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import guest
import lab


class SSHTests(unittest.TestCase):
    def test_targets_only_private_ipv4_and_isolated_native_ssh(self):
        args = guest.ssh_arguments("192.168.64.19", "desktop-check-01", Path("/private/run"))
        for option in ("IdentityAgent=none", "ForwardAgent=no", "ForwardX11=no",
                       "ClearAllForwardings=yes", "PubkeyAuthentication=no",
                       "GlobalKnownHostsFile=/dev/null", "StrictHostKeyChecking=accept-new",
                       "UserKnownHostsFile=/private/run/known_hosts"):
            self.assertIn(option, args)
        self.assertEqual(args[1:4], ["-F", "/dev/null", "-T"])
        self.assertEqual(args[-1], "omarchy@192.168.64.19")
        for ip in ("127.0.0.1", "169.254.1.1", "8.8.8.8", "::1", "guest;bad"):
            with self.subTest(ip=ip), self.assertRaises((lab.LabError, ValueError)):
                guest.ssh_arguments(ip, "desktop-check-01", Path("/private/run"))

    def test_master_and_arbitrary_paths_cannot_be_targets(self):
        for name in ("desktop-base", "installer-base", "../other", "setup-unknown"):
            with self.subTest(name=name), self.assertRaises(lab.LabError):
                guest.run_directory(name)

    def test_password_only_on_stdin_and_errors_do_not_echo_diagnostics(self):
        client = guest.Guest.__new__(guest.Guest)
        client.argv, client.env, client.password = ["ssh", "guest"], {}, "fixture-secret"
        with patch.object(guest.subprocess, "run", return_value=Mock(returncode=1,
                          stdout="fixture-secret", stderr="fixture-secret")) as run:
            with self.assertRaisesRegex(lab.LabError, "exit 1") as raised:
                client.command("sudo example", sudo=True)
        self.assertNotIn("fixture-secret", str(raised.exception))
        self.assertNotIn("fixture-secret", repr(run.call_args.args))
        self.assertEqual(run.call_args.kwargs["input"], "fixture-secret\n")

    def test_constructor_checks_run_pins_before_network(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / "report.json").write_text(json.dumps({"inputs": {"wrong": True}}))
            with patch.object(guest, "run_directory", return_value=path), \
                    patch.object(lab, "run_tart") as tart, self.assertRaises(lab.LabError):
                guest.Guest({}, "desktop-check-01", Path("/askpass"))
            tart.assert_not_called()

    def test_reboot_requires_new_boot_id_and_preserved_marker(self):
        client = guest.Guest.__new__(guest.Guest)
        client.boot_session = Mock(side_effect=["old", "old", "new"])
        client.command = Mock(side_effect=[Mock(stdout="marker"), Mock(returncode=255),
                                          Mock(stdout="marker")])
        with patch.object(guest.time, "sleep"):
            result = client.reboot()
        self.assertEqual(result["before"], "old")
        self.assertEqual(result["after"], "new")
        self.assertTrue(result["marker_preserved"])
        self.assertEqual(client.command.call_args_list[1].kwargs, {"sudo": True, "check": False})

    def test_homebrew_inspection_rejects_enabled_analytics(self):
        client = guest.Guest.__new__(guest.Guest)
        answers = ["omarchy", "26.6.2", "25G83", "System Integrity Protection status: enabled.",
                   "assessments enabled", "", "Homebrew 7.0.6\nInfluxDB analytics are enabled."]
        client.command = Mock(side_effect=[Mock(stdout=value) for value in answers])
        with self.assertRaisesRegex(lab.LabError, "analytics"):
            client.inspect({"macos": {"version": "26.6.2", "build": "25G83"}}, homebrew=True)

    def test_reboot_marker_loss_is_failure(self):
        client = guest.Guest.__new__(guest.Guest)
        client.boot_session = Mock(side_effect=["old", "new"])
        client.command = Mock(side_effect=[Mock(stdout="marker"), Mock(returncode=0), Mock(stdout="")])
        with patch.object(guest.time, "sleep"), self.assertRaises(lab.LabError):
            client.reboot()

    def test_mark_is_exclusive_not_overwrite(self):
        client = guest.Guest.__new__(guest.Guest)
        client.command = Mock()
        result = client.mark()
        self.assertRegex(result["marker"], r"^[0-9a-f]{32}$")
        command = client.command.call_args.args[0]
        self.assertIn("set -C", command)
        self.assertIn('test ! -L "$HOME/.macarchy-vm-reset-check"', command)

    def test_homebrew_recipe_is_guarded_pinned_and_no_passwordless_sudo(self):
        recipe = (lab.HERE / "prepare-homebrew.sh").read_text()
        self.assertIn('"${MACARCHY_VM_PREPARE-}" == "disposable-guest"', recipe)
        self.assertRegex(recipe, r"revision=[a-f0-9]{40}")
        self.assertRegex(recipe, r"digest=[a-f0-9]{64}")
        self.assertIn("HOMEBREW_NO_ANALYTICS=1", recipe)
        self.assertIn("brew analytics off", recipe)
        self.assertIn("trap cleanup EXIT", recipe)
        self.assertNotIn("NOPASSWD", recipe)


if __name__ == "__main__":
    unittest.main()
