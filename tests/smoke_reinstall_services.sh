#!/usr/bin/env bash
# Run as root in a disposable Debian container with the repository at /source.

set -euo pipefail
IFS=$'\n\t'

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

cp /source/scripts/reinstall_services.sh "$repo/scripts/reinstall_services.sh"
for helper in update_birdnet maintenance_control archive_control admin_control; do
  cat >"$repo/scripts/$helper.sh" <<EOF
#!/usr/bin/env bash
echo $helper
EOF
done
cp /source/scripts/link_webroot.sh "$repo/scripts/link_webroot.sh"
cat >"$repo/scripts/update_caddyfile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>/tmp/avian-service-refresh-smoke/caddy.called
EOF
cat >"$repo/scripts/security_refresh.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch /tmp/avian-service-refresh-smoke/security.called
rm -f /etc/sudoers.d/010_caddy-nopasswd
EOF
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
EOF
printf 'legacy broad rule\n' >/etc/sudoers.d/010_caddy-nopasswd
printf 'cron sentinel\n' >/etc/crontab
printf 'keep local bin\n' >/usr/local/bin/avian-refresh-unknown
chown root:root /usr/local/bin
chmod 0755 /usr/local/bin

cat >/usr/local/bin/systemctl <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>/tmp/avian-service-refresh-smoke/systemctl.log
case "${1:-}" in
  is-active) echo active ;;
esac
exit 0
EOF
cat >/usr/local/bin/apt <<'EOF'
#!/usr/bin/env bash
touch /tmp/avian-service-refresh-smoke/apt.called
exit 99
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
chmod 0755 /usr/local/bin/systemctl /usr/local/bin/apt /usr/local/bin/mktemp

cp /source/scripts/reinstall_services.sh /usr/local/sbin/avian-service-refresh
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
[ ! -e "$test_root/security.called" ] \
  || fail 'contended service refresh changed security state'
flock -u 8
exec 8>&-

# The updater passes its already locked descriptor to avoid deadlocking its
# own post-update refresh.
exec 9<>/run/lock/avian-update.lock
flock -n 9 || fail 'could not hold inherited update lock for test'
AVIAN_UPDATE_LOCK_FD=9 /usr/local/sbin/avian-service-refresh --legacy-migration \
  >"$test_root/refresh.log" 2>&1 || fail 'inherited-lock service refresh failed'
flock -u 9
exec 9>&-
run_refresh

grep -q '/var/tmp/avian-service-refresh.' "$test_root/mktemp.log" \
  || fail 'service refresh did not place its verified fetch on persistent storage'
if find /var/tmp -maxdepth 1 -type d -name 'avian-service-refresh.*' \
  -print -quit | grep -q .; then
  fail 'service refresh left its verified fetch workspace behind'
fi

[ -e "$test_root/security.called" ] || fail 'security policy hook was not called'
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
[ "$(grep -c '^called$' "$test_root/caddy.called")" -eq 2 ] \
  || fail 'root-owned Caddy refresh was not idempotently invoked'
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

[ "$(grep -c '^daemon-reload$' "$test_root/systemctl.log")" -eq 2 ] \
  || fail 'daemon reload was not idempotent'

# A checkout change to code that would become privileged must fail before the
# installed helper or security policy is replaced.
installed_hash=$(sha256sum /usr/local/sbin/avian-maintenance-control | cut -d' ' -f1)
printf 'dirty\n' >>"$repo/scripts/maintenance_control.sh"
chown "$station_user:$station_user" "$repo/scripts/maintenance_control.sh"
rm -f "$test_root/security.called"
if /usr/local/sbin/avian-service-refresh >"$test_root/dirty.log" 2>&1; then
  fail 'dirty privileged helper was accepted'
fi
[ ! -e "$test_root/security.called" ] || fail 'dirty helper reached security hook'
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
