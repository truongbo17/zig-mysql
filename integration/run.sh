#!/usr/bin/env bash
set -euo pipefail

# Disposable integration matrix. Requires Docker and Zig 0.16 or 0.17.
prefix="zig-mysql-test-$$"
container80="$prefix-80"
container84="$prefix-84"
container97="$prefix-97"
mariadb_container="$prefix-mariadb"
binary="$(mktemp -t zig-mysql-socket-test.XXXXXX)"
socket_dir=/tmp/zig-mysql-test-socket
ca_file=/tmp/zig-mysql-test-ca.pem
stall_pid=""
soak_report="/tmp/zig-mysql-soak-${prefix}.json"
cleanup() {
  if [[ -n "$stall_pid" ]]; then kill "$stall_pid" >/dev/null 2>&1 || true; fi
  docker rm -f "$container80" "$container84" "$container97" "$mariadb_container" >/dev/null 2>&1 || true
  rm -f "$binary"
  rm -f "$ca_file" "$soak_report"
  rm -f "/tmp/zig-mysql-stall-$prefix.log"
  rmdir "$socket_dir" 2>/dev/null || true
}
trap cleanup EXIT

wait_mysql() {
  local name="$1"
  for _ in $(seq 1 90); do
    if docker logs "$name" 2>&1 | grep -q 'MySQL init process done. Ready for start up.' && \
       docker exec -e MYSQL_PWD=zig_mysql_test "$name" mysql -uroot -N -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2
  return 1
}

docker run --name "$container80" -e MYSQL_ROOT_PASSWORD=zig_mysql_test \
  -e MYSQL_DATABASE=zigtest -p 127.0.0.1:33306:3306 -d mysql:8.0.46 >/dev/null
wait_mysql "$container80"
docker exec -e MYSQL_PWD=zig_mysql_test "$container80" mysql -uroot -e \
  "CREATE USER 'zigtest'@'%' IDENTIFIED WITH mysql_native_password BY 'zig_mysql_test'; GRANT ALL ON zigtest.* TO 'zigtest'@'%';"
zig build integration
python3 -u integration/stall_server.py > "/tmp/zig-mysql-stall-$prefix.log" 2>&1 &
stall_pid="$!"
sleep 0.5
if ! kill -0 "$stall_pid" 2>/dev/null; then
  cat "/tmp/zig-mysql-stall-$prefix.log" >&2
  exit 1
fi
timeout 15s zig build timeout-integration
kill "$stall_pid" >/dev/null 2>&1 || true
stall_pid=""
rm -f "/tmp/zig-mysql-stall-$prefix.log"
# Exercise bounded concurrency and forced connection termination against MySQL.
timeout 120s zig build stress-integration
# Exercise multiple waves of concurrent operations and forced socket kills.
SOAK_METRICS_PATH="$soak_report" timeout 50s bash integration/soak.sh 12
# The CI smoke must NEVER qualify as 24-hour release acceptance. A broken
# evidence parser (exit code 2) fails the test; only policy rejection (1) is OK.
gate_result=0
python3 integration/release_gate.py \
  --report "$soak_report" \
  --policy docs/production-soak-policy.json \
  --expected-sha "$(git rev-parse HEAD)" && gate_result=0 || gate_result=$?
if [[ "$gate_result" -ne 1 ]]; then
  echo "CI short soak release gate expected rejection 1; got $gate_result" >&2
  exit 1
fi
echo "Short CI soak was correctly refused by 24-hour production release gate"
# Restart the disposable MySQL process to ensure fresh sessions recover.
docker restart "$container80" >/dev/null
wait_mysql "$container80"
timeout 120s zig build stress-integration
# Run the reproducible pool benchmark while MySQL 8.0 is available. GitHub
# runner measurements are diagnostic only; do not use as fixed performance SLAs.
if [[ "$(uname -s)" == Linux ]]; then
  timeout 90s zig build -Doptimize=ReleaseFast bench
else
  zig build -Doptimize=ReleaseFast bench
fi

if [[ "$(uname -s)" == Linux ]]; then
  mkdir -p "$socket_dir"
  chmod 777 "$socket_dir"
  zig test --test-no-exec -femit-bin="$binary" \
    --dep zig_mysql -Mroot=integration/inside_socket.zig -lssl -lcrypto -lc -Mzig_mysql=src/root.zig
  chmod 755 "$binary"
fi

for entry in "84 mysql:8.4.11" "97 mysql:9.7.1"; do
  read -r suffix image <<< "$entry"
  if [[ "$(uname -s)" != Linux && "$suffix" == 97 ]]; then continue; fi
  name="$prefix-$suffix"
  docker_args=(-e MYSQL_ROOT_PASSWORD=zig_mysql_test -e MYSQL_DATABASE=zigtest)
  if [[ "$suffix" == 84 ]]; then docker_args+=(-p 127.0.0.1:33307:3306); fi
  if [[ "$(uname -s)" == Linux ]]; then docker_args+=(-v "$socket_dir:/var/run/mysqld"); fi
  docker run --name "$name" "${docker_args[@]}" -d "$image" >/dev/null
  wait_mysql "$name"
  if [[ "$suffix" == 84 ]]; then
    docker cp "$name":/var/lib/mysql/ca.pem "$ca_file"
    zig build tls-integration
  fi
  if [[ "$(uname -s)" == Linux ]]; then
    "$binary"
  fi
  docker rm -f "$name" >/dev/null
done

# Run a disposable binlog-replicated primary/replica drill, then manually
# fence and promote the replica and verify the writer-only pool.
timeout 300s bash integration/replication_run.sh

# Independently validate the classic protocol against supported MariaDB
# families. Use the upstream MariaDB image's own initialization variables.
for mariadb_tag in "10.11" "11.4"; do
  docker run --name "$mariadb_container"     -e MARIADB_ROOT_PASSWORD=zig_mysql_test     -e MARIADB_DATABASE=zigtest     -e MARIADB_USER=zigtest     -e MARIADB_PASSWORD=zig_mysql_test     -p 127.0.0.1:33308:3306 -d "mariadb:$mariadb_tag" >/dev/null

  ready=0
  for _ in $(seq 1 90); do
    if docker exec -e MYSQL_PWD=zig_mysql_test "$mariadb_container" mariadb -uroot -N -e "SELECT 1" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then
    docker logs "$mariadb_container" >&2
    exit 1
  fi

  echo "MariaDB $mariadb_tag integration..."
  zig build mariadb-integration
  docker rm -f "$mariadb_container" >/dev/null
done
