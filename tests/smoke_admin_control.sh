#!/usr/bin/env bash
# Run as root inside a disposable Debian container with the repository at
# /source. Exercises the installed Caddy-to-root admin boundary end to end.

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
    || fail "$label returned the wrong error"
}

expect_denied() {
  local label=$1
  shift
  if "$@" >/tmp/avian-admin-denied.out 2>&1; then
    fail "$label unexpectedly succeeded"
  fi
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fail "test must run as root"
[ -r /source/scripts/admin_control.sh ] || fail "repository is not mounted at /source"

birdnet_user=aviantest
birdnet_home=/home/$birdnet_user
repo=$birdnet_home/BirdNET-Pi
conf=$repo/birdnet.conf
admin=/usr/local/sbin/avian-admin-control

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
cp /source/avian/api/admin-auth.php "$repo/avian/api/admin-auth.php"
cp /source/avian/api/config.php "$repo/avian/api/config.php"
cp /source/avian/api/birdnet-status.php "$repo/avian/api/birdnet-status.php"
printf '{}\n' >"$repo/avian/frontend/dims.json"
printf '{}\n' >"$repo/avian/frontend/masks.json"
printf 'ordinary\n' >"$repo/ordinary.txt"
cat >"$conf" <<EOF
BIRDNET_USER=missing-user
BIRDNET_USER=$birdnet_user
SITE_NAME="Before"
CONFIDENCE=0.5
MAX_FILES_SPECIES=0
RTSP_STREAM="rtsp://camera-user:camera-password@192.0.2.10/live"
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
  avian-caddy-refresh \
  avian-link-webroot; do
  install -o root -g root -m 0755 /tmp/avian-noop-control "/usr/local/sbin/$helper"
done

/source/scripts/security_refresh.sh >/tmp/avian-security-refresh.out
grep -Fxq 'security refresh: ok' /tmp/avian-security-refresh.out \
  || fail "security refresh did not report success"
[ ! -e /etc/sudoers.d/010_caddy-nopasswd ] \
  || fail "legacy unrestricted Caddy rule remains"
[ "$(stat -c '%U:%G:%a' /etc/sudoers.d/020_avian-admin)" = root:root:440 ] \
  || fail "sudoers owner or mode is wrong"
grep -Fq '/usr/local/sbin/avian-admin-control *' /etc/sudoers.d/020_avian-admin \
  || fail "admin validator is missing from sudoers"
! grep -Eq 'NOPASSWD:[[:space:]]*ALL([[:space:]]|$)' /etc/sudoers.d/020_avian-admin \
  || fail "sudoers grants unrestricted root access"
cat >/etc/sudoers.d/019_avian-alias-test <<'EOF'
Cmnd_Alias AVIAN_TEST_ALL = ALL
caddy ALL=(root) NOPASSWD: AVIAN_TEST_ALL
EOF
chmod 0440 /etc/sudoers.d/019_avian-alias-test
visudo -cf /etc/sudoers.d/019_avian-alias-test >/dev/null
expect_failure "aliased unrestricted sudo rule" "unrestricted Caddy sudo rule" \
  /source/scripts/security_refresh.sh
rm -f /etc/sudoers.d/019_avian-alias-test
/source/scripts/security_refresh.sh >/tmp/avian-security-refresh.out

[ "$(stat -c '%U:%G:%a' "$conf")" = "$birdnet_user:$birdnet_user:640" ] \
  || fail "config owner or mode is wrong"
[ "$(stat -c '%a' "$repo/avian/frontend/dims.json")" = 660 ] \
  || fail "generated index mode is wrong"
[ "$(stat -c '%G' "$repo/avian/frontend/dims.json")" = caddy ] \
  || fail "generated index is not writable by Caddy"
if [ $(( 8#$(stat -c '%a' "$repo/ordinary.txt") & 8#020 )) -ne 0 ]; then
  fail "ordinary checkout file remains group-writable"
fi
legacy_state=$repo/scripts/disk_check_exclude.txt
[ "$(stat -c '%U:%G:%a:%h' "$legacy_state")" = "$birdnet_user:caddy:660:1" ] \
  || fail "legacy cleanup state owner, mode, or link count is wrong"
[ "$(cat "$legacy_state")" = $'##start\n##end' ] \
  || fail "legacy cleanup state was not initialized safely"
printf 'manual-protected.mp3\n' | sudo -u caddy tee -a "$legacy_state" >/dev/null
state_hash=$(sha256sum "$legacy_state")
/source/scripts/security_refresh.sh >/tmp/avian-security-refresh.out
[ "$(sha256sum "$legacy_state")" = "$state_hash" ] \
  || fail "security refresh replaced existing cleanup state"
expect_denied "Caddy cleanup-state sibling creation" \
  sudo -u caddy touch "$repo/scripts/caddy-created"
expect_denied "Caddy cleanup-state replacement" \
  sudo -u caddy rm "$legacy_state"

expect_failure "non-root direct helper call" "admin control must run as root" \
  sudo -u caddy "$admin" version
version_output=$("$admin" version)
grep -Fq '"version":1' <<<"$version_output" || fail "version action failed"
expect_failure "version arguments" "unexpected arguments" "$admin" version extra
expect_failure "unknown action" "unknown action" "$admin" definitely-not-an-action
expect_failure "missing config value" "config-set requires a key and value" \
  "$admin" config-set SITE_NAME
expect_failure "unknown config key" "invalid config value for UNKNOWN" \
  "$admin" config-set UNKNOWN value
expect_failure "duplicate config key" "duplicate config key: SITE_NAME" \
  "$admin" config-set-many SITE_NAME First SITE_NAME Second
expect_failure "odd config pair list" "config-set-many requires key and value pairs" \
  "$admin" config-set-many SITE_NAME First CONFIDENCE
oversized_integer=99999999999999999999999999999999999999999999999999
expect_failure "oversized integer config" "invalid config value for MAX_FILES_SPECIES" \
  "$admin" config-set MAX_FILES_SPECIES "$oversized_integer"
expect_failure "oversized stdin count" "config input count is not allowed" \
  "$admin" config-set-stdin "$oversized_integer"
expect_failure "noncanonical stdin count" "config input count is not allowed" \
  "$admin" config-set-stdin 01

inode_before=$(stat -c '%i' "$conf")
result=$("$admin" config-set-many SITE_NAME 'My Yard' CONFIDENCE 0.75 EBIRD_API_KEY 'abc+123==')
grep -Fq '"updated":3' <<<"$result" || fail "multi-value update failed"
[ "$(stat -c '%i' "$conf")" != "$inode_before" ] \
  || fail "config replacement was not atomic"
grep -Fxq 'SITE_NAME="My Yard"' "$conf" || fail "site name was not updated"
grep -Fxq 'CONFIDENCE=0.75' "$conf" || fail "confidence was not updated"
grep -Fxq 'EBIRD_API_KEY="abc+123=="' "$conf" || fail "secret was not updated"
[ "$(grep -c '^SITE_NAME=' "$conf")" -eq 1 ] || fail "site name was duplicated"
[ "$(stat -c '%U:%G:%a' "$conf")" = "$birdnet_user:$birdnet_user:640" ] \
  || fail "atomic replacement lost config ownership or mode"

hash_before=$(sha256sum "$conf")
inode_before=$(stat -c '%i' "$conf")
expect_failure "partially invalid config batch" "invalid config value for LATITUDE" \
  "$admin" config-set-many SITE_NAME Changed LATITUDE 91
[ "$(sha256sum "$conf")" = "$hash_before" ] \
  || fail "invalid config batch changed file content"
[ "$(stat -c '%i' "$conf")" = "$inode_before" ] \
  || fail "invalid config batch replaced the file"

injection_marker=/tmp/avian-admin-injection
rm -f "$injection_marker"
# shellcheck disable=SC2016 # Deliberate literal attack payload.
config_attack='$(touch /tmp/avian-admin-injection)'
expect_failure "config shell injection" "invalid config value for SITE_NAME" \
  "$admin" config-set SITE_NAME "$config_attack"
[ ! -e "$injection_marker" ] || fail "config value executed shell syntax"
expect_failure "unit shell injection" "unit is not allowed" \
  "$admin" restart 'caddy;touch /tmp/avian-admin-injection'
[ ! -e "$injection_marker" ] || fail "unit name executed shell syntax"

secret_value='private-api-token-abc123=='
{
  sleep 1
  printf 'GEMINI_API_KEY\0%s\0' "$secret_value"
} | "$admin" config-set-stdin 1 >/tmp/avian-admin-stdin.out &
stdin_pid=$!
sleep 0.2
cmdline=$(tr '\0' ' ' <"/proc/$stdin_pid/cmdline")
[[ "$cmdline" != *"$secret_value"* ]] || fail "stdin secret leaked into process arguments"
wait "$stdin_pid"
grep -Fq '"updated":1' /tmp/avian-admin-stdin.out || fail "stdin update failed"
grep -Fxq 'GEMINI_API_KEY="private-api-token-abc123=="' "$conf" \
  || fail "stdin secret was not written"
hash_before=$(sha256sum "$conf")
if printf 'SITE_NAME\0Incomplete' | "$admin" config-set-stdin 1 \
  >/tmp/avian-admin-failure.out 2>&1; then
  fail "incomplete stdin update unexpectedly succeeded"
fi
grep -Fq 'incomplete config input' /tmp/avian-admin-failure.out \
  || fail "incomplete stdin update returned the wrong error"
[ "$(sha256sum "$conf")" = "$hash_before" ] \
  || fail "incomplete stdin update changed the config"
if printf 'SITE_NAME\0Complete\0trailing' | "$admin" config-set-stdin 1 \
  >/tmp/avian-admin-failure.out 2>&1; then
  fail "trailing stdin data unexpectedly succeeded"
fi
grep -Fq 'unexpected config input' /tmp/avian-admin-failure.out \
  || fail "trailing stdin data returned the wrong error"
[ "$(sha256sum "$conf")" = "$hash_before" ] \
  || fail "trailing stdin data changed the config"
if printf 'SITE_NAME\0Complete\0\0' | "$admin" config-set-stdin 1 \
  >/tmp/avian-admin-failure.out 2>&1; then
  fail "trailing stdin delimiter unexpectedly succeeded"
fi
grep -Fq 'unexpected config input' /tmp/avian-admin-failure.out \
  || fail "trailing stdin delimiter returned the wrong error"
[ "$(sha256sum "$conf")" = "$hash_before" ] \
  || fail "trailing stdin delimiter changed the config"

expect_failure "disallowed restart unit" "unit is not allowed" \
  "$admin" restart ssh
expect_failure "allowed restart failure" "service restart failed" \
  "$admin" restart birdnet_analysis
expect_failure "journal lower bound" "journal line count is not allowed" \
  "$admin" journal birdnet_analysis 9
expect_failure "journal upper bound" "journal line count is not allowed" \
  "$admin" journal birdnet_analysis 501
expect_failure "oversized journal count" "journal line count is not allowed" \
  "$admin" journal birdnet_analysis "$oversized_integer"
expect_failure "journal unit allowlist" "unit is not allowed" \
  "$admin" journal ssh 20

admin_sudo_output=$(sudo -u caddy sudo -n "$admin" version)
grep -Fq '"version":1' <<<"$admin_sudo_output" \
  || fail "sudoers does not allow the root validator"
expect_failure "validator rejects sudo wildcard arguments" "unknown action" \
  sudo -u caddy sudo -n "$admin" arbitrary root arguments
expect_denied "sudoers direct shell" \
  sudo -u caddy sudo -n /bin/sh -c true
expect_denied "sudoers alternate helper path" \
  sudo -u caddy sudo -n /tmp/avian-noop-control
sudo -u caddy sudo -n /usr/local/sbin/avian-archive-control status
expect_denied "sudoers fixed archive arguments" \
  sudo -u caddy sudo -n /usr/local/sbin/avian-archive-control status extra

outside_conf=/tmp/avian-outside.conf
cat >"$outside_conf" <<EOF
BIRDNET_USER=$birdnet_user
SITE_NAME=Outside
EOF
chmod 0600 "$outside_conf"
outside_state=$(stat -c '%U:%G:%a:%s' "$outside_conf")
rm -f /etc/birdnet/birdnet.conf
ln -s "$outside_conf" /etc/birdnet/birdnet.conf
expect_failure "admin config symlink escape" "config path is not safe" \
  "$admin" config-set SITE_NAME Escaped
expect_failure "security config symlink escape" "config path is not safe" \
  /source/scripts/security_refresh.sh
[ "$(stat -c '%U:%G:%a:%s' "$outside_conf")" = "$outside_state" ] \
  || fail "outside config was changed through a symlink"
grep -Fxq 'SITE_NAME=Outside' "$outside_conf" \
  || fail "outside config content changed through a symlink"
rm -f /etc/birdnet/birdnet.conf
ln -s "$conf" /etc/birdnet/birdnet.conf

outside_cleanup=/tmp/avian-outside-cleanup
printf 'protected cleanup sentinel\n' >"$outside_cleanup"
chmod 0600 "$outside_cleanup"
outside_state=$(stat -c '%U:%G:%a:%s' "$outside_cleanup")
rm -f "$legacy_state"
ln -s "$outside_cleanup" "$legacy_state"
expect_failure "cleanup state symlink escape" "Unsafe runtime file" \
  /source/scripts/security_refresh.sh
[ "$(stat -c '%U:%G:%a:%s' "$outside_cleanup")" = "$outside_state" ] \
  || fail "outside cleanup file was changed through a symlink"
grep -Fxq 'protected cleanup sentinel' "$outside_cleanup" \
  || fail "outside cleanup content changed through a symlink"
rm -f "$legacy_state"

outside_cleanup=$repo/ordinary.txt
outside_state=$(stat -c '%U:%G:%a:%s' "$outside_cleanup")
ln "$outside_cleanup" "$legacy_state"
expect_failure "cleanup state hardlink escape" "Unsafe runtime file" \
  /source/scripts/security_refresh.sh
[ "$(stat -c '%U:%G:%a:%s' "$outside_cleanup")" = "$outside_state" ] \
  || fail "outside cleanup file was changed through a hardlink"
rm -f "$legacy_state"

mkfifo "$legacy_state"
expect_failure "cleanup state special node" "Unsafe runtime file" \
  /source/scripts/security_refresh.sh
rm -f "$legacy_state"
mkdir "$legacy_state"
expect_failure "cleanup state directory" "Unsafe runtime file" \
  /source/scripts/security_refresh.sh
rmdir "$legacy_state"

outside_scripts=/tmp/avian-outside-scripts
mkdir -p "$outside_scripts"
printf 'protected scripts sentinel\n' >"$outside_scripts/sentinel"
outside_state=$(stat -c '%U:%G:%a:%s' "$outside_scripts/sentinel")
mv "$repo/scripts" "$repo/scripts.real"
ln -s "$outside_scripts" "$repo/scripts"
expect_failure "cleanup state directory symlink" "Unsafe runtime directory" \
  /source/scripts/security_refresh.sh
[ "$(stat -c '%U:%G:%a:%s' "$outside_scripts/sentinel")" = "$outside_state" ] \
  || fail "outside scripts directory changed through a symlink"
rm -f "$repo/scripts"
mv "$repo/scripts.real" "$repo/scripts"
printf '##start\n##end\nmanual-protected.mp3\n' >"$legacy_state"

outside_file=/tmp/avian-outside-masks
printf 'protected\n' >"$outside_file"
chmod 0600 "$outside_file"
outside_state=$(stat -c '%U:%G:%a:%s' "$outside_file")
rm -f "$repo/avian/frontend/masks.json"
ln -s "$outside_file" "$repo/avian/frontend/masks.json"
expect_failure "runtime file symlink escape" "Unsafe runtime file" \
  /source/scripts/security_refresh.sh
[ "$(stat -c '%U:%G:%a:%s' "$outside_file")" = "$outside_state" ] \
  || fail "outside file was changed through a runtime symlink"
rm -f "$repo/avian/frontend/masks.json"
printf '{}\n' >"$repo/avian/frontend/masks.json"

outside_dir=/tmp/avian-outside-runtime
mkdir -p "$outside_dir"
printf 'protected\n' >"$outside_dir/sentinel"
chmod 0700 "$outside_dir"
chmod 0600 "$outside_dir/sentinel"
outside_state=$(stat -c '%U:%G:%a' "$outside_dir/sentinel")
rmdir "$repo/avian/assets/references"
ln -s "$outside_dir" "$repo/avian/assets/references"
expect_failure "runtime directory symlink escape" "Unsafe runtime directory" \
  /source/scripts/security_refresh.sh
[ "$(stat -c '%U:%G:%a' "$outside_dir/sentinel")" = "$outside_state" ] \
  || fail "outside directory was changed through a runtime symlink"
rm -f "$repo/avian/assets/references"
mkdir -p "$repo/avian/assets/references"

mv "$repo" "$birdnet_home/BirdNET-Pi.real"
ln -s "$birdnet_home/BirdNET-Pi.real" "$repo"
expect_failure "checkout symlink boundary" "checkout cannot be a symbolic link" \
  /source/scripts/security_refresh.sh
expect_failure "admin checkout symlink boundary" "checkout path is not safe" \
  "$admin" version
rm -f "$repo"
mv "$birdnet_home/BirdNET-Pi.real" "$repo"
/source/scripts/security_refresh.sh >/tmp/avian-security-refresh.out

# The root test harness owns the log redirection; PHP still runs as Caddy.
# shellcheck disable=SC2024
sudo -u caddy php -S 127.0.0.1:8896 -t "$repo" \
  >/tmp/avian-admin-api-server.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5; do
  if curl -fsS http://127.0.0.1:8896/avian/api/config.php \
    >/tmp/avian-admin-api-body 2>/dev/null; then
    break
  fi
  sleep 1
done
grep -Fq '"values"' /tmp/avian-admin-api-body || fail "config API did not start"

curl -fsS \
  'http://127.0.0.1:8896/avian/api/birdnet-status.php?action=system' \
  >/tmp/avian-admin-status-body
! grep -Fq 'camera-password' /tmp/avian-admin-status-body \
  || fail "status API exposed credentials from RTSP_STREAM"
! grep -Fq 'RTSP_STREAM' /tmp/avian-admin-status-body \
  || fail "status API exposed the RTSP stream setting"

code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data '{"SITE_NAME":"API Yard"}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 200 ] || fail "config API rejected a valid non-restart update"
grep -Fq '"ok":true' /tmp/avian-admin-api-body || fail "config API success body is wrong"
grep -Fxq 'SITE_NAME="API Yard"' "$conf" || fail "config API did not update the config"

api_secret='api-secret-456=='
code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data "{\"GEMINI_API_KEY\":\"$api_secret\"}" \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 200 ] || fail "config API rejected a valid secret update"
grep -Fq '"GEMINI_API_KEY":"(saved)"' /tmp/avian-admin-api-body \
  || fail "config API did not mask its secret response"
! grep -Fq "$api_secret" /tmp/avian-admin-api-body \
  || fail "config API echoed a secret value"
grep -Fxq 'GEMINI_API_KEY="api-secret-456=="' "$conf" \
  || fail "config API did not write its stdin secret"

hash_before=$(sha256sum "$conf")
code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data '{"UNKNOWN":"value"}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 400 ] || fail "config API accepted an unknown key"
[ "$(sha256sum "$conf")" = "$hash_before" ] \
  || fail "unknown API key changed the config"
code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data '{"MAX_FILES_SPECIES":"100"}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 400 ] || fail "config API accepted a string for an integer field"
[ "$(sha256sum "$conf")" = "$hash_before" ] \
  || fail "wrong API value type changed the config"

# shellcheck disable=SC2016 # Deliberate literal JSON attack payload.
api_attack_body='{"SITE_NAME":"$(touch /tmp/avian-admin-api-injection)"}'
code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data "$api_attack_body" \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 400 ] || fail "config API accepted a shell injection string"
[ ! -e /tmp/avian-admin-api-injection ] || fail "config API executed shell syntax"

code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  --data '{"CONFIDENCE":0.8}' \
  http://127.0.0.1:8896/avian/api/config.php)
[ "$code" = 500 ] || fail "config API hid a service restart failure"
grep -Fq 'settings saved, but a BirdNET service did not restart' /tmp/avian-admin-api-body \
  || fail "config API restart error is not actionable"

code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  'http://127.0.0.1:8896/avian/api/birdnet-status.php?action=restart&unit=birdnet_analysis')
[ "$code" = 500 ] || fail "status API restart failure returned HTTP 200"
grep -Fq '"ok":false' /tmp/avian-admin-api-body || fail "status API restart failure body is wrong"
grep -Fq 'service restart failed' /tmp/avian-admin-api-body \
  || fail "status API restart failure lost its error"

code=$(curl -sS -o /tmp/avian-admin-api-body -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H 'X-Avian-Action: 1' \
  'http://127.0.0.1:8896/avian/api/birdnet-status.php?action=restart&unit=ssh')
[ "$code" = 400 ] || fail "status API accepted a disallowed unit"

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
trap - EXIT

echo 'admin control smoke: ok'
