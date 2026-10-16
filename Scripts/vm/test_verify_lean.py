"""Pure recipe/assessment checks: no VM, subprocess or filesystem fixtures."""
import tomllib
import unittest
from unittest.mock import Mock

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
                  "generationID": "first", "accent": "#cba6f7"}
        changed = dict(before, generationID="second", accent="#7aa2f7")
        self.assertEqual(lean.assess_runtime(before, changed, changed_theme=True), [])
        self.assertTrue(lean.assess_runtime(before, before, changed_theme=True))
        self.assertTrue(lean.assess_runtime(before, dict(changed, pid=3), changed_theme=True))
        self.assertTrue(lean.assess_runtime(before, dict(changed, started=3), changed_theme=True))
        self.assertTrue(lean.assess_runtime(before, dict(changed, executablePath="/other")))
        # The idle record is intentionally unchanged; liveness is checked by the
        # real CLI's launchd PID/start inspection, not periodic publication.
        io = {"pid": 1, "start": 2, "logical_writes": 10, "disk_bytes_written": 20, "sampled": 10}
        later = dict(io, sampled=315)
        self.assertEqual(lean.assess_idle(io, later, before, before, "same", "same")["logical_write_bytes_per_second"], 0)
        for invalid in (dict(later, sampled=310), dict(later, pid=3), dict(later, start=3),
                        dict(later, logical_writes=11), dict(later, disk_bytes_written=21)):
            with self.assertRaises(ValueError):
                lean.assess_idle(io, invalid, before, before, "same", "same")
        with self.assertRaises(ValueError):
            lean.assess_idle(io, later, before, changed, "same", "same")
        with self.assertRaises(ValueError):
            lean.assess_idle(io, later, before, before, "inode1", "inode2")

    def test_stopped_doctor_must_find_the_owned_service_not_an_unrelated_failure(self):
        report = {"outcome": "drifted", "transaction_status": "clear",
                  "providers": {"focus_ring": "lean"},
                  "theme": [{"adapter_id": "lean-focus-ring", "status": "failed",
                             "message": "the owned lean service is stopped; run environment apply to repair"}],
                  "entries": [{"id": "lean_focus_service", "status": "install_required"}]}
        self.assertTrue(lean.assess_stopped(report))
        self.assertFalse(lean.assess_stopped(dict(report, theme=[])))
        self.assertFalse(lean.assess_stopped(dict(report, entries=[])))
        self.assertFalse(lean.assess_stopped(dict(report, transaction_status="recovery_required")))

    def test_reconcile_must_report_restart_and_acknowledge_new_identity(self):
        before = {"pid": 1, "started": 2, "generationID": "g", "accent": "#abcdef", "executablePath": "/helper"}
        after = dict(before, pid=3, started=4)
        row = {"adapter_id": "lean-focus-ring", "status": "applied",
               "message": "Started stopped owned lean service. Acknowledged"}
        appearance = {"adapter_id": "macos-appearance", "status": "applied"}
        result = {"outcome": "success", "reconciliation": [row, appearance]}
        self.assertTrue(lean.assess_restarted(result, before, after))
        self.assertFalse(lean.assess_restarted(result, before, before))
        self.assertFalse(lean.assess_restarted(result, before, dict(after, accent="#123456")))
        for invalid in (dict(result, outcome="failure"), dict(result, reconciliation=[]),
                        dict(result, reconciliation=[dict(row, message="stale"), appearance]),
                        dict(result, reconciliation=[row, appearance, appearance])):
            self.assertFalse(lean.assess_restarted(invalid, before, after))

    def test_failure_cleanup_always_checks_absence_even_if_teardown_fails(self):
        for response in ({"outcome": "absent", "transaction_status": "clear"},
                         {"outcome": "unexpected"}, RuntimeError("transport failed")):
            cli = Mock(side_effect=response if isinstance(response, Exception) else None,
                       return_value=response)
            absent = Mock()
            report = {}
            lean.failure_cleanup(cli, absent, report, ["--json"])
            cli.assert_called_once_with("failure-teardown", "environment", "teardown", "--json", expected=(0, 1))
            absent.assert_called_once_with("failure-service-absent")
            self.assertEqual("cleanup_errors" in report, response != {"outcome": "absent", "transaction_status": "clear"})


if __name__ == "__main__":
    unittest.main()
