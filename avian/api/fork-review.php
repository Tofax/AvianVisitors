<?php
// Narrow JSON facade for the illustration fork review server.

declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

require_once __DIR__ . '/admin-auth.php';
avian_require_admin();

function fork_review_response(int $status, array $body): void {
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
    exit;
}

$control = getenv('AV_FORK_REVIEW_CONTROL') ?: '/usr/local/sbin/avian-fork-review';

function run_fork_review_control(string $control, string $action): array {
    if (!is_executable($control)) {
        return [
            'status' => 503,
            'body' => [
                'ok' => false,
                'error' => 'fork review control is not installed',
            ],
        ];
    }

    $out = [];
    $rc = 0;
    exec(
        'sudo -n ' . escapeshellarg($control) . ' ' . escapeshellarg($action) . ' 2>&1',
        $out,
        $rc
    );

    $decoded = json_decode(implode("\n", $out), true);
    if (!is_array($decoded)) {
        return [
            'status' => 500,
            'body' => [
                'ok' => false,
                'error' => 'fork review control returned an invalid response',
            ],
        ];
    }

    if (($decoded['ok'] ?? false) && ($decoded['running'] ?? false)) {
        $token = (string)($decoded['access_token'] ?? '');
        $port = (int)($decoded['port'] ?? 8765);

        if ($token === '') {
            return [
                'status' => 500,
                'body' => [
                    'ok' => false,
                    'error' => 'fork review access token is missing',
                ],
            ];
        }

        unset($decoded['access_token']);
        $decoded['port'] = $port;
        $decoded['access'] = rawurlencode($token);
    }

    return [
        'status' => $rc === 0 ? 200 : 409,
        'body' => $decoded,
    ];
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'GET') {
    $result = run_fork_review_control($control, 'status');
    fork_review_response($result['status'], $result['body']);
}

avian_require_json_action();

$body = json_decode((string)file_get_contents('php://input'), true);
if (!is_array($body)) {
    fork_review_response(400, ['ok' => false, 'error' => 'bad json']);
}

$action = (string)($body['action'] ?? '');
if (!in_array($action, ['start', 'stop'], true)) {
    fork_review_response(400, ['ok' => false, 'error' => 'unknown action']);
}

$result = run_fork_review_control($control, $action);
fork_review_response($result['status'], $result['body']);
