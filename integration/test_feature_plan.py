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
        self.assertIn("Sprint B starts at [#20", readme)
        self.assertIn("24-hour soak", readme)
        self.assertIn("NOT yet passed", readme)

    def test_roadmap_agrees_that_sprint_a_is_delivered(self):
        roadmap = (REPO / "docs/FEATURE_ROADMAP.md").read_text()
        self.assertIn("**Sprint A complete:**", roadmap)
        self.assertIn("Sprint B #20", roadmap)
        self.assertIn("does not close production gate #13", roadmap)

    def test_plan_and_gate_are_explicit(self):
        readme = (REPO / "README.md").read_text()
        self.assertIn("## Feature plan and issue tracker", readme)
        self.assertIn("### Parallel production acceptance — NOT yet passed", readme)
        self.assertIn("Blocked — not executed", readme)
        self.assertIn("Next implementation", readme)


if __name__ == "__main__":
    unittest.main()
