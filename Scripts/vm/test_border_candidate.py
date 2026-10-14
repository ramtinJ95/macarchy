"""Pure unit tests for candidate border builds; no subprocess or guest access."""
import copy
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import guest  # noqa: E402
import lab  # noqa: E402
import verify  # noqa: E402
import verify_borders  # noqa: E402

RUN = "setup-0123456789ab"
SESSION = "verify-0123456789ab"
CANDIDATE = "verify-fedcba987654"


def journeys():
    drive = verify.build_parser()._subparsers._group_actions[0].choices["drive"]
    choices = next(a.choices for a in drive._actions if a.dest == "journey")
    return ([j for j in choices if "border" in j][0],
            [j for j in choices if "border" not in j][0])


def argv(journey, candidate=CANDIDATE):
    return ["drive", "--run", RUN, "--session", SESSION, "--journey", journey,
            "--candidate-session", candidate, "--border-count", "8"]


def patch_all(test, specs):
    mocks = {}
    for target, attr, kwargs in specs:
        p = patch.object(target, attr, **kwargs)
        mocks[attr] = p.start()
        test.addCleanup(p.stop)
    return mocks


class MainCandidateTests(unittest.TestCase):
    def setUp(self):
        self.border, self.other = journeys()
        self.m = patch_all(self, [(lab, "initialize", {}), (lab, "check_version", {}),
                                  (guest, "Guest", {}), (verify, "drive", {"return_value": {"status": "passed"}})])

    def main(self, args):
        with patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
            try:
                return verify.main(args)
            except SystemExit as exc:
                return exc.code
            except verify.Blocked:
                return 1

    def assert_refused_before_initialize(self, args):
        self.assertNotIn(self.main(args), (0, None))
        for attr in ("initialize", "Guest", "drive"):
            self.m[attr].assert_not_called()

    def test_candidate_requires_border_journey(self):
        self.assert_refused_before_initialize(argv(self.other)[:-2])

    def test_candidate_must_be_a_verify_session(self):
        for name in ("setup-0123456789ab", "verify-0123", "../verify-fedcba987654"):
            with self.subTest(name=name):
                self.assert_refused_before_initialize(argv(self.border, name))

    def test_candidate_must_differ_from_prepared_session(self):
        self.assert_refused_before_initialize(argv(self.border, SESSION))

    def test_border_journey_accepts_candidate_and_count(self):
        self.assertIn(self.main(argv(self.border)), (0, None))
        self.m["check_version"].assert_called()
        self.m["initialize"].assert_called_once()
        self.m["drive"].assert_called_once()
        self.m["drive"].assert_called_once_with(
            self.m["initialize"].return_value, RUN, SESSION, self.border, 8, CANDIDATE, False)



class BuildCandidateTests(unittest.TestCase):
    def setUp(self):
        self.source = verify.guest_directory(CANDIDATE)
        self.bin_dir = self.source + "/.build/arm64-apple-macosx/release"
        self.paths = {p: self.bin_dir + "/" + p for p in ("macarchy", "macarchy-focus-ring")}
        self.hashes = dict(zip(self.paths.values(), ("a" * 64, "b" * 64)))
        self.candidate = {"run": RUN, "status": "ready", "guest": {"source": self.source},
                          "host_source": {"snapshot_sha256": "c" * 64}}
        self.ctx = {"binary": "/p/bin/macarchy", "helper": "/p/bin/macarchy-focus-ring",
                    "bin_dir": "/p/bin", "themes_root": "/p/Themes", "state": "/p/state",
                    "profile": "/p/profile", "flags": {"borders": True}, "source": "/p",
                    "incumbent": "/p/incumbent"}
        self.report = {"session": SESSION}
        self.commands = []

        def fake_run(client, evidence, report, name, command, **kwargs):
            self.commands.append(name)
            return self.bin_dir + "\n" if name == "candidate-bin-path" else ""

        self.m = patch_all(self, [
            (verify_borders, "_v", {"return_value": verify}),
            (verify_borders, "run", {"side_effect": fake_run}),
            (verify_borders, "_sha256", {"return_value": self.hashes}),
            (verify_borders, "set_theme", {}),
            (guest, "run_directory", {"return_value": Path("/runs") / RUN}),
            (verify, "session_ready", {"return_value": self.candidate}),
            (verify, "guest_identity", {})])

    def build(self):
        verify_borders.build_candidate(client="client", ctx=self.ctx, evidence=[],
                                       report=self.report, run_id=RUN, name=CANDIDATE)

    def assert_blocked_before_commands(self):
        before = copy.deepcopy(self.ctx)
        with self.assertRaises(verify.Blocked):
            self.build()
        self.assertEqual(self.commands, [])
        self.m["set_theme"].assert_not_called()
        self.assertEqual(self.ctx, before)
        self.assertNotIn("candidate_build", self.report)

    def test_wrong_source_is_rejected_before_identity_or_commands(self):
        self.candidate["guest"]["source"] = verify.guest_directory(SESSION)
        self.assert_blocked_before_commands()
        self.m["guest_identity"].assert_not_called()

    def test_guest_identity_failure_stops_before_commands(self):
        self.m["guest_identity"].side_effect = verify.Blocked("not the disposable guest")
        self.assert_blocked_before_commands()

    def test_success_swaps_only_candidate_product_paths(self):
        before = copy.deepcopy(self.ctx)
        self.build()
        self.m["session_ready"].assert_called_once_with(Path("/runs") / RUN, CANDIDATE)
        self.m["guest_identity"].assert_called_once_with("client", self.candidate)
        self.assertEqual(self.commands, ["candidate-build-macarchy",
                                         "candidate-build-macarchy-focus-ring",
                                         "candidate-bin-path", "candidate-regular-files"])
        changed = {k for k in set(before) | set(self.ctx) if before.get(k) != self.ctx.get(k)}
        self.assertEqual({k: self.ctx.get(k) for k in changed}, {
            "binary": self.paths["macarchy"], "helper": self.paths["macarchy-focus-ring"],
            "bin_dir": self.bin_dir, "themes_root": self.source + "/Themes"})
        self.m["set_theme"].assert_called_once()
        self.assertIs(self.m["set_theme"].call_args.args[3], self.ctx)

    def test_records_candidate_snapshot_and_artifact_hashes(self):
        self.build()
        build = self.report["candidate_build"]
        self.assertEqual({k: build[k] for k in ("session", "snapshot_sha256", "source",
                                                "bin_dir", "replaces")},
                         {"session": CANDIDATE, "snapshot_sha256": "c" * 64,
                          "source": self.source, "bin_dir": self.bin_dir,
                          "replaces": {"binary": "/p/bin/macarchy",
                                       "helper": "/p/bin/macarchy-focus-ring"}})
        self.assertEqual(build["products"], {
            p: {"path": path, "sha256": self.hashes[path]} for p, path in self.paths.items()})
        self.assertEqual(tuple(self.m["_sha256"].call_args.args[2]),
                         tuple(self.paths.values()))


if __name__ == "__main__":
    unittest.main()
