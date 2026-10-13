"""Pure source-boundary checks; never execute Swift tests or create special files."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "Tests/TestSafety/IsolatedTestEnvironment.swift"


class TestSafetyBoundary(unittest.TestCase):
    def test_special_file_creation_is_centralized(self):
        forbidden = re.compile(r"\b(?:mkfifo|mkfifoat|mkfifox_np|mknod|mknodat)\b")
        offenders = []
        for directory in ("Tests", "Scripts", "Sources"):
            for path in (ROOT / directory).rglob("*"):
                if path.suffix not in (".swift", ".sh", ".py") or path in (GUARD, Path(__file__)):
                    continue
                if any(part.startswith(".") for part in path.relative_to(ROOT).parts):
                    continue
                if forbidden.search(path.read_text()):
                    offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [], "Route all special-file fixtures through TestSafety")

    def test_swift_and_shell_use_the_same_guard(self):
        shell = (ROOT / "Scripts/verify-keybindings-portability.sh").read_text()
        self.assertIn("Tests/TestSafety/IsolatedTestEnvironment.swift", shell)
        self.assertLess(shell.index("--check-directory"), shell.index("--create-fifo"))
        for name in ("ThemeCoreTests/BoundedRegularFileTests.swift",
                     "ThemeCoreTests/OmarchyThemeConverterTests.swift",
                     "MacarchyCLITests/KeybindingPortabilityTests.swift"):
            source = (ROOT / "Tests" / name).read_text()
            self.assertIn("try IsolatedTestEnvironment.requireGuest()", source)
            self.assertIn("try IsolatedTestEnvironment.makeFIFO(at:", source)

    def test_ci_runs_boundary_audit_and_opts_in_without_a_host_bypass(self):
        for name in ("ci.yml", "release.yml"):
            with self.subTest(workflow=name):
                workflow = (ROOT / ".github/workflows" / name).read_text()
                self.assertIn("python3 -B Scripts/test-test-safety.py", workflow)
                self.assertIn('MACARCHY_TEST_VM: "1"', workflow)
        guard = GUARD.read_text()
        self.assertIn('sysctlbyname("kern.hv_vmm_present"', guard)
        self.assertNotIn("GITHUB_ACTIONS", guard)


if __name__ == "__main__":
    unittest.main()
