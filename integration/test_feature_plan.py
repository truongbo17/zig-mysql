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

    def test_plan_and_gate_are_explicit(self):
        readme = (REPO / "README.md").read_text()
        self.assertIn("## Feature plan and issue tracker", readme)
        self.assertIn("### Parallel production acceptance — NOT yet passed", readme)
        self.assertIn("Blocked — not executed", readme)
        self.assertIn("Next implementation", readme)


if __name__ == "__main__":
    unittest.main()
