<?php
// AvianVisitors - bulk data export. Your detections and recordings are
// yours; this makes them easy to take somewhere and do science on.
//
// Endpoints:
//   ?what=detections            -> full detections table as CSV
//   ?what=recordings            -> every extracted clip, one tar stream
//   ?what=recordings&sci=X y    -> one species' clips, one tar stream
//
// Everything streams: the CSV is written row by row off the SQLite
// cursor and the tar comes straight from tar's stdout, so a Zero 2 W
// never holds more than a buffer in memory. mp3 doesn't compress, so
// no gzip. Same auth stance as the rest of avian/api/.

declare(strict_types=1);

require_once __DIR__ . '/admin-auth.php';
avian_require_admin();

$BIRDNETPI_DIR = dirname(__DIR__, 2);
$DB_PATH   = "$BIRDNETPI_DIR/scripts/birds.db";
$EXTRACTED = dirname($BIRDNETPI_DIR) . '/BirdSongs/Extracted';
$what = $_GET['what'] ?? '';

if ($what === 'detections') {
    if (!file_exists($DB_PATH)) {
        http_response_code(503);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['error' => 'birds.db not found']);
        exit;
    }
    $db = new SQLite3($DB_PATH, SQLITE3_OPEN_READONLY);
    $db->busyTimeout(2000);
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="detections-' . date('Y-m-d') . '.csv"');
    header('Cache-Control: no-store');
    while (ob_get_level()) ob_end_clean();
    $out = fopen('php://output', 'w');
    $cols = ['Date', 'Time', 'Sci_Name', 'Com_Name', 'Confidence',
             'Lat', 'Lon', 'Cutoff', 'Week', 'Sens', 'Overlap', 'File_Name'];
    // Explicit escape='' writes standard RFC-4180 quoting and quiets the
    // PHP 8.4+ deprecation about the changing default.
    fputcsv($out, $cols, ',', '"', '');
    // Row-by-row off the cursor - rows() would buffer a production DB's
    // 100k+ rows into RAM. ASC order reads as a diary and the reverse
    // index scan costs nothing.
    $res = $db->query('SELECT ' . implode(',', $cols) . ' FROM detections ORDER BY Date, Time');
    while ($r = $res->fetchArray(SQLITE3_NUM)) {
        fputcsv($out, $r, ',', '"', '');
    }
    $db->close();
    exit;
}

if ($what === 'recordings') {
    $byDate = "$EXTRACTED/By_Date";
    if (!is_dir($byDate)) {
        http_response_code(503);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['error' => 'no extracted recordings']);
        exit;
    }
    $sci = trim((string)($_GET['sci'] ?? ''));
    $label = 'recordings';
    $list = [];
    if ($sci !== '') {
        if (!preg_match("/^[A-Z][a-z-]+ [a-z-]+$/", $sci)) {
            http_response_code(400);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['error' => 'bad sci name']);
            exit;
        }
        // Resolve the species' on-disk dir name (space->underscore common
        // name) from the DB, then collect its clips from every date dir.
        if (!file_exists($DB_PATH)) {
            http_response_code(503);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['error' => 'birds.db not found']);
            exit;
        }
        $db = new SQLite3($DB_PATH, SQLITE3_OPEN_READONLY);
        $db->busyTimeout(2000);
        $st = $db->prepare('SELECT DISTINCT Com_Name FROM detections WHERE Sci_Name = :s');
        $st->bindValue(':s', $sci, SQLITE3_TEXT);
        $rs = $st->execute();
        // Match dirs the way recording.php does - normalized to bare
        // alphanumerics, because BirdNET-Pi isn't consistent about
        // apostrophes in species dir names (Anna's vs Annas).
        $norm = function (string $s): string {
            return preg_replace('/[^a-z0-9]/', '', strtolower($s));
        };
        $want = [];
        while ($r = $rs->fetchArray(SQLITE3_ASSOC)) {
            $want[$norm((string)$r['Com_Name'])] = true;
        }
        $db->close();
        if (!$want) {
            http_response_code(404);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['error' => 'species not in your detections']);
            exit;
        }
        foreach (scandir($byDate) ?: [] as $date) {
            if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date)) continue;
            foreach (scandir("$byDate/$date") ?: [] as $sub) {
                if ($sub === '.' || $sub === '..' || !is_dir("$byDate/$date/$sub")) continue;
                if (isset($want[$norm($sub)])) $list[] = "By_Date/$date/$sub";
            }
        }
        if (!$list) {
            http_response_code(404);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['error' => 'no clips on disk for that species']);
            exit;
        }
        $label = strtolower(str_replace(' ', '-', $sci));
    } else {
        $list[] = 'By_Date';
    }

    header('Content-Type: application/x-tar');
    header('Content-Disposition: attachment; filename="' . $label . '-' . date('Y-m-d') . '.tar"');
    header('Cache-Control: no-store');
    while (ob_get_level()) ob_end_clean();
    set_time_limit(0);
    // tar streams from disk to stdout; -C keeps paths tidy relative to
    // Extracted/. Every path in $list was built above from validated
    // parts, and escapeshellarg guards the boundary anyway.
    $args = implode(' ', array_map('escapeshellarg', $list));
    $p = popen('tar -cf - -C ' . escapeshellarg($EXTRACTED) . ' ' . $args, 'r');
    if ($p) {
        fpassthru($p);
        pclose($p);
    }
    exit;
}

http_response_code(400);
header('Content-Type: application/json; charset=utf-8');
echo json_encode(['error' => 'what=detections or what=recordings']);
