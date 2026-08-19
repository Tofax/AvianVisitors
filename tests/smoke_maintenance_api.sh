#!/usr/bin/env bash
# Run inside a disposable Debian container with the repository at /source.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

cat >/tmp/maintenance-control-test <<'EOF'
#!/bin/sh
printf '{"ok":true,"action":"%s","state":"queued"}\n' "$1"
EOF
chmod 0755 /tmp/maintenance-control-test
mkdir -p /tmp/maintenance-api-bin
cat >/tmp/maintenance-api-bin/sudo <<'EOF'
#!/bin/sh
[ "${1:-}" = -n ] && shift
exec "$@"
EOF
chmod 0755 /tmp/maintenance-api-bin/sudo
export PATH="/tmp/maintenance-api-bin:$PATH"

AV_MAINTENANCE_CONTROL=/tmp/maintenance-control-test php -S 127.0.0.1:8898 -t /source \
  >/tmp/maintenance-api-server.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT

for _ in 1 2 3 4 5; do
  curl -fsS http://127.0.0.1:8898/avian/api/maintenance.php >/tmp/maintenance-api-body 2>/dev/null && break
  sleep 1
done
grep -q '"action":"status"' /tmp/maintenance-api-body || fail "local GET status"

code=$(curl -sS -o /tmp/maintenance-api-body -w '%{http_code}' \
  -H 'X-Forwarded-For: 203.0.113.8' http://127.0.0.1:8898/avian/api/maintenance.php)
[ "$code" = 401 ] || fail "forwarded request guard"

code=$(curl -sS -o /tmp/maintenance-api-body -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  http://127.0.0.1:8898/avian/api/maintenance.php)
[ "$code" = 403 ] || fail "action header guard"

code=$(curl -sS -o /tmp/maintenance-api-body -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data '{"action":"update"}' http://127.0.0.1:8898/avian/api/maintenance.php)
[ "$code" = 400 ] || fail "confirmation guard"

code=$(curl -sS -o /tmp/maintenance-api-body -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data '{"action":"update","confirm":"update-station"}' \
  http://127.0.0.1:8898/avian/api/maintenance.php)
[ "$code" = 200 ] || fail "confirmed update"
grep -q '"action":"update"' /tmp/maintenance-api-body || fail "fixed action routing"

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
trap - EXIT
AV_REQUIRE_AUTH=1 AV_ADMIN_PASSWORD=testpass \
  AV_MAINTENANCE_CONTROL=/tmp/maintenance-control-test \
  php -S 127.0.0.1:8897 -t /source >/tmp/maintenance-auth-server.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5; do
  code=$(curl -sS -o /tmp/maintenance-api-body -w '%{http_code}' \
    http://127.0.0.1:8897/avian/api/maintenance.php) && [ "$code" = 401 ] && break
  sleep 1
done
[ "$code" = 401 ] || fail "configured auth gate"
curl -fsS -H 'Authorization: Basic YmlyZG5ldDp0ZXN0cGFzcw==' \
  http://127.0.0.1:8897/avian/api/maintenance.php >/tmp/maintenance-api-body
grep -q '"action":"status"' /tmp/maintenance-api-body || fail "authenticated status"

echo 'maintenance api smoke: ok'
