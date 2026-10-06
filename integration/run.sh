#!/usr/bin/env bash
set -euo pipefail

# Disposable integration matrix. Requires Docker and Zig 0.16 or 0.17.
prefix="zig-mysql-test-$$"
container80="$prefix-80"
container84="$prefix-84"
container97="$prefix-97"
binary="$(mktemp -t zig-mysql-socket-test.XXXXXX)"
ca_file=/tmp/zig-mysql-test-ca.pem
cleanup() {
  docker rm -f "$container80" "$container84" "$container97" >/dev/null 2>&1 || true
  rm -f "$binary"
  rm -f "$ca_file"
}
trap cleanup EXIT

wait_mysql() {
  local name="$1"
  for _ in $(seq 1 90); do
    if docker logs "$name" 2>&1 | rg -q 'MySQL init process done. Ready for start up.' && \
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

if [[ "$(uname -s)" == Linux ]]; then
  zig test --test-no-exec -femit-bin="$binary" \
    --dep zig_mysql -Mroot=integration/inside_socket.zig -lssl -lcrypto -lc -Mzig_mysql=src/root.zig
  chmod 755 "$binary"
fi

for entry in "84 mysql:8.4.11" "97 mysql:9.7.1"; do
  read -r suffix image <<< "$entry"
  if [[ "$(uname -s)" != Linux && "$suffix" == 97 ]]; then continue; fi
  name="$prefix-$suffix"
  port_args=()
  if [[ "$suffix" == 84 ]]; then port_args=(-p 127.0.0.1:33307:3306); fi
  docker run --name "$name" -e MYSQL_ROOT_PASSWORD=zig_mysql_test \
    -e MYSQL_DATABASE=zigtest "${port_args[@]}" -d "$image" >/dev/null
  wait_mysql "$name"
  if [[ "$suffix" == 84 ]]; then
    docker cp "$name":/var/lib/mysql/ca.pem "$ca_file"
    zig build tls-integration
  fi
  if [[ "$(uname -s)" == Linux ]]; then
    docker cp "$binary" "$name":/tmp/zig-mysql-socket-test
    docker exec "$name" /tmp/zig-mysql-socket-test
  fi
done
