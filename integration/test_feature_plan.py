"""Guard the manually maintained issue tracker against dropped roadmap tickets.

As new child issues are created, extend EXPECTED_ISSUE_IDS in the same PR
that updates README.md and docs/FEATURE_ROADMAP.md. This checks references
only; live issue state is verified via GitHub during review.
"""
import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
EXPECTED_ISSUE_IDS = set(range(10, 39))  # epics #10-13; child tickets #14-38
PATTERN = re.compile(r"https://github\.com/truongbo17/zig-mysql/issues/(\d+)")


def issue_refs(file):
    return {int(m) for m in PATTERN.findall((REPO / file).read_text())}


class RoadmapCoverageTests(unittest.TestCase):
    def test_readme_links_every_planned_ticket(self):
        missing = EXPECTED_ISSUE_IDS - issue_refs("README.md")
        self.assertFalse(missing, f"README issue links missing: {sorted(missing)}")

    def test_roadmap_links_every_planned_ticket(self):
        missing = EXPECTED_ISSUE_IDS - issue_refs("docs/FEATURE_ROADMAP.md")
        self.assertFalse(missing, f"Feature roadmap links missing: {sorted(missing)}")

    def test_sprint_a_all_six_issues_have_delivered_prs(self):
        readme = (REPO / "README.md").read_text()
        section = readme.split("### Sprint A —", 1)[1].split("### Sprint B —", 1)[0]
        self.assertIn("(P0, COMPLETE)", readme)
        for item in range(14, 20):
            rows = [line for line in section.splitlines()
                    if line.startswith("| A") and f"/issues/{item})" in line]
            self.assertEqual(len(rows), 1, f"expected exactly one Sprint A row for #{item}")
            self.assertIn("Done", rows[0])
            self.assertIn("/pull/", rows[0])
            self.assertNotIn("Planned", rows[0])
            self.assertNotIn("In progress", rows[0])
        sprint_b = readme.split("### Sprint B —", 1)[1].split("### Sprint C —", 1)[0]
        b1 = [line for line in sprint_b.splitlines()
              if line.startswith("| B1 |") and "/issues/20)" in line]
        self.assertEqual(len(b1), 1)
        self.assertIn("Done", b1[0])
        self.assertIn("/pull/52", b1[0])
        self.assertIn("24-hour soak", readme)
        self.assertIn("NOT yet passed", readme)

    def test_roadmap_agrees_that_sprint_a_is_delivered(self):
        roadmap = (REPO / "docs/FEATURE_ROADMAP.md").read_text()
        self.assertIn("**Sprint A complete:**", roadmap)
        self.assertIn("Sprint B #20", roadmap)
        self.assertIn("does not close production gate #13", roadmap)

    def test_sprint_b_all_four_issues_have_delivered_prs(self):
        readme = (REPO / "README.md").read_text()
        section = readme.split("### Sprint B —", 1)[1].split("### Sprint C —", 1)[0]
        for number, issue, pr in ((1, 20, 52), (2, 21, 53), (3, 22, 54), (4, 23, 55)):
            rows = [line for line in section.splitlines()
                    if line.startswith(f"| B{number} |") and f"/issues/{issue})" in line]
            self.assertEqual(len(rows), 1, f"missing Sprint B{number} issue #{issue}")
            self.assertIn("Done", rows[0])
            self.assertIn(f"/pull/{pr}", rows[0])
            self.assertIn("/actions/runs/", rows[0])
            self.assertNotIn("pending", rows[0].lower())
        roadmap = (REPO / "docs/FEATURE_ROADMAP.md").read_text()
        self.assertIn("**Sprint B complete:**", roadmap)
        self.assertIn("production release gate #13", roadmap)
        self.assertIn("24-hour soak", readme)

    def test_sprint_c_issue_tracker_and_production_gate(self):
        readme = (REPO / "README.md").read_text()
        section = readme.split("### Sprint C —", 1)[1].split("### Sprint D —", 1)[0]
        for number, issue, pr in ((1, 24, 56), (2, 25, 57), (3, 26, 58), (4, 27, 59)):
            rows = [line for line in section.splitlines()
                    if line.startswith(f"| C{number} |") and f"/issues/{issue})" in line]
            self.assertEqual(len(rows), 1, f"Sprint C{number} issue #{issue} missing")
            self.assertIn("Done", rows[0])
            self.assertIn(f"/pull/{pr}", rows[0])
            self.assertIn("/actions/runs/", rows[0])
            self.assertNotIn("pending", rows[0].lower())
        roadmap = (REPO / "docs/FEATURE_ROADMAP.md").read_text()
        self.assertIn("**Sprint C complete:**", roadmap)
        self.assertIn("production release gate #13", roadmap)
        report = (REPO / "docs/SPRINT_C_REPORT.md").read_text()
        self.assertIn("p50/p95/p99", report)
        self.assertIn("24-hour", report)
        self.assertIn("OPS #13", report)

    def test_sprint_e_all_issues_delivered_without_waiving_tls_or_ops(self):
        readme = (REPO / "README.md").read_text()
        section = readme.split("### Sprint E —", 1)[1].split(
            "### Parallel production acceptance", 1
        )[0]
        for item, issue, pr in ((1, 32, 120), (2, 33, 121), (3, 34, 122)):
            rows = [
                line for line in section.splitlines()
                if line.startswith(f"| E{item} |")
                and f"/issues/{issue})" in line
            ]
            self.assertEqual(len(rows), 1, f"missing delivered Sprint E{item}")
            self.assertIn("DONE", rows[0])
            self.assertIn(f"/pull/{pr}", rows[0])
            self.assertIn("/actions/runs/", rows[0])
            self.assertNotIn("Planned", rows[0])
        d_section = readme.split("### Sprint D —", 1)[1].split("### Sprint E —", 1)[0]
        for item in (3, 4):
            rows = [line for line in d_section.splitlines() if line.startswith(f"| D{item} |")]
            self.assertEqual(1, len(rows))
            self.assertIn("BLOCKED", rows[0])
            self.assertIn("/issues/65", rows[0])
        roadmap = (REPO / "docs/FEATURE_ROADMAP.md").read_text()
        self.assertIn("**Sprint E complete", roadmap)
        report = (REPO / "docs/SPRINT_E_STATUS.md").read_text()
        self.assertIn("3 of 3 issues closed", report)
        self.assertIn("not", report.lower())
        self.assertIn("Windows", report)
        self.assertIn("production", report.lower())
        self.assertIn("38832510637", report)

    def test_plan_and_gate_are_explicit(self):
        readme = (REPO / "README.md").read_text()
        self.assertIn("## Feature plan and issue tracker", readme)
        self.assertIn("### Parallel production acceptance — NOT yet passed", readme)
        self.assertIn("Blocked — not executed", readme)
        self.assertIn("Next implementation", readme)


if __name__ == "__main__":
    unittest.main()
