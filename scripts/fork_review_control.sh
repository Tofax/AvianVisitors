#!/usr/bin/env bash
# Root-owned control plane for the illustration fork review server.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

readonly CONTROL_HELPER=/usr/local/sbin/avian-fork-review
readonly UNIT=avian-fork-review
readonly PORT=8765
readonly STATE_DIR=/var/lib/avian-fork-review
readonly TOKEN_FILE=$STATE_DIR/access-token

json_escape() {
  local value=${1-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

fail() {
  local message=${1:-fork review control failed}
  printf '{"ok":false,"error":"%s"}\n' "$(json_escape "$message")"
  exit 1
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fail 'fork review control must run as root'
[ "$(readlink -f "$0")" = "$CONTROL_HELPER" ] \
  || fail "fork review must use $CONTROL_HELPER"

birdnet_user() {
  local user
  user=$(awk -F= '
    $1 == "BIRDNET_USER" {
      gsub(/^[ \t"]+|[ \t"]+$/, "", $2)
      print $2
      exit
    }
  ' /etc/birdnet/birdnet.conf 2>/dev/null || true)

  [ -n "$user" ] || user=$(stat -c '%U' /home/*/BirdNET-Pi 2>/dev/null | head -1)
  [ -n "$user" ] || fail 'could not determine BirdNET user'
  printf '%s' "$user"
}

repo_dir() {
  local user dir
  user=$(birdnet_user)
  dir="/home/$user/BirdNET-Pi"
  [ -d "$dir" ] || fail 'BirdNET-Pi checkout not found'
  printf '%s' "$dir"
}

read_token() {
  [ -r "$TOKEN_FILE" ] || return 0
  tr -d '\r\n' <"$TOKEN_FILE"
}

write_token() {
  local token=$1 temp
  install -d -o root -g root -m 0700 "$STATE_DIR"
  temp=$(mktemp "$STATE_DIR/.access-token.XXXXXX") \
    || fail 'could not create fork review token'
  printf '%s\n' "$token" >"$temp"
  install -o root -g root -m 0600 "$temp" "$TOKEN_FILE"
  rm -f "$temp"
}

print_status() {
  local active token=''
  active=$(systemctl is-active "$UNIT.service" 2>/dev/null || true)

  case "$active" in
    active|activating)
      token=$(read_token)
      [ -n "$token" ] || fail 'fork review access token is missing'
      printf '{"ok":true,"running":true,"port":%s,"access_token":"%s"}\n' \
        "$PORT" "$(json_escape "$token")"
      ;;
    *)
      printf '{"ok":true,"running":false,"port":%s}\n' "$PORT"
      ;;
  esac
}

start_server() {
  local user root token
  user=$(birdnet_user)
  root=$(repo_dir)

  if systemctl is-active --quiet "$UNIT.service"; then
    print_status
    return 0
  fi

  systemctl reset-failed "$UNIT.service" >/dev/null 2>&1 || true

  token=$(
    od -An -N32 -tx1 /dev/urandom \
      | tr -d ' \n'
  )
  [ "${#token}" -eq 64 ] || fail 'could not generate fork review access token'
  write_token "$token"

  if ! systemd-run --quiet --collect \
    --unit="$UNIT" \
    --uid="$user" \
    --working-directory="$root" \
    --property=Type=simple \
    --property=Restart=no \
    --setenv="AVIAN_REVIEW_ACCESS_TOKEN=$token" \
    /usr/bin/python3 \
      "$root/avian/scripts/review_illustrations.py" \
      --region ES-CT \
      --locale ca \
      --labels "$root/model/labels.txt" \
      --serve-existing \
      --host 0.0.0.0 \
      --port "$PORT" \
      --no-browser; then
    rm -f "$TOKEN_FILE"
    fail 'could not start fork review server'
  fi

  sleep 1

  if ! systemctl is-active --quiet "$UNIT.service"; then
    rm -f "$TOKEN_FILE"
    fail 'fork review server did not stay running'
  fi

  print_status
}

stop_server() {
  systemctl stop "$UNIT.service" >/dev/null 2>&1 || true
  rm -f "$TOKEN_FILE"
  print_status
}

action=${1:-status}
case "$action" in
  status)
    [ "$#" -eq 1 ] || fail 'unexpected arguments'
    print_status
    ;;
  start)
    [ "$#" -eq 1 ] || fail 'unexpected arguments'
    start_server
    ;;
  stop)
    [ "$#" -eq 1 ] || fail 'unexpected arguments'
    stop_server
    ;;
  *)
    fail 'unknown action'
    ;;
esac
