#!/bin/bash
# AvianVisitors — nightly Google Drive archive + optional rolling purge.  v2
#
# For every COMPLETED day under ~/BirdSongs/Extracted/By_Date (dates before
# today minus KEEP_DAYS):
#   1. writes two analytics CSVs to <REMOTE>/Analytics/ from a point-in-time
#      SNAPSHOT of birds.db (never holds a lock against the live analyzer),
#      reconciled against the clip count on disk
#   2. uploads each species' mp3s + spectrogram pngs to
#      <REMOTE>/Recordings/<Species>/  (filenames already carry date+time)
#   3. verifies via rclone check --one-way (Drive stores md5 for all files)
#   4. if PURGE=true: deletes EXACTLY the files that were enumerated before
#      upload and covered by the verify — never a blind rm -rf. Directories
#      fall only to rmdir, so anything unexpected (a straggler extraction,
#      a stray file, a dotfile) survives and flags the day for the next run.
#
# Any failure leaves data local and the next night retries; uploads are
# idempotent. Status: ~/bird-archive/status (OK/FAIL + timestamp).
#
# Scope: only dated children of By_Date matching YYYY-MM-DD; symlinks skipped
# at both day and species level; web-root files, cutouts/, Charts/,
# StreamData/, birds.db rows, and BirdDB.txt are never touched.

set -u -o pipefail

CONF="$HOME/bird-archive/archive.conf"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

REMOTE="${REMOTE:-gdrive:AvianVisitors}"
PURGE="${PURGE:-false}"
KEEP_DAYS="${KEEP_DAYS:-0}"
BY_DATE="${BY_DATE:-$HOME/BirdSongs/Extracted/By_Date}"
DB="${DB:-$HOME/BirdNET-Pi/scripts/birds.db}"
LOG="${LOG:-$HOME/bird-archive/archive.log}"
STATUS="$HOME/bird-archive/status"
TMP="$HOME/bird-archive/tmp"
SNAP="$TMP/birds-snap.db"
RC=(--transfers 4 --checkers 8 --retries 3 --low-level-retries 10 --stats 0 --log-level ERROR --log-file "$LOG")

mkdir -p "$(dirname "$LOG")" "$TMP"
log()  { echo "$(date -Is) $*" >>"$LOG"; }
sfail(){ echo "FAIL $(date -Is) $*" >"$STATUS"; }

# single-instance lock: a slow upload must never overlap the next run
exec 9>"$HOME/bird-archive/.lock"
if ! flock -n 9; then log "another run still in progress; exiting"; exit 0; fi

# config validation — a malformed KEEP_DAYS must not silently no-op the run
if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]]; then
  log "FATAL: KEEP_DAYS is not a non-negative integer: '$KEEP_DAYS'"; sfail config; exit 1
fi

# clock sanity — Pi 4 has no RTC; a wrong clock could make 'today' drift
ntp_ok=0
for _ in $(seq 1 10); do
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && { ntp_ok=1; break; }
  sleep 30
done
if [ "$ntp_ok" != 1 ]; then log "FATAL: clock not NTP-synchronized"; sfail ntp; exit 1; fi

# fresh-boot guard — after an outage, Persistent=true fires this at boot while
# the analyzer is still extracting backlog clips INTO yesterday's dir. Wait
# out the first hour of uptime so the backlog drains before we enumerate.
up=$(awk '{print int($1)}' /proc/uptime)
if [ "$up" -lt 3600 ]; then
  log "recent boot (up ${up}s); waiting $((3600 - up))s for analyzer backlog to drain"
  sleep $((3600 - up))
fi

# patient remote probe — boot-time WiFi, transient DNS, Drive hiccups
probe_ok=0
for _ in $(seq 1 20); do
  rclone mkdir "$REMOTE" "${RC[@]}" && { probe_ok=1; break; }
  sleep 60
done
if [ "$probe_ok" != 1 ]; then
  log "FATAL: remote $REMOTE unreachable after 20 attempts (token expired? offline? quota?)"
  sfail remote; exit 1
fi

[ -d "$BY_DATE" ] || { log "FATAL: $BY_DATE missing"; sfail layout; exit 1; }

# cutoff computed ONCE, local time
today=$(date +%F)
cutoff=$(date -d "$today - $KEEP_DAYS day" +%F) && [ -n "$cutoff" ] \
  || { log "FATAL: cutoff computation failed"; sfail config; exit 1; }
log "run start: today=$today cutoff=$cutoff purge=$PURGE remote=$REMOTE"

# ONE point-in-time snapshot of the live DB; all analytics reads hit the copy.
# (.backup yields the lock between pages, so the analyzer's INSERTs never starve)
rm -f "$SNAP"
if ! sqlite3 -cmd ".timeout 3000" "$DB" ".backup '$SNAP'"; then
  log "FATAL: birds.db snapshot failed"; sfail db; exit 1
fi

overall_fail=0
for daydir in "$BY_DATE"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
  [ -d "$daydir" ] || continue                 # unmatched glob stays literal
  [ -L "$daydir" ] && { log "SKIP symlinked day: $daydir"; continue; }
  day=$(basename "$daydir")
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [[ "$day" < "$cutoff" ]] || continue         # ISO dates compare lexically

  day_ok=1

  # ---- 1. analytics from the snapshot, reconciled against disk ----
  det_csv="$TMP/$day-detections.csv"
  sum_csv="$TMP/$day-summary.csv"
  sqlite3 -readonly -csv -header "$SNAP" \
    "SELECT Date, Time, Sci_Name, Com_Name, Confidence, File_Name
     FROM detections WHERE Date = '$day' ORDER BY Time;" >"$det_csv" \
    || { log "ERROR: detections query failed $day"; day_ok=0; }
  sqlite3 -readonly -csv -header "$SNAP" \
    "SELECT Com_Name, Sci_Name, COUNT(*) AS detections, MIN(Time) AS first_heard,
            MAX(Time) AS last_heard, ROUND(MAX(Confidence),4) AS max_confidence
     FROM detections WHERE Date = '$day'
     GROUP BY Sci_Name, Com_Name ORDER BY detections DESC;" >"$sum_csv" \
    || { log "ERROR: summary query failed $day"; day_ok=0; }
  if [ "$day_ok" = 1 ]; then
    # every clip on disk implies a DB row; fewer CSV rows than clips means the
    # analytics are lying — never purge a day whose stats didn't export
    mp3s=$(find "$daydir" -mindepth 2 -maxdepth 2 -type f -name '*.mp3' | wc -l)
    rows=$(wc -l <"$det_csv"); [ "$rows" -gt 0 ] && rows=$((rows - 1))  # minus header
    if [ "$rows" -lt "$mp3s" ]; then
      log "ERROR: $day analytics rows ($rows) < clips on disk ($mp3s); retaining"
      day_ok=0
    fi
  fi
  if [ "$day_ok" = 1 ] && [ "${rows:-0}" -gt 0 ]; then
    rclone copy "$det_csv" "$REMOTE/Analytics" "${RC[@]}" \
      && rclone copy "$sum_csv" "$REMOTE/Analytics" "${RC[@]}" \
      || { log "ERROR: analytics upload failed $day"; day_ok=0; }
  fi
  rm -f "$det_csv" "$sum_csv"

  # purge is allowed for this day only if its analytics are safely in Drive
  allow_purge=false
  [ "$PURGE" = "true" ] && [ "$day_ok" = 1 ] && allow_purge=true

  # ---- 2+3+4. per-species: enumerate -> upload -> verify -> delete the
  #      enumerated files only; rmdir catches anything that arrived after ----
  files_done=0
  for spdir in "$daydir"/*/; do
    [ -d "$spdir" ] || continue
    sp_path="${spdir%/}"
    [ -L "$sp_path" ] && { log "SKIP symlinked species: $sp_path"; day_ok=0; continue; }
    sp=$(basename "$sp_path")
    mapfile -d '' -t flist < <(find "$sp_path" -mindepth 1 -maxdepth 1 -type f -print0)
    if [ "${#flist[@]}" -eq 0 ]; then
      # nothing to upload; in purge mode fold the empty dir (rmdir = safe)
      [ "$allow_purge" = true ] && rmdir -- "$sp_path" 2>/dev/null
      continue
    fi
    if ! rclone copy "$sp_path" "$REMOTE/Recordings/$sp" "${RC[@]}"; then
      log "ERROR: upload failed $day/$sp"; day_ok=0; continue
    fi
    if ! rclone check "$sp_path" "$REMOTE/Recordings/$sp" --one-way "${RC[@]}"; then
      log "ERROR: verify failed $day/$sp"; day_ok=0; continue
    fi
    files_done=$((files_done + ${#flist[@]}))
    if [ "$allow_purge" = true ]; then
      if rm -- "${flist[@]}"; then
        # only removes an EMPTY dir; a straggler file arriving post-verify
        # keeps the dir (and itself) for the next night's sweep
        rmdir -- "$sp_path" 2>/dev/null \
          || log "NOTE: $day/$sp gained files after verify; leftovers retained"
      else
        log "ERROR: delete failed $day/$sp"; day_ok=0
      fi
    fi
  done

  # ---- day wrap-up ----
  if [ "$day_ok" = 1 ] && [ "$files_done" -gt 0 ]; then
    log "OK: $day archived & verified ($files_done files)"
    if [ "$allow_purge" = true ]; then
      if rmdir -- "$daydir" 2>/dev/null; then
        log "PURGED: $day"
      else
        log "RETAINED: $day not empty after purge (unarchived leftovers kept)"; overall_fail=1
      fi
    fi
  elif [ "$day_ok" = 1 ]; then
    log "NOTE: $day contained no archivable files"
    [ "$allow_purge" = true ] && rmdir -- "$daydir" 2>/dev/null && log "PURGED empty: $day"
  else
    log "RETAINED: $day had failures; nothing deleted, retrying next night"; overall_fail=1
  fi
done

rm -f "$SNAP"

# weekly duplicate sweep: Drive can duplicate a file when an upload commits
# but the response is lost and a retry re-sends; collapse to newest
if [ "$overall_fail" = 0 ] && [ "$(date +%u)" = "7" ]; then
  rclone dedupe --dedupe-mode newest "$REMOTE/Recordings" "${RC[@]}" \
    || log "NOTE: weekly dedupe failed (harmless, will retry next week)"
fi

if [ "$overall_fail" = 0 ]; then echo "OK $(date -Is)" >"$STATUS"; else sfail "see archive.log"; fi
log "run complete (fail=$overall_fail); disk: $(df -h "$BY_DATE" | awk 'NR==2{print $5" used, "$4" free"}')"
exit "$overall_fail"
