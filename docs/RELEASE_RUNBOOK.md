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

## 2a. Dedicated GitHub Actions runner workflow (prepared, not executed)

The manually dispatched workflow at
[staging-soak.yml](../.github/workflows/staging-soak.yml) pins a full
24-hour single-process run to the exact main-branch revision; it does not
run on a GitHub-hosted runner. It requires a Linux x64 self-hosted runner
with the custom label **zig-mysql-soak**, reachable isolated staging MySQL
server and OpenSSL/Zig-compatible toolchain. An organization must provision
this runner and a GitHub Actions environment called **production-validation**
with authorized reviewers; this environment is NOT automatically created
by committing the workflow.

Configure these GitHub Actions **environment variables**:

- SOAK_ENVIRONMENT_CLASS = isolated-staging
- SOAK_MYSQL_ADDRESS = literal IP:port of the dedicated **nonproduction**
  MySQL fixture, different from the default 127.0.0.1:33306
- SOAK_MYSQL_USERNAME = least-privileged dedicated test user
- SOAK_MYSQL_DATABASE = disposable staging test database

Configure this GitHub Actions **environment secret**:

- SOAK_MYSQL_PASSWORD = fixture password. Do not place it in the repo or
  in job artifacts.

On the Actions page, select **Staging 24h Soak**, choose **Run workflow** on
main, and select Zig 0.17 or 0.16. The job checks environment configuration,
source SHA, Python policy tests and Zig unit tests, then executes one 24-hour
staging run. It runs the release gate on the exact sha and uploads the JSON
evidence artifact even if validation failed (when a report exists). Job timeout
is 1500 minutes. It does **not** create a release, tag, deployment or branch
protection rule.

For a production claim, run the acceptance workload for **each supported Zig
version**, review independent security/HA results and sign off on the approved
environment and target database; successful test artifacts alone do not
authorize a deployment.

The monitor now stores only first/last/peak RSS/FDs, count and timestamps
(**constant RAM**, not all 24-hour samples), and streams the test log. It
requires exactly one completion marker and includes completed workload rounds
and SQL operations in the JSON. The versioned policy requires at least
1,000,000 completed SELECT operations over 24 hours; this is an initial
integrity check, *not* a realistic throughput or query-payload SLO.
Configure stronger load and realistic query shapes before commercial release.

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
