"""Pure recipe checks; no subprocesses, VM, installs or special-file fixtures."""
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import verify
import verify_lean as lean
import verify_packaged_lean as package


class PackagedLeanTests(unittest.TestCase):
    def test_upgrade_requires_stable_plist_new_process_and_second_cellar_binary(self):
        first, second = [package.CELLAR + "/0.12.4_" + str(n) for n in (1, 2)]
        root = "/Users/omarchy/fixture/state"
        plist = {"Label": lean.LABEL, "ProgramArguments": [
            package.BIN + "/macarchy-focus-ring", "--managed", "--state-root", root]}
        before = {"pid": 1, "started": 1, "generationID": "g", "accent": "#aabbcc",
                  "executablePath": first + "/bin/macarchy-focus-ring"}
        after = dict(before, pid=2, started=2, executablePath=second + "/bin/macarchy-focus-ring")
        self.assertTrue(package.assess_upgrade(before, after, first, second, plist, plist, root))
        for changed in (before, dict(after, executablePath=before["executablePath"]),
                        dict(after, pid=1, started=1), dict(after, generationID="other"),
                        dict(after, accent="#112233")):
            self.assertFalse(package.assess_upgrade(before, changed, first, second, plist, plist, root))
        for changed in (dict(plist, Label="foreign"), dict(plist, ProgramArguments=[
                first + "/bin/macarchy-focus-ring", "--managed", "--state-root", root])):
            self.assertFalse(package.assess_upgrade(before, after, first, second, changed, changed, root))
        self.assertFalse(package.assess_upgrade(before, after, first, second, plist, dict(plist, extra=True), root))

    def test_link_guard_requires_all_three_exact_owned_symlinks(self):
        guard = package.link_guard(package.CELLAR + "/0.12.4_1")
        for name in package.PRODUCTS:
            self.assertIn("test -L " + package.BIN + "/" + name, guard)
            self.assertIn(package.CELLAR + "/0.12.4_1/bin/" + name, guard)
        self.assertNotIn("rm ", guard)

    def test_cleanup_is_identity_guarded_and_refuses_foreign_service_or_links(self):
        section = {"owner": {"session": "verify-0123456789ab", "identity": "1:2"},
                   "copies": [package.CELLAR + "/0.12.4_1", package.CELLAR + "/0.12.4_2"]}
        sh = Mock()
        package.cleanup(sh, section)
        commands = {call.args[0]: call.args[1] for call in sh.call_args_list}
        self.assertIn("launchctl print", commands["package-cleanup-service-absent"])
        command = commands["package-cleanup"]
        self.assertTrue(command.startswith(package.owner_guard(section["owner"])))
        self.assertIn("test ! -L " + package.CELLAR, command)
        self.assertIn("stat -f '%d:%i'", command)
        self.assertIn(".verify-owner", command)
        for name in package.PRODUCTS:
            self.assertLess(command.index("readlink " + package.BIN + "/" + name), command.index("; rm -rf"))
        refused = Mock(side_effect=verify.Blocked("foreign service"))
        with self.assertRaises(verify.Blocked):
            package.cleanup(refused, section)
        self.assertEqual(refused.call_count, 1)
        empty = Mock()
        package.cleanup(empty, {})
        empty.assert_not_called()

    def test_prepare_refuses_existing_targets_before_any_build_or_write(self):
        sh = Mock(side_effect=verify.Blocked("existing target"))
        with self.assertRaises(verify.Blocked):
            package.prepare(sh, {"guest": {"source": "/source"}}, Path("drive-packaged-lean-01"), {})
        self.assertEqual(sh.call_count, 1)
        command = sh.call_args.args[1]
        for path in [package.CELLAR] + [package.BIN + "/" + name for name in package.PRODUCTS]:
            self.assertIn("test ! -e " + path + " && test ! -L " + path, command)

    def test_journey_always_attempts_owned_cleanup_on_failure(self):
        with patch.object(package.borders, "_runner"), patch.object(package.borders, "require_console_user"), \
                patch.object(package, "prepare", side_effect=verify.Failed("build failed")), \
                patch.object(package, "cleanup") as cleanup:
            with self.assertRaises(verify.Failed):
                package.run_journey(Mock(), {}, Mock(), {})
            cleanup.assert_called_once()
        self.assertIn("packaged-lean", verify.JOURNEYS)
        self.assertIn("Not a Homebrew install", verify.JOURNEYS["packaged-lean"]["claim"])


if __name__ == "__main__":
    unittest.main()
