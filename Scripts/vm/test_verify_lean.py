"""Pure recipe/assessment checks: no VM, subprocess or filesystem fixtures."""
import tomllib
import unittest

import verify
import verify_lean as lean
import verify_borders as borders


class LeanJourneyTests(unittest.TestCase):
    def test_teardown_requires_exact_known_failure_and_positive_lean_removal(self):
        rows = [{"adapter_id": name, "status": status, "requirement": "required"}
                for name, status in lean.MISSING_DEFAULTS.items()]
        rows += [{"adapter_id": "macos-appearance", "status": "applied", "requirement": "required"},
                 {"adapter_id": "lean-focus-ring", "status": "applied", "requirement": "required",
                  "message": "Stopped and unregistered owned lean; no Borders state was adopted or changed."}]
        result = {"outcome": "blocked", "mutated": True, "transaction_status": "clear", "theme": rows,
                  "message": "Required theme reconciliation of the default consumer set failed; run 'macarchy reconcile'."}
        self.assertTrue(lean.assess_restoration(result))
        for key, value in (("outcome", "converged"), ("mutated", False),
                           ("transaction_status", "recovery_required"), ("message", "unexpected"),
                           ("theme", rows[:-1]), ("theme", rows + [rows[-1]])):
            self.assertFalse(lean.assess_restoration(dict(result, **{key: value})))

    def test_review_digest_is_not_an_adoption_request(self):
        ready = {"outcome": "ready", "adoption": [],
                 "keybindings": {"adoption_evidence_digest": "sha256:example"}}
        self.assertEqual(borders._blockers(ready), [])
        self.assertTrue(borders._blockers(dict(ready, adoption=["foreign entry"])))
        self.assertTrue(borders._blockers(dict(ready, outcome="adoption_required")))
        self.assertTrue(borders._blockers(dict(ready, blocked=True)))

    def test_closed_profile_has_only_opt_in_focus_and_no_other_provider(self):
        profile = tomllib.loads(lean.profile("lean"))
        self.assertEqual(profile["focus_ring"]["provider"], "lean")
        for name in lean.DISABLED:
            self.assertEqual(profile[name]["provider"], "disabled")
        self.assertTrue(all(value is False for value in profile["tools"].values()))
        self.assertEqual(tomllib.loads(lean.profile("disabled"))["focus_ring"]["provider"], "disabled")
        with self.assertRaises(ValueError):
            lean.profile("borders")

    def test_claim_is_separate_from_preview_and_not_hardware_parity(self):
        self.assertIn("lean", verify.JOURNEYS)
        self.assertIn("No new physical", verify.JOURNEYS["lean"]["claim"])
        self.assertGreater(lean.PERSIST_SECONDS, 300)

    def test_same_process_live_theme_and_duration_are_independent(self):
        before = {"pid": 1, "started": 2, "executablePath": "/helper",
                  "generationID": "first", "accent": "#cba6f7", "updated": 10}
        changed = dict(before, generationID="second", accent="#7aa2f7", updated=12)
        self.assertEqual(lean.assess_runtime(before, changed, changed_theme=True), [])
        self.assertTrue(lean.assess_runtime(before, before, changed_theme=True))
        self.assertTrue(lean.assess_runtime(before, dict(changed, pid=3), changed_theme=True))
        self.assertTrue(lean.assess_runtime(before, dict(changed, started=3), changed_theme=True))
        self.assertTrue(lean.assess_runtime(before, dict(changed, executablePath="/other")))
        self.assertEqual(lean.assess_runtime(before, dict(before, updated=315), persisted=True), [])
        self.assertTrue(lean.assess_runtime(before, dict(before, updated=310), persisted=True))
        self.assertTrue(lean.assess_runtime(before, dict(before, updated=9), persisted=True))


if __name__ == "__main__":
    unittest.main()
