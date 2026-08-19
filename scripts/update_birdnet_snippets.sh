#!/usr/bin/env bash
# Compatibility hook for the updater shipped before AvianVisitors v1. The old
# updater invokes this file as root after switching branches. Move immediately
# into the verified, root-owned surgical refresher; future updates do not use
# this hook.

set -euo pipefail
IFS=$'\n\t'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "update migration must run as root" >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_dir=$(cd -- "$script_dir/.." && pwd -P)

origin=$(git -C "$repo_dir" config --get remote.origin.url)
case "$origin" in
  https://github.com/Twarner491/AvianVisitors|https://github.com/Twarner491/AvianVisitors.git) ;;
  *) echo "Refusing update from an unexpected origin" >&2; exit 1 ;;
esac

relative=scripts/reinstall_services.sh
git -C "$repo_dir" ls-files --error-unmatch "$relative" >/dev/null
git -C "$repo_dir" diff --quiet HEAD -- "$relative" \
  || { echo "Service refresher differs from the checked-out commit" >&2; exit 1; }
[ "$(git -C "$repo_dir" hash-object "$repo_dir/$relative")" = \
  "$(git -C "$repo_dir" rev-parse "HEAD:$relative")" ] \
  || { echo "Service refresher verification failed" >&2; exit 1; }

install -o root -g root -m 0755 \
  "$repo_dir/$relative" /usr/local/sbin/avian-service-refresh
exec /usr/local/sbin/avian-service-refresh --legacy-migration
