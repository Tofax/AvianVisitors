#!/usr/bin/env bash
# Safely update an AvianVisitors BirdNET-Pi checkout.

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

automatic=false

usage() {
  printf 'Usage: %s [-a]\n' "$0" >&2
  exit 64
}

while getopts ':a' option; do
  case "$option" in
    a) automatic=true ;;
    *) usage ;;
  esac
done
shift "$((OPTIND - 1))"
[ "$#" -eq 0 ] || usage

die() {
  printf 'Update stopped: %s\n' "$*" >&2
  exit 1
}

safe_root_helper() {
  local helper=$1 owner mode
  [ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] || return 1
  owner=$(stat -c '%u:%g' "$helper")
  mode=$(stat -c '%a' "$helper")
  [ "$owner" = 0:0 ] && [ "$mode" = 755 ]
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  safe_root_helper "$UPDATE_HELPER" \
    || die "root-owned updater is missing or unsafe: $UPDATE_HELPER"
  if [ "$automatic" = true ]; then
    exec sudo -n "$UPDATE_HELPER" -a
  fi
  exec sudo "$UPDATE_HELPER"
fi

[ "$(readlink -f "$0")" = "$UPDATE_HELPER" ] \
  || die "root updates must use $UPDATE_HELPER"
safe_root_helper "$UPDATE_HELPER" \
  || die "root-owned updater is unsafe: $UPDATE_HELPER"

conf_value() {
  local file=$1 key=$2
  awk -v wanted="$key" '
    $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]\"\047 ]+|[[:space:]\"\047 ]+$/, "", value)
      print value
      exit
    }
  ' "$file" 2>/dev/null || true
}

[ -r "$CONFIG_FILE" ] || die 'BirdNET-Pi configuration was not found'
station_user=$(conf_value "$CONFIG_FILE" BIRDNET_USER)
[[ "$station_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
  || die 'BirdNET-Pi user is invalid'

passwd_row=$(getent passwd "$station_user")
[ -n "$passwd_row" ] || die 'BirdNET-Pi user does not exist'
station_home=$(printf '%s\n' "$passwd_row" | cut -d: -f6)
if [[ ! "$station_home" =~ ^/[A-Za-z0-9._/+@-]+$ ]] \
  || [[ "$station_home" = *'..'* ]]; then
  die 'BirdNET-Pi home path is invalid'
fi
repo_dir=$station_home/BirdNET-Pi
[ -d "$repo_dir/.git" ] || die 'BirdNET-Pi checkout was not found'

if [ "$automatic" = true ]; then
  automatic_setting=$(conf_value "$CONFIG_FILE" AUTOMATIC_UPDATE)
  if [ "${automatic_setting:-0}" != 1 ]; then
    echo 'Automatic updates are disabled.'
    exit 0
  fi
fi

run_as_station() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    /usr/sbin/runuser -u "$station_user" -- \
      env -i HOME="$station_home" USER="$station_user" LOGNAME="$station_user" \
      GIT_CONFIG_GLOBAL=/dev/null \
      PATH=/usr/local/bin:/usr/bin:/bin "$@"
  else
    [ "$(id -un)" = "$station_user" ] \
      || die "run this update as $station_user or root"
    env HOME="$station_home" GIT_CONFIG_GLOBAL=/dev/null "$@"
  fi
}

git_station() {
  run_as_station git -C "$repo_dir" "$@"
}

read_git_nul() {
  local destination=$1 output
  shift
  output=$(mktemp /tmp/avian-git-output.XXXXXX)
  if ! git_station "$@" >"$output"; then
    rm -f "$output"
    die 'Git could not inspect the checkout'
  fi
  mapfile -d '' -t "$destination" <"$output"
  rm -f "$output"
}

read_git_lines() {
  local destination=$1 output
  shift
  output=$(mktemp /tmp/avian-git-output.XXXXXX)
  if ! git_station "$@" >"$output"; then
    rm -f "$output"
    die 'Git could not inspect the checkout'
  fi
  mapfile -t "$destination" <"$output"
  rm -f "$output"
}

# The installed helper is the only process that mutates the checkout. Keep its
# lock outside station- and web-writable paths.
lock_file=/run/lock/avian-update.lock
if [ ! -e "$lock_file" ]; then
  install -o root -g root -m 0600 /dev/null "$lock_file"
fi
if [ ! -f "$lock_file" ] || [ -L "$lock_file" ] \
  || [ "$(stat -c '%u:%g:%a' "$lock_file")" != 0:0:600 ]; then
  die "update lock is unsafe: $lock_file"
fi
exec 9<>"$lock_file"
flock -n 9 || die 'another update is already running'
safe_root_helper "$REFRESH_HELPER" \
  || die "root-owned service refresher is missing or unsafe: $REFRESH_HELPER"

state_dir=$station_home/.local/state/avian-visitors
run_as_station mkdir -p "$state_dir"
run_as_station chmod 0700 "$state_dir"

origin_url=$(git_station config --get remote.origin.url || true)
case "$origin_url" in
  "$OFFICIAL_ORIGIN"|"$OFFICIAL_ORIGIN.git") ;;
  '') die 'origin is not configured' ;;
  *) die "origin must be $OFFICIAL_ORIGIN" ;;
esac

# User-level Git URL rewrites are ignored above. Reject equivalent repository
# or worktree settings that could redirect the verified origin.
scoped_git_keys=()
read_git_lines scoped_git_keys config --show-scope --name-only --list
for scoped_git_key in "${scoped_git_keys[@]}"; do
  config_scope=${scoped_git_key%%$'\t'*}
  local_git_key=${scoped_git_key#*$'\t'}
  case "$config_scope" in local|worktree) ;; *) continue ;; esac
  case "${local_git_key,,}" in
    url.*|http.*|https.*|include.*|includeif.*|core.gitproxy)
      die "local Git transport setting is not allowed: $local_git_key"
      ;;
    remote.origin.proxy|remote.origin.uploadpack|remote.origin.vcs)
      die "local Git transport setting is not allowed: $local_git_key"
      ;;
  esac
done

# Fetching is the only operation allowed before all working-tree and ancestry
# checks pass. The explicit refspec ignores a station-controlled default fetch
# mapping, and --no-tags keeps unrelated refs out of the update boundary.
# Complete a shallow checkout in the same constrained fetch. Multiple shallow
# boundaries can otherwise hide a valid legacy ancestor and look like a fork.
shallow_repository=$(git_station rev-parse --is-shallow-repository) \
  || die 'Git could not inspect the checkout history'
fetch_history_args=()
[ "$shallow_repository" != true ] || fetch_history_args=(--unshallow)
if ! git_station fetch --no-tags --prune "${fetch_history_args[@]}" origin \
  "refs/heads/$RELEASE_BRANCH:refs/remotes/origin/$RELEASE_BRANCH"; then
  die "could not fetch origin/$RELEASE_BRANCH"
fi
target_ref=refs/remotes/origin/$RELEASE_BRANCH
git_station show-ref --verify --quiet "$target_ref" \
  || die "origin/$RELEASE_BRANCH was not found"

original_branch=$(git_station symbolic-ref --quiet --short HEAD || true)
[ -n "$original_branch" ] || die 'detached checkouts cannot be updated automatically'
case "$original_branch" in
  "$RELEASE_BRANCH"|main) ;;
  *) die "switch to main or $RELEASE_BRANCH before updating" ;;
esac
original_head=$(git_station rev-parse --verify HEAD)
target_commit=$(git_station rev-parse --verify "$target_ref^{commit}")
original_release_head=''
if git_station show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH"; then
  original_release_head=$(git_station rev-parse --verify "refs/heads/$RELEASE_BRANCH^{commit}")
fi
original_fetch_refspecs=()
if git_station config --get-all remote.origin.fetch >/dev/null 2>&1; then
  read_git_nul original_fetch_refspecs \
    config --null --get-all remote.origin.fetch
fi

staged_paths=()
read_git_nul staged_paths diff --cached --name-only -z HEAD
[ "${#staged_paths[@]}" -eq 0 ] \
  || die 'commit or discard staged changes before updating'

changed_paths=()
read_git_nul changed_paths diff --name-only -z HEAD
tracked_generated_paths=()
untracked_generated_paths=()
for changed_path in "${changed_paths[@]}"; do
  case "$changed_path" in
    avian/frontend/masks.json|avian/frontend/dims.json)
      [ -f "$repo_dir/$changed_path" ] \
        || die "generated file is missing: $changed_path"
      tracked_generated_paths+=("$changed_path")
      ;;
    *) die "tracked file has local changes: $changed_path" ;;
  esac
done

if [ "$original_branch" = main ]; then
  for generated_path in avian/frontend/masks.json avian/frontend/dims.json; do
    untracked_match=$(git_station ls-files --others -- "$generated_path")
    if [ "$untracked_match" = "$generated_path" ]; then
      if [ ! -f "$repo_dir/$generated_path" ] || [ -L "$repo_dir/$generated_path" ]; then
        die "generated file is unsafe: $generated_path"
      fi
      untracked_generated_paths+=("$generated_path")
    fi
  done
fi

backup_dir=''
generated_archive=''
collision_archive=''
collision_paths=()
legacy_branch_created=false
fetch_refspec_changed=false
transaction_complete=false
last_archive=''

new_backup_dir() {
  if [ -z "$backup_dir" ]; then
    backup_dir=$state_dir/update-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
    run_as_station mkdir -p "$backup_dir"
    run_as_station chmod 0700 "$backup_dir"
  fi
}

archive_paths() {
  local archive_name=$1
  shift
  [ "$#" -gt 0 ] || die 'internal error: no paths to archive'
  new_backup_dir
  local list_file=$backup_dir/$archive_name.paths
  local archive_file=$backup_dir/$archive_name.tar
  printf '%s\0' "$@" | run_as_station tee "$list_file" >/dev/null
  run_as_station tar -C "$repo_dir" --no-recursion --null \
    --files-from "$list_file" --create --file "$archive_file"
  local checksum
  checksum=$(run_as_station sha256sum "$archive_file")
  checksum=${checksum%% *}
  printf '%s  %s\n' "$checksum" "$(basename "$archive_file")" \
    | run_as_station tee -a "$backup_dir/SHA256SUMS" >/dev/null
  run_as_station chmod 0600 "$list_file" "$archive_file" "$backup_dir/SHA256SUMS"
  last_archive=$archive_file
}

restore_archive() {
  local archive_file=$1
  [ -f "$archive_file" ] || return 1
  run_as_station tar -C "$repo_dir" --extract --file "$archive_file" --no-same-owner
}

rollback() {
  local result=$? current_branch current_ref rollback_failed=false worktree_ready=false
  trap - EXIT
  if [ "$result" -ne 0 ] && [ "$transaction_complete" = false ]; then
    set +e
    if [ "$original_branch" = "$RELEASE_BRANCH" ]; then
      current_branch=$(git_station symbolic-ref --quiet --short HEAD 2>/dev/null)
      if [ "$current_branch" != "$RELEASE_BRANCH" ]; then
        git_station switch "$RELEASE_BRANCH" >/dev/null 2>&1 \
          || rollback_failed=true
      fi
      current_ref=$(git_station rev-parse --verify "refs/heads/$RELEASE_BRANCH" 2>/dev/null)
      if [ "$current_ref" != "$original_head" ]; then
        git_station update-ref "refs/heads/$RELEASE_BRANCH" "$original_head" "$current_ref" \
          || rollback_failed=true
      fi
      current_ref=$(git_station rev-parse --verify "refs/heads/$RELEASE_BRANCH" 2>/dev/null)
      if [ "$current_ref" = "$original_head" ] \
        && git_station restore --source="$original_head" --staged --worktree -- .; then
        worktree_ready=true
      else
        rollback_failed=true
      fi
    else
      current_branch=$(git_station symbolic-ref --quiet --short HEAD 2>/dev/null)
      if [ "$current_branch" != main ]; then
        git_station switch main >/dev/null 2>&1 || rollback_failed=true
      fi
      current_branch=$(git_station symbolic-ref --quiet --short HEAD 2>/dev/null)
      if [ "$current_branch" = main ]; then
        if [ -n "$original_release_head" ]; then
          current_ref=$(git_station rev-parse --verify "refs/heads/$RELEASE_BRANCH" 2>/dev/null)
          if [ "$current_ref" != "$original_release_head" ]; then
            git_station update-ref "refs/heads/$RELEASE_BRANCH" \
              "$original_release_head" "$current_ref" || rollback_failed=true
          fi
        elif [ "$legacy_branch_created" = true ] \
          && git_station show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH"; then
          current_ref=$(git_station rev-parse --verify "refs/heads/$RELEASE_BRANCH" 2>/dev/null)
          git_station update-ref -d "refs/heads/$RELEASE_BRANCH" "$current_ref" \
            || rollback_failed=true
        fi
        if [ -n "$collision_archive" ]; then
          restore_archive "$collision_archive" >/dev/null 2>&1 \
            || rollback_failed=true
        fi
        worktree_ready=true
      else
        rollback_failed=true
      fi
    fi
    if [ -n "$generated_archive" ] && [ "$worktree_ready" = true ]; then
      restore_archive "$generated_archive" >/dev/null 2>&1 \
        || rollback_failed=true
    elif [ -n "$generated_archive" ]; then
      rollback_failed=true
    fi
    if [ "$fetch_refspec_changed" = true ]; then
      if git_station config --unset-all remote.origin.fetch >/dev/null 2>&1; then
        for original_fetch_refspec in "${original_fetch_refspecs[@]}"; do
          git_station config --add remote.origin.fetch "$original_fetch_refspec" \
            >/dev/null 2>&1 || rollback_failed=true
        done
      else
        rollback_failed=true
      fi
    fi
    if [ "$rollback_failed" = true ]; then
      echo "Rollback was incomplete. Backups remain at $backup_dir" >&2
    fi
    set -e
  fi
  exit "$result"
}
trap rollback EXIT

generated_paths=("${tracked_generated_paths[@]}" "${untracked_generated_paths[@]}")
if [ "${#generated_paths[@]}" -gt 0 ]; then
  archive_paths generated "${generated_paths[@]}"
  generated_archive=$last_archive
  if [ "${#tracked_generated_paths[@]}" -gt 0 ]; then
    git_station restore --worktree -- "${tracked_generated_paths[@]}"
  fi
  for generated_path in "${untracked_generated_paths[@]}"; do
    run_as_station rm -f -- "$repo_dir/$generated_path"
  done
fi

if [ "$original_branch" = "$RELEASE_BRANCH" ]; then
  git_station merge-base --is-ancestor "$original_head" "$target_commit" \
    || die "local $RELEASE_BRANCH has commits not present on origin"
  if [ "$original_head" != "$target_commit" ]; then
    git_station merge --ff-only "$target_ref"
  fi
else
  # A legacy main checkout can migrate without deleting unrelated local files.
  # Only untracked paths that the release branch needs are moved aside.
  git_station merge-base --is-ancestor "$original_head" "$target_commit" \
    || die 'legacy main is not an ancestor of the release branch'
  if git_station show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH"; then
    release_head=$(git_station rev-parse --verify "refs/heads/$RELEASE_BRANCH^{commit}")
    git_station merge-base --is-ancestor "$release_head" "$target_commit" \
      || die "local $RELEASE_BRANCH has diverged from origin"
  fi

  untracked_paths=()
  target_paths=()
  read_git_nul untracked_paths ls-files --others -z
  read_git_nul target_paths ls-tree -r --name-only -z "$target_ref"
  declare -A target_files=()
  declare -A target_directories=()
  for target_path in "${target_paths[@]}"; do
    target_files["$target_path"]=1
    target_parent=$target_path
    while [[ "$target_parent" == */* ]]; do
      target_parent=${target_parent%/*}
      target_directories["$target_parent"]=1
    done
  done
  for untracked_path in "${untracked_paths[@]}"; do
    [[ "$untracked_path" != /* && "$untracked_path" != *$'\n'* \
      && "/$untracked_path/" != *'/../'* ]] \
      || die 'an unsafe untracked path blocks migration'
    if [[ -n "${target_files[$untracked_path]+present}" \
      || -n "${target_directories[$untracked_path]+present}" ]]; then
      collision_paths+=("$untracked_path")
      continue
    fi
    probe=$untracked_path
    while [[ "$probe" == */* ]]; do
      probe=${probe%/*}
      if [[ -n "${target_files[$probe]+present}" ]]; then
        collision_paths+=("$untracked_path")
        break
      fi
    done
  done

  if [ "${#collision_paths[@]}" -gt 0 ]; then
    archive_paths legacy-collisions "${collision_paths[@]}"
    collision_archive=$last_archive
    for collision_path in "${collision_paths[@]}"; do
      run_as_station rm -f -- "$repo_dir/$collision_path"
    done
  fi

  if git_station show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH"; then
    git_station switch "$RELEASE_BRANCH"
  else
    git_station switch --create "$RELEASE_BRANCH"
    legacy_branch_created=true
  fi
  git_station merge --ff-only "$target_ref"
fi

# Depth-limited legacy clones normally fetch only main. Replace every inherited
# mapping with the exact release mapping before recording the new upstream.
release_fetch_refspec="+refs/heads/$RELEASE_BRANCH:refs/remotes/origin/$RELEASE_BRANCH"
git_station config --replace-all remote.origin.fetch "$release_fetch_refspec" \
  || die 'could not configure the release fetch mapping'
fetch_refspec_changed=true
git_station branch --set-upstream-to="origin/$RELEASE_BRANCH" "$RELEASE_BRANCH" >/dev/null

if [ -n "$generated_archive" ]; then
  restore_archive "$generated_archive"
fi
transaction_complete=true

new_head=$(git_station rev-parse --verify HEAD)
if [ "$new_head" = "$original_head" ]; then
  echo 'Already up to date.'
else
  git_station --no-pager diff --stat "$original_head" "$new_head"
fi
if [ -n "$collision_archive" ]; then
  printf 'Legacy file backup: %s\n' "$backup_dir"
fi

safe_root_helper "$REFRESH_HELPER" \
  || die "root-owned service refresher is missing or unsafe: $REFRESH_HELPER"
AVIAN_UPDATE_LOCK_FD=9 "$REFRESH_HELPER"

echo 'AvianVisitors update complete.'
