#!/usr/bin/env bash

set -u

PASS=0
WARN=0
FAIL=0

BIRDNET_HOME="${HOME}/BirdNET-Pi"
FRAME_PNG="${HOME}/BirdSongs/Extracted/frame/frame.png"
FRAME_URL="http://birdnet.local/frame/frame.png"
WEB_URL="http://birdnet.local/"
GENERATION_LOCK="/run/lock/avian-generation.lock"

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

echo "AvianVisitors / BirdNET health check"
echo "=================================="
echo

# ------------------------------------------------------------
# Repository / installation
# ------------------------------------------------------------

if [ -d "${BIRDNET_HOME}" ]; then
  pass "BirdNET-Pi installation exists"
else
  fail "BirdNET-Pi installation not found: ${BIRDNET_HOME}"
fi

if [ -d "${BIRDNET_HOME}/.git" ]; then
  branch="$(git -C "${BIRDNET_HOME}" branch --show-current 2>/dev/null || true)"
  if [ -n "${branch}" ]; then
    pass "BirdNET-Pi Git checkout detected (${branch})"
  else
    warn "BirdNET-Pi Git checkout exists but branch could not be determined"
  fi
else
  warn "BirdNET-Pi is not a Git checkout"
fi

# ------------------------------------------------------------
# systemd
# ------------------------------------------------------------

failed_units="$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)"

if [ "${failed_units}" -eq 0 ]; then
  pass "No failed systemd units"
else
  fail "${failed_units} failed systemd unit(s)"
  systemctl --failed --no-pager
fi

if systemctl is-active --quiet caddy.service; then
  pass "Caddy is active"
else
  fail "Caddy is not active"
fi

if systemctl is-enabled --quiet caddy.service 2>/dev/null; then
  pass "Caddy is enabled"
else
  warn "Caddy is not enabled"
fi

# ------------------------------------------------------------
# Caddy access to /home
# ------------------------------------------------------------

caddy_pid="$(systemctl show caddy.service -p MainPID --value 2>/dev/null || true)"
user_gid="$(id -g "${USER}" 2>/dev/null || true)"

if [ -n "${caddy_pid}" ] && [ "${caddy_pid}" != "0" ] && [ -r "/proc/${caddy_pid}/status" ]; then
  caddy_groups="$(
    awk '/^Groups:/ {
      for (i=2; i<=NF; i++) print $i
    }' "/proc/${caddy_pid}/status"
  )"

  if printf '%s\n' "${caddy_groups}" | grep -qx "${user_gid}"; then
    pass "Caddy has access to ${USER}'s group"
  else
    fail "Caddy is missing supplementary group ${USER} (${user_gid})"
  fi
else
  warn "Could not inspect Caddy process groups"
fi

# ------------------------------------------------------------
# HTTP
# ------------------------------------------------------------

check_http() {
  local url="$1"
  local description="$2"
  local code

  code="$(curl \
    --silent \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 10 \
    "${url}" 2>/dev/null || true)"

  if [ "${code}" = "200" ]; then
    pass "${description} returns HTTP 200"
  elif [ -z "${code}" ] || [ "${code}" = "000" ]; then
    fail "${description} is unreachable"
  else
    fail "${description} returns HTTP ${code}"
  fi
}

check_http "${WEB_URL}" "AvianVisitors web"
check_http "${FRAME_URL}" "Frame image"

# ------------------------------------------------------------
# Frame renderer
# ------------------------------------------------------------

if systemctl cat avian-frame-render.service >/dev/null 2>&1; then
  pass "avian-frame-render.service is installed"
else
  fail "avian-frame-render.service is not installed"
fi

if systemctl cat avian-frame-render.timer >/dev/null 2>&1; then
  pass "avian-frame-render.timer is installed"
else
  fail "avian-frame-render.timer is not installed"
fi

if systemctl is-active --quiet avian-frame-render.timer; then
  pass "avian-frame-render.timer is active"
else
  fail "avian-frame-render.timer is not active"
fi

if systemctl is-enabled --quiet avian-frame-render.timer 2>/dev/null; then
  pass "avian-frame-render.timer is enabled"
else
  fail "avian-frame-render.timer is not enabled"
fi

next_frame="$(
  systemctl list-timers avian-frame-render.timer \
    --no-legend \
    --no-pager 2>/dev/null \
    | awk '{$1=$1; print}' \
    | cut -d' ' -f1-4
)"

if [ -n "${next_frame}" ]; then
  pass "Next frame render scheduled: ${next_frame}"
else
  warn "Could not determine next frame render"
fi

# ------------------------------------------------------------
# frame.png
# ------------------------------------------------------------

if [ -f "${FRAME_PNG}" ]; then
  pass "frame.png exists"

  now="$(date +%s)"
  modified="$(stat -c %Y "${FRAME_PNG}")"
  age_minutes=$(( (now - modified) / 60 ))
  pass "frame.png age is ${age_minutes} minute(s) (unchanged frames are expected)"
else
  fail "frame.png does not exist: ${FRAME_PNG}"
fi

renderer_result="$(
  systemctl show avian-frame-render.service     -p Result     --value 2>/dev/null || true
)"

renderer_status="$(
  systemctl show avian-frame-render.service     -p ExecMainStatus     --value 2>/dev/null || true
)"

renderer_finished="$(
  systemctl show avian-frame-render.service     -p ExecMainExitTimestamp     --value 2>/dev/null || true
)"

if [ "${renderer_result}" = "success" ] && [ "${renderer_status}" = "0" ]; then
  if [ -n "${renderer_finished}" ]; then
    pass "Last frame render succeeded: ${renderer_finished}"
  else
    pass "Last frame render succeeded"
  fi
else
  fail "Last frame render failed (Result=${renderer_result:-unknown}, status=${renderer_status:-unknown})"
fi

# ------------------------------------------------------------
# Renderer Python environment
# ------------------------------------------------------------

FRAME_PYTHON="${BIRDNET_HOME}/frame/server/.venv/bin/python"

if [ -x "${FRAME_PYTHON}" ]; then
  pass "Frame Python virtual environment exists"

  if "${FRAME_PYTHON}" -c 'import PIL' >/dev/null 2>&1; then
    pass "Pillow is importable"
  else
    fail "Pillow is not importable in frame venv"
  fi

  if "${FRAME_PYTHON}" -c 'import playwright' >/dev/null 2>&1; then
    pass "Playwright is importable"
  else
    fail "Playwright is not importable in frame venv"
  fi
else
  fail "Frame Python virtual environment not found"
fi

# ------------------------------------------------------------
# Generation lock
# ------------------------------------------------------------

if [ -f "${GENERATION_LOCK}" ]; then
  lock_state="$(stat -c '%U:%G:%a:%h' "${GENERATION_LOCK}" 2>/dev/null || true)"

  if [ "${lock_state}" = "root:caddy:660:1" ]; then
    pass "Illustration generation lock is safe"
  else
    fail "Unexpected generation lock: ${lock_state}"
  fi
else
  fail "Illustration generation lock does not exist"
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "=================================="
printf 'PASS: %d   WARN: %d   FAIL: %d\n' "${PASS}" "${WARN}" "${FAIL}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi

exit 0
