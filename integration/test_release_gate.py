"""Offline release evidence validator regression tests (no Docker required)."""
import copy
import unittest

import release_gate


SHA = "a" * 40
POLICY = {
    "minimum_soak_seconds": 86400,
    "minimum_sample_count": 1000,
    "minimum_completed_operations": 1000000,
    "maximum_rss_peak_kb": 524288,
    "maximum_fd_peak": 256,
    "maximum_rss_growth_kb": 65536,
    "maximum_fd_growth": 8,
}
REPORT = {
    "git_sha": SHA,
    "soak_completed": True,
    "soak_rounds": 1000,
    "soak_operations": 1280000,
    "soak_reported_seconds": 86400,
    "exit_code": 0,
    "requested_seconds": 86400,
    "wall_seconds": 86410,
    "sample_span_seconds": 86398,
    "sample_count": 400000,
    "test_process_count": 1,
    "rss_first_kb": 30000,
    "rss_last_kb": 42000,
    "rss_peak_kb": 44000,
    "fds_first": 12,
    "fds_last": 12,
    "fds_peak": 15,
}


class GateTests(unittest.TestCase):
    def test_valid_structural_evidence(self):
        self.assertEqual(release_gate.evaluate(REPORT, POLICY, SHA), [])

    def test_short_ci_smoke_cannot_promote(self):
        data = dict(REPORT, requested_seconds=12, wall_seconds=13,
                    sample_span_seconds=11, sample_count=60)
        reasons = release_gate.evaluate(data, POLICY, SHA)
        self.assertTrue(any("duration" in x or "interval" in x for x in reasons))

    def test_missing_resource_samples_fail_closed(self):
        data = dict(REPORT, rss_first_kb=None, rss_peak_kb=None,
                    sample_count=0, test_process_count=0)
        self.assertTrue(release_gate.evaluate(data, POLICY, SHA))

    def test_report_must_match_exact_commit(self):
        self.assertTrue(any("commit" in x for x in
                            release_gate.evaluate(REPORT, POLICY, "b" * 40)))

    def test_report_invalid_sha_rejected(self):
        self.assertTrue(release_gate.evaluate(dict(REPORT, git_sha="fake"), POLICY, SHA))

    def test_memory_leak_budget_rejected(self):
        data = dict(REPORT, rss_last_kb=120000, rss_peak_kb=121000)
        self.assertTrue(any("growth" in x for x in release_gate.evaluate(data, POLICY, SHA)))

    def test_file_descriptor_growth_budget_rejected(self):
        data = dict(REPORT, fds_last=55, fds_peak=60)
        self.assertTrue(any("growth" in x for x in release_gate.evaluate(data, POLICY, SHA)))

    def test_peak_budget_rejected(self):
        data = dict(REPORT, rss_peak_kb=800000, fds_peak=300)
        failures = release_gate.evaluate(data, POLICY, SHA)
        self.assertTrue(any("RSS peak" in x for x in failures))
        self.assertTrue(any("file descriptor peak" in x for x in failures))

    def test_samples_must_cover_runtime(self):
        data = dict(REPORT, sample_span_seconds=2)
        self.assertTrue(any("samples" in x for x in release_gate.evaluate(data, POLICY, SHA)))

    def test_failure_exit_and_process_count(self):
        data = dict(REPORT, exit_code=1, test_process_count=2)
        self.assertGreaterEqual(len(release_gate.evaluate(data, POLICY, SHA)), 2)

    def test_no_weak_production_policy(self):
        policy = dict(POLICY, minimum_soak_seconds=3600)
        self.assertTrue(release_gate.evaluate(REPORT, policy, SHA))

    def test_policy_requires_nonzero_limits(self):
        policy = dict(POLICY, maximum_fd_growth=0)
        self.assertTrue(release_gate.evaluate(REPORT, policy, SHA))

    def test_missing_sql_completion_fails(self):
        data = dict(REPORT, soak_completed=False, soak_rounds=0, soak_operations=0)
        self.assertTrue(any("COMPLETE" in x for x in
                            release_gate.evaluate(data, POLICY, SHA)))

    def test_forged_operation_count_fails(self):
        data = dict(REPORT, soak_operations=1280001)
        self.assertTrue(any("inconsistent" in x for x in
                            release_gate.evaluate(data, POLICY, SHA)))

    def test_insufficient_real_operations_fail(self):
        data = dict(REPORT, soak_rounds=10, soak_operations=12800)
        self.assertTrue(any("insufficient completed SQL" in x for x in
                            release_gate.evaluate(data, POLICY, SHA)))

    def test_soak_reports_another_duration_fails(self):
        data = dict(REPORT, soak_reported_seconds=12)
        self.assertTrue(any("duration differs" in x for x in
                            release_gate.evaluate(data, POLICY, SHA)))

    def test_missing_operations_policy_fails(self):
        policy = dict(POLICY)
        del policy["minimum_completed_operations"]
        self.assertTrue(release_gate.evaluate(REPORT, policy, SHA))

    def test_nonfinite_fails_closed(self):
        data = dict(REPORT, rss_peak_kb=float("nan"))
        self.assertTrue(release_gate.evaluate(data, POLICY, SHA))


if __name__ == "__main__":
    unittest.main()
