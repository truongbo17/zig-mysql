#!/usr/bin/env python3
"""Diagnostic Linux profiler for the child benchmark binary only.

Usage: python3 bench/profile_runner.py zig build -Doptimize=ReleaseFast high-ccu-bench
The profiler observes a *running* process, never fabricates RSS/FD numbers.
"""
import os
import subprocess
import sys
import time
from pathlib import Path


def child_processes(parent_pid):
    processes = {}
    for item in Path("/proc").iterdir():
        if not item.name.isdigit():
            continue
        try:
            status = (item / "status").read_text()
            ppid_line = next(x for x in status.splitlines() if x.startswith("PPid:"))
            processes[int(item.name)] = int(ppid_line.split()[1])
        except (OSError, ValueError, StopIteration):
            continue
    live = {parent_pid}
    while True:
        related = {pid for pid, ppid in processes.items() if ppid in live}
        if related <= live:
            break
        live |= related
    return live


def sample(pid):
    maximum_rss_kb = 0
    maximum_fds = 0
    matches = 0
    for candidate in child_processes(pid):
        root = Path("/proc") / str(candidate)
        try:
            executable = os.path.basename(os.readlink(root / "exe"))
            if not executable.startswith("zig-mysql-high-ccu"):
                continue
            status = (root / "status").read_text().splitlines()
            value = next((line.split()[1] for line in status if line.startswith("VmRSS:")), None)
            if value is None:
                continue
            maximum_rss_kb = max(maximum_rss_kb, int(value))
            maximum_fds = max(maximum_fds, len(list((root / "fd").iterdir())))
            matches += 1
        except (OSError, ValueError):
            continue
    return maximum_rss_kb, maximum_fds, matches


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Usage: profile_runner.py COMMAND [ARGS...]")
    if not Path("/proc").exists():
        raise SystemExit("Linux /proc is required for RSS/FD profiling")
    proc = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    peak_rss_kb = peak_fds = observed = 0
    try:
        while proc.poll() is None:
            rss, fds, count = sample(proc.pid)
            peak_rss_kb = max(peak_rss_kb, rss)
            peak_fds = max(peak_fds, fds)
            observed += count
            time.sleep(0.1)
        output = proc.stdout.read().decode("utf-8", errors="replace")
        sys.stdout.write(output)
        print(f"D4_PROFILE samples={observed} peak_rss_kb={peak_rss_kb} peak_fds={peak_fds}")
        if proc.returncode != 0:
            raise SystemExit(proc.returncode)
        if observed == 0:
            raise SystemExit("No benchmark process samples; RSS/FD evidence absent")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    main()
