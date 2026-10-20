#!/usr/bin/env python3
"""Validate ONE official GitHub soak run/artifact against its recorded SHA.

Structural validation is not cryptographic provenance. Call only after
retrieving run/artifact metadata and the JSON from the GitHub API over an
authenticated Actions token; independently enforce protected branches,
environment reviewers, HA/security sign-offs and artifact verification.
"""
import argparse
import json
import pathlib
import re
import sys

import release_gate

REPO = "truongbo17/zig-mysql"
WORKFLOW = ".github/workflows/staging-soak.yml"
VERSIONS = ("0.16.0", "0.17.0")


def evaluate(run, artifact, report, policy, sha, zig):
    reasons = []
    if not isinstance(run, dict) or not isinstance(artifact, dict):
        return ["run and artifact metadata must be objects"]
    if zig not in VERSIONS:
        return ["only approved Zig versions are accepted"]
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        return ["expected commit must be a full SHA"]

    repository = run.get("repository")
    if not isinstance(repository, dict) or repository.get("full_name") != REPO:
        reasons.append("run must belong to exact trusted repository")
    if run.get("head_sha") != sha:
        reasons.append("run commit does not match approved SHA")
    if run.get("head_branch") != "main" or run.get("event") != "workflow_dispatch":
        reasons.append("run was not manually dispatched on main")
    if str(run.get("path", "")).split("@", 1)[0] != WORKFLOW:
        reasons.append("run is not dedicated Staging 24h Soak workflow")
    if (run.get("name") != "Staging 24h Soak" or
            run.get("status") != "completed" or
            run.get("conclusion") != "success"):
        reasons.append("staging soak GitHub run must have completed successfully")

    run_id = run.get("id")
    if isinstance(run_id, bool) or not isinstance(run_id, int) or run_id <= 0:
        reasons.append("missing valid run ID")
    expected_name = f"zig-mysql-soak-{zig}-{sha}"
    if artifact.get("name") != expected_name:
        reasons.append("soak artifact name or Zig version mismatch")
    if artifact.get("expired") is not False:
        reasons.append("soak artifact missing or expired")
    size = artifact.get("size_in_bytes")
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
        reasons.append("soak artifact empty")
    digest = artifact.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        reasons.append("soak artifact missing GitHub SHA256 digest metadata")
    attached = artifact.get("workflow_run")
    if not isinstance(attached, dict) or attached.get("id") != run_id or attached.get("head_sha") != sha:
        reasons.append("artifact does not originate from the asserted GitHub run/SHA")

    reasons.extend(release_gate.evaluate(report, policy, sha))
    return reasons


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ("run", "artifact", "report", "policy"):
        ap.add_argument("--" + name, required=True, type=pathlib.Path)
    ap.add_argument("--expected-sha", required=True)
    ap.add_argument("--zig", choices=VERSIONS, required=True)
    args = ap.parse_args()
    try:
        run = json.loads(args.run.read_text())
        artifact = json.loads(args.artifact.read_text())
        report = json.loads(args.report.read_text())
        policy = json.loads(args.policy.read_text())
    except (ValueError, OSError) as exc:
        print("SOAK PROVENANCE FAIL: unreadable JSON:", exc, file=sys.stderr)
        return 2
    errors = evaluate(run, artifact, report, policy, args.expected_sha, args.zig)
    for err in errors:
        print("SOAK PROVENANCE FAIL:", err, file=sys.stderr)
    if errors:
        return 1
    print(f"SOAK METADATA POLICY PASS: Zig {args.zig}, commit {args.expected_sha}")
    print("NOT A RELEASE APPROVAL: HA/security, branch controls and human approval remain.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
