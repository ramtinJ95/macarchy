#!/usr/bin/env python3
"""Run with python3 -B Scripts/test-changelog.py; no Swift build required."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "changelog", Path(__file__).with_name("changelog.py"))
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)

HEADER = """# Changelog

## [Unreleased]
"""
PREVIOUS = """
## [0.1.0] - 2026-01-01

### Added

- First release.
"""


class FragmentRepository(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="macarchy-changelog-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "changelog.d").mkdir()
        (self.root / "changelog.d/README.md").write_text("# Not a fragment\n")
        self.write_changelog("")

    def write_changelog(self, unreleased):
        (self.root / "CHANGELOG.md").write_text(HEADER + unreleased + PREVIOUS)

    def fragment(self, name, text):
        (self.root / "changelog.d" / name).write_text(text)

    def check(self):
        return changelog.main(["--root", str(self.root), "check"])

    def release(self, *extra):
        changelog.main(["--root", str(self.root), "release", "1.0.0",
                        "2026-10-20", *extra])
        return (self.root / "CHANGELOG.md").read_text()


class CheckTests(FragmentRepository):
    def test_valid_fragments_and_unreleased_bullets_pass(self):
        self.write_changelog("\n### Fixed\n\n- Direct entry.\n")
        self.fragment("a.md", "### Added\n\n- One.\n- Two wraps\n  onto a second line.\n")
        self.check()

    def test_malformed_fragments_are_rejected(self):
        for text in ("", "- No section.\n", "### Fixes\n\n- Typo section.\n",
                     "### Fixed\n", "### Fixed\n\nProse paragraph.\n",
                     "### Fixed\n\n- One.\n\n### Added\n\n- Two.\n",
                     "### Fixed\n\n- One.\n\n  Detached continuation.\n",
                     "Intro\n### Fixed\n\n- One.\n"):
            with self.subTest(text=text):
                self.fragment("bad.md", text)
                with self.assertRaises(SystemExit) as raised:
                    self.check()
                self.assertIn("changelog.d/bad.md", str(raised.exception))

    def test_non_markdown_entries_are_rejected(self):
        self.fragment("notes.txt", "### Fixed\n\n- One.\n")
        with self.assertRaisesRegex(SystemExit, "regular .md files"):
            self.check()

    def test_stray_unreleased_text_is_rejected(self):
        self.write_changelog("\nSomething unstructured.\n")
        with self.assertRaisesRegex(SystemExit, "Unreleased"):
            self.check()


class ReleaseTests(FragmentRepository):
    def test_release_merges_by_section_and_consumes_fragments(self):
        self.write_changelog("\n### Fixed\n\n- Direct fix.\n")
        self.fragment("b-fix.md", "### Fixed\n\n- Fragment fix\n  wrapped.\n")
        self.fragment("a-add.md", "### Added\n\n- New thing.\n")
        self.fragment("c-known.md", "### Known limitations\n\n- Still slow.\n")
        self.assertEqual(self.release(), HEADER + """
## [1.0.0] - 2026-10-20

### Added

- New thing.

### Fixed

- Direct fix.
- Fragment fix
  wrapped.

### Known limitations

- Still slow.
""" + PREVIOUS)
        self.assertEqual(
            [path.name for path in (self.root / "changelog.d").iterdir()], ["README.md"])

    def test_pr_numbers_attach_to_named_fragment_bullets(self):
        self.fragment("fix.md", "### Fixed\n\n- One.\n- Two\n  wrapped.\n")
        self.fragment("other.md", "### Fixed\n\n- Unnumbered\n")
        text = self.release("--pr", "fix=301", "--pr", "other.md=7")
        self.assertIn("- One (#301).\n- Two\n  wrapped (#301).\n- Unnumbered (#7)\n", text)

    def test_unknown_pr_fragment_changes_nothing(self):
        self.fragment("fix.md", "### Fixed\n\n- One.\n")
        before = (self.root / "CHANGELOG.md").read_text()
        with self.assertRaisesRegex(SystemExit, "names no fragment: missing"):
            self.release("--pr", "missing=1")
        self.assertEqual(before, (self.root / "CHANGELOG.md").read_text())
        self.assertTrue((self.root / "changelog.d/fix.md").exists())

    def test_empty_or_repeated_release_is_refused(self):
        with self.assertRaisesRegex(SystemExit, "nothing to release"):
            self.release()
        self.fragment("fix.md", "### Fixed\n\n- One.\n")
        self.release()
        self.fragment("again.md", "### Fixed\n\n- Two.\n")
        with self.assertRaisesRegex(SystemExit, "already has a 1.0.0 section"):
            self.release()

    def test_invalid_version_or_date_is_refused(self):
        self.fragment("fix.md", "### Fixed\n\n- One.\n")
        for arguments in (["v1.0.0", "2026-10-20"], ["1.0", "2026-10-20"],
                          ["1.0.0", "2026-13-01"], ["1.0.0", "today"]):
            with self.subTest(arguments=arguments):
                with self.assertRaises(SystemExit):
                    changelog.main(["--root", str(self.root), "release", *arguments])
        self.assertTrue((self.root / "changelog.d/fix.md").exists())


if __name__ == "__main__":
    unittest.main()
