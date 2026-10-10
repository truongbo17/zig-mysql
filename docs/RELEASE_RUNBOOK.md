# Production Release Gate — zig-mysql

This runbook defines **evidence checks**, not production certification or
cluster-HA software. A PASS of the offline soak checker does NOT prove that the
JSON was untampered, that GitHub CI passed, or that an independent security
assessment was performed. Use trusted artifacts, required CI checks, human
change approval and your organization's release controls.

## 1. Baseline CI gate

Before promotion, verify the release commit (not just a branch label) passed
the **required** Zig 0.16 and 0.17 jobs against MySQL 8.0/8.4/9.x and
MariaDB 10.11/11.4. Protect `main` and the release tag with required status
checks, appropriate reviewer rules and restricted push permissions.

The CI smoke additionally executes the 24-hour gate on a short soak report
and requires the gate to refuse it. This is a **negative policy test**, not
evidence of a completed 24-hour soak.

## 2. Dedicated 24-hour staging soak (Linux)

Use an isolated MySQL server with representative CPU, memory, storage and
network. The helper assumes the disposable integration fixture's database
credentials on localhost port 33306; avoid using production credentials.

```bash
# Configure thresholds and disk paths before your 24-hour run.
export SOAK_METRICS_PATH=/var/tmp/zig-mysql-soak.json
export SOAK_MAX_RSS_KB=524288
export SOAK_MAX_FDS=256
bash integration/soak.sh 86400
```

The same Zig process must remain alive for the entire run. The monitor records
wall time, actual RSS/FD sample span, initial/final/peak RSS (KiB), initial/
final/peak FDs, process count and full Git commit. Apply the repository's
versioned [sample policy](production-soak-policy.json) only after validating
budgets against representative staging measurements; numbers are *initial
guardrails*, not universal production SLAs.

```bash
python3 integration/release_gate.py \
  --report /var/tmp/zig-mysql-soak.json \
  --policy docs/production-soak-policy.json \
  --expected-sha "$(git rev-parse HEAD)"
```

**No 24-hour run has been demonstrated in GitHub-hosted CI.** A 12-second
smoke report MUST be rejected, even if the underlying test and RSS measurements
pass. The gate requires >=86,400 seconds requested AND observed, a sample span
covering that duration within 30 seconds, enough samples, one instrumented
Zig test process, exit_code=0 and RSS/FD growth and peak budgets.

The checker assesses the report's internal consistency but does not
cryptographically attest its origin or fetch a live GitHub Actions result.
Use an authenticated pipeline to bind the report to its commit and protect the
artifact against replacement.

## 3. Network-partition safety gate

`bash integration/replication_run.sh` builds a disposable MySQL primary and
replica with real binary-log replication. It:

1. Ensures an initial transaction has replicated and read-only replica rejects
   a writer-only pool.
2. Disconnects the source from the Docker replica network **without stopping
   its mysqld**, then commits an isolated source transaction. Checks that the
   replica does not contain it and still rejects writer checkout.
3. Reconnects the Docker network, restarts replica I/O, and **requires** the
   isolated transaction to appear on the replica before proceeding.
4. Stops/fences the former primary, manually promotes the caught-up replica,
   and checks replicated data plus a new write on the promoted node.

This validates a bounded test scenario only. It is **not** evidence of
automatic election, quorum, operator-safe fencing, in-flight write
exactly-once guarantees, complete rollback of split-brain, or guarantees under
packet loss and multi-site failover. For production HA, validate those
capabilities with a suitable external orchestrator on the target cluster.

## 4. Human acceptance and rollback

Require an engineering owner to sign off on actual application traffic,
transaction idempotency, tested rollback, staging p50/p95/p99 and resource
baseline, TLS certificate rotation, security review, operational alerts,
replica lag SLO and runbooks. Do not use a 24-hour PASS alone as authorization
for payments or other high-integrity transaction production.
