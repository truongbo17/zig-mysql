#!/usr/bin/env python3
"""Fail-closed local evidence checker for a staged zig-mysql production release.

This validates soak output only. It does NOT independently attest CI status,
prove that the JSON was untampered, or certify HA/security review. Execute it
on trusted CI artifacts from the exact release commit; enforce GitHub branch
protection and required status checks separately.
"""
import argparse
import json
import math
import pathlib
import re
import sys

NUMERICS = ("requested_seconds", "wall_seconds", "sample_span_seconds", "sample_count",
            "test_process_count", "rss_first_kb", "rss_last_kb", "rss_peak_kb",
            "fds_first", "fds_last", "fds_peak", "soak_rounds",
            "soak_operations", "soak_reported_seconds")


def evaluate(report, policy, expected_sha):
    failures = []
    if not isinstance(report, dict) or not isinstance(policy, dict):
        return ["evidence and policy must be JSON objects"]
    for key in NUMERICS:
        val = report.get(key)
        if isinstance(val, bool) or not isinstance(val, (int, float)) or not math.isfinite(val) or val < 0:
            failures.append(f"{key} must be a finite nonnegative number")
    if failures:
        return failures

    duration = policy.get("minimum_soak_seconds")
    min_samples = policy.get("minimum_sample_count")
    max_rss = policy.get("maximum_rss_peak_kb")
    max_fd = policy.get("maximum_fd_peak")
    max_rss_growth = policy.get("maximum_rss_growth_kb")
    max_fd_growth = policy.get("maximum_fd_growth")
    thresholds = (duration, min_samples, max_rss, max_fd, max_rss_growth, max_fd_growth)
    if any(isinstance(x, bool) or not isinstance(x, int) or x <= 0 for x in thresholds):
        return ["all production policy thresholds must be positive integers"]
    if duration < 86400:
        failures.append("minimum_soak_seconds cannot be less than 86400 for production")
    min_operations = policy.get("minimum_completed_operations")
    if isinstance(min_operations, bool) or not isinstance(min_operations, int) or min_operations <= 0:
        return ["minimum_completed_operations must be a positive integer"]
    if report.get("soak_completed") is not True:
        failures.append("Zig soak did not emit a unique SOAK COMPLETE marker")
    if report["soak_rounds"] < 1:
        failures.append("no completed Zig workload rounds")
    # The current in-repository soak workload runs 16 borrowers * 80 queries
    # per round. This check is structural, not tamper-resistant attestation.
    if report["soak_operations"] != report["soak_rounds"] * 1280:
        failures.append("SQL operation count is inconsistent with soak rounds")
    if report["soak_operations"] < min_operations:
        failures.append("insufficient completed SQL operations")
    if report["soak_reported_seconds"] != report["requested_seconds"]:
        failures.append("Zig soak duration differs from requested monitor duration")
    if report["exit_code"] != 0:
        failures.append("soak process exited unsuccessfully")
    if report["test_process_count"] != 1:
        failures.append("expected exactly one instrumented Zig test process")
    if report["requested_seconds"] < duration:
        failures.append("configured soak duration is below release minimum")
    # Require evidence that the actual monitor observed essentially the full
    # interval; a compile-only or early-exiting test cannot satisfy the gate.
    if report["wall_seconds"] < duration:
        failures.append("observed wall duration is below release minimum")
    if report["sample_count"] < min_samples:
        failures.append("too few measured RSS/FD samples")
    if report["sample_span_seconds"] < duration - 30:
        failures.append("resource samples do not cover the required 24-hour interval")
    if report["rss_peak_kb"] > max_rss:
        failures.append("RSS peak exceeded release budget")
    if report["fds_peak"] > max_fd:
        failures.append("file descriptor peak exceeded release budget")
    if report["rss_last_kb"] - report["rss_first_kb"] > max_rss_growth:
        failures.append("RSS growth exceeded release budget")
    if report["fds_last"] - report["fds_first"] > max_fd_growth:
        failures.append("file descriptor growth exceeded release budget")
    if report["rss_peak_kb"] < max(report["rss_first_kb"], report["rss_last_kb"]):
        failures.append("inconsistent RSS peak")
    if report["fds_peak"] < max(report["fds_first"], report["fds_last"]):
        failures.append("inconsistent FD peak")
    sha = report.get("git_sha")
    if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
        failures.append("missing full Git commit SHA in resource report")
    if not isinstance(expected_sha, str) or re.fullmatch(r"[0-9a-f]{40}", expected_sha) is None:
        failures.append("a trusted full expected Git SHA is required")
    elif sha != expected_sha:
        failures.append("soak artifact commit differs from intended release")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    parser.add_argument("--policy", type=pathlib.Path, required=True)
    parser.add_argument("--expected-sha", required=True)
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
        policy = json.loads(args.policy.read_text())
    except (OSError, ValueError) as exc:
        print(f"RELEASE GATE FAIL: could not read evidence: {exc}", file=sys.stderr)
        return 2
    reasons = evaluate(report, policy, args.expected_sha)
    if reasons:
        for reason in reasons:
            print(f"RELEASE GATE FAIL: {reason}", file=sys.stderr)
        return 1
    print(f"RELEASE SOAK GATE PASS for commit {args.expected_sha} "
          f"({report['requested_seconds']}s, {report['sample_count']} samples)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
