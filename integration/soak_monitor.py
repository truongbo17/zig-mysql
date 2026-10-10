#!/usr/bin/env python3
"""Bounded-memory Linux RSS/FD monitor for a single long-lived Zig pool soak.

This is a structural instrument, not a trusted attestation or a substitute
for profiling application code on representative staging hardware.
"""
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import threading
import time

PROC = pathlib.Path("/proc")
COMPLETE = re.compile(
    r"SOAK COMPLETE rounds=(\d+), requests=(\d+), seconds_requested=(\d+)"
)


def children(pid):
    """Zig build may spawn tests on a non-leader thread."""
    found = set()
    try:
        tids = list((PROC / str(pid) / "task").iterdir())
    except OSError:
        return []
    for tid in tids:
        try:
            found.update(int(x) for x in (tid / "children").read_text().split())
        except (OSError, ValueError):
            continue
    return list(found)


def test_descendants(pid):
    pending = children(pid)
    visited = set()
    while pending:
        child = pending.pop()
        if child in visited:
            continue
        visited.add(child)
        pending.extend(children(child))
        try:
            cmd = (PROC / str(child) / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        program = cmd.split(" ", 1)[0]
        if program.endswith("/test"):
            yield child


def snapshot(pid):
    try:
        status = (PROC / str(pid) / "status").read_text()
        rss = next(int(line.split()[1]) for line in status.splitlines() if line.startswith("VmRSS:"))
        fds = len(os.listdir(PROC / str(pid) / "fd"))
        return rss, fds
    except (OSError, StopIteration, ValueError):
        return None


def parse_completion(line):
    result = COMPLETE.search(line)
    if result is None:
        return None
    return tuple(map(int, result.groups()))


def track_output(stream, completed):
    # Stream each line; do not buffer 24 hours of process output in memory.
    for line in stream:
        print(line, end="", flush=True)
        match = parse_completion(line)
        if match:
            completed.append(match)
    stream.close()


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit() or not 1 <= int(sys.argv[1]) <= 86400:
        print("usage: python3 integration/soak_monitor.py <seconds 1..86400>", file=sys.stderr)
        return 2
    if not PROC.is_dir():
        print("Linux /proc required", file=sys.stderr)
        return 2

    duration = int(sys.argv[1])
    env = dict(os.environ, SOAK_SECONDS=str(duration))
    process = subprocess.Popen(
        ["zig", "build", "soak-integration"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    completed = []
    output = threading.Thread(
        target=track_output, args=(process.stdout, completed), daemon=True
    )
    output.start()

    started = time.monotonic()
    observed = set()
    first = last = None
    first_at = last_at = None
    peak_rss = peak_fds = 0
    count = 0
    try:
        while process.poll() is None:
            for pid in test_descendants(process.pid):
                metrics = snapshot(pid)
                if metrics is None:
                    continue
                now = time.monotonic() - started
                observed.add(pid)
                if first is None:
                    first, first_at = metrics, now
                last, last_at = metrics, now
                peak_rss = max(peak_rss, metrics[0])
                peak_fds = max(peak_fds, metrics[1])
                count += 1
            # O(1) memory over a multi-day interval.
            time.sleep(0.5)
        result_code = process.wait()
        output.join(timeout=15)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        process.wait()
        output.join(timeout=15)
        raise

    git = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    )
    commit = git.stdout.strip() if git.returncode == 0 else None
    # Exactly one COMPLETE record is expected from exactly one Zig test process.
    complete = completed[0] if len(completed) == 1 else None
    report = {
        "git_sha": commit,
        "requested_seconds": duration,
        "wall_seconds": round(time.monotonic() - started, 3),
        "sample_span_seconds": round(last_at - first_at, 3) if count >= 2 else 0,
        "exit_code": result_code,
        "test_process_count": len(observed),
        "sample_count": count,
        "rss_first_kb": first[0] if first else None,
        "rss_last_kb": last[0] if last else None,
        "rss_peak_kb": peak_rss if count else None,
        "fds_first": first[1] if first else None,
        "fds_last": last[1] if last else None,
        "fds_peak": peak_fds if count else None,
        "soak_completed": complete is not None,
        "soak_rounds": complete[0] if complete else 0,
        "soak_operations": complete[1] if complete else 0,
        "soak_reported_seconds": complete[2] if complete else 0,
    }
    print("SOAK_RESOURCE_SUMMARY " + json.dumps(report, sort_keys=True), flush=True)
    path = os.environ.get("SOAK_METRICS_PATH")
    if path:
        pathlib.Path(path).write_text(json.dumps(report, indent=2) + "\n")
    if result_code != 0 or count == 0 or not report["soak_completed"]:
        print("SOAK RESOURCE MONITOR FAIL: no clean observed completion", file=sys.stderr)
        return result_code or 1
    for key, metric in (("SOAK_MAX_RSS_KB", peak_rss), ("SOAK_MAX_FDS", peak_fds)):
        budget = int(os.environ.get(key, "0"))
        if budget and metric > budget:
            print(f"SOAK RESOURCE MONITOR FAIL: {key} exceeded", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
