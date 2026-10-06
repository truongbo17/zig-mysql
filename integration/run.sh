#!/usr/bin/env bash
set -euo pipefail

# Disposable integration matrix. Requires Docker and Zig 0.16 or 0.17.
prefix="zig-mysql-test-$$"
container80="$prefix-80"
container84="$prefix-84"
container97="$prefix-97"
binary="$(mktemp -t zig-mysql-socket-test.XXXXXX)"
cleanup() {
  docker rm -f "$container80" "$container84" "$container97" >/dev/null 2>&1 || true
  rm -f "$binary"
}
trap cleanup EXIT

wait_mysql() {
  local name="$1"
  for _ in $(seq 1 90); do
    if docker exec -e MYSQL_PWD=zig_mysql_test "$name" mysql -uroot -N -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2
  return 1
}

docker run --name "$container80" -e MYSQL_ROOT_PASSWORD=zig_mysql_test \
  -e MYSQL_DATABASE=zigtest -p 127.0.0.1:33306:3306 -d mysql:8.0 >/dev/null
wait_mysql "$container80"
docker exec -e MYSQL_PWD=zig_mysql_test "$container80" mysql -uroot -e \
  "CREATE USER 'zigtest'@'%' IDENTIFIED WITH mysql_native_password BY 'zig_mysql_test'; GRANT ALL ON zigtest.* TO 'zigtest'@'%';"
zig build integration

arch="$(docker info --format '{{.Architecture}}')"
case "$arch" in
  x86_64|amd64) target=x86_64-linux ;;
  aarch64|arm64) target=aarch64-linux ;;
  *) echo "Unsupported Docker architecture: $arch" >&2; exit 1 ;;
esac
zig test --test-no-exec -target "$target" -femit-bin="$binary" \
  --dep zig_mysql -Mroot=integration/inside_socket.zig -Mzig_mysql=src/root.zig
chmod 755 "$binary"

for entry in "84 mysql:8.4" "97 mysql:9.7"; do
  read -r suffix image <<< "$entry"
  name="$prefix-$suffix"
  docker run --name "$name" -e MYSQL_ROOT_PASSWORD=zig_mysql_test \
    -e MYSQL_DATABASE=zigtest -d "$image" >/dev/null
  wait_mysql "$name"
  docker cp "$binary" "$name":/tmp/zig-mysql-socket-test
  docker exec "$name" /tmp/zig-mysql-socket-test
done
