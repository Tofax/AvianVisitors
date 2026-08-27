#!/usr/bin/env bash
# Run as root in a disposable Debian container with the repository at /source
# and AVIAN_REINSTALL_SERVICES_TEST=1 set explicitly.

set -euo pipefail
IFS=$'\n\t'

[ -f /.dockerenv ] \
  || { echo 'FAIL: refusing reinstall services smoke outside a disposable container' >&2; exit 1; }
[ "${AVIAN_REINSTALL_SERVICES_TEST:-0}" = 1 ] \
  || { echo 'FAIL: refusing reinstall services smoke without AVIAN_REINSTALL_SERVICES_TEST=1' >&2; exit 1; }

fail() {
  echo "FAIL: $*" >&2
  [ ! -f "$test_root/refresh.log" ] || cat "$test_root/refresh.log" >&2
  exit 1
}

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'run this smoke test as root' >&2; exit 1; }
test_root=/tmp/avian-service-refresh-smoke
station_user=birdrefresh
station_home=$test_root/home
repo=$station_home/BirdNET-Pi
webroot=$station_home/BirdSongs/Extracted
official=https://github.com/Twarner491/AvianVisitors.git
official_remote=$test_root/official.git
rm -rf "$test_root"
mkdir -p "$repo/scripts" "$repo/avian/frontend/fonts" "$repo/avian/frontend/assets" \
  "$repo/avian/assets" "$webroot" /etc/birdnet /etc/sudoers.d /etc/caddy \
  /usr/local/bin /usr/local/sbin
id "$station_user" >/dev/null 2>&1 \
  || useradd -M -d "$station_home" -s /bin/bash "$station_user"
id caddy >/dev/null 2>&1 \
  || useradd -M -d /var/lib/caddy -s /usr/sbin/nologin caddy

cp /source/scripts/reinstall_services.sh "$repo/scripts/reinstall_services.sh"
for helper in update_birdnet maintenance_control archive_control; do
  cat >"$repo/scripts/$helper.sh" <<EOF
#!/usr/bin/env bash
echo $helper
EOF
done
cp /source/scripts/admin_control.sh "$repo/scripts/admin_control.sh"
cp /source/scripts/link_webroot.sh "$repo/scripts/link_webroot.sh"
cp /source/scripts/livestream.sh "$repo/scripts/livestream.sh"
cp /source/scripts/update_caddyfile.sh "$repo/scripts/update_caddyfile.sh"
cp /source/scripts/security_refresh.sh "$repo/scripts/security_refresh.sh"
cat >"$repo/scripts/example.sh" <<'EOF'
#!/usr/bin/env bash
echo example
EOF

for frontend_file in \
  index.html styles.css apt.js masks.json dims.json nest.webp nest-eggs.webp \
  stamps.css stamps.js stamp-batch-root.css stamp-batch-root.js \
  stamp-batch-a.css stamp-batch-a.js stamp-batch-b.css stamp-batch-b.js \
  stamp-batch-c.css stamp-batch-c.js grain.png stats-press.png; do
  printf '%s\n' "$frontend_file" >"$repo/avian/frontend/$frontend_file"
done
printf 'favicon\n' >"$repo/avian/assets/favicon.png"
chmod 0755 "$repo/scripts/"*.sh

git -C "$repo" init -q -b avian-visitors
git -C "$repo" config user.name 'Refresh smoke'
git -C "$repo" config user.email refresh@example.test
git -C "$repo" add .
git -C "$repo" commit -qm fixture
git -C "$repo" remote add origin "$official"
git -C "$repo" update-ref refs/remotes/origin/avian-visitors HEAD
git clone -q --bare "$repo" "$official_remote"
cat >/etc/gitconfig <<EOF
[url "file://$official_remote"]
    insteadOf = $official
[safe]
    directory = $official_remote
EOF
chown -R "$station_user:$station_user" "$station_home"

cat >/etc/birdnet/birdnet.conf <<EOF
BIRDNET_USER=$station_user
EXTRACTED=$webroot
REC_CARD=plughw:CARD=Device
RTSP_STREAM=
export CADDY_PWD="FirstHopLegacy12!" # accepted legacy form
EOF
printf '<?php echo "legacy"; ?>\n' >"$webroot/index.php"
printf '%s\n' 'caddy ALL=(ALL) NOPASSWD: ALL' \
  >/etc/sudoers.d/010_caddy-nopasswd
printf 'cron sentinel\n' >/etc/crontab
printf 'keep local bin\n' >/usr/local/bin/avian-refresh-unknown
chown root:root /usr/local/bin
chmod 0755 /usr/local/bin

cat >/usr/bin/systemctl <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>/tmp/avian-service-refresh-smoke/systemctl.log
icecast_marker=/tmp/avian-service-refresh-smoke/icecast-active
case "$*" in
  'is-active --quiet caddy') exit 0 ;;
  'is-active icecast2')
    if [ -e "$icecast_marker" ]; then echo active; else echo inactive; exit 3; fi
    ;;
  'is-active --quiet icecast2') [ -e "$icecast_marker" ] ;;
  'cat icecast2') printf '[Service]\nExecStart=/usr/bin/icecast2\n' ;;
  'show -p MainPID --value icecast2'|'show -p ControlPID --value icecast2')
    echo 0
    ;;
  'show -p ControlGroup --value icecast2') echo /avian-refresh-icecast2 ;;
  'stop icecast2'|'kill --kill-who=all --signal=KILL icecast2')
    rm -f "$icecast_marker"
    ;;
  'start icecast2') touch "$icecast_marker" ;;
esac
exit 0
EOF
cat >/usr/local/bin/apt <<'EOF'
#!/usr/bin/env bash
touch /tmp/avian-service-refresh-smoke/apt.called
exit 99
EOF
cat >/usr/local/bin/pgrep <<'EOF'
#!/usr/bin/env bash
if [ "$*" = '-u birdrefresh -x pulseaudio' ]; then
  printf '%s\n' 4242
  exit 0
fi
exit 1
EOF
cat >/usr/local/bin/mktemp <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    /tmp/avian-service-refresh.*)
      echo 'large verified fetch attempted to use /tmp' >&2
      exit 88
      ;;
  esac
done
printf '%s\n' "$*" >>/tmp/avian-service-refresh-smoke/mktemp.log
exec /usr/bin/mktemp "$@"
EOF
chmod 0755 \
  /usr/bin/systemctl /usr/local/bin/apt /usr/local/bin/pgrep \
  /usr/local/bin/mktemp

previous_refresh=/source/tests/testdata/reinstall_services_16c7217d.sh
[ "$(sha256sum "$previous_refresh" | cut -d' ' -f1)" = \
  6ac215542c525e99b9315ff704eff05218999f3ec4adf015c9bc7c7d8caba9c5 ] \
  || fail 'previous release helper fixture does not match public commit 16c7217d'
cp "$previous_refresh" /usr/local/sbin/avian-service-refresh
chown root:root /usr/local/sbin/avian-service-refresh
chmod 0755 /usr/local/sbin/avian-service-refresh

if /usr/local/sbin/avian-service-refresh --unexpected \
  >"$test_root/arguments.log" 2>&1; then
  fail 'service refresh accepted an unknown argument'
fi
grep -q '^Usage: avian-service-refresh' "$test_root/arguments.log" \
  || fail 'unknown service-refresh argument was not explained'

run_refresh() {
  /usr/local/sbin/avian-service-refresh >"$test_root/refresh.log" 2>&1 \
    || fail 'service refresh failed'
}

install -o root -g root -m 0600 /dev/null /run/lock/avian-update.lock
exec 8<>/run/lock/avian-update.lock
flock -n 8 || fail 'could not hold shared update lock for test'
if /usr/local/sbin/avian-service-refresh >"$test_root/contention.log" 2>&1; then
  fail 'service refresh ignored a concurrent updater lock'
fi
grep -q 'another update is already running' "$test_root/contention.log" \
  || fail 'service refresh lock error was unclear'
[ ! -e /etc/sudoers.d/020_avian-admin ] \
  || fail 'contended service refresh changed security state'
flock -u 8
exec 8>&-

# The updater passes its already locked descriptor to avoid deadlocking its
# own post-update refresh.
exec 9<>/run/lock/avian-update.lock
flock -n 9 || fail 'could not hold inherited update lock for test'
AVIAN_UPDATE_LOCK_FD=9 /usr/local/sbin/avian-service-refresh \
  >"$test_root/refresh.log" 2>&1 || fail 'inherited-lock service refresh failed'
flock -u 9
exec 9>&-
[ "$(grep -c '^daemon-reload$' "$test_root/systemctl.log")" -eq 3 ] \
  || fail 'first-hop refresh performed an unexpected daemon reload'

# This invocation began in the exact 16c7217d helper. It atomically replaced
# itself, then invoked the newly installed security helper. The new security
# hook must apply the audio policy before that first old process returns.
[ "$(sha256sum /usr/local/sbin/avian-service-refresh | cut -d' ' -f1)" = \
  "$(sha256sum "$repo/scripts/reinstall_services.sh" | cut -d' ' -f1)" ] \
  || fail 'first-hop refresh did not install the new service helper'
icecast_guard=/etc/systemd/system/icecast2.service.d/zz-avian-lan-auth.conf
[ -f "$icecast_guard" ] && [ ! -L "$icecast_guard" ] \
  || fail 'first-hop refresh did not install the Icecast start guard'
[ "$(stat -c '%U:%G:%a:%h' "$icecast_guard")" = root:root:644:1 ] \
  || fail 'first-hop Icecast start guard metadata is unsafe'
grep -Fxq \
  'ExecCondition=+/usr/local/sbin/avian-admin-control icecast-start-allowed' \
  "$icecast_guard" \
  || fail 'first-hop Icecast start guard condition is missing'
[ -f /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf ] \
  || fail 'first-hop refresh did not install the live stream restart policy'
if grep -qx 'Restart=on-failure' \
  /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf; then
  fail 'first-hop live stream policy downgraded restart resilience'
fi
grep -qx 'Restart=always' \
  /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf \
  || fail 'first-hop live stream policy has the wrong restart mode'
grep -qx 'ExecCondition=/usr/local/bin/livestream.sh --check' \
  /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf \
  || fail 'first-hop live stream policy lacks its capture condition'
[ "$(grep -c '^stop livestream.service$' "$test_root/systemctl.log")" -eq 1 ] \
  || fail 'first-hop refresh did not immediately stop direct live streaming'
grep -q 'PulseAudio is still running for birdrefresh' "$test_root/refresh.log" \
  || fail 'first-hop refresh did not report the existing PulseAudio process'
grep -q 'Bird recording is not yet confirmed recovered' "$test_root/refresh.log" \
  || fail 'first-hop refresh overstated direct recorder recovery'
grep -q 'Reboot the station, then check birdnet_recording.service' \
  "$test_root/refresh.log" \
  || fail 'first-hop PulseAudio warning lacked reboot guidance'

# The same first invocation must migrate the exported legacy password into
# root-owned verifier state, scrub every plaintext assignment, and render the
# real candidate Caddy policy. This is not deferred to a second refresh.
auth_dir=/var/lib/avian-visitors
auth_state=$auth_dir/admin-auth.state
auth_lock=$auth_dir/admin-auth.lock
auth_rate=$auth_dir/admin-auth.rate
auth_marker=$auth_dir/admin-auth.initialized
[ "$(cut -f1-3 "$auth_state")" = $'v1\t0\t0' ] \
  || fail 'first-hop migration created the wrong admin auth state'
auth_verifier=$(cut -f4 "$auth_state")
php -r 'exit(password_verify("FirstHopLegacy12!", $argv[1]) ? 0 : 1);' \
  "$auth_verifier" \
  || fail 'first-hop migration did not preserve the legacy credential'
[ "$(stat -c '%U:%G:%a:%h' "$auth_state")" = root:caddy:640:1 ] \
  || fail 'first-hop admin auth state metadata is unsafe'
[ "$(stat -c '%U:%G:%a:%h' "$auth_lock")" = root:root:600:1 ] \
  || fail 'first-hop admin auth lock metadata is unsafe'
[ "$(stat -c '%U:%G:%a:%h' "$auth_rate")" = root:caddy:660:1 ] \
  || fail 'first-hop admin rate state metadata is unsafe'
[ "$(stat -c '%U:%G:%a:%h:%s' "$auth_marker")" = root:root:400:1:3 ] \
  || fail 'first-hop migration marker metadata is unsafe'
grep -Fxq 'CADDY_PWD=""' /etc/birdnet/birdnet.conf \
  || fail 'first-hop migration did not install the scrubbed password assignment'
if grep -Fq 'FirstHopLegacy12!' /etc/birdnet/birdnet.conf \
  || grep -Eq '^[[:space:]]*export[[:space:]]+CADDY_PWD=' /etc/birdnet/birdnet.conf; then
  fail 'first-hop migration left the exported plaintext password in config'
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null \
  || fail 'first-hop Caddy policy did not validate'
[ "$(stat -c '%U:%G:%a' /etc/caddy/Caddyfile)" = root:caddy:640 ] \
  || fail 'first-hop Caddy policy contains a verifier with unsafe metadata'
grep -Fq "$auth_verifier" /etc/caddy/Caddyfile \
  || fail 'first-hop Caddy policy did not use the migrated verifier'
grep -Fq 'FirstHopLegacy12!' /etc/caddy/Caddyfile \
  && fail 'first-hop Caddy policy exposed the plaintext password'

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile \
  >"$test_root/caddy.log" 2>&1 &
caddy_pid=$!
for _ in {1..50}; do
  if curl -sS --max-time 1 -o /dev/null http://127.0.0.1/ 2>/dev/null; then
    break
  fi
  sleep 0.1
done
kill -0 "$caddy_pid" 2>/dev/null \
  || { cat "$test_root/caddy.log" >&2; fail 'first-hop Caddy policy did not start'; }
[ "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/index.php)" = 401 ] \
  || fail 'first-hop Caddy render did not protect the legacy surface'
[ "$(curl -sS -u 'birdnet:FirstHopLegacy12!' -o /dev/null -w '%{http_code}' \
  http://127.0.0.1/index.php)" = 502 ] \
  || fail 'first-hop Caddy render rejected the migrated credential'
kill "$caddy_pid"
wait "$caddy_pid" 2>/dev/null || true

if /usr/local/bin/livestream.sh --check; then
  fail 'direct ALSA condition allowed the live stream to start'
fi
sed -i 's/^REC_CARD=.*/REC_CARD=default/' /etc/birdnet/birdnet.conf
/usr/local/bin/livestream.sh --check \
  || fail 'direct to default transition left the live stream blocked'

# Reapplying the policy must safely replace its existing root-owned drop-in.
# A normal shared-audio path has no migration warning on stderr.
policy_file=/etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf
/usr/local/sbin/avian-service-refresh --audio-policy \
  >"$test_root/safe-policy.out" 2>"$test_root/safe-policy.err" \
  || fail 'safe existing live stream drop-in was rejected'
[ ! -s "$test_root/safe-policy.err" ] \
  || fail 'safe existing live stream drop-in produced unexpected stderr'
grep -q 'shared audio or RTSP remains available' "$test_root/safe-policy.out" \
  || fail 'shared-audio policy status was not reported'
[ "$(stat -c '%U:%G:%a' "$policy_file")" = root:root:644 ] \
  || fail 'safe existing live stream drop-in lost its ownership or mode'
[ "$(grep -c '^daemon-reload$' "$test_root/systemctl.log")" -eq 4 ] \
  || fail 'explicit audio-policy refresh performed an unexpected daemon reload'

# Never replace a policy file whose ownership shows that it is not managed by
# root. Restore the fixture afterward so the remaining idempotence checks run.
policy_hash=$(sha256sum "$policy_file" | cut -d' ' -f1)
chown "$station_user:$station_user" "$policy_file"
if /usr/local/sbin/avian-service-refresh --audio-policy \
  >"$test_root/unsafe-policy.out" 2>"$test_root/unsafe-policy.err"; then
  fail 'non-root-owned live stream drop-in was accepted'
fi
grep -q 'live stream drop-in file is unsafe' "$test_root/unsafe-policy.err" \
  || fail 'unsafe live stream drop-in failure was unclear'
[ "$(stat -c '%U:%G' "$policy_file")" = "$station_user:$station_user" ] \
  || fail 'unsafe live stream drop-in ownership was changed'
[ "$(sha256sum "$policy_file" | cut -d' ' -f1)" = "$policy_hash" ] \
  || fail 'unsafe live stream drop-in contents were changed'
chown root:root "$policy_file"
chmod 0644 "$policy_file"
[ "$(grep -c '^daemon-reload$' "$test_root/systemctl.log")" -eq 4 ] \
  || fail 'rejected audio policy changed systemd state'

sed -i 's|^RTSP_STREAM=.*|RTSP_STREAM=rtsp://camera.example.test/audio|' \
  /etc/birdnet/birdnet.conf
sed -i 's/^REC_CARD=.*/REC_CARD=plughw:CARD=Device/' /etc/birdnet/birdnet.conf
/usr/local/bin/livestream.sh --check \
  || fail 'RTSP transition was blocked by direct REC_CARD'
sed -i 's|^RTSP_STREAM=.*|RTSP_STREAM=|' /etc/birdnet/birdnet.conf
run_refresh

grep -q '/var/tmp/avian-service-refresh.' "$test_root/mktemp.log" \
  || fail 'service refresh did not place its verified fetch on persistent storage'
if find /var/tmp -maxdepth 1 -type d -name 'avian-service-refresh.*' \
  -print -quit | grep -q .; then
  fail 'service refresh left its verified fetch workspace behind'
fi

[ -f /etc/sudoers.d/020_avian-admin ] \
  || fail 'security policy hook did not install its focused sudo rule'
[ ! -e /etc/sudoers.d/010_caddy-nopasswd ] \
  || fail 'legacy unrestricted sudo rule survived'
[ ! -e "$test_root/apt.called" ] || fail 'service refresh ran a package command'
grep -qx 'cron sentinel' /etc/crontab || fail 'crontab was changed'
grep -qx 'keep local bin' /usr/local/bin/avian-refresh-unknown \
  || fail 'unknown /usr/local/bin file was changed'

for helper in \
  avian-update-control avian-service-refresh avian-maintenance-control \
  avian-archive-control avian-security-refresh avian-admin-control \
  avian-link-webroot avian-caddy-refresh; do
  [ "$(stat -c '%U:%G:%a' "/usr/local/sbin/$helper")" = root:root:755 ] \
    || fail "unsafe helper installation: $helper"
done
[ "$(stat -c '%U:%G:%a' /usr/local/bin)" = root:root:755 ] \
  || fail '/usr/local/bin permissions changed'
[ "$(grep -c '^reload caddy$' "$test_root/systemctl.log")" -eq 2 ] \
  || fail 'real root-owned Caddy refresh was not idempotently invoked'
if [ ! -L /usr/local/bin/example.sh ] \
  || [ "$(readlink /usr/local/bin/example.sh)" != "$repo/scripts/example.sh" ]; then
  fail 'tracked script symlink was not refreshed'
fi

for target in \
  avian index.html styles.css apt.js masks.json dims.json nest.webp nest-eggs.webp \
  stamps.css stamps.js stamp-batch-root.css stamp-batch-root.js \
  stamp-batch-a.css stamp-batch-a.js stamp-batch-b.css stamp-batch-b.js \
  stamp-batch-c.css stamp-batch-c.js grain.png stats-press.png fonts assets \
  favicon.png favicon.ico; do
  [ -L "$webroot/$target" ] || fail "webroot link missing: $target"
done

# Three reloads belong to each full refresh: live-stream policy, final service
# refresh, and Icecast start guard. The explicit safe audio-policy check adds
# one more. The phase checks above prevent duplicate reloads from canceling out.
[ "$(grep -c '^daemon-reload$' "$test_root/systemctl.log")" -eq 7 ] \
  || fail 'daemon reload was not idempotent'
[ "$(grep -c '^stop livestream.service$' "$test_root/systemctl.log")" -eq 2 ] \
  || fail 'direct ALSA mode did not stop live streaming'
if grep -q '^disable .*livestream.service$' "$test_root/systemctl.log"; then
  fail 'direct ALSA mode disabled the live stream unit'
fi
[ -f /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf ] \
  || fail 'live stream restart drop-in was not installed'
[ "$(stat -c '%U:%G:%a' /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf)" = root:root:644 ] \
  || fail 'live stream restart drop-in permissions are unsafe'
grep -qx 'Restart=always' \
  /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf \
  || fail 'live stream restart drop-in has the wrong policy'
grep -qx 'ExecCondition=/usr/local/bin/livestream.sh --check' \
  /etc/systemd/system/livestream.service.d/10-avian-visitors-restart.conf \
  || fail 'live stream restart drop-in lacks its capture condition'

# Re-enter through the exact old helper with an already-required state and an
# active Icecast unit. The newly installed Caddy helper must publish one atomic
# restore-intent record, close the route, and stop the backend before the old
# process can report success.
required_verifier=$(cut -f4 "$auth_state")
printf 'v1\t1\t1\t%s\n' "$required_verifier" >"$auth_state"
chown root:caddy "$auth_state"
chmod 0640 "$auth_state"
rm -f "$auth_dir/icecast-start-blocked" "$auth_dir/icecast-restore-on-unlock"
touch "$test_root/icecast-active"
stops_before=$(grep -c '^stop icecast2$' "$test_root/systemctl.log" || true)
kills_before=$(grep -c '^kill --kill-who=all --signal=KILL icecast2$' \
  "$test_root/systemctl.log" || true)
cp "$previous_refresh" /usr/local/sbin/avian-service-refresh
chown root:root /usr/local/sbin/avian-service-refresh
chmod 0755 /usr/local/sbin/avian-service-refresh
/usr/local/sbin/avian-service-refresh >"$test_root/required-first-hop.log" 2>&1 \
  || fail 'already-required active first-hop refresh failed'
[ "$(cat "$auth_dir/icecast-start-blocked")" = \
  "v2"$'\t'"blocked"$'\t'"yes" ] \
  || fail 'already-required first-hop lost active Icecast restore intent'
[ "$(stat -c '%U:%G:%a:%h' "$auth_dir/icecast-start-blocked")" = \
  root:root:400:1 ] \
  || fail 'already-required first-hop transition metadata is unsafe'
[ ! -e "$test_root/icecast-active" ] \
  || fail 'already-required first-hop left Icecast active'
[ "$(grep -c '^stop icecast2$' "$test_root/systemctl.log")" -eq \
  $((stops_before + 1)) ] \
  || fail 'already-required first-hop did not stop Icecast exactly once'
[ "$(grep -c '^kill --kill-who=all --signal=KILL icecast2$' \
  "$test_root/systemctl.log")" -eq $((kills_before + 1)) ] \
  || fail 'already-required first-hop did not verify the unit-wide cutoff'
first_stream_instruction=$(awk '
  /handle @stream/ { stream=1; next }
  stream && /route[[:space:]]*{/ { route=1; next }
  route && NF { sub(/^[[:space:]]*/, ""); print; exit }
' /etc/caddy/Caddyfile)
[ "$first_stream_instruction" = 'respond 404' ] \
  || fail 'already-required first-hop did not close the Caddy stream route'

# A checkout change to code that would become privileged must fail before the
# installed helper or security policy is replaced.
installed_hash=$(sha256sum /usr/local/sbin/avian-maintenance-control | cut -d' ' -f1)
printf 'dirty\n' >>"$repo/scripts/maintenance_control.sh"
chown "$station_user:$station_user" "$repo/scripts/maintenance_control.sh"
rm -f /etc/sudoers.d/020_avian-admin
if /usr/local/sbin/avian-service-refresh >"$test_root/dirty.log" 2>&1; then
  fail 'dirty privileged helper was accepted'
fi
[ ! -e /etc/sudoers.d/020_avian-admin ] \
  || fail 'dirty helper reached security hook'
[ "$(sha256sum /usr/local/sbin/avian-maintenance-control | cut -d' ' -f1)" = "$installed_hash" ] \
  || fail 'dirty helper replaced the installed copy'

# A station-owned commit and tracking ref cannot authorize new root code. The
# trusted fetch remains on the release committed to the disposable remote.
as_station() {
  runuser -u "$station_user" -- env HOME="$station_home" \
    USER="$station_user" LOGNAME="$station_user" \
    PATH=/usr/local/bin:/usr/bin:/bin "$@"
}
as_station git -C "$repo" add scripts/maintenance_control.sh
as_station git -C "$repo" commit -qm 'forged local helper'
as_station git -C "$repo" update-ref refs/remotes/origin/avian-visitors HEAD
if /usr/local/sbin/avian-service-refresh >"$test_root/forged.log" 2>&1; then
  fail 'station-owned commit was accepted as official helper code'
fi
grep -q 'checkout is not the current official' "$test_root/forged.log" \
  || fail 'unverified checkout failure was unclear'
[ "$(sha256sum /usr/local/sbin/avian-maintenance-control | cut -d' ' -f1)" = "$installed_hash" ] \
  || fail 'station-owned commit replaced the installed helper'

# A root process cannot bypass the installed-copy boundary by executing the
# station-owned checkout script directly.
if "$repo/scripts/reinstall_services.sh" >"$test_root/direct.log" 2>&1; then
  fail 'root executed the checkout refresher directly'
fi

echo 'reinstall services smoke: ok'
