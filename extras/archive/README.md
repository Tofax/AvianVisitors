# Nightly Google Drive archive + rolling disk clear

A BirdNET-Pi station on a 28-32GB SD card records roughly 150-400MB of
extracted clips a day; the card fills in a few months. This extra archives
every completed day's recordings to Google Drive — sorted into one folder per
species — plus per-day analytics CSVs from the detections database, verifies
every file landed (rclone `check`; Drive stores md5), and only then, if you
opt in, clears those days from the SD card. Any failure leaves everything
local and the next night's run picks up the backlog: the archive is
idempotent and self-healing.

What lands in Drive:

```
AvianVisitors/
├── Recordings/
│   ├── Chimney_Swift/            every clip + spectrogram, filenames
│   │                             already carry date + time
│   └── <Species>/...
└── Analytics/
    ├── 2026-07-15-detections.csv  every detection: time, species, confidence
    └── 2026-07-15-summary.csv     per-species count, first/last heard, max conf
```

## Safety model

- deletes **only** files it enumerated *before* upload and verified by
  checksum after; directories fall to `rmdir` only, so anything unexpected
  (a straggler extraction, a stray file) survives and flags the day for
  the next night
- never touches today's directory, `birds.db` rows, `BirdDB.txt`,
  StreamData/, Charts/, cutouts/, or the web-root symlinks
- reads the database from a point-in-time snapshot (`.backup`), so the
  live analyzer's inserts are never blocked
- refuses to run without NTP sync; waits out fresh boots so the analyzer
  can drain its backlog; retries an unreachable Drive for 20 minutes
  before giving up (nothing deleted on any failure)
- writes `~/bird-archive/status` (`OK`/`FAIL` + timestamp) — check it, or
  wire it to your notifier of choice; a station that can't upload keeps
  recording and keeps its files

## Setup

1. `sudo apt install rclone` on the Pi, then create a Drive remote named
   `gdrive`: run `rclone authorize "drive"` on any machine with a browser
   and paste the token into `rclone config` on the Pi (headless flow).
   The narrow `drive.file` scope is enough — the Pi only ever sees files
   it created.
2. Copy this directory to `~/bird-archive/`, then:
   ```
   cp archive.conf.example ~/bird-archive/archive.conf   # edit REMOTE if needed
   chmod +x ~/bird-archive/archive_to_drive.sh
   sudo cp bird-archive.{service,timer} /etc/systemd/system/   # adjust User= if not pi
   sudo systemctl daemon-reload
   ```
3. First run in safe mode (`PURGE=false`, the default): run
   `~/bird-archive/archive_to_drive.sh` manually, watch
   `~/bird-archive/archive.log`, and eyeball the files in Drive.
4. When satisfied: set `PURGE=true` (and `KEEP_DAYS=1` if you want
   yesterday to stay playable on the website for one extra day), then
   `sudo systemctl enable --now bird-archive.timer` (03:15 nightly,
   catches up after downtime).

Note: once old days are purged, their audio plays from Drive rather than
the website — the detail modal still lists historical detections (they
live in the DB) but pre-purge recordings 404 gracefully. Stats, the
collage, and the frame are DB-driven and unaffected.
