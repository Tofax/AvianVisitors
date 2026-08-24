<?php
// AvianVisitors - illustration cutout audit/review backend.
//
// Admin-only endpoints for the Tools illustration-review UI.
//
// GET  ?action=list
//      Returns the last audit snapshot merged with manual review decisions.
//
// GET  ?action=preview&file=<slug[-2].png>
//      Returns a diagnostic PNG on a strong background with enclosed
//      transparent holes highlighted. The source illustration is untouched.
//
// POST ?action=audit
//      Starts a background audit of every final illustration.
//
// POST ?action=mark
//      JSON {action:"mark", file:"...", status:"good"|"bad"|"pending"}
//      Stores only the human decision; it never modifies an illustration.

declare(strict_types=1);
header('Cache-Control: no-store');

require_once __DIR__ . '/admin-auth.php';
avian_require_admin();

$ROOT = dirname(__DIR__, 2);
$ILLUS = "$ROOT/avian/assets/illustrations";
$AUDIT = "$ILLUS/.cutout-audit.json";
$STATE = "$ILLUS/.cutout-audit.state.json";
$REVIEW = "$ILLUS/.cutout-review.json";
$LOG = "$ILLUS/.cutout-audit.log";
$SCRIPT = "$ROOT/avian/scripts/audit_cutouts.py";
$STALE_S = 20 * 60;

function json_response(int $status, array $body): void {
    header('Content-Type: application/json; charset=utf-8');
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function read_json_file(string $path): array {
    if (!is_readable($path)) return [];
    $decoded = json_decode((string)file_get_contents($path), true);
    return is_array($decoded) ? $decoded : [];
}

function atomic_write_json(string $path, array $body): bool {
    $json = json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if (!is_string($json)) return false;

    try {
        $tmp = $path . '.tmp.' . bin2hex(random_bytes(8));
    } catch (Throwable $e) {
        return false;
    }

    $handle = @fopen($tmp, 'x+b');
    if ($handle === false) return false;

    $ok = true;
    $payload = $json . "\n";
    $offset = 0;
    $length = strlen($payload);

    while ($offset < $length) {
        $written = @fwrite($handle, substr($payload, $offset));
        if ($written === false || $written === 0) {
            $ok = false;
            break;
        }
        $offset += $written;
    }

    if ($ok && !@fflush($handle)) $ok = false;
    if ($ok && function_exists('fsync')) @fsync($handle);
    if ($ok && !@chmod($tmp, 0664)) $ok = false;
    if ($ok && !@rename($tmp, $path)) $ok = false;
    if (!@fclose($handle)) $ok = false;
    if (!$ok) @unlink($tmp);

    return $ok;
}

function find_executable(string $name): ?string {
    foreach (explode(PATH_SEPARATOR, (string)getenv('PATH')) as $directory) {
        if ($directory === '' || $directory[0] !== DIRECTORY_SEPARATOR) continue;
        $candidate = rtrim($directory, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $name;
        if (is_file($candidate) && is_executable($candidate)) return $candidate;
    }
    return null;
}

function audit_python(string $root): string {
    $candidate = "$root/birdnet/bin/python3";
    if (is_executable($candidate)) return $candidate;
    return find_executable('python3') ?? '';
}

function valid_cutout_file(string $file): bool {
    // Illustration filenames are normalized scientific-name slugs, optionally
    // followed by -2 for flight pose. Reject every path separator by shape.
    return (bool)preg_match('/^[a-z0-9]+(?:-[a-z0-9]+)+(?:-2)?\.png$/', $file);
}

function current_audit_state(string $path, int $staleSeconds): array {
    $state = read_json_file($path);
    $running = !empty($state['running']);
    if ($running && (time() - (int)($state['at'] ?? 0)) > $staleSeconds) {
        $running = false;
        $state['running'] = false;
        $state['ok'] = false;
        $state['error'] = $state['error'] ?? 'audit timed out';
    }
    $state['running'] = $running;
    return $state;
}

function merged_list(string $auditPath, string $reviewPath, string $statePath, int $staleSeconds): array {
    $audit = read_json_file($auditPath);
    $reviews = read_json_file($reviewPath);
    $state = current_audit_state($statePath, $staleSeconds);

    $items = [];
    $counts = [
        'pending' => 0,
        'good' => 0,
        'bad' => 0,
        'suspicious' => 0,
        'review_candidates' => 0,
        'very_likely_bad' => 0,
        'very_high' => 0,
        'high' => 0,
        'medium' => 0,
        'low' => 0,
        'very_low' => 0,
    ];

    foreach (($audit['items'] ?? []) as $item) {
        if (!is_array($item) || !isset($item['file'])) continue;
        $file = (string)$item['file'];
        $review = $reviews[$file] ?? null;
        $status = is_array($review) ? (string)($review['status'] ?? 'pending') : 'pending';
        if (!in_array($status, ['pending', 'good', 'bad'], true)) $status = 'pending';

        $score = (float)($item['score'] ?? 0);
        $candidate = array_key_exists('review_candidate', $item)
            ? !empty($item['review_candidate'])
            : $score >= 40.0;
        $veryLikely = array_key_exists('very_likely_bad', $item)
            ? !empty($item['very_likely_bad'])
            : $score >= 70.0;
        $item['review_candidate'] = $candidate;
        $item['very_likely_bad'] = $veryLikely;
        $item['review'] = $status;
        $item['reviewed_at'] = is_array($review) ? ($review['reviewed_at'] ?? null) : null;
        $items[] = $item;

        // "Pending" is the actionable queue, not every unreviewed image.
        if ($status === 'pending') {
            if ($candidate) $counts['pending']++;
        } else {
            $counts[$status]++;
        }
        if ($candidate) $counts['review_candidates']++;
        if ($veryLikely) $counts['very_likely_bad']++;
        if (!empty($item['suspicious'])) $counts['suspicious']++;
        $level = (string)($item['level'] ?? '');
        if (array_key_exists($level, $counts)) $counts[$level]++;
    }

    return [
        'ok' => true,
        'generated_at' => $audit['generated_at'] ?? null,
        'needs_audit' => empty($audit['items']),
        'audit' => $state,
        'summary' => [
            'total' => count($items),
            'pending' => $counts['pending'],
            'good' => $counts['good'],
            'bad' => $counts['bad'],
            'suspicious' => $counts['suspicious'],
            'review_candidates' => $counts['review_candidates'],
            'very_likely_bad' => $counts['very_likely_bad'],
            'levels' => [
                'very_high' => $counts['very_high'],
                'high' => $counts['high'],
                'medium' => $counts['medium'],
                'low' => $counts['low'],
                'very_low' => $counts['very_low'],
            ],
            'errors' => is_array($audit['errors'] ?? null) ? count($audit['errors']) : 0,
        ],
        'items' => $items,
    ];
}

$action = (string)($_GET['action'] ?? 'list');
$method = (string)($_SERVER['REQUEST_METHOD'] ?? 'GET');

if ($method === 'GET' && $action === 'list') {
    json_response(200, merged_list($AUDIT, $REVIEW, $STATE, $STALE_S));
}

if ($method === 'GET' && $action === 'preview') {
    $file = (string)($_GET['file'] ?? '');
    if (!valid_cutout_file($file)) {
        json_response(400, ['ok' => false, 'error' => 'invalid illustration filename']);
    }
    if (!is_file("$ILLUS/$file")) {
        json_response(404, ['ok' => false, 'error' => 'illustration not found']);
    }

    $python = audit_python($ROOT);
    if ($python === '' || !is_readable($SCRIPT) || !function_exists('proc_open')) {
        json_response(503, ['ok' => false, 'error' => 'cutout preview unavailable']);
    }

    $tmp = @tempnam(sys_get_temp_dir(), 'avian-cutout-preview-');
    if ($tmp === false) {
        json_response(500, ['ok' => false, 'error' => 'cannot create preview']);
    }

    $command = [
        $python,
        $SCRIPT,
        '--dir', $ILLUS,
        '--preview', $file,
        '--preview-output', $tmp,
    ];
    $descriptors = [
        0 => ['file', '/dev/null', 'r'],
        1 => ['file', '/dev/null', 'a'],
        2 => ['file', '/dev/null', 'a'],
    ];

    $process = @proc_open(
        $command,
        $descriptors,
        $pipes,
        $ROOT,
        null,
        ['bypass_shell' => true]
    );
    $rc = is_resource($process) ? proc_close($process) : -1;

    if ($rc !== 0 || !is_file($tmp) || filesize($tmp) === 0) {
        @unlink($tmp);
        json_response(500, ['ok' => false, 'error' => 'could not build preview']);
    }

    header_remove('Content-Type');
    header('Content-Type: image/png');
    header('Content-Length: ' . (string)filesize($tmp));
    header('Content-Disposition: inline; filename="review-' . $file . '"');
    readfile($tmp);
    @unlink($tmp);
    exit;
}

if ($method !== 'POST') {
    json_response(405, ['ok' => false, 'error' => 'method not allowed']);
}

avian_require_json_action();

try {
    $body = json_decode((string)file_get_contents('php://input'), false, 16, JSON_THROW_ON_ERROR);
} catch (JsonException $e) {
    json_response(400, ['ok' => false, 'error' => 'invalid JSON body']);
}
if (!$body instanceof stdClass) {
    json_response(400, ['ok' => false, 'error' => 'JSON object required']);
}

$fields = get_object_vars($body);
$bodyAction = (string)($fields['action'] ?? $action);

if ($action === 'audit' || $bodyAction === 'audit') {
    if (array_diff(array_keys($fields), ['action'])) {
        json_response(400, ['ok' => false, 'error' => 'unexpected field']);
    }

    $state = current_audit_state($STATE, $STALE_S);
    if (!empty($state['running'])) {
        json_response(409, ['ok' => false, 'error' => 'audit already running', 'audit' => $state]);
    }

    $python = audit_python($ROOT);
    $nohup = is_executable('/usr/bin/nohup')
        ? '/usr/bin/nohup'
        : (find_executable('nohup') ?? '');

    if ($python === '' || $nohup === '' || !is_readable($SCRIPT)
        || !is_executable('/bin/sh') || !function_exists('proc_open')) {
        json_response(503, ['ok' => false, 'error' => 'cutout audit unavailable']);
    }

    if (!is_dir($ILLUS)) {
        json_response(503, ['ok' => false, 'error' => 'illustration directory unavailable']);
    }

    // Mark the state before spawning so a double-click cannot start a second
    // expensive scan during the small process-launch window.
    $starting = [
        'schema' => 1,
        'running' => true,
        'ok' => null,
        'done' => 0,
        'total' => 0,
        'at' => time(),
        'started_at' => time(),
    ];
    if (!atomic_write_json($STATE, $starting)) {
        json_response(500, ['ok' => false, 'error' => 'cannot write audit state']);
    }

    $cmd = ': >> ' . escapeshellarg($LOG) . ' || exit 1; '
         . escapeshellarg($nohup) . ' ' . escapeshellarg($python)
         . ' ' . escapeshellarg($SCRIPT)
         . ' --dir ' . escapeshellarg($ILLUS)
         . ' --output ' . escapeshellarg($AUDIT)
         . ' --state ' . escapeshellarg($STATE)
         . ' >> ' . escapeshellarg($LOG) . ' 2>&1 < /dev/null & '
         . 'worker_pid=$!; sleep 0.05; kill -0 "$worker_pid" 2>/dev/null';

    $descriptors = [
        0 => ['file', '/dev/null', 'r'],
        1 => ['file', '/dev/null', 'a'],
        2 => ['file', '/dev/null', 'a'],
    ];
    $process = @proc_open(
        ['/bin/sh', '-c', $cmd],
        $descriptors,
        $pipes,
        $ROOT,
        null,
        ['bypass_shell' => true]
    );
    $spawnStatus = is_resource($process) ? proc_close($process) : -1;

    if ($spawnStatus !== 0) {
        atomic_write_json($STATE, [
            'schema' => 1,
            'running' => false,
            'ok' => false,
            'error' => 'could not start audit',
            'at' => time(),
        ]);
        json_response(500, ['ok' => false, 'error' => 'could not start audit']);
    }

    json_response(202, ['ok' => true, 'audit' => $starting]);
}

if ($action === 'mark' || $bodyAction === 'mark') {
    if (array_diff(array_keys($fields), ['action', 'file', 'status'])) {
        json_response(400, ['ok' => false, 'error' => 'unexpected field']);
    }

    $file = $fields['file'] ?? null;
    $status = $fields['status'] ?? null;
    if (!is_string($file) || !valid_cutout_file($file)) {
        json_response(400, ['ok' => false, 'error' => 'invalid illustration filename']);
    }
    if (!is_file("$ILLUS/$file")) {
        json_response(404, ['ok' => false, 'error' => 'illustration not found']);
    }
    if (!is_string($status) || !in_array($status, ['good', 'bad', 'pending'], true)) {
        json_response(400, ['ok' => false, 'error' => 'invalid review status']);
    }

    $reviews = read_json_file($REVIEW);
    if ($status === 'pending') {
        unset($reviews[$file]);
    } else {
        $reviews[$file] = [
            'status' => $status,
            'reviewed_at' => time(),
        ];
    }
    ksort($reviews, SORT_STRING);

    if (!atomic_write_json($REVIEW, $reviews)) {
        json_response(500, ['ok' => false, 'error' => 'cannot save review']);
    }

    json_response(200, merged_list($AUDIT, $REVIEW, $STATE, $STALE_S));
}

json_response(404, ['ok' => false, 'error' => 'unknown action']);
