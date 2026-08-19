#!/usr/bin/env bash
# Privileged control plane for the optional AvianVisitors Drive archive.
#
# The web UI may invoke only the fixed actions below. OAuth credentials and
# remote paths never cross the API. The archive worker itself always runs as
# the unprivileged BirdNET-Pi user.

set -u -o pipefail

CONTROL_VERSION=1

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
  local message=${1:-archive control failed}
  printf '{"ok":false,"error":"%s"}\n' "$(json_escape "$message")"
  exit 1
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  fail "archive control must run as root"
fi

birdnet_user=''
if [ -r /etc/birdnet/birdnet.conf ]; then
  birdnet_user=$(awk -F= '
    /^[[:space:]]*BIRDNET_USER[[:space:]]*=/ {
      value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", value);
      print value; exit
    }
  ' /etc/birdnet/birdnet.conf)
fi
if [ -z "$birdnet_user" ]; then
  while IFS=: read -r candidate _ uid _ _ candidate_home shell; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] \
      && [[ "$shell" != *nologin ]] && [[ "$shell" != *false ]] \
      && [ -d "$candidate_home/BirdNET-Pi" ]; then
      birdnet_user=$candidate
      break
    fi
  done < <(getent passwd)
fi
[[ "$birdnet_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || fail "could not resolve the BirdNET-Pi user"

passwd_row=$(getent passwd "$birdnet_user")
[ -n "$passwd_row" ] || fail "BirdNET-Pi user does not exist"
birdnet_home=$(printf '%s\n' "$passwd_row" | cut -d: -f6)
birdnet_group=$(id -gn "$birdnet_user")
[[ "$birdnet_home" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "BirdNET-Pi home path is not safe"
[[ "$birdnet_home" != *'..'* ]] || fail "BirdNET-Pi home path is not safe"

repo_dir="$birdnet_home/BirdNET-Pi"
source_dir="$repo_dir/extras/archive"
archive_dir="$birdnet_home/bird-archive"
archive_script="$archive_dir/archive_to_drive.sh"
archive_conf="$archive_dir/archive.conf"
archive_status="$archive_dir/status"
birdnet_conf="$repo_dir/birdnet.conf"
service_path=/etc/systemd/system/bird-archive.service
timer_path=/etc/systemd/system/bird-archive.timer

conf_value() {
  local file=$1 key=$2 fallback=${3-}
  local value=''
  if [ -r "$file" ]; then
    value=$(awk -v wanted="$key" '
      $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
        value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value);
        if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
        print value; exit
      }
    ' "$file")
  fi
  printf '%s' "${value:-$fallback}"
}

write_conf_value() {
  local key=$1 value=$2
  [ -f "$archive_conf" ] || fail "archive is not installed"
  local temp
  temp=$(mktemp "$archive_dir/.archive.conf.XXXXXX") || fail "could not create archive config"
  if ! awk -v wanted="$key" -v replacement="$value" '
    BEGIN { found=0 }
    $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      print wanted "=" replacement; found=1; next
    }
    { print }
    END { if (!found) print wanted "=" replacement }
  ' "$archive_conf" >"$temp"; then
    rm -f "$temp"
    fail "could not update archive config"
  fi
  install -o "$birdnet_user" -g "$birdnet_group" -m 0600 "$temp" "$archive_conf"
  rm -f "$temp"
}

dependency_state() {
  command -v "$1" >/dev/null 2>&1 && printf true || printf false
}

installed=false
if [ -x "$archive_script" ] && [ -f "$archive_conf" ] && [ -f "$service_path" ] && [ -f "$timer_path" ]; then
  installed=true
fi

remote=$(conf_value "$archive_conf" REMOTE 'gdrive:AvianVisitors')
remote_name=${remote%%:*}
remote_configured=false
if [[ "$remote_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
  for rclone_conf in "$birdnet_home/.config/rclone/rclone.conf" "$birdnet_home/.rclone.conf"; do
    if [ -r "$rclone_conf" ] && awk -v section="[$remote_name]" '
      /^\[/ { active = ($0 == section) }
      active && /^[[:space:]]*type[[:space:]]*=[[:space:]]*drive[[:space:]]*$/ { drive = 1 }
      active && /^[[:space:]]*token[[:space:]]*=/ && /"refresh_token"[[:space:]]*:/ { token = 1 }
      END { exit !(drive && token) }
    ' "$rclone_conf"; then
      remote_configured=true
      break
    fi
  done
fi

preserve=false
max_files=$(conf_value "$birdnet_conf" MAX_FILES_SPECIES 0)
if [[ "$max_files" =~ ^[0-9]+$ ]] && [ "$max_files" -ge 10000 ]; then preserve=true; fi
full_disk=$(conf_value "$birdnet_conf" FULL_DISK '')
retention_ready=false
if [ "$preserve" = true ] && [ "$full_disk" = keep ]; then retention_ready=true; fi

last_state=never
last_at=''
last_detail=''
last_verified_files=0
if [ -r "$archive_status" ]; then
  status_line=$(head -n 1 "$archive_status")
  last_state=${status_line%% *}
  [ "$last_state" = OK ] || [ "$last_state" = FAIL ] || last_state=unknown
  last_at=$(printf '%s' "$status_line" | awk '{print $2}')
  last_detail=$(printf '%s' "$status_line" | cut -d' ' -f3-)
  [ "$last_detail" = "$status_line" ] && last_detail=''
  if [[ "$status_line" =~ verified_files=([0-9]+) ]]; then
    last_verified_files=${BASH_REMATCH[1]}
  fi
fi

timer_enabled=$(systemctl is-enabled bird-archive.timer 2>/dev/null || true)
timer_active=$(systemctl is-active bird-archive.timer 2>/dev/null || true)
service_active=$(systemctl is-active bird-archive.service 2>/dev/null || true)
next_run=$(systemctl show bird-archive.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
purge=$(conf_value "$archive_conf" PURGE false)
[ "$purge" = true ] || purge=false
keep_days=$(conf_value "$archive_conf" KEEP_DAYS 0)
[[ "$keep_days" =~ ^[0-9]+$ ]] || keep_days=0

print_status() {
  printf '{'
  printf '"ok":true,"version":%s,' "$CONTROL_VERSION"
  printf '"installed":%s,' "$installed"
  printf '"dependencies":{"rclone":%s,"sqlite3":%s},' "$(dependency_state rclone)" "$(dependency_state sqlite3)"
  printf '"remote":{"name":"%s","configured":%s},' "$(json_escape "$remote_name")" "$remote_configured"
  printf '"retention":{"preserve":%s,"full_disk":"%s","ready":%s},' "$preserve" "$(json_escape "$full_disk")" "$retention_ready"
  printf '"timer":{"enabled":"%s","active":"%s","next":"%s"},' \
    "$(json_escape "$timer_enabled")" "$(json_escape "$timer_active")" "$(json_escape "$next_run")"
  printf '"service":{"active":"%s"},' "$(json_escape "$service_active")"
  printf '"purge":%s,"keep_days":%s,' "$purge" "$keep_days"
  printf '"last":{"state":"%s","at":"%s","detail":"%s","verified_files":%s}' \
    "$(json_escape "$last_state")" "$(json_escape "$last_at")" "$(json_escape "$last_detail")" "$last_verified_files"
  printf '}\n'
}

require_installed() {
  [ "$installed" = true ] || fail "archive is not installed"
}

require_ready() {
  require_installed
  command -v rclone >/dev/null 2>&1 || fail "rclone is not installed"
  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is not installed"
  [ "$remote_configured" = true ] || fail "rclone remote $remote_name is not configured"
  [ "$retention_ready" = true ] || fail "set Preserve all recordings and When disk fills to keep first"
}

action=${1:-status}
case "$action" in
  status)
    print_status
    ;;
  install)
    [ -f "$source_dir/archive_to_drive.sh" ] || fail "archive extra is missing from this checkout"
    [ -f "$source_dir/archive.conf.example" ] || fail "archive config template is missing"
    install -d -o "$birdnet_user" -g "$birdnet_group" -m 0700 "$archive_dir"
    install -o root -g root -m 0755 "$source_dir/archive_to_drive.sh" "$archive_script"
    if [ ! -f "$archive_conf" ]; then
      install -o "$birdnet_user" -g "$birdnet_group" -m 0600 "$source_dir/archive.conf.example" "$archive_conf"
    else
      chown "$birdnet_user:$birdnet_group" "$archive_conf"
      chmod 0600 "$archive_conf"
    fi
    cat >"$service_path" <<EOF
[Unit]
Description=AvianVisitors nightly Google Drive archive
Wants=network-online.target time-sync.target
After=network-online.target time-sync.target
StartLimitIntervalSec=6h
StartLimitBurst=3

[Service]
Type=oneshot
User=$birdnet_user
UMask=0077
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=$archive_script
TimeoutStartSec=2h
Restart=on-failure
RestartSec=600
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
SystemCallArchitectures=native
EOF
    cat >"$timer_path" <<'EOF'
[Unit]
Description=Nightly AvianVisitors archive at 03:15

[Timer]
OnCalendar=*-*-* 03:15:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$service_path" "$timer_path"
    systemctl daemon-reload >/dev/null 2>&1 || fail "systemd reload failed"
    installed=true
    print_status
    ;;
  enable)
    require_ready
    # A newly enabled schedule always starts copy-only. Cleanup requires its
    # own visible opt-in after the schedule is running.
    if [ "$purge" = true ]; then
      write_conf_value PURGE false
      purge=false
    fi
    systemctl enable --now bird-archive.timer >/dev/null 2>&1 || fail "could not enable the archive timer"
    timer_enabled=enabled
    timer_active=active
    next_run=$(systemctl show bird-archive.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
    print_status
    ;;
  disable)
    require_installed
    # Cleanup belongs to the nightly schedule. Clear it first so a failed
    # timer operation can only leave the safer copy-only behavior behind.
    if [ "$purge" = true ]; then
      write_conf_value PURGE false
      purge=false
    fi
    systemctl disable --now bird-archive.timer >/dev/null 2>&1 || fail "could not disable the archive timer"
    timer_enabled=disabled
    timer_active=inactive
    next_run=''
    print_status
    ;;
  run)
    require_ready
    if [ "$service_active" = active ] || [ "$service_active" = activating ]; then
      fail "an archive run is already active"
    fi
    systemctl --no-block start bird-archive.service >/dev/null 2>&1 || fail "could not start the archive"
    service_active=activating
    print_status
    ;;
  purge-on)
    require_ready
    [ "$timer_enabled" = enabled ] || fail "enable the nightly archive before local cleanup"
    if [ "$last_state" != OK ] || [ "$last_verified_files" -le 0 ]; then
      fail "run and verify at least one file before enabling local cleanup"
    fi
    write_conf_value PURGE true
    purge=true
    print_status
    ;;
  purge-off)
    require_installed
    write_conf_value PURGE false
    purge=false
    print_status
    ;;
  *)
    fail "unknown archive action"
    ;;
esac
