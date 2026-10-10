#!/usr/bin/env python3
"""Measure one Zig soak test process, including RSS and open file descriptors.

Works on Linux /proc without third-party packages. The inner Zig test owns the
pool for the whole run; this process only observes it. A short CI smoke run
does not establish a 24-hour memory leak acceptance.
"""
import json
import os
import pathlib
import subprocess
import sys
import time

PROC = pathlib.Path("/proc")


def children(pid):
    # Linux /proc/<tgid>/task/<tid>/children is thread-specific. Zig's
    # parallel build worker may launch the test from a non-leader thread.
    # Reading only task/<tgid>/children therefore misses the Zig test.
    children_ids = set()
    try:
        tasks = list((PROC / str(pid) / "task").iterdir())
    except OSError:
        return []
    for task in tasks:
        try:
            children_ids.update(int(x) for x in (task / "children").read_text().split())
        except (OSError, ValueError):
            continue
    return list(children_ids)


def test_descendants(pid):
    todo = children(pid)
    while todo:
        child = todo.pop()
        todo.extend(children(child))
        try:
            cmd = (PROC / str(child) / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        binary = cmd.split(" ", 1)[0].strip()
        if binary.endswith("/test") or "/test " in cmd:
            yield child


def snapshot(pid):
    try:
        status = (PROC / str(pid) / "status").read_text()
        rss = next(int(row.split()[1]) for row in status.splitlines() if row.startswith("VmRSS:"))
        fd_count = len(os.listdir(PROC / str(pid) / "fd"))
        return rss, fd_count
    except (OSError, StopIteration, ValueError):
        return None


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit() or not 1 <= int(sys.argv[1]) <= 86400:
        print("usage: python3 integration/soak_monitor.py <seconds 1..86400>", file=sys.stderr)
        return 2
    if not PROC.is_dir():
        print("soak monitor requires Linux /proc", file=sys.stderr)
        return 2

    requested = int(sys.argv[1])
    env = dict(os.environ, SOAK_SECONDS=str(requested))
    proc = subprocess.Popen(["zig", "build", "soak-integration"], env=env)
    start = time.monotonic()
    samples = []
    seen_pids = set()
    try:
        while proc.poll() is None:
            for pid in test_descendants(proc.pid):
                measured = snapshot(pid)
                if measured:
                    seen_pids.add(pid)
                    samples.append((time.monotonic() - start, *measured))
            time.sleep(0.2)
        returncode = proc.wait()
    except (KeyboardInterrupt, BaseException):
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        raise

    # Pin the evidence to the exact checked-out source revision. This value
    # must be compared against a trusted expected SHA by the release gate.
    sha_result = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True)
    git_sha = sha_result.stdout.strip() if sha_result.returncode == 0 else None

    summary = {
        "git_sha": git_sha,
        "sample_span_seconds": round(samples[-1][0] - samples[0][0], 3) if len(samples) >= 2 else 0,
        "requested_seconds": requested,
        "wall_seconds": round(time.monotonic() - start, 3),
        "exit_code": returncode,
        "sample_count": len(samples),
        "test_process_count": len(seen_pids),
        "rss_first_kb": samples[0][1] if samples else None,
        "rss_last_kb": samples[-1][1] if samples else None,
        "rss_peak_kb": max((x[1] for x in samples), default=None),
        "fds_first": samples[0][2] if samples else None,
        "fds_last": samples[-1][2] if samples else None,
        "fds_peak": max((x[2] for x in samples), default=None),
    }
    print("SOAK_RESOURCE_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    output = os.environ.get("SOAK_METRICS_PATH")
    if output:
        pathlib.Path(output).write_text(json.dumps(summary, indent=2) + "\n")
    if returncode != 0 or not samples:
        return returncode or 1
    max_rss = int(os.environ.get("SOAK_MAX_RSS_KB", "0"))
    max_fds = int(os.environ.get("SOAK_MAX_FDS", "0"))
    if max_rss and summary["rss_peak_kb"] > max_rss:
        print("RSS resource budget exceeded", file=sys.stderr)
        return 1
    if max_fds and summary["fds_peak"] > max_fds:
        print("File-descriptor resource budget exceeded", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
