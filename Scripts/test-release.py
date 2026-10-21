#!/usr/bin/env python3
"""Run with python3 -B Scripts/test-release.py; no network, Swift or gh required."""

import argparse
import datetime
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

SHA = "a" * 40
OTHER = "b" * 40
FORMULA = '''class Macarchy < Formula
  desc "Theme-driven macOS environment"
  homepage "https://github.com/ramtinJ95/macarchy"
  url "https://github.com/ramtinJ95/macarchy/releases/download/v0.12.3/macarchy-0.12.3-arm64-apple-darwin.tar.gz"
  sha256 "81139ad6456d55e5299d5fba12ba849948d7072dad74faa7b7f383ca338176ac"
  license "MIT"

  def install
    prefix.install "bin", "share"
  end
end
'''


class TemporaryGit(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="macarchy-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git("init", "--quiet", "--initial-branch", "main")
        for key, value in (("user.name", "Release fixture"),
                           ("user.email", "release@example.invalid"),
                           ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")):
            self.git("config", key, value)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message="fixture"):
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", message)


class VersionAndTagTests(unittest.TestCase):
    def test_versions_must_be_stable_semver(self):
        self.assertEqual(release.parse_version("0.14.10"), "0.14.10")
        for text in ("v1.2.3", "1.2", "1.2.3-rc1", " 1.2.3", "1.2.3\n"):
            with self.subTest(text=text):
                with self.assertRaises(argparse.ArgumentTypeError):
                    release.parse_version(text)
        self.assertLess(release.version_key("0.9.11"), release.version_key("0.14.0"))

    def test_source_version_bump_requires_exactly_one_declaration(self):
        swift = 'struct R {\n  static let sourceVersion = "0.14.5"\n}\n'
        self.assertEqual(release.bump_source_version(swift, "0.15.0"),
                         swift.replace("0.14.5", "0.15.0"))
        for broken in ("struct R {}\n", swift + swift):
            with self.subTest(broken=broken):
                with self.assertRaises(release.ReleaseError):
                    release.bump_source_version(broken, "0.15.0")

    def test_remote_tag_commit_prefers_the_peeled_commit(self):
        annotated = f"{OTHER}\trefs/tags/v1.0.0\n{SHA}\trefs/tags/v1.0.0^{{}}\n"
        self.assertEqual(release.remote_tag_commit(annotated, "v1.0.0"), SHA)
        self.assertEqual(release.remote_tag_commit(f"{SHA}\trefs/tags/v1.0.0\n", "v1.0.0"),
                         SHA)
        self.assertIsNone(release.remote_tag_commit("", "v1.0.0"))


class CiStateTests(unittest.TestCase):
    def run_entry(self, status="completed", conclusion="success", sha=SHA):
        return {"databaseId": 1, "status": status, "conclusion": conclusion,
                "url": "https://example.invalid/run", "headSha": sha}

    def test_any_successful_run_for_the_commit_counts(self):
        runs = [self.run_entry(conclusion="failure"), self.run_entry()]
        self.assertEqual(release.ci_state(runs, SHA)[0], "success")

    def test_pending_failed_missing_and_other_commits(self):
        self.assertEqual(release.ci_state(
            [self.run_entry("in_progress", "")], SHA)[0], "pending")
        self.assertEqual(release.ci_state(
            [self.run_entry(conclusion="failure")], SHA)[0], "failed")
        self.assertEqual(release.ci_state([], SHA), ("missing", None))
        self.assertEqual(release.ci_state([self.run_entry(sha=OTHER)], SHA)[0], "missing")


class PullRequestArchiveTests(unittest.TestCase):
    def pr_run(self, run_id=1, **changes):
        return {"id": run_id, "event": "pull_request", "path": ".github/workflows/ci.yml",
                "conclusion": "success", "head_sha": f"{run_id:040x}",
                "head_repository": {"full_name": release.REPOSITORY},
                "html_url": f"https://example.invalid/runs/{run_id}"} | changes

    def pull(self, base_sha=SHA, base_repo=release.REPOSITORY, head_repo=release.REPOSITORY):
        return {"base": {"sha": base_sha, "repo": {"full_name": base_repo}},
                "head": {"repo": {"full_name": head_repo} if head_repo else None}}

    def test_only_a_successful_same_repository_ci_run_of_the_tree_is_trusted(self):
        self.assertTrue(release.trusted_pr_run(self.pr_run(), SHA, True, SHA))
        for changes in ({"event": "push"}, {"path": ".github/workflows/release.yml"},
                        {"conclusion": "failure"}, {"conclusion": None},
                        {"head_repository": {"full_name": "someone/macarchy"}},
                        {"head_repository": None}):
            with self.subTest(changes=changes):
                self.assertFalse(
                    release.trusted_pr_run(self.pr_run(**changes), SHA, True, SHA))
        self.assertFalse(release.trusted_pr_run(self.pr_run(), OTHER, True, SHA))
        self.assertFalse(release.trusted_pr_run(self.pr_run(), SHA, False, SHA))

    def test_the_base_comes_from_exactly_one_same_repository_pull_request(self):
        self.assertEqual(release.pull_request_base([self.pull()]), SHA)
        for pulls in ([], [self.pull(), self.pull(OTHER)], [self.pull(base_repo="a/b")],
                      [self.pull(head_repo="a/b")], [self.pull(head_repo=None)]):
            with self.subTest(pulls=pulls):
                self.assertIsNone(release.pull_request_base(pulls))

    def test_lookup_skips_expired_and_untrusted_archives(self):
        runs = {n: self.pr_run(n) for n in range(1, 7)}
        runs[2]["conclusion"] = "failure"
        head_trees = {runs[3]["head_sha"]: OTHER}
        pulls = {runs[n]["head_sha"]: [self.pull(f"{n + 100:040x}")] for n in runs}
        pulls[runs[5]["head_sha"]] = []
        behind = {f"{104:040x}...{runs[4]['head_sha']}"}
        artifacts = [{"expired": True, "workflow_run": {"id": 1}},
                     *({"expired": False, "workflow_run": {"id": n}} for n in (2, 3, 4, 5, 6))]

        def gh_json(_, path):
            if "/artifacts?name=" in path:
                self.assertIn(f"?name=pr-archive-tree-{SHA}&", path)
                return {"total_count": len(artifacts), "artifacts": artifacts}
            if "/actions/runs/" in path:
                return runs[int(path.rsplit("/", 1)[1])]
            if path.endswith("/pulls"):
                return pulls[path.rsplit("/", 2)[1]]
            if "/compare/" in path:
                return {"status": "diverged" if path.rsplit("/", 1)[1] in behind
                        else "ahead"}
            return {"tree": {"sha": head_trees.get(path.rsplit("/", 1)[1], SHA)}}

        original = release.gh_json
        release.gh_json = gh_json
        self.addCleanup(setattr, release, "gh_json", original)
        self.assertEqual(release.find_pr_archive(SHA)["id"], 6)
        artifacts.pop()
        self.assertIsNone(release.find_pr_archive(SHA))


class ArchiveAndFormulaTests(TemporaryGit):
    def setUp(self):
        super().setUp()
        self.write(release.TAP_FORMULA, FORMULA)
        self.commit()

    def test_checksum_record_must_name_the_archive(self):
        name = release.archive_name("1.0.0")
        self.assertEqual(release.parse_checksum(f"{'c' * 64}  {name}\n", name), "c" * 64)
        for record in (f"{'c' * 64}  other.tar.gz\n", f"{'c' * 64} {name}\n",
                       f"{'C' * 64}  {name}\n", f"{'c' * 64}  {name}"):
            with self.subTest(record=record):
                with self.assertRaises(release.ReleaseError):
                    release.parse_checksum(record, name)

    def tap_diff(self, edit):
        edit()
        return self.git(*release.TAP_DIFF)

    def test_rewrite_changes_only_url_and_sha256(self):
        url, digest = release.archive_url("1.0.0"), "d" * 64

        def rewrite():
            path = self.root / release.TAP_FORMULA
            path.write_text(release.rewrite_formula(path.read_text(), url, digest))

        diff = self.tap_diff(rewrite)
        release.check_tap_diff(diff)
        text = (self.root / release.TAP_FORMULA).read_text()
        self.assertIn(f'  url "{url}"\n  sha256 "{digest}"\n', text)
        self.assertEqual(release.rewrite_formula(text, url, digest), text)

    def test_diff_guard_refuses_any_other_change(self):
        def add_line():
            path = self.root / release.TAP_FORMULA
            path.write_text(release.rewrite_formula(
                path.read_text(), release.archive_url("1.0.0"), "d" * 64)
                .replace('  license "MIT"', '  license "Apache-2.0"'))

        def other_file():
            self.write("Formula/other.rb", "class Other\nend\n")
            self.git("add", "--intent-to-add", "Formula/other.rb")

        for edit in (add_line, other_file):
            with self.subTest(edit=edit.__name__):
                with self.assertRaises(release.ReleaseError):
                    release.check_tap_diff(self.tap_diff(edit))
                self.git("reset", "--quiet", "--hard")
                self.git("clean", "--quiet", "-fd")

    def test_formula_version_reads_the_release_url(self):
        self.assertEqual(release.formula_version(FORMULA), "0.12.3")
        self.assertGreater(release.version_key("0.12.3"), release.version_key("0.9.10"))
        with self.assertRaises(release.ReleaseError):
            release.formula_version(FORMULA.replace("/releases/download/v0.12.3/", "/"))

    def test_rewrite_refuses_ambiguous_or_missing_fields(self):
        nested = FORMULA.replace("  def install", '  url "https://mirror.invalid/x"\n'
                                 "  def install")
        for formula in (nested, FORMULA.replace("  sha256", "  # sha256")):
            with self.subTest(formula=formula):
                with self.assertRaises(release.ReleaseError):
                    release.rewrite_formula(formula, "https://example.invalid", "d" * 64)


class PlanStepTests(unittest.TestCase):
    def report(self, outcome="ready", **fields):
        return {"schema_version": 1, "operation": "setup_plan", "outcome": outcome,
                "actions": [{"stage": "theme", "id": "activate_curated_theme"}],
                "adoption": [], "native_starters": [],
                "components": {"preferences": {"succeeded": True, "report": {}}},
                **fields}

    def test_ready_plan_without_approvals_applies(self):
        self.assertEqual(release.plan_step(self.report()), ("apply", []))
        self.assertEqual(release.plan_step(self.report("no_change", actions=[])),
                         ("skip", []))

    def test_plans_needing_a_person_stop(self):
        for fields, reason in (
            ({"outcome": "blocked"}, "outcome is 'blocked'"),
            ({"outcome": "recovery_required"}, "recovery_required"),
            ({"schema_version": 2}, "schema"),
            ({"actions": [{"stage": "packages"}]}, "Homebrew packages"),
            ({"package_installation": {"approval_digest": "x"}}, "Homebrew packages"),
            ({"actions": [{"stage": "prerequisites"}]}, "prerequisites"),
            ({"adoption": [{"id": "yabai", "digest": "x"}]}, "adoption approval: yabai"),
            ({"components": {"preferences": {"report": {"approval_digest": "x"}}}},
             "native preferences"),
            ({"native_starters": [{"provider": "kitty"}]}, "native starter"),
        ):
            with self.subTest(fields=fields):
                step, reasons = release.plan_step(self.report(**fields))
                self.assertEqual(step, "stop")
                self.assertIn(reason, "; ".join(reasons))


class PrepareTests(TemporaryGit):
    def setUp(self):
        super().setUp()
        self.write("VERSION.txt", "0.14.5\n")
        self.write(str(release.SOURCE_VERSION),
                   'struct RuntimeEnvironment {\n  static let sourceVersion = "0.14.5"\n}\n')
        self.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n"
                   "## [0.14.5] - 2026-10-20\n\n### Fixed\n\n- Old.\n")
        self.write("changelog.d/README.md", "# Fragments\n")
        self.write("changelog.d/fix.md", "### Fixed\n\n- New fix.\n")
        self.commit()
        self.git("switch", "--quiet", "-c", "feature")

    def prepare(self, version="0.15.0"):
        release.prepare(version, {"fix": 42}, root=self.root,
                        today=datetime.date(2026, 10, 21))

    def test_prepare_commits_version_bump_and_changelog_once(self):
        self.prepare()
        self.assertEqual(self.git("log", "-1", "--format=%s"),
                         "chore(release): prepare v0.15.0")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual((self.root / "VERSION.txt").read_text(), "0.15.0\n")
        self.assertIn('sourceVersion = "0.15.0"',
                      (self.root / release.SOURCE_VERSION).read_text())
        self.assertIn("## [Unreleased]\n\n## [0.15.0] - 2026-10-21\n\n### Fixed\n\n"
                      "- New fix (#42).\n\n## [0.14.5]",
                      (self.root / "CHANGELOG.md").read_text())
        self.assertFalse((self.root / "changelog.d/fix.md").exists())
        head = self.git("rev-parse", "HEAD")
        self.prepare()
        self.assertEqual(self.git("rev-parse", "HEAD"), head)

    def test_prepare_refuses_unsafe_starting_points(self):
        self.write("stray.txt", "uncommitted\n")
        with self.assertRaisesRegex(release.ReleaseError, "not clean"):
            self.prepare()
        (self.root / "stray.txt").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "not newer"):
            self.prepare("0.14.4")
        self.git("switch", "--quiet", "main")
        with self.assertRaisesRegex(release.ReleaseError, "not main"):
            self.prepare()
        self.assertEqual((self.root / "VERSION.txt").read_text(), "0.14.5\n")


if __name__ == "__main__":
    unittest.main()
