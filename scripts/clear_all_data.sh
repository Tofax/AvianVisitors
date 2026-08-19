#!/usr/bin/env bash
# This script removes all data that has been collected. It is tantamount to
# starting all data-collection from scratch. Only run this if you are sure
# you are okay will losing all the data that you've collected and processed
# so far.
set -euo pipefail
IFS=$'\n\t'

conf=/etc/birdnet/birdnet.conf
[ -r "$conf" ] || { echo "BirdNET-Pi config was not found" >&2; exit 1; }
conf_value() {
  local key=$1
  awk -v wanted="$key" '
    $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      value=$0; sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", value)
      print value; exit
    }
  ' "$conf"
}
BIRDNET_USER=$(conf_value BIRDNET_USER)
RECS_DIR=$(conf_value RECS_DIR)
EXTRACTED=$(conf_value EXTRACTED)
PROCESSED=$(conf_value PROCESSED)
IDFILE=$(conf_value IDFILE)
[[ "$BIRDNET_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
  || { echo "Invalid BirdNET-Pi user" >&2; exit 1; }
USER=$BIRDNET_USER
HOME=$(getent passwd "$USER" | cut -d: -f6)
[[ "$HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$HOME" != *'..'* ]] \
  || { echo "Invalid BirdNET-Pi home" >&2; exit 1; }
HOME=$(readlink -m -- "$HOME")
RECS_DIR=$(readlink -m -- "$RECS_DIR")
EXTRACTED=$(readlink -m -- "$EXTRACTED")
PROCESSED=$(readlink -m -- "$PROCESSED")
IDFILE=$(readlink -m -- "$IDFILE")
case "$RECS_DIR" in "$HOME/BirdSongs"|"$HOME/BirdSongs/"*) ;; *) echo "Unsafe recordings path" >&2; exit 1 ;; esac
case "$EXTRACTED" in "$RECS_DIR/"*) ;; *) echo "Unsafe extracted path" >&2; exit 1 ;; esac
case "$PROCESSED" in "$RECS_DIR/"*) ;; *) echo "Unsafe processed path" >&2; exit 1 ;; esac
case "$IDFILE" in "$HOME/"*) ;; *) echo "Unsafe identification path" >&2; exit 1 ;; esac
repo_dir=$HOME/BirdNET-Pi
my_dir=$repo_dir/scripts
[ -d "$repo_dir/.git" ] && [ -d "$my_dir" ] \
  || { echo "BirdNET-Pi checkout was not found" >&2; exit 1; }
echo "Stopping services"
sudo systemctl stop birdnet_recording.service
sudo systemctl stop birdnet_analysis.service
echo "Removing all data . . . "
sudo rm -rf -- "${RECS_DIR}"
sudo rm -f -- "${IDFILE}" "$repo_dir/BirdDB.txt"

echo "Re-creating necessary directories"
[ -d "${EXTRACTED}" ] || sudo -u "${USER}" mkdir -p "${EXTRACTED}"
[ -d "${EXTRACTED}/By_Date" ] || sudo -u "${USER}" mkdir -p "${EXTRACTED}/By_Date"
[ -d "${EXTRACTED}/Charts" ] || sudo -u "${USER}" mkdir -p "${EXTRACTED}/Charts"
[ -d "${PROCESSED}" ] || sudo -u "${USER}" mkdir -p "${PROCESSED}"

sudo -u "${USER}" ln -fs "$repo_dir/exclude_species_list.txt" "$my_dir"
sudo -u "${USER}" ln -fs "$repo_dir/confirmed_species_list.txt" "$my_dir"
sudo -u "${USER}" ln -fs "$repo_dir/include_species_list.txt" "$my_dir"
sudo -u "${USER}" ln -fs "$repo_dir/whitelist_species_list.txt" "$my_dir"
sudo -u "${USER}" ln -fs "$repo_dir/homepage/"* "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$repo_dir/model/labels.txt" "${my_dir}"
sudo -u "${USER}" ln -fs "$my_dir" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$my_dir/play.php" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$my_dir/spectrogram.php" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$my_dir/overview.php" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$my_dir/stats.php" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$my_dir/todays_detections.php" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$my_dir/history.php" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$my_dir/weekly_report.php" "${EXTRACTED}"
webroot_helper=/usr/local/sbin/avian-link-webroot
if [ ! -x "$webroot_helper" ]; then
  echo "AvianVisitors webroot helper is not installed" >&2
  exit 1
fi
if ! "$webroot_helper" "$repo_dir" "${EXTRACTED}" "${USER}"; then
  echo "Could not restore the AvianVisitors webroot" >&2
  exit 1
fi
sudo -u "${USER}" ln -fs "${HOME}/phpsysinfo" "${EXTRACTED}"
sudo -u "${USER}" ln -fs "$repo_dir/templates/phpsysinfo.ini" "${HOME}/phpsysinfo/"
sudo -u "${USER}" ln -fs "$repo_dir/templates/green_bootstrap.css" "${HOME}/phpsysinfo/templates/"
sudo -u "${USER}" ln -fs "$repo_dir/templates/index_bootstrap.html" "${HOME}/phpsysinfo/templates/html"
chmod -R g+rw "${RECS_DIR}"


echo "Dropping and re-creating database"
sudo -u "$USER" "$my_dir/createdb.sh"
echo "Re-generating BirdDB.txt"
sudo -u "$USER" touch "$repo_dir/BirdDB.txt"
echo "Date;Time;Sci_Name;Com_Name;Confidence;Lat;Lon;Cutoff;Week;Sens;Overlap" > "$repo_dir/BirdDB.txt"
ln -sfn "$repo_dir/BirdDB.txt" "$my_dir/BirdDB.txt"
chown "$USER:$USER" "$repo_dir/BirdDB.txt"
chmod g+rw "$repo_dir/BirdDB.txt"
echo "Restarting services"
if ! /usr/local/sbin/avian-caddy-refresh; then
  echo "Could not update the Caddy configuration; services were not restarted" >&2
  exit 1
fi
services=(
  chart_viewer.service
  spectrogram_viewer.service
  icecast2.service
  birdnet_recording.service
  birdnet_analysis.service
  birdnet_log.service
  birdnet_stats.service
)
for service in "${services[@]}"; do
  systemctl restart "$service"
done
