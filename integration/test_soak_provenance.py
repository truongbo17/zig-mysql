"""Offline negative tests; these synthetic fixtures NEVER constitute soak evidence."""
import copy
import unittest

import soak_provenance

SHA = "a" * 40
RUN = {
    "id": 123,
    "repository": {"full_name": "truongbo17/zig-mysql"},
    "head_sha": SHA,
    "head_branch": "main",
    "event": "workflow_dispatch",
    "path": ".github/workflows/staging-soak.yml",
    "name": "Staging 24h Soak",
    "status": "completed",
    "conclusion": "success",
}
ARTIFACT = {
    "name": "zig-mysql-soak-0.16.0-" + SHA,
    "expired": False, "size_in_bytes": 8192,
    "digest": "sha256:" + "f" * 64,
    "workflow_run": {"id": 123, "head_sha": SHA},
}
REPORT = {
    "git_sha": SHA, "soak_completed": True, "soak_rounds": 1000,
    "soak_operations": 1280000, "soak_reported_seconds": 86400,
    "exit_code": 0, "requested_seconds": 86400, "wall_seconds": 86420,
    "sample_span_seconds": 86400, "sample_count": 100000,
    "test_process_count": 1, "rss_first_kb": 30000, "rss_last_kb": 35000,
    "rss_peak_kb": 37000, "fds_first": 12, "fds_last": 12, "fds_peak": 15,
}
POLICY = {
    "minimum_soak_seconds": 86400, "minimum_sample_count": 1000,
    "minimum_completed_operations": 1000000,
    "maximum_rss_peak_kb": 524288, "maximum_fd_peak": 256,
    "maximum_rss_growth_kb": 65536, "maximum_fd_growth": 8,
}


class SoakProvenanceTests(unittest.TestCase):
    def verify(self, run=None, artifact=None, report=None, sha=SHA, zig="0.16.0"):
        return soak_provenance.evaluate(
            RUN if run is None else run, ARTIFACT if artifact is None else artifact,
            REPORT if report is None else report, POLICY, sha, zig,
        )

    def test_structural_example_must_pass(self):
        self.assertEqual([], self.verify())

    def test_run_must_be_successful_correct_workflow_and_dispatch(self):
        for change in (
            {"conclusion": "failure"}, {"status": "in_progress"},
            {"event": "push"}, {"head_branch": "feature"},
            {"path": ".github/workflows/tests.yml"},
            {"repository": {"full_name": "attacker/zig-mysql"}},
            {"head_sha": "b" * 40},
        ):
            self.assertTrue(self.verify(run={**RUN, **change}), change)

    def test_artifact_origin_name_expiry_and_digest(self):
        for change in (
            {"workflow_run": {"id": 456, "head_sha": SHA}},
            {"workflow_run": {"id": 123, "head_sha": "b" * 40}},
            {"expired": True}, {"digest": ""},
            {"digest": "sha256:garbage"}, {"size_in_bytes": 0},
            {"name": "zig-mysql-soak-0.17.0-" + SHA},
        ):
            self.assertTrue(self.verify(artifact={**ARTIFACT, **change}), change)

    def test_short_report_wrong_sha_and_failed_process(self):
        for change in (
            {"requested_seconds": 12, "wall_seconds": 13, "sample_span_seconds": 11},
            {"git_sha": "b" * 40}, {"exit_code": 1},
            {"test_process_count": 2}, {"soak_completed": False},
            {"soak_operations": 3},
        ):
            self.assertTrue(self.verify(report={**REPORT, **change}), change)

    def test_duplicate_version_and_unpinned_commit_rejected(self):
        self.assertTrue(self.verify(zig="0.17.0"))
        self.assertTrue(self.verify(sha="not-a-commit"))
        self.assertTrue(self.verify(sha="b" * 40))


if __name__ == "__main__":
    unittest.main()
