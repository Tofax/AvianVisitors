#!/usr/bin/env bash

set -u

PASS=0
WARN=0
FAIL=0

FRAME_DIR="${HOME}/AvianVisitors/frame"
CONFIG="${HOME}/.birdframe/config.toml"
FRAME_URL="http://birdnet.local/frame/frame.png"
WAVESHARE_LIB="${HOME}/RPi_Zero_PhotoPainter/7in3_e-Paper_E/python/lib"
PYTHON="${FRAME_DIR}/.venv/bin/python"

pass() {
  printf '✓ %s\n' "$1"
  PASS=$((PASS + 1))
}

warn() {
  printf '! %s\n' "$1"
  WARN=$((WARN + 1))
}

fail() {
  printf '✗ %s\n' "$1"
  FAIL=$((FAIL + 1))
}

echo "AvianVisitors / birdpic health check"
echo "===================================="
echo

# ------------------------------------------------------------
# Repository
# ------------------------------------------------------------

if [ -d "${HOME}/AvianVisitors/.git" ]; then
  branch="$(git -C "${HOME}/AvianVisitors" branch --show-current 2>/dev/null || true)"

  if [ "${branch}" = "catalan" ]; then
    pass "AvianVisitors checkout is on catalan"
  else
    warn "AvianVisitors checkout is on '${branch:-unknown}', expected catalan"
  fi
else
  fail "AvianVisitors Git checkout not found"
fi

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

if [ -f "${CONFIG}" ]; then
  pass "birdframe config exists"
else
  fail "birdframe config not found: ${CONFIG}"
fi

if grep -Eq '^[[:space:]]*panel[[:space:]]*=[[:space:]]*"waveshare_7in3e"' "${CONFIG}" 2>/dev/null; then
  pass "Panel is configured as waveshare_7in3e"
else
  fail "Panel is not configured as waveshare_7in3e"
fi

if grep -Eq '^[[:space:]]*image_url[[:space:]]*=[[:space:]]*"http://birdnet\.local/frame/frame\.png"' "${CONFIG}" 2>/dev/null; then
  pass "Frame image URL is configured correctly"
else
  warn "Frame image URL is not the expected birdnet.local URL"
fi

# ------------------------------------------------------------
# Network / image
# ------------------------------------------------------------

if getent hosts birdnet.local >/dev/null 2>&1; then
  pass "birdnet.local resolves"
else
  fail "birdnet.local does not resolve"
fi

http_code="$(
  curl \
    --silent \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 10 \
    "${FRAME_URL}" 2>/dev/null || true
)"

if [ "${http_code}" = "200" ]; then
  pass "Frame image returns HTTP 200"
else
  fail "Frame image returns HTTP ${http_code:-000}"
fi

# ------------------------------------------------------------
# systemd
# ------------------------------------------------------------

if systemctl cat birdframe.service >/dev/null 2>&1; then
  pass "birdframe.service is installed"
else
  fail "birdframe.service is not installed"
fi

if systemctl cat birdframe.timer >/dev/null 2>&1; then
  pass "birdframe.timer is installed"
else
  fail "birdframe.timer is not installed"
fi

if systemctl is-active --quiet birdframe.timer; then
  pass "birdframe.timer is active"
else
  fail "birdframe.timer is not active"
fi

if systemctl is-enabled --quiet birdframe.timer 2>/dev/null; then
  pass "birdframe.timer is enabled"
else
  fail "birdframe.timer is not enabled"
fi

last_log="$(
  journalctl \
    -u birdframe.service \
    -n 100 \
    --no-pager \
    2>/dev/null || true
)"

if printf '%s\n' "${last_log}" | grep -q "panel updated"; then
  pass "A successful panel update is present in the journal"
else
  warn "No successful 'panel updated' entry found"
fi

if printf '%s\n' "${last_log}" | tail -30 | grep -q "panel push failed"; then
  fail "Recent birdframe log contains 'panel push failed'"
else
  pass "No recent panel push failure detected"
fi

# ------------------------------------------------------------
# Python environment
# ------------------------------------------------------------

if [ -x "${PYTHON}" ]; then
  pass "birdframe Python virtual environment exists"
else
  fail "birdframe Python virtual environment not found"
fi

check_python_module() {
  local module="$1"

  if [ -x "${PYTHON}" ] && "${PYTHON}" -c "import ${module}" >/dev/null 2>&1; then
    pass "Python module '${module}' is importable"
  else
    fail "Python module '${module}' is not importable"
  fi
}

check_python_module PIL
check_python_module gpiozero
check_python_module lgpio
check_python_module spidev

# ------------------------------------------------------------
# Waveshare driver
# ------------------------------------------------------------

if [ -d "${WAVESHARE_LIB}/waveshare_epd" ]; then
  pass "Waveshare E6 Python library exists"
else
  fail "Waveshare E6 Python library not found: ${WAVESHARE_LIB}"
fi

if [ -f "${WAVESHARE_LIB}/waveshare_epd/epd7in3e.py" ]; then
  pass "Waveshare epd7in3e driver exists"
else
  fail "Waveshare epd7in3e driver not found"
fi

# ------------------------------------------------------------
# SPI / I2C
# ------------------------------------------------------------

if [ -e /dev/spidev0.0 ] || [ -e /dev/spidev0.1 ]; then
  pass "SPI device is available"
else
  fail "No SPI device found"
fi

if compgen -G '/dev/i2c-*' >/dev/null; then
  pass "I2C device is available"
else
  warn "No I2C device found"
fi

# ------------------------------------------------------------
# Failed units
# ------------------------------------------------------------

failed_units="$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)"

if [ "${failed_units}" -eq 0 ]; then
  pass "No failed systemd units"
else
  fail "${failed_units} failed systemd unit(s)"
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "===================================="
printf 'PASS: %d   WARN: %d   FAIL: %d\n' "${PASS}" "${WARN}" "${FAIL}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi

exit 0
