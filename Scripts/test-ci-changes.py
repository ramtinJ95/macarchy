#!/usr/bin/env python3
"""Run with python3 Scripts/test-ci-changes.py; no Swift build required."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "ci_changes", Path(__file__).with_name("ci-changes.py"))
ci_changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_changes)


class PathPolicyTests(unittest.TestCase):
    def test_only_explicit_root_documentation_is_lightweight(self):
        for paths in ([b"README.md"], [b"AGENTS.md"],
                      [b"README.md", b"AGENTS.md"]):
            with self.subTest(paths=paths):
                self.assertFalse(ci_changes.requires_full_checks(paths))

    def test_unknown_shipped_and_build_inputs_require_full_checks(self):
        for path in (
            b"Sources/ThemeCore/File.swift", b"Tests/Example.swift",
            b"Tests/Fixtures/README.md", b"Package.swift", b"Package.resolved",
            b"VERSION.txt", b"CHANGELOG.md", b"LICENSE",
            b"Documentation/theme-json.md", b"Themes/example/README.md",
            b"Desktop/defaults.toml", b"Environment/Brewfile",
            b"Keybindings/metadata.toml", b"Scripts/build-release-layout.sh",
            b".github/workflows/ci.yml", b".github/workflows/release.yml",
            b".gitignore", b"new-directory/file", b"README.md\nother",
            b"README.md/file", b"readme.md", b"non-utf8-\xff",
        ):
            with self.subTest(path=path):
                self.assertTrue(ci_changes.requires_full_checks(
                    [b"README.md", path]))

    def test_empty_diff_runs_full_checks(self):
        self.assertTrue(ci_changes.requires_full_checks([]))


class GitDiffTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macarchy-ci-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "ci@example.invalid")
        self.write("README.md", "readme\n")
        self.write("Sources/example.swift", "// source\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.root, stderr=subprocess.PIPE
        ).decode().strip()

    def write(self, name, contents):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def commit(self):
        self.git("add", "--all")
        self.git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                 "commit", "--quiet", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def full(self):
        return ci_changes.classify(self.base, cwd=self.root)

    def test_documentation_edit_and_deletion(self):
        self.write("README.md", "edited\n")
        self.commit()
        self.assertFalse(self.full())
        (self.root / "README.md").unlink()
        self.commit()
        self.assertFalse(self.full())

    def test_source_change_in_earlier_pr_commit_is_not_skipped(self):
        self.write("Sources/example.swift", "// changed\n")
        self.commit()
        self.write("README.md", "latest commit changes only docs\n")
        self.commit()
        self.assertTrue(self.full())

    def test_rename_source_into_allowlist_still_runs_full_checks(self):
        (self.root / "Sources/example.swift").replace(self.root / "README.md")
        self.commit()
        self.assertTrue(self.full())

    def test_rename_out_of_allowlist_runs_full_checks(self):
        (self.root / "README.md").rename(self.root / "unknown.md")
        self.commit()
        self.assertTrue(self.full())

    def test_unusual_filename_cannot_masquerade_as_readme(self):
        self.write("README.md\nunknown", "new\n")
        self.commit()
        self.assertTrue(self.full())

    def test_empty_diff_is_conservative(self):
        self.assertTrue(self.full())

    def test_invalid_or_missing_base_is_an_error(self):
        with self.assertRaises(ValueError):
            ci_changes.classify("--help", cwd=self.root)
        with self.assertRaises(subprocess.CalledProcessError):
            ci_changes.classify("0" * 40, cwd=self.root)


if __name__ == "__main__":
    unittest.main()
