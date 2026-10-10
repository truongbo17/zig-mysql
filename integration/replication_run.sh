#!/usr/bin/env bash
set -euo pipefail

# Disposable MySQL 8.0 primary/replica with binary-log file-position replication.
# Manual promotion is deliberate: this is NOT quorum-based HA or split-brain fencing.
prefix="zig-mysql-repl-$$"
network="$prefix-net"
primary="$prefix-primary"
replica="$prefix-replica"
cleanup() {
  docker rm -f "$primary" "$replica" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_db() {
  local name="$1"
  for _ in $(seq 1 90); do
    if docker exec -e MYSQL_PWD=zig_mysql_test "$name" mysql -uroot -N -e "SELECT 1" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  docker logs "$name" >&2
  return 1
}
sql() {
  docker exec -e MYSQL_PWD=zig_mysql_test "$1" mysql -uroot -N -B -e "$2"
}

docker network create "$network" >/dev/null
docker run --name "$primary" --network "$network" \
  -e MYSQL_ROOT_PASSWORD=zig_mysql_test -e MYSQL_DATABASE=zigtest \
  -e MYSQL_USER=zigtest -e MYSQL_PASSWORD=zig_mysql_test \
  -p 127.0.0.1:33312:3306 -d mysql:8.0.46 \
  --server-id=41 --log-bin=mysql-bin --binlog-format=ROW >/dev/null
docker run --name "$replica" --network "$network" \
  -e MYSQL_ROOT_PASSWORD=zig_mysql_test -e MYSQL_DATABASE=zigtest \
  -e MYSQL_USER=zigtest -e MYSQL_PASSWORD=zig_mysql_test \
  -p 127.0.0.1:33313:3306 -d mysql:8.0.46 \
  --server-id=42 --log-bin=mysql-bin --relay-log=relay-bin >/dev/null
wait_db "$primary"
wait_db "$replica"
# Use the same test-only MySQL 8.0 mysql_native_password fixture as the
# baseline MySQL integration suite. Never send a full caching_sha2 password
# over unencrypted TCP; production users should configure verified TLS.
sql "$primary" "ALTER USER 'zigtest'@'%' IDENTIFIED WITH mysql_native_password BY 'zig_mysql_test';"
sql "$replica" "ALTER USER 'zigtest'@'%' IDENTIFIED WITH mysql_native_password BY 'zig_mysql_test';"

sql "$primary" "CREATE USER 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'zig_mysql_test'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';"
read -r binlog pos _ < <(sql "$primary" "SHOW MASTER STATUS")
if [[ -z "${binlog:-}" || ! "${pos:-}" =~ ^[0-9]+$ ]]; then
  echo "Primary binary-log status unavailable" >&2
  exit 1
fi
sql "$replica" "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$primary', SOURCE_PORT=3306, SOURCE_USER='repl', SOURCE_PASSWORD='zig_mysql_test', SOURCE_LOG_FILE='$binlog', SOURCE_LOG_POS=$pos, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;"
sql "$primary" "CREATE TABLE zigtest.failover_probe(id INT PRIMARY KEY, note VARCHAR(32)); INSERT INTO zigtest.failover_probe VALUES(1,'replicated');"

replicated=0
for _ in $(seq 1 90); do
  if [[ "$(sql "$replica" "SELECT COUNT(*) FROM zigtest.failover_probe WHERE id=1 AND note='replicated'" 2>/dev/null || :)" == "1" ]]; then
    replicated=1
    break
  fi
  sleep 1
done
if [[ "$replicated" != "1" ]]; then
  sql "$replica" "SHOW REPLICA STATUS\\G" >&2 || true
  echo "Replication did not catch up to inserted marker" >&2
  exit 1
fi
sql "$replica" "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;"
echo "Real MySQL replication before promotion: replica is read-only"
REPLICATION_PHASE=before zig build replication-integration

# No connection is allowed to the former primary after it is stopped.
# Explicit, *manual* promotion after replication caught up.
docker stop "$primary" >/dev/null
sql "$replica" "STOP REPLICA; RESET REPLICA ALL; SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
echo "Real MySQL replication after manual promotion: former primary stopped"
REPLICATION_PHASE=after zig build replication-integration
