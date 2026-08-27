#!/usr/bin/env bash
# Run as root with real Caddy in a disposable Debian container.

set -euo pipefail
IFS=$'\n\t'

fail() {
  echo "FAIL: $*" >&2
  [ ! -f /tmp/avian-live-caddy.log ] || tail -n 80 /tmp/avian-live-caddy.log >&2
  exit 1
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fail "test must run as root"
for command in caddy curl php; do
  command -v "$command" >/dev/null || fail "$command is required"
done

test_root=$(mktemp -d)
site=$test_root/site
auth_dir=/var/lib/avian-visitors
admin=/usr/local/sbin/avian-admin-control
caddy_pid=''
toggle_pid=''
stream_backend_pid=''
listener_pid=''
cleanup() {
  [ -z "$listener_pid" ] || kill "$listener_pid" 2>/dev/null || true
  [ -z "$toggle_pid" ] || kill "$toggle_pid" 2>/dev/null || true
  [ -z "$stream_backend_pid" ] || kill "$stream_backend_pid" 2>/dev/null || true
  [ -z "$caddy_pid" ] || kill "$caddy_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT

id caddy >/dev/null 2>&1 \
  || useradd --system --no-create-home --shell /usr/sbin/nologin caddy
id bird >/dev/null 2>&1 || useradd --create-home --shell /bin/bash bird
mkdir -p "$site" /home/bird/BirdNET-Pi/.git /etc/birdnet /etc/caddy "$auth_dir"
cat >/etc/birdnet/birdnet.conf <<EOF
BIRDNET_USER=bird
EXTRACTED=$site
EOF
printf 'shell\n' >"$site/index.html"
install -o root -g root -m 0600 /dev/null "$auth_dir/admin-auth.lock"
legacy_hash='$2y$14$FJs8skDlFXw6UEyzPutTQuQBPcFdy0iyGDrL3silEC/X6CwX7aOhi'
printf 'v1\t0\t0\t%s\n' "$legacy_hash" >"$auth_dir/admin-auth.state"
chown root:caddy "$auth_dir/admin-auth.state"
chmod 0640 "$auth_dir/admin-auth.state"
printf 'v1\n' >"$auth_dir/admin-auth.initialized"
chmod 0400 "$auth_dir/admin-auth.initialized"

install -o root -g root -m 0755 /source/scripts/admin_control.sh "$admin"
install -o root -g root -m 0755 /source/scripts/update_caddyfile.sh \
  /usr/local/sbin/avian-caddy-refresh

cat >"$test_root/stream_backend.php" <<'PHP'
<?php
ignore_user_abort(false);
header('Content-Type: audio/mpeg');
for ($index = 0; $index < 1200 && !connection_aborted(); $index++) {
    echo "audio-frame\n";
    flush();
    usleep(50000);
}
PHP

cat >"$test_root/toggle_backend.php" <<'PHP'
<?php
$pipes = [];
$process = proc_open(
    ['/usr/local/sbin/avian-admin-control', 'lan-auth-set-stdin', '1'],
    [['pipe', 'r'], ['pipe', 'w'], ['pipe', 'w']],
    $pipes
);
if (!is_resource($process)) {
    http_response_code(500);
    exit;
}
fwrite($pipes[0], "legacy-safe\0");
fclose($pipes[0]);
$body = stream_get_contents($pipes[1]);
$error = stream_get_contents($pipes[2]);
fclose($pipes[1]);
fclose($pipes[2]);
$status = proc_close($process);
http_response_code($status === 0 ? 200 : 500);
header('Content-Type: application/json');
header('Set-Cookie: rebound=1; Path=/; HttpOnly; SameSite=Strict');
echo $status === 0 ? $body : $error;
PHP

cat >/usr/local/sbin/avian-test-start-stream <<EOF
#!/bin/sh
# systemd does not pass the caller's auth-state lock into a restarted unit.
# Match that boundary in the fake service manager before forking the backend.
exec 9>&-
php -d output_buffering=0 -S 127.0.0.1:8000 "$test_root/stream_backend.php" \
  >/tmp/avian-stream-backend.log 2>&1 &
echo \$! >/tmp/avian-stream-backend.pid
EOF
chmod 0755 /usr/local/sbin/avian-test-start-stream

cat >/usr/bin/systemctl <<'EOF'
#!/bin/sh
set -eu
case "$*" in
  'is-active --quiet caddy')
    [ -s /tmp/avian-live-caddy.pid ] && kill -0 "$(cat /tmp/avian-live-caddy.pid)"
    ;;
  'reload caddy')
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    ;;
  'start caddy') exit 0 ;;
  'is-active --quiet icecast2')
    [ ! -e /tmp/avian-icecast-report-inactive ] || exit 3
    [ -s /tmp/avian-stream-backend.pid ] \
      && kill -0 "$(cat /tmp/avian-stream-backend.pid)"
    ;;
  'try-restart icecast2')
    old=$(cat /tmp/avian-stream-backend.pid)
    kill "$old"
    wait "$old" 2>/dev/null || true
    /usr/local/sbin/avian-test-start-stream
    ;;
  'stop icecast2')
    [ ! -e /tmp/avian-icecast-report-inactive ] || exit 0
    kill "$(cat /tmp/avian-stream-backend.pid)" 2>/dev/null || true
    ;;
  'kill --kill-who=all --signal=KILL icecast2')
    kill -KILL "$(cat /tmp/avian-stream-backend.pid)" 2>/dev/null || true
    ;;
  'start icecast2') /usr/local/sbin/avian-test-start-stream ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 /usr/bin/systemctl

cat >/etc/caddy/avian-site-overlay.caddy <<'EOF'
handle /toggle {
  reverse_proxy 127.0.0.1:9001
}
EOF
chown root:caddy /etc/caddy/avian-site-overlay.caddy
chmod 0640 /etc/caddy/avian-site-overlay.caddy

/usr/local/sbin/avian-test-start-stream
stream_backend_pid=$(cat /tmp/avian-stream-backend.pid)
php -S 127.0.0.1:9001 "$test_root/toggle_backend.php" \
  >/tmp/avian-toggle-backend.log 2>&1 &
toggle_pid=$!
for _ in $(seq 1 50); do
  : >/tmp/avian-stream-ready.out
  curl -sS --max-time 0.2 http://127.0.0.1:8000/ \
    >/tmp/avian-stream-ready.out 2>/dev/null || true
  [ -s /tmp/avian-stream-ready.out ] && break
  sleep 0.1
done
[ -s /tmp/avian-stream-ready.out ] || fail "stream backend did not start"

# First render sees inactive Caddy. The fake start accepts the validated file;
# the test then runs that exact generated file as a foreground Caddy process.
/usr/local/sbin/avian-caddy-refresh >/tmp/avian-first-render.log 2>&1
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile \
  >/tmp/avian-live-caddy.log 2>&1 &
caddy_pid=$!
echo "$caddy_pid" >/tmp/avian-live-caddy.pid
for _ in $(seq 1 50); do
  if curl -fsS --max-time 1 http://127.0.0.1/ >/dev/null 2>&1; then break; fi
  sleep 0.1
done
curl -fsS http://127.0.0.1/ >/dev/null || fail "Caddy did not start"

# Client B opens the live microphone route before Client A enables policy.
: >/tmp/avian-stream-preflight.out
curl -sS --no-buffer --max-time 1 -D /tmp/avian-stream-preflight.headers \
  http://127.0.0.1/stream >/tmp/avian-stream-preflight.out \
  2>/tmp/avian-stream-preflight.err || true
[ -s /tmp/avian-stream-preflight.out ] || fail "stream preflight failed: $(tr '\n' ' ' </tmp/avian-stream-preflight.headers) $(cat /tmp/avian-stream-preflight.err)"
curl -sS --no-buffer --max-time 30 http://127.0.0.1/stream \
  >/tmp/avian-live-listener.out 2>/tmp/avian-live-listener.err &
listener_pid=$!
for _ in $(seq 1 50); do
  [ -s /tmp/avian-live-listener.out ] && break
  sleep 0.1
done
[ -s /tmp/avian-live-listener.out ] || fail "live listener did not receive audio"

code=$(curl -sS --max-time 20 -D /tmp/avian-toggle-headers \
  -o /tmp/avian-toggle-body -w '%{http_code}' http://127.0.0.1/toggle)
[ "$code" = 200 ] || fail "initiating request returned $code"
grep -Eiq '^Set-Cookie:[[:space:]]*rebound=1' /tmp/avian-toggle-headers \
  || fail "initiating request lost its rebound cookie"
grep -Fq '"lan_auth":1' /tmp/avian-toggle-body \
  || fail "root policy transition did not finish"

ended=0
for _ in $(seq 1 50); do
  if ! kill -0 "$listener_pid" 2>/dev/null; then ended=1; break; fi
  sleep 0.1
done
[ "$ended" = 1 ] || fail "existing live listener did not reach EOF"
wait "$listener_pid" 2>/dev/null || true
listener_pid=''
[ "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/stream)" = 404 ] \
  || fail "new live audio request was not closed"
[ "$(cut -f2 "$auth_dir/admin-auth.state")" = 1 ] \
  || fail "authoritative policy was not committed"
[ "$(stat -c '%U:%G:%a:%h' /etc/caddy/Caddyfile)" = root:caddy:640:1 ] \
  || fail "generated Caddyfile metadata is unsafe"

# A failed or inactive unit can still retain a backend process in its cgroup.
# The cutoff must send the kill even when is-active reports false.
printf 'legacy-safe\0' | "$admin" lan-auth-set-stdin 0 >/tmp/avian-disable-body
stream_backend_pid=$(cat /tmp/avian-stream-backend.pid)
curl -sS --no-buffer --max-time 30 http://127.0.0.1/stream \
  >/tmp/avian-inactive-listener.out 2>/tmp/avian-inactive-listener.err &
listener_pid=$!
for _ in $(seq 1 50); do
  [ -s /tmp/avian-inactive-listener.out ] && break
  sleep 0.1
done
[ -s /tmp/avian-inactive-listener.out ] \
  || fail "inactive-unit listener did not receive audio"
touch /tmp/avian-icecast-report-inactive
code=$(curl -sS --max-time 20 -D /tmp/avian-inactive-toggle-headers \
  -o /tmp/avian-inactive-toggle-body -w '%{http_code}' http://127.0.0.1/toggle)
[ "$code" = 200 ] || fail "inactive-unit transition returned $code"
ended=0
for _ in $(seq 1 50); do
  if ! kill -0 "$listener_pid" 2>/dev/null; then ended=1; break; fi
  sleep 0.1
done
[ "$ended" = 1 ] || fail "inactive-unit live listener did not reach EOF"
wait "$listener_pid" 2>/dev/null || true
listener_pid=''
[ ! -s /tmp/avian-stream-backend.pid ] \
  || ! kill -0 "$(cat /tmp/avian-stream-backend.pid)" 2>/dev/null \
  || fail "inactive Icecast cgroup process survived the cutoff"
[ "$(cut -f2 "$auth_dir/admin-auth.state")" = 1 ] \
  || fail "inactive-unit policy transition was not committed"

echo "Caddy live transition smoke: ok"
