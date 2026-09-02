#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

birdnet_installer="$repo/scripts/install_birdnet.sh"
services_installer="$repo/scripts/install_services.sh"
frame_installer="$repo/frame/display/install.sh"

[ -f "$birdnet_installer" ] || fail "BirdNET installer is missing"
[ -f "$services_installer" ] || fail "services installer is missing"
[ -f "$frame_installer" ] || fail "frame installer is missing"

# ---------------------------------------------------------------------------
# BirdNET virtual environment
# ---------------------------------------------------------------------------

grep -Fq 'if [ ! -x birdnet/bin/python ]; then' "$birdnet_installer" \
  || fail "BirdNET venv is not guarded against recreation"

grep -A2 -F 'if [ ! -x birdnet/bin/python ]; then' "$birdnet_installer" \
  | grep -Fq 'python3 -m venv birdnet' \
  || fail "BirdNET venv creation is not inside the existence guard"

echo "PASS: existing BirdNET venv is reused"

# ---------------------------------------------------------------------------
# bird_tmp ownership / cleanup
# ---------------------------------------------------------------------------

grep -Fq 'local bird_tmp_created=0' "$birdnet_installer" \
  || fail "bird_tmp ownership flag is missing"

grep -Fq 'bird_tmp_created=1' "$birdnet_installer" \
  || fail "bird_tmp creation is not tracked"

grep -Fq 'if [ "$bird_tmp_created" -eq 1 ]; then' "$birdnet_installer" \
  || fail "bird_tmp cleanup is not conditional"

if grep -Eq '^[[:space:]]*rm -rf[[:space:]]+\$HOME/bird_tmp[[:space:]]*$' "$birdnet_installer"; then
  fail "unconditional bird_tmp removal is still present"
fi

echo "PASS: pre-existing bird_tmp is protected"

# ---------------------------------------------------------------------------
# birdpic virtual environment
# ---------------------------------------------------------------------------

grep -Fq 'if [ ! -x .venv/bin/python ]; then' "$frame_installer" \
  || fail "birdpic venv is not guarded against recreation"

grep -A2 -F 'if [ ! -x .venv/bin/python ]; then' "$frame_installer" \
  | grep -Fq 'python3 -m venv .venv' \
  || fail "birdpic venv creation is not inside the existence guard"

echo "PASS: existing birdpic venv is reused"

# ---------------------------------------------------------------------------
# systemd getty override
# ---------------------------------------------------------------------------

grep -Fq 'mkdir -p /etc/systemd/system/getty@tty1.service.d' "$services_installer" \
  || fail "getty override directory is not created idempotently"

if grep -Eq '^[[:space:]]*mkdir[[:space:]]+/etc/systemd/system/getty@tty1\.service\.d' "$services_installer"; then
  fail "non-idempotent getty mkdir is still present"
fi

echo "PASS: getty override directory creation is idempotent"

echo
echo "installer idempotency smoke: ok"
