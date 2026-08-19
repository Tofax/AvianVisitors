#!/usr/bin/env bash
# One-time bridge from the pre-v1 BirdNET-Pi checkout to AvianVisitors v1.
# It installs only the verified updater and service refresher, then hands the
# checkout to the normal migration path.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

readonly OFFICIAL_ORIGIN='https://github.com/Twarner491/AvianVisitors'
readonly RELEASE_BRANCH='avian-visitors'
readonly CONFIG_FILE='/etc/birdnet/birdnet.conf'
readonly UPDATE_HELPER='/usr/local/sbin/avian-update-control'
readonly REFRESH_HELPER='/usr/local/sbin/avian-service-refresh'

die() {
  printf 'v1 update setup stopped: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 0 ] || die 'this setup does not accept arguments'
[ "${EUID:-$(id -u)}" -eq 0 ] || die 'run this setup with sudo'
[ -r "$CONFIG_FILE" ] || die 'BirdNET-Pi configuration was not found'

conf_value() {
  local key=$1
  awk -v wanted="$key" '
    $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_FILE"
}

station_user=$(conf_value BIRDNET_USER)
[[ "$station_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
  || die 'BirdNET-Pi user is invalid'
passwd_row=$(getent passwd "$station_user")
[ -n "$passwd_row" ] || die 'BirdNET-Pi user does not exist'
station_home=$(printf '%s\n' "$passwd_row" | cut -d: -f6)
[[ "$station_home" =~ ^/[A-Za-z0-9._/+@-]+$ ]] \
  && [[ "$station_home" != *'..'* ]] \
  || die 'BirdNET-Pi home path is invalid'
repo_dir=$station_home/BirdNET-Pi
[ -d "$repo_dir/.git" ] || die 'BirdNET-Pi checkout was not found'

configured_origin=$(runuser -u "$station_user" -- \
  env -i HOME="$station_home" USER="$station_user" LOGNAME="$station_user" \
  GIT_CONFIG_GLOBAL=/dev/null PATH=/usr/local/bin:/usr/bin:/bin \
  git -C "$repo_dir" config --get remote.origin.url || true)
case "$configured_origin" in
  "$OFFICIAL_ORIGIN"|"$OFFICIAL_ORIGIN.git") ;;
  *) die "origin must be $OFFICIAL_ORIGIN" ;;
esac

work_dir=$(mktemp -d /var/tmp/avian-v1-bootstrap.XXXXXX)
trusted_repo=$work_dir/official.git
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT
mkdir "$trusted_repo"

trusted_git() {
  env -i HOME=/root GIT_CONFIG_GLOBAL=/dev/null \
    PATH=/usr/local/bin:/usr/bin:/bin git -C "$trusted_repo" "$@"
}

trusted_git init --bare -q
if ! trusted_git fetch --no-tags "${OFFICIAL_ORIGIN}.git" \
  "refs/heads/$RELEASE_BRANCH:refs/heads/$RELEASE_BRANCH"; then
  die "could not fetch the official $RELEASE_BRANCH release"
fi
verified_head=$(trusted_git rev-parse --verify "refs/heads/$RELEASE_BRANCH^{commit}")

sources=(scripts/update_birdnet.sh scripts/reinstall_services.sh)
targets=("$UPDATE_HELPER" "$REFRESH_HELPER")
for index in "${!sources[@]}"; do
  staged=$work_dir/$(basename "${sources[$index]}")
  trusted_git show "$verified_head:${sources[$index]}" >"$staged"
  bash -n "$staged" || die "invalid release helper: ${sources[$index]}"
  target=${targets[$index]}
  temp_target=$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")
  install -o root -g root -m 0755 "$staged" "$temp_target"
  mv -f "$temp_target" "$target"
done

cleanup
trap - EXIT
exec "$UPDATE_HELPER"
