#!/usr/bin/env bash
# Run as root in a disposable Debian container with the repository at /source.

set -euo pipefail
IFS=$'\n\t'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_failure() {
  local label=$1 expected=$2
  shift 2
  if "$@" >/tmp/avian-admin-failure.out 2>&1; then
    fail "$label unexpectedly succeeded"
  fi
  grep -Fq "$expected" /tmp/avian-admin-failure.out \
    || fail "$label returned the wrong error: $(cat /tmp/avian-admin-failure.out)"
}

state_field() {
  cut -f"$1" /var/lib/avian-visitors/admin-auth.state
}

loaded_field() {
  cut -f"$1" /tmp/avian-caddy-loaded.state
}

wait_for_crash_barrier() {
  local label=$1
  for _ in $(seq 1 100); do
    [ -s /tmp/avian-caddy-refresh-parent ] \
      && [ -e /tmp/avian-caddy-refresh-crash-ready ] \
      && return 0
    sleep 0.1
  done
  fail "$label did not reach the Caddy crash barrier"
}

end_crashed_action() {
  local action_pid=$1 helper_pid='' parent_pid
  parent_pid=$(cat /tmp/avian-caddy-refresh-parent)
  [ "$parent_pid" != 1 ] && [ "$parent_pid" != "$BASHPID" ] \
    || fail "crash barrier resolved the test runner instead of the admin action"
  if [ -s /tmp/avian-caddy-refresh-child ]; then
    helper_pid=$(cat /tmp/avian-caddy-refresh-child)
    kill -KILL "$helper_pid" 2>/dev/null || true
  fi
  kill -KILL "$parent_pid" 2>/dev/null || true
  wait "$action_pid" 2>/dev/null || true
  rm -f /tmp/avian-caddy-refresh-parent /tmp/avian-caddy-refresh-child \
    /tmp/avian-caddy-refresh-crash-ready \
    /tmp/avian-caddy-refresh-stop-before \
    /tmp/avian-caddy-refresh-stop-before-live \
    /tmp/avian-caddy-refresh-stop-after
}

password_stdin() {
  local password=$1
  shift
  printf '%s\0' "$password" | "$@"
}

password_pair_stdin() {
  local current=$1 next=$2
  shift 2
  printf '%s\0%s\0' "$current" "$next" | "$@"
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fail "test must run as root"
[ -r /source/scripts/admin_control.sh ] || fail "repository is not mounted at /source"

birdnet_user=aviantest
birdnet_home=/home/$birdnet_user
repo=$birdnet_home/BirdNET-Pi
conf=$repo/birdnet.conf
admin=/usr/local/sbin/avian-admin-control
legacy_password='mésange!'
new_password=BirdPassword12

id caddy >/dev/null 2>&1 \
  || useradd --system --no-create-home --shell /usr/sbin/nologin caddy
id "$birdnet_user" >/dev/null 2>&1 \
  || useradd --create-home --shell /bin/bash "$birdnet_user"
usermod -a -G "$birdnet_user" caddy

mkdir -p \
  "$repo/.git" \
  "$repo/avian/api" \
  "$repo/avian/assets/illustrations" \
  "$repo/avian/assets/references" \
  "$repo/avian/frontend" \
  "$repo/scripts" \
  /etc/birdnet \
  /etc/sudoers.d
cp /source/avian/api/admin-state.php "$repo/avian/api/admin-state.php"
cp /source/avian/api/admin-auth.php "$repo/avian/api/admin-auth.php"
cp /source/avian/api/menu.php "$repo/avian/api/menu.php"
cp /source/avian/api/config.php "$repo/avian/api/config.php"
cp /source/avian/api/birdnet-status.php "$repo/avian/api/birdnet-status.php"
cp /source/homepage/views.php "$repo/views.php"
cp /source/scripts/common.php "$repo/scripts/common.php"
printf '{}\n' >"$repo/avian/frontend/dims.json"
printf '{}\n' >"$repo/avian/frontend/masks.json"
printf '##start\n##end\n' >"$repo/scripts/disk_check_exclude.txt"
printf '<?php echo "RECORDINGS_VIEW_OK"; ?>\n' >"$repo/play.php"
printf 'body {}\n' >"$repo/style.css"
cat >"$conf" <<EOF
BIRDNET_USER=$birdnet_user
SITE_NAME="Before"
LATITUDE=1.0000
LONGITUDE=1.0000
COLOR_SCHEME=light
SILENCE_UPDATE_INDICATOR=1
CONFIDENCE=0.5
MAX_FILES_SPECIES=0
RTSP_STREAM="rtsp://camera-user:camera-password@192.0.2.10/live"
export CADDY_PWD="$legacy_password" # manually configured legacy password
EOF
ln -s "$conf" /etc/birdnet/birdnet.conf

install -o root -g root -m 0755 /source/scripts/admin_control.sh "$admin"
cat >/tmp/avian-noop-control <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 /tmp/avian-noop-control
for helper in \
  avian-archive-control \
  avian-maintenance-control \
  avian-update-control \
  avian-service-refresh \
  avian-link-webroot; do
  install -o root -g root -m 0755 /tmp/avian-noop-control "/usr/local/sbin/$helper"
done
cat >/usr/local/sbin/avian-caddy-refresh <<'EOF'
#!/bin/sh
set -eu
printf 'candidate=%s close=%s\n' \
  "${AVIAN_AUTH_STATE_CANDIDATE:-live}" "${AVIAN_CLOSE_STREAMS:-0}" \
  >>/tmp/avian-caddy-refresh.log
if [ -n "${AVIAN_AUTH_STATE_CANDIDATE:-}" ]; then
  case "$AVIAN_AUTH_STATE_CANDIDATE" in
    /var/lib/avian-visitors/.admin-auth.state.*) ;;
    *) exit 9 ;;
  esac
  [ -f "$AVIAN_AUTH_STATE_CANDIDATE" ] || exit 9
  state_source=$AVIAN_AUTH_STATE_CANDIDATE
else
  state_source=/var/lib/avian-visitors/admin-auth.state
fi
if [ -e /tmp/avian-caddy-refresh-stop-before ] \
  || { [ -e /tmp/avian-caddy-refresh-stop-before-live ] \
    && [ -z "${AVIAN_AUTH_STATE_CANDIDATE:-}" ]; }; then
  printf '%s\n' "$$" >/tmp/avian-caddy-refresh-child
  printf '%s\n' "$PPID" >/tmp/avian-caddy-refresh-parent
  touch /tmp/avian-caddy-refresh-crash-ready
  kill -STOP "$PPID"
  while [ -e /tmp/avian-caddy-refresh-stop-before ] \
    || [ -e /tmp/avian-caddy-refresh-stop-before-live ]; do sleep 1; done
fi
[ ! -e /tmp/avian-caddy-refresh-started ] \
  || printf 'started\n' >/tmp/avian-caddy-refresh-ready
[ ! -e /tmp/avian-caddy-refresh-slow ] || sleep 1
[ ! -e /tmp/avian-caddy-refresh-fail ] || exit 1
cp "$state_source" /tmp/avian-caddy-loaded.state
[ ! -e /tmp/avian-caddy-refresh-stop-after ] || {
  printf '%s\n' "$PPID" >/tmp/avian-caddy-refresh-parent
  touch /tmp/avian-caddy-refresh-crash-ready
  kill -STOP "$PPID"
}
[ ! -e /tmp/avian-caddy-refresh-status20 ] || exit 20
[ ! -e /tmp/avian-caddy-refresh-status21 ] || exit 21
EOF
chmod 0755 /usr/local/sbin/avian-caddy-refresh
chown root:root /usr/local/sbin/avian-caddy-refresh

/source/scripts/security_refresh.sh >/tmp/avian-security-refresh.out
grep -Fxq 'security refresh: ok' /tmp/avian-security-refresh.out \
  || fail "security refresh did not report success"

[ "$(stat -c '%U:%G:%a:%h' /var/lib/avian-visitors/admin-auth.lock)" = root:root:600:1 ] \
  || fail "admin state lock metadata is wrong"
[ "$(stat -c '%U:%G:%a:%h' /var/lib/avian-visitors/admin-auth.state)" = root:caddy:640:1 ] \
  || fail "admin state metadata is wrong"
[ "$(stat -c '%U:%G:%a:%h' /var/lib/avian-visitors/admin-auth.rate)" = root:caddy:660:1 ] \
  || fail "admin rate metadata is wrong"
grep -Fxq '{"version":1,"entries":{}}' /var/lib/avian-visitors/admin-auth.rate \
  || fail "admin rate state was not initialized canonically"
[ "$(stat -c '%U:%G:%a:%h' /var/lib/avian-visitors/admin-auth.initialized)" = root:root:400:1 ] \
  || fail "admin initialization marker metadata is wrong"
[ "$(state_field 1):$(state_field 2):$(state_field 3)" = 'v1:0:0' ] \
  || fail "migration did not initialize trusted mode at epoch zero"
verifier=$(state_field 4)
[[ "$verifier" =~ ^\$2y\$14\$[./A-Za-z0-9]{53}$ ]] \
  || fail "migration did not create a fixed-cost verifier"
printf '%s\0%s\0' "$verifier" "$legacy_password" | php -r '
  $parts = explode("\0", stream_get_contents(STDIN));
  exit(count($parts) === 3 && password_verify($parts[1], $parts[0]) ? 0 : 1);
' || fail "UTF-8 legacy password did not migrate"
grep -Fxq 'CADDY_PWD=""' "$conf" || fail "legacy plaintext password was not scrubbed"
! grep -Fq "$legacy_password" "$conf" || fail "legacy password bytes remained in config"
! grep -Eq '^[[:space:]]*export[[:space:]]+CADDY_PWD=' "$conf" \
  || fail "exported legacy password assignment remained in config"

# The Caddy marker is valid only for the exact trusted-mode epoch. A queued
# request from an older Caddy config must be rejected if policy becomes
# required between two authentication checks in the same PHP request.
LEGACY_PASSWORD="$legacy_password" php -r '
  $_SERVER["AVIAN_LEGACY_AUTH"] = "1";
  $_SERVER["AVIAN_LEGACY_AUTH_EPOCH"] = "0";
  require $argv[1] . "/scripts/common.php";
  $currentMarkerAccepted = is_authenticated();
  $_SERVER["AVIAN_LEGACY_AUTH_EPOCH"] = "stale";
  $_SERVER["PHP_AUTH_USER"] = "birdnet";
  $_SERVER["PHP_AUTH_PW"] = getenv("LEGACY_PASSWORD");
  $trustedFallbackAccepted = is_authenticated();
  $statePath = "/var/lib/avian-visitors/admin-auth.state";
  $required = "v1\t1\t1\t" . $argv[2] . "\n";
  $trusted = "v1\t0\t0\t" . $argv[2] . "\n";
  if (file_put_contents($statePath, $required, LOCK_EX) !== strlen($required)) {
    exit(2);
  }
  clearstatcache(true, $statePath);
  $requiredRejected = !is_authenticated();
  if (file_put_contents($statePath, $trusted, LOCK_EX) !== strlen($trusted)) {
    exit(3);
  }
  clearstatcache(true, $statePath);
  exit($currentMarkerAccepted && $trustedFallbackAccepted && $requiredRejected ? 0 : 1);
' "$repo" "$verifier" || fail "legacy auth did not track a same-request policy change"

# A retry after interruption between inode creation and content setup repairs
# the derived rate state atomically without changing authoritative auth state.
state_hash=$(sha256sum /var/lib/avian-visitors/admin-auth.state)
: >/var/lib/avian-visitors/admin-auth.rate
/source/scripts/security_refresh.sh >/tmp/avian-security-retry.out
grep -Fxq '{"version":1,"entries":{}}' /var/lib/avian-visitors/admin-auth.rate \
  || fail "security refresh did not repair empty rate state"
[ "$(sha256sum /var/lib/avian-visitors/admin-auth.state)" = "$state_hash" ] \
  || fail "rate recovery changed authoritative auth state"

state_hash=$(sha256sum /var/lib/avian-visitors/admin-auth.state)
printf 'CADDY_PWD="restored-old-password"\n' >>"$conf"
"$admin" auth-state-init >/tmp/avian-init-again.out
[ "$(sha256sum /var/lib/avian-visitors/admin-auth.state)" = "$state_hash" ] \
  || fail "routine initialization replaced authoritative state"
grep -Fxq 'CADDY_PWD=""' "$conf" || fail "routine initialization did not scrub restored plaintext"
! grep -Fq 'restored-old-password' "$conf" \
  || fail "routine initialization left restored password bytes in config"

grep -Fq '"version":3' < <("$admin" version) || fail "control version is not three"
expect_failure "Caddy username initialization" "web requests cannot initialize" \
  env SUDO_USER=caddy "$admin" auth-state-init
expect_failure "Caddy UID initialization" "web requests cannot initialize" \
  env SUDO_UID="$(id -u caddy)" "$admin" auth-state-init
expect_failure "Caddy username reset" "web requests cannot reset" \
  env SUDO_USER=caddy "$admin" password-reset-stdin <<<"ignored"
expect_failure "Caddy UID reset" "web requests cannot reset" \
  env SUDO_UID="$(id -u caddy)" "$admin" password-reset-stdin <<<"ignored"

# Start the real PHP endpoints with multiple workers so an old-cookie request
# can overlap the policy-changing request.
cat >"$repo/avian/stale-auth.php" <<'PHP'
<?php
touch('/tmp/avian-stale-ready');
while (!is_file('/tmp/avian-stale-release')) usleep(10000);
require __DIR__ . '/api/admin-auth.php';
avian_require_admin();
echo "ok\n";
PHP
cat >"$repo/avian/make-idle.php" <<'PHP'
<?php
require __DIR__ . '/api/admin-auth.php';
$state = avian_admin_state();
if (!avian_admin_session_valid($_SERVER, $state, false, true)) {
    http_response_code(401);
    exit;
}
$_SESSION[AVIAN_ADMIN_SESSION_SEEN_KEY] = time() - AVIAN_ADMIN_SESSION_IDLE_SECONDS - 1;
session_write_close();
echo "idle\n";
PHP
cat >"$repo/avian/delayed-idle.php" <<'PHP'
<?php
require __DIR__ . '/api/admin-auth.php';
$result = avian_idle_lock_admin_session($_SERVER);
touch('/tmp/avian-idle-ready');
while (!is_file('/tmp/avian-idle-release')) usleep(10000);
header('Content-Type: application/json');
echo json_encode($result);
PHP
cat >"$repo/avian/session-check.php" <<'PHP'
<?php
require __DIR__ . '/api/admin-auth.php';
if (!avian_admin_session_valid($_SERVER)) {
    http_response_code(401);
    exit;
}
echo "session ok\n";
PHP
cat >"$repo/avian/forced-menu.php" <<'PHP'
<?php
$_SERVER['AVIAN_DIRECT_LOCAL'] = '1';
$_SERVER['AVIAN_FORCE_AUTH'] = '1';
$_SERVER['HTTP_X_FORWARDED_FOR'] = $_SERVER['REMOTE_ADDR'];
$_SERVER['HTTP_X_FORWARDED_HOST'] = $_SERVER['HTTP_HOST'];
$_SERVER['HTTP_X_FORWARDED_PROTO'] = 'http';
require __DIR__ . '/api/menu.php';
PHP
cat >"$repo/avian/forced-config.php" <<'PHP'
<?php
$_SERVER['AVIAN_DIRECT_LOCAL'] = '1';
$_SERVER['AVIAN_FORCE_AUTH'] = '1';
$_SERVER['HTTP_X_FORWARDED_FOR'] = $_SERVER['REMOTE_ADDR'];
$_SERVER['HTTP_X_FORWARDED_HOST'] = $_SERVER['HTTP_HOST'];
$_SERVER['HTTP_X_FORWARDED_PROTO'] = 'http';
require __DIR__ . '/api/config.php';
PHP
chown -R "$birdnet_user:$birdnet_user" "$repo"
chmod 0640 "$conf"
sudo -u caddy env PHP_CLI_SERVER_WORKERS=4 php -S 127.0.0.1:8896 -t "$repo" \
  >/tmp/avian-admin-api-server.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  code=$(curl -sS -o /tmp/avian-menu-body -w '%{http_code}' \
    http://127.0.0.1:8896/avian/api/menu.php || true)
  [ "$code" = 200 ] && break
  sleep 0.3
done
[ "$code" = 200 ] || fail "admin API did not start"

# The public recordings dispatcher stays available without a configured
# password. File Manager and Adminer must never inherit that direct route.
saved_state=$(cat /var/lib/avian-visitors/admin-auth.state)
printf 'v1\t0\t0\t-\n' >/var/lib/avian-visitors/admin-auth.state
chown root:caddy /var/lib/avian-visitors/admin-auth.state
chmod 0640 /var/lib/avian-visitors/admin-auth.state
code=$(curl -sS -o /tmp/avian-view-body -w '%{http_code}' \
  'http://127.0.0.1:8896/views.php?view=Recordings')
[ "$code" = 200 ] && grep -Fq RECORDINGS_VIEW_OK /tmp/avian-view-body \
  || fail "trusted recordings view did not remain available"
for view in File Adminer; do
  code=$(curl -sS -o /tmp/avian-view-body -w '%{http_code}' \
    "http://127.0.0.1:8896/views.php?view=$view")
  [ "$code" = 401 ] || fail "blank-password dispatcher exposed $view"
done
printf '%s\n' "$saved_state" >/var/lib/avian-visitors/admin-auth.state
chown root:caddy /var/lib/avian-visitors/admin-auth.state
chmod 0640 /var/lib/avian-visitors/admin-auth.state
for view in File Adminer; do
  code=$(curl -sS -o /tmp/avian-view-body -w '%{http_code}' \
    "http://127.0.0.1:8896/views.php?view=$view")
  [ "$code" = 401 ] || fail "configured dispatcher exposed $view without proof"
  code=$(curl -sS -o /tmp/avian-view-body -w '%{http_code}' \
    -u "birdnet:$legacy_password" \
    "http://127.0.0.1:8896/views.php?view=$view")
  [ "$code" = 200 ] || fail "configured dispatcher rejected $view with proof"
done

curl -fsS -c /tmp/avian-cookie -u "birdnet:$legacy_password" \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php >/tmp/avian-menu-body \
  || fail "UTF-8 legacy password did not unlock the native UI"

# A confirmed-idle response can be delayed in transit until after another tab
# creates a fresh session. It must not carry an expiry for the shared cookie.
curl -fsS -b /tmp/avian-cookie http://127.0.0.1:8896/avian/make-idle.php \
  >/tmp/avian-make-idle-body || fail "could not prepare idle session"
rm -f /tmp/avian-idle-ready /tmp/avian-idle-release
curl -sS -D /tmp/avian-idle-headers -o /tmp/avian-idle-body \
  -b /tmp/avian-cookie http://127.0.0.1:8896/avian/delayed-idle.php &
idle_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e /tmp/avian-idle-ready ] && break
  sleep 0.1
done
[ -e /tmp/avian-idle-ready ] || fail "idle response did not reach its barrier"
curl -fsS -c /tmp/avian-cookie -u "birdnet:$legacy_password" \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php >/tmp/avian-menu-body \
  || fail "replacement login did not create a fresh session"
touch /tmp/avian-idle-release
wait "$idle_pid"
! grep -Eiq '^Set-Cookie:[[:space:]]*avian_admin=' /tmp/avian-idle-headers \
  || fail "delayed idle response emitted an expired admin cookie"
curl -fsS -b /tmp/avian-cookie http://127.0.0.1:8896/avian/session-check.php \
  >/tmp/avian-session-check || fail "fresh session failed after delayed idle response"
cp /tmp/avian-cookie /tmp/avian-cookie-old

hash_before=$(sha256sum /var/lib/avian-visitors/admin-auth.state)
for password in "$legacy_password" wrong; do
  code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
    -b /tmp/avian-cookie -u "birdnet:$password" \
    -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
    --data '{"lan_admin_auth":true}' \
    http://127.0.0.1:8896/avian/api/config.php)
  [ "$code" = 401 ] || fail "cached Basic header without marker changed policy"
done
[ "$(sha256sum /var/lib/avian-visitors/admin-auth.state)" = "$hash_before" ] \
  || fail "cached Basic request changed state"

code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -b /tmp/avian-cookie -u birdnet:wrong \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  -H 'X-Avian-Credential: 1' --data '{"lan_admin_auth":true}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 401 ] || fail "wrong marked credential changed policy"

rm -f /tmp/avian-stale-ready /tmp/avian-stale-release
curl -sS -D /tmp/avian-stale-headers -o /tmp/avian-stale-body \
  -b /tmp/avian-cookie-old http://127.0.0.1:8896/avian/stale-auth.php &
stale_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e /tmp/avian-stale-ready ] && break
  sleep 0.1
done
[ -e /tmp/avian-stale-ready ] || fail "stale auth request did not reach its barrier"

code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -b /tmp/avian-cookie -c /tmp/avian-cookie -u "birdnet:$legacy_password" \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  -H 'X-Avian-Credential: 1' --data '{"lan_admin_auth":true}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 200 ] || fail "marked UTF-8 credential did not enable policy: $(cat /tmp/avian-api-body)"
touch /tmp/avian-stale-release
wait "$stale_pid" || true
! grep -Eiq '^Set-Cookie:[[:space:]]*avian_admin=' /tmp/avian-stale-headers \
  || fail "stale request emitted a replacement or expired admin cookie"
curl -fsS -b /tmp/avian-cookie http://127.0.0.1:8896/avian/api/config.php \
  >/tmp/avian-api-body || fail "new policy session did not survive stale response"
for password in "$legacy_password" wrong; do
  code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
    -b /tmp/avian-cookie -u "birdnet:$password" \
    http://127.0.0.1:8896/avian/api/config.php)
  [ "$code" = 200 ] \
    || fail "unmarked cached Basic interfered with an ordinary session request"
done

code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -b /tmp/avian-cookie -X POST -H 'Content-Type: application/json' \
  -H 'X-Avian-Action: 1' --data '{"lan_admin_auth":false}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 401 ] || fail "session-only disable was accepted"
for password in "$legacy_password" wrong; do
  code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
    -b /tmp/avian-cookie -u "birdnet:$password" \
    -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
    --data '{"lan_admin_auth":false}' \
    http://127.0.0.1:8896/avian/api/config.php)
  [ "$code" = 401 ] \
    || fail "unmarked cached Basic header disabled policy"
done
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -b /tmp/avian-cookie -u birdnet:wrong \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  -H 'X-Avian-Credential: 1' --data '{"lan_admin_auth":false}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 401 ] || fail "wrong marked credential disabled policy"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -b /tmp/avian-cookie -c /tmp/avian-cookie -u "birdnet:$legacy_password" \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  -H 'X-Avian-Credential: 1' --data '{"lan_admin_auth":false}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 200 ] || fail "marked credential did not disable policy"

code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -b /tmp/avian-cookie -c /tmp/avian-cookie -u "birdnet:$legacy_password" \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  -H 'X-Avian-Credential: 1' --data "{\"admin_password\":\"$new_password\"}" \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 200 ] || fail "UTF-8 credential did not rotate to alphanumeric: $(cat /tmp/avian-api-body)"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -u "birdnet:$legacy_password" -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php)
[ "$code" = 401 ] || fail "old password remained valid after rotation"
curl -fsS -u "birdnet:$new_password" -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php >/tmp/avian-menu-body \
  || fail "new password did not unlock"

for unit in caddy php8.2-fpm php8.3-fpm php8.4-fpm; do
  code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
    "http://127.0.0.1:8896/avian/api/birdnet-status.php?action=restart&unit=$unit")
  [ "$code" = 400 ] || fail "$unit was restartable through its own HTTP request"
done

# Establish required mode first. Its same-policy cutoff guidance mentions SSH,
# but it is not a credential recovery failure. Keep the Access controls
# available and preserve the Icecast remediation.
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -u "birdnet:$new_password" -X POST -H 'Content-Type: application/json' \
  -H 'X-Avian-Action: 1' -H 'X-Avian-Credential: 1' \
  --data '{"lan_admin_auth":true}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 200 ] || fail "API setup did not establish required mode"
touch /tmp/avian-caddy-refresh-status20
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -u "birdnet:$new_password" -X POST -H 'Content-Type: application/json' \
  -H 'X-Avian-Action: 1' -H 'X-Avian-Credential: 1' \
  --data '{"lan_admin_auth":true}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 500 ] || fail "uncertain API stream cutoff returned $code"
grep -Fq '"reauth":false' /tmp/avian-api-body \
  || fail "same-policy stream cutoff incorrectly reported an epoch change"
grep -Fq 'sudo systemctl restart icecast2' /tmp/avian-api-body \
  || fail "same-policy stream cutoff lost its Icecast guidance"
grep -Fq 'reboot the station' /tmp/avian-api-body \
  || fail "uncertain API stream cutoff lost its remediation"
grep -Fq 'stream returns 404' /tmp/avian-api-body \
  || fail "uncertain API stream cutoff lost its verification step"
! grep -Fq '"recovery":true' /tmp/avian-api-body \
  || fail "stream remediation was misclassified as missing credentials"
rm -f /tmp/avian-caddy-refresh-status20
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -u "birdnet:$new_password" -X POST -H 'Content-Type: application/json' \
  -H 'X-Avian-Action: 1' -H 'X-Avian-Credential: 1' \
  --data '{"lan_admin_auth":true}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 200 ] || fail "same-policy API cutoff retry did not recover"

rm -f /var/lib/avian-visitors/admin-auth.initialized
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -u "birdnet:$new_password" -X POST -H 'Content-Type: application/json' \
  -H 'X-Avian-Action: 1' -H 'X-Avian-Credential: 1' \
  --data '{"lan_admin_auth":true}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 500 ] || fail "missing initialization marker returned $code"
grep -Fq '"recovery":true' /tmp/avian-api-body \
  || fail "credential initialization failure did not request SSH recovery"
printf 'v1\n' >/var/lib/avian-visitors/admin-auth.initialized
chown root:root /var/lib/avian-visitors/admin-auth.initialized
chmod 0400 /var/lib/avian-visitors/admin-auth.initialized

# Root transaction failure and retry behavior.
password_stdin "$new_password" "$admin" lan-auth-set-stdin 1 >/dev/null
old_epoch=$(state_field 3)
touch /tmp/avian-caddy-refresh-fail
expect_failure "disable refresh rollback" "protected access was restored" \
  password_stdin "$new_password" "$admin" lan-auth-set-stdin 0
rm -f /tmp/avian-caddy-refresh-fail
[ "$(state_field 2)" = 1 ] || fail "failed disable left policy open"
[ "$(state_field 3)" -eq $((old_epoch + 2)) ] \
  || fail "failed disable did not advance rollback epoch"

password_stdin "$new_password" "$admin" lan-auth-set-stdin 0 >/dev/null
state_hash=$(sha256sum /var/lib/avian-visitors/admin-auth.state)
touch /tmp/avian-caddy-refresh-fail
expect_failure "enable refresh rollback" "setting was not changed" \
  password_stdin "$new_password" "$admin" lan-auth-set-stdin 1
rm -f /tmp/avian-caddy-refresh-fail
[ "$(sha256sum /var/lib/avian-visitors/admin-auth.state)" = "$state_hash" ] \
  || fail "failed enable changed authoritative state"

touch /tmp/avian-caddy-refresh-status20
expect_failure "uncertain stream cutoff" "older live audio connection may remain" \
  password_stdin "$new_password" "$admin" lan-auth-set-stdin 1
rm -f /tmp/avian-caddy-refresh-status20
[ "$(state_field 2)" = 1 ] || fail "uncertain cutoff did not remain fail closed"
retry=$(password_stdin "$new_password" "$admin" lan-auth-set-stdin 1)
grep -Fq '"changed":false' <<<"$retry" || fail "protected-mode cutoff retry did not succeed"

password_stdin "$new_password" "$admin" lan-auth-set-stdin 0 >/dev/null
state_hash=$(sha256sum /var/lib/avian-visitors/admin-auth.state)
touch /tmp/avian-caddy-refresh-fail
expect_failure "password transition lock" "password was not changed" \
  password_pair_stdin "$new_password" AnotherPass12 "$admin" password-change-stdin
rm -f /tmp/avian-caddy-refresh-fail
[ "$(sha256sum /var/lib/avian-visitors/admin-auth.state)" = "$state_hash" ] \
  || fail "failed transition lock changed authoritative state"

expect_failure "short new password" "12 to 64" \
  password_pair_stdin "$new_password" ShortPass "$admin" password-change-stdin
password_pair_stdin "$new_password" AnotherPass12 "$admin" password-change-stdin >/dev/null
expect_failure "old password proof" "current admin password is incorrect" \
  password_stdin "$new_password" "$admin" lan-auth-set-stdin 1
new_password=AnotherPass12

# An interrupted in-place limiter update stays fail closed. The documented
# SSH password reset must repair it before the new credential becomes active.
printf '{"version":1' >/var/lib/avian-visitors/admin-auth.rate
password_stdin RecoveredPassword12 "$admin" password-reset-stdin >/dev/null
grep -Fxq '{"version":1,"entries":{}}' /var/lib/avian-visitors/admin-auth.rate \
  || fail "SSH password reset did not repair truncated rate state"
reset_verifier=$(state_field 4)
printf '%s\0%s\0' "$reset_verifier" RecoveredPassword12 | php -r '
  $parts = explode("\0", stream_get_contents(STDIN));
  exit(count($parts) === 3 && password_verify($parts[1], $parts[0]) ? 0 : 1);
' || fail "recovery password did not become authoritative"
new_password=RecoveredPassword12

# Enable applies a fail-closed Caddy candidate before it advances live state.
# A power-loss style stop at that boundary must leave Caddy stricter than the
# authoritative policy, and the exact retry must converge both copies.
rm -f /tmp/avian-caddy-refresh-parent /tmp/avian-caddy-refresh-child \
  /tmp/avian-caddy-refresh-crash-ready
touch /tmp/avian-caddy-refresh-stop-after
password_stdin "$new_password" "$admin" lan-auth-set-stdin 1 \
  >/tmp/avian-enable-crash.out 2>&1 &
crash_pid=$!
wait_for_crash_barrier "enable transition"
[ "$(state_field 2)" = 0 ] || fail "enable crash advanced live policy"
[ "$(loaded_field 2)" = 1 ] || fail "enable crash did not leave Caddy fail closed"
end_crashed_action "$crash_pid"
rm -f /var/lib/avian-visitors/.admin-auth.state.*
retry=$(password_stdin "$new_password" "$admin" lan-auth-set-stdin 1)
grep -Fq '"changed":true' <<<"$retry" || fail "enable crash retry did not converge"
cmp -s /var/lib/avian-visitors/admin-auth.state /tmp/avian-caddy-loaded.state \
  || fail "enable retry left Caddy and state split"

# Disable commits trusted mode first. If the process dies before Caddy reload,
# the old required Caddy policy remains closed. A same-policy retry must still
# render authoritative state instead of returning an unreconciled no-op.
touch /tmp/avian-caddy-refresh-stop-before
password_stdin "$new_password" "$admin" lan-auth-set-stdin 0 \
  >/tmp/avian-disable-crash.out 2>&1 &
crash_pid=$!
wait_for_crash_barrier "disable transition"
[ "$(state_field 2)" = 0 ] || fail "disable crash did not commit trusted state"
[ "$(loaded_field 2)" = 1 ] || fail "disable crash opened the old Caddy policy"
end_crashed_action "$crash_pid"
curl -fsS -c /tmp/avian-reconcile-cookie -u "birdnet:$new_password" \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/forced-menu.php >/tmp/avian-reconcile-menu \
  || fail "disable recovery could not create a forced-auth session"
curl -fsS -b /tmp/avian-reconcile-cookie \
  http://127.0.0.1:8896/avian/forced-config.php >/tmp/avian-reconcile-get \
  || fail "disable recovery could not read the saved policy"
grep -Fq '"policy_reconciliation_needed":true' /tmp/avian-reconcile-get \
  || fail "forced Caddy mismatch was not exposed to Settings"
code=$(curl -sS -o /tmp/avian-reconcile-post -w '%{http_code}' \
  -b /tmp/avian-reconcile-cookie -u "birdnet:$new_password" \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  -H 'X-Avian-Credential: 1' --data '{"lan_admin_auth":false}' \
  http://127.0.0.1:8896/avian/forced-config.php)
[ "$code" = 200 ] \
  || fail "same-value HTTP recovery failed: $(cat /tmp/avian-reconcile-post)"
cmp -s /var/lib/avian-visitors/admin-auth.state /tmp/avian-caddy-loaded.state \
  || fail "same-value HTTP recovery left Caddy and state split"

# Password rotation first installs a required-mode Caddy barrier. A crash at
# that boundary leaves live state unchanged and every legacy route closed.
state_hash=$(sha256sum /var/lib/avian-visitors/admin-auth.state)
touch /tmp/avian-caddy-refresh-stop-after
password_pair_stdin "$new_password" BarrierPassword12 \
  "$admin" password-change-stdin >/tmp/avian-password-barrier-crash.out 2>&1 &
crash_pid=$!
wait_for_crash_barrier "password transition lock"
[ "$(sha256sum /var/lib/avian-visitors/admin-auth.state)" = "$state_hash" ] \
  || fail "transition-lock crash changed authoritative password state"
[ "$(loaded_field 2)" = 1 ] \
  || fail "transition-lock crash did not close legacy Caddy routes"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -H 'Forwarded: for=198.51.100.2' -u "birdnet:$new_password" \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php)
[ "$code" = 200 ] || fail "transition lock rejected the still-authoritative password"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -H 'Forwarded: for=198.51.100.2' -u birdnet:BarrierPassword12 \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php)
[ "$code" = 401 ] || fail "transition lock activated the new password before state commit"
end_crashed_action "$crash_pid"
password_pair_stdin "$new_password" BarrierPassword12 \
  "$admin" password-change-stdin >/dev/null
new_password=BarrierPassword12
cmp -s /var/lib/avian-visitors/admin-auth.state /tmp/avian-caddy-loaded.state \
  || fail "transition-lock retry left Caddy and state split"

# If the process dies after state commit but before the final render, the
# transition Caddy remains required while native controls use the new proof.
# Retrying the same new password must install the final trusted-mode Caddy.
touch /tmp/avian-caddy-refresh-stop-before-live
password_pair_stdin "$new_password" CrashPassword12 \
  "$admin" password-change-stdin >/tmp/avian-password-state-crash.out 2>&1 &
crash_pid=$!
wait_for_crash_barrier "password state commit"
crash_verifier=$(state_field 4)
php -r 'exit(password_verify("CrashPassword12", $argv[1]) ? 0 : 1);' \
  "$crash_verifier" || fail "password crash did not commit the new verifier"
[ "$(state_field 2)" = 0 ] || fail "password crash changed final policy"
[ "$(loaded_field 2)" = 1 ] \
  || fail "password crash did not keep legacy Caddy locked"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -H 'Forwarded: for=198.51.100.2' -u "birdnet:$new_password" \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php)
[ "$code" = 401 ] || fail "native API retained the revoked password after state commit"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -H 'Forwarded: for=198.51.100.2' -u birdnet:CrashPassword12 \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php)
[ "$code" = 200 ] || fail "native API rejected the authoritative password after state commit"
end_crashed_action "$crash_pid"
retry=$(password_pair_stdin CrashPassword12 CrashPassword12 \
  "$admin" password-change-stdin)
grep -Fq '"changed":false' <<<"$retry" \
  || fail "same-password crash retry was not idempotent"
cmp -s /var/lib/avian-visitors/admin-auth.state /tmp/avian-caddy-loaded.state \
  || fail "password retry left Caddy and state split"
new_password=CrashPassword12

# SSH reset uses the same hard-close barrier and can converge by repeating the
# reset after an interruption between state commit and final Caddy render.
touch /tmp/avian-caddy-refresh-stop-before-live
password_stdin ResetCrashPass12 "$admin" password-reset-stdin \
  >/tmp/avian-reset-crash.out 2>&1 &
crash_pid=$!
wait_for_crash_barrier "password reset"
reset_crash_verifier=$(state_field 4)
php -r 'exit(password_verify("ResetCrashPass12", $argv[1]) ? 0 : 1);' \
  "$reset_crash_verifier" || fail "reset crash did not commit the new verifier"
[ "$(loaded_field 2)" = 1 ] \
  || fail "reset crash did not keep legacy Caddy locked"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -H 'Forwarded: for=198.51.100.2' -u birdnet:CrashPassword12 \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php)
[ "$code" = 401 ] || fail "native API retained the password revoked by reset"
code=$(curl -sS -o /tmp/avian-api-body -w '%{http_code}' \
  -H 'Forwarded: for=198.51.100.2' -u birdnet:ResetCrashPass12 \
  -X POST -H 'X-Avian-Credential: 1' \
  http://127.0.0.1:8896/avian/api/menu.php)
[ "$code" = 200 ] || fail "native API rejected the reset password"
end_crashed_action "$crash_pid"
password_stdin ResetCrashPass12 "$admin" password-reset-stdin >/dev/null
cmp -s /var/lib/avian-visitors/admin-auth.state /tmp/avian-caddy-loaded.state \
  || fail "reset retry left Caddy and state split"
new_password=ResetCrashPass12

# A required-mode password change can commit while an older audio listener is
# still uncertain. Repeating the now-current password must retry the cutoff.
password_stdin "$new_password" "$admin" lan-auth-set-stdin 1 >/dev/null
touch /tmp/avian-caddy-refresh-status20
expect_failure "password cutoff uncertainty" "older live audio connection may remain" \
  password_pair_stdin "$new_password" AudioRetryPass12 \
  "$admin" password-change-stdin
rm -f /tmp/avian-caddy-refresh-status20
new_password=AudioRetryPass12
retry=$(password_pair_stdin "$new_password" "$new_password" \
  "$admin" password-change-stdin)
grep -Fq '"changed":false' <<<"$retry" \
  || fail "same-password cutoff retry was not idempotent"
[ "$(tail -n 1 /tmp/avian-caddy-refresh.log)" = 'candidate=live close=1' ] \
  || fail "same-password retry did not request the required audio cutoff"

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
trap - EXIT

# The shared lock must serialize a slow policy transition with an ordinary
# config write so neither transaction can overwrite the other.
touch /tmp/avian-caddy-refresh-slow /tmp/avian-caddy-refresh-started
rm -f /tmp/avian-caddy-refresh-ready
password_stdin "$new_password" "$admin" lan-auth-set-stdin 1 \
  >/tmp/avian-policy-slow.out &
policy_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e /tmp/avian-caddy-refresh-ready ] && break
  sleep 0.1
done
[ -e /tmp/avian-caddy-refresh-ready ] || fail "slow refresh did not reach its barrier"
"$admin" config-set SITE_NAME Concurrent >/tmp/avian-config-concurrent.out &
config_pid=$!
wait "$policy_pid"
wait "$config_pid"
rm -f /tmp/avian-caddy-refresh-slow /tmp/avian-caddy-refresh-started
[ "$(state_field 2)" = 1 ] || fail "concurrent config write reverted policy"
grep -Fxq 'SITE_NAME=Concurrent' "$conf" || fail "serialized config update was lost"

# Max epoch is rejected before any candidate state or Caddy refresh.
max_verifier=$(state_field 4)
printf 'v1\t1\t2147483647\t%s\n' "$max_verifier" \
  >/var/lib/avian-visitors/admin-auth.state
chown root:caddy /var/lib/avian-visitors/admin-auth.state
chmod 0640 /var/lib/avian-visitors/admin-auth.state
state_hash=$(sha256sum /var/lib/avian-visitors/admin-auth.state)
expect_failure "max epoch transition" "cannot safely be advanced" \
  password_stdin "$new_password" "$admin" lan-auth-set-stdin 0
[ "$(sha256sum /var/lib/avian-visitors/admin-auth.state)" = "$state_hash" ] \
  || fail "max epoch transition changed state"

# Unsafe fixed rate state is rejected by refresh instead of repaired through
# a link or attacker-controlled inode.
chmod 0666 /var/lib/avian-visitors/admin-auth.rate
expect_failure "unsafe rate metadata" "Unsafe admin rate state" \
  /source/scripts/security_refresh.sh
chmod 0660 /var/lib/avian-visitors/admin-auth.rate

echo "admin control smoke: ok"
