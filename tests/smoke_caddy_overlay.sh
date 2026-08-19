#!/usr/bin/env bash
# Run inside a disposable Debian container with the repository at /source.
# Exercises the optional, root-owned local Caddy overlay without touching a
# host installation.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f /.dockerenv ] || fail "this smoke test must run in a disposable container"
[ "$(id -u)" -eq 0 ] || fail "this smoke test must run as root"

test_root=/tmp/avian-caddy-overlay-smoke
overlay=/etc/caddy/avian-site-overlay.caddy
generator=/source/scripts/update_caddyfile.sh
mkdir -p "$test_root" /etc/birdnet /etc/caddy /srv/avian /usr/sbin

if ! getent group caddy >/dev/null; then
  groupadd --system caddy
fi
caddy_gid=$(getent group caddy | awk -F: 'NR == 1 { print $3 }')
[ -n "$caddy_gid" ] || fail "could not resolve the caddy group"

cat >/etc/birdnet/birdnet.conf <<'EOF'
BIRDNET_USER=bird
EXTRACTED=/srv/avian
CADDY_PWD=
EOF

cat >/usr/sbin/caddy <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test_root=/tmp/avian-caddy-overlay-smoke
case "${1:-}" in
  fmt)
    printf 'fmt\n' >>"$test_root/order.log"
    ;;
  validate)
    printf 'validate\n' >>"$test_root/order.log"
    [ ! -e "$test_root/fail-validate" ]
    ;;
  *)
    echo "unexpected caddy command: $*" >&2
    exit 1
    ;;
esac
EOF

cat >/usr/sbin/systemctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>/tmp/avian-caddy-overlay-smoke/order.log
EOF
chmod 0755 /usr/sbin/caddy /usr/sbin/systemctl

reset_logs() {
  : >"$test_root/order.log"
  rm -f "$test_root/fail-validate"
}

remove_overlay() {
  if [ -d "$overlay" ] && [ ! -L "$overlay" ]; then
    rmdir "$overlay"
  elif [ -e "$overlay" ] || [ -L "$overlay" ]; then
    rm -f "$overlay"
  fi
}

write_original_caddyfile() {
  printf 'original caddy config\n' >/etc/caddy/Caddyfile
}

assert_original_untouched() {
  [ "$(cat /etc/caddy/Caddyfile)" = 'original caddy config' ] \
    || fail "$1 replaced the active Caddyfile"
  if grep -q '^systemctl ' "$test_root/order.log"; then
    fail "$1 reloaded Caddy"
  fi
}

expect_unsafe_refusal() {
  local name=$1
  reset_logs
  write_original_caddyfile
  if bash "$generator" >"$test_root/$name.log" 2>&1; then
    fail "$name overlay was accepted"
  fi
  assert_original_untouched "$name"
  [ ! -s "$test_root/order.log" ] \
    || fail "$name overlay reached Caddy validation"
  grep -q 'Refusing unsafe Caddy site overlay' "$test_root/$name.log" \
    || fail "$name refusal was not explicit"
  remove_overlay
}

# With no local overlay, generation stays identical at the site-block opening:
# no import and no extra blank line.
remove_overlay
reset_logs
write_original_caddyfile
bash "$generator"
[ "$(sed -n '2p' /etc/caddy/Caddyfile)" = 'http:// {' ] \
  || fail "generated site block is missing"
[ "$(sed -n '3p' /etc/caddy/Caddyfile)" = '  root * /srv/avian' ] \
  || fail "an absent overlay changed the generated site block"
if grep -q 'avian-site-overlay' /etc/caddy/Caddyfile; then
  fail "an absent overlay was imported"
fi
[ "$(tr '\n' ' ' <"$test_root/order.log")" = 'fmt validate systemctl reload-or-restart caddy ' ] \
  || fail "the normal validation and reload order changed"

# A valid overlay is referenced, not copied, and is placed before managed site
# directives so station-local routing can gate the whole generated site.
cat >"$overlay" <<'EOF'
@localOverlay path /local-overlay-test
respond @localOverlay 418
EOF
chown root:caddy "$overlay"
chmod 0640 "$overlay"
cp "$overlay" "$test_root/valid-overlay.expected"
reset_logs
write_original_caddyfile
bash "$generator"
[ "$(sed -n '3p' /etc/caddy/Caddyfile)" = "  import $overlay" ] \
  || fail "valid overlay was not imported at the top of the site block"
[ "$(sed -n '4p' /etc/caddy/Caddyfile)" = '  root * /srv/avian' ] \
  || fail "managed site directives do not follow the overlay import"
if grep -q '@localOverlay' /etc/caddy/Caddyfile; then
  fail "overlay contents were copied into the generated Caddyfile"
fi
[ "$(stat -c '%U:%G:%a:%h' "$overlay")" = 'root:caddy:640:1' ] \
  || fail "valid overlay fixture metadata changed"
cmp -s "$overlay" "$test_root/valid-overlay.expected" \
  || fail "valid overlay contents changed"
[ "$(tr '\n' ' ' <"$test_root/order.log")" = 'fmt validate systemctl reload-or-restart caddy ' ] \
  || fail "valid overlay changed validation and reload order"
remove_overlay

# A symlink cannot redirect the privileged import to another file.
cat >"$test_root/symlink-target" <<'EOF'
respond /redirected 200
EOF
chown root:caddy "$test_root/symlink-target"
chmod 0640 "$test_root/symlink-target"
ln -s "$test_root/symlink-target" "$overlay"
expect_unsafe_refusal symlink

# A second hard link would let another pathname replace the imported content.
cat >"$test_root/hardlink-source" <<'EOF'
respond /hardlinked 200
EOF
chown root:caddy "$test_root/hardlink-source"
chmod 0640 "$test_root/hardlink-source"
ln "$test_root/hardlink-source" "$overlay"
expect_unsafe_refusal hardlink
rm -f "$test_root/hardlink-source"

printf 'respond /wrong-owner 200\n' >"$overlay"
chown 65534:caddy "$overlay"
chmod 0640 "$overlay"
expect_unsafe_refusal wrong-owner

printf 'respond /wrong-group 200\n' >"$overlay"
chown root:root "$overlay"
chmod 0640 "$overlay"
expect_unsafe_refusal wrong-group

printf 'respond /wrong-mode 200\n' >"$overlay"
chown root:caddy "$overlay"
chmod 0644 "$overlay"
expect_unsafe_refusal wrong-mode

mkfifo "$overlay"
chown root:caddy "$overlay"
chmod 0640 "$overlay"
expect_unsafe_refusal fifo

mkdir "$overlay"
chown root:caddy "$overlay"
chmod 0750 "$overlay"
expect_unsafe_refusal directory

# A syntactically invalid but safely owned overlay must fail validation before
# the active Caddyfile is replaced or the service is reloaded.
printf 'this is deliberately invalid caddy syntax\n' >"$overlay"
chown root:caddy "$overlay"
chmod 0640 "$overlay"
reset_logs
touch "$test_root/fail-validate"
write_original_caddyfile
if bash "$generator" >"$test_root/validation.log" 2>&1; then
  fail "failed Caddy validation was ignored"
fi
assert_original_untouched validation
[ "$(tr '\n' ' ' <"$test_root/order.log")" = 'fmt validate ' ] \
  || fail "Caddy validation did not happen before reload"
if find /etc/caddy -maxdepth 1 -name '.Caddyfile.*' -print -quit | grep -q .; then
  fail "failed validation left a temporary Caddyfile"
fi

echo 'Caddy overlay smoke: ok'
