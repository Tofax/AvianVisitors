<?php
// Admin-only BirdWeather settings facade. The BirdWeather station token is a
// write credential carried in API URLs, not the station's public numeric ID.
// It is accepted only as a write-only input and is never returned, logged, or
// used to construct client-visible URLs.

declare(strict_types=1);

require_once __DIR__ . '/admin-auth.php';

const AVIAN_BIRDWEATHER_API = 'https://app.birdweather.com/api/v1/stations';
const AVIAN_BIRDWEATHER_PUBLIC = 'https://app.birdweather.com';
const AVIAN_BIRDWEATHER_RESPONSE_MAX = 262144;

function birdweather_response(int $status, array $body): void {
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
    exit;
}

function birdweather_conf_path(): string {
    // CLI-only override keeps runtime tests away from the real station config.
    if (PHP_SAPI === 'cli') {
        $override = getenv('AV_BIRDWEATHER_CONF');
        if (is_string($override) && $override !== '') return $override;
    }
    return '/etc/birdnet/birdnet.conf';
}

function birdweather_parse_conf_value(string $raw): ?string {
    if (strlen($raw) > 1024) return null;
    $raw = trim($raw);
    if ($raw === '') return '';
    $first = $raw[0];
    if ($first === "'") {
        $close = strpos($raw, "'", 1);
        if ($close === false || preg_match('/\A\s*(?:#.*)?\z/D', substr($raw, $close + 1)) !== 1) {
            return null;
        }
        return substr($raw, 1, $close - 1);
    }
    if ($first === '"') {
        $value = '';
        $length = strlen($raw);
        for ($index = 1; $index < $length; $index++) {
            $character = $raw[$index];
            if ($character === '"') {
                return preg_match('/\A\s*(?:#.*)?\z/D', substr($raw, $index + 1)) === 1
                    ? $value
                    : null;
            }
            if ($character === '\\') {
                $index++;
                if ($index >= $length) return null;
                $escaped = $raw[$index];
                $value .= in_array($escaped, ['\\', '"', '$', '`'], true)
                    ? $escaped
                    : '\\' . $escaped;
                continue;
            }
            if ($character === '$' || $character === '`') return null;
            $value .= $character;
        }
        return null;
    }
    if (preg_match('/\A([A-Za-z0-9._+,:@%\/=~-]*)(?:\s+#.*)?\z/D', $raw, $match) !== 1) {
        return null;
    }
    return $match[1];
}

function birdweather_read_conf(string $path): array {
    if (!is_readable($path) || is_dir($path)) return [];
    $values = [];
    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) return [];
    foreach ($lines as $line) {
        if ($line === '' || $line[0] === '#') continue;
        if (preg_match('/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$/', $line, $match) !== 1) {
            continue;
        }
        // Only these four keys are retained. This keeps unrelated secrets out
        // of memory and out of any accidental future response serialization.
        if (in_array($match[1], [
            'BIRDWEATHER_ID',
            'BIRDWEATHER_ENABLED',
            'BIRDWEATHER_UPLOAD_AUDIO',
            'PRIVACY_THRESHOLD',
        ], true)) {
            $value = birdweather_parse_conf_value($match[2]);
            if ($value === null) unset($values[$match[1]]);
            else $values[$match[1]] = $value;
        }
    }
    return $values;
}

function birdweather_token_is_valid(string $token): bool {
    return preg_match('/\A[A-Za-z0-9._~-]{1,160}\z/D', $token) === 1;
}

function birdweather_effective_config(array $conf): array {
    $token = trim((string)($conf['BIRDWEATHER_ID'] ?? ''));
    $tokenConfigured = $token !== '';
    $tokenValid = birdweather_token_is_valid($token);
    $enabledExplicit = array_key_exists('BIRDWEATHER_ENABLED', $conf);
    $audioExplicit = array_key_exists('BIRDWEATHER_UPLOAD_AUDIO', $conf);

    $enabled = $enabledExplicit
        ? (string)$conf['BIRDWEATHER_ENABLED'] === '1'
        : $tokenConfigured;
    // Old installations have neither policy key. Preserve their audio upload
    // behavior. Once either policy key exists, a missing audio key is false.
    $uploadAudio = $audioExplicit
        ? (string)$conf['BIRDWEATHER_UPLOAD_AUDIO'] === '1'
        : ($tokenConfigured && !$enabledExplicit);
    $privacy = filter_var(
        $conf['PRIVACY_THRESHOLD'] ?? 0,
        FILTER_VALIDATE_INT,
        ['options' => ['min_range' => 0, 'max_range' => 3]]
    );
    if ($privacy === false) $privacy = 0;

    return [
        'enabled' => $enabled && $tokenValid,
        'token_configured' => $tokenConfigured,
        'configuration_valid' => !$tokenConfigured || $tokenValid,
        'upload_audio' => $uploadAudio,
        'privacy_threshold' => (int)$privacy,
        'enabled_implicit' => !$enabledExplicit,
        'upload_audio_implicit' => !$audioExplicit,
    ];
}

function birdweather_public_status(array $conf): array {
    $effective = birdweather_effective_config($conf);
    return [
        'ok' => true,
        'enabled' => $effective['enabled'],
        'token_configured' => $effective['token_configured'],
        'configuration_valid' => $effective['configuration_valid'],
        'upload_audio' => $effective['upload_audio'],
        'privacy_threshold' => $effective['privacy_threshold'],
        'migration' => [
            'enabled_implicit' => $effective['enabled_implicit'],
            'upload_audio_implicit' => $effective['upload_audio_implicit'],
        ],
        'sharing' => [
            'detections_include' => [
                'bird names',
                'confidence',
                'timestamp',
                'station coordinates',
            ],
            'audio_is_full_recording' => true,
        ],
        'birdweather_url' => AVIAN_BIRDWEATHER_PUBLIC,
    ];
}

function birdweather_station_id_value(mixed $value): ?int {
    if (is_int($value)) return $value > 0 && $value <= 2147483647 ? $value : null;
    if (!is_string($value) || preg_match('/\A[1-9][0-9]{0,9}\z/D', $value) !== 1) return null;
    $stationId = (int)$value;
    return $stationId > 0 && $stationId <= 2147483647 ? $stationId : null;
}

function birdweather_find_station_id(mixed $value, int $depth = 0): ?int {
    if (!is_array($value) || $depth > 6) return null;
    foreach (['stationId', 'station_id'] as $key) {
        if (array_key_exists($key, $value)) {
            $stationId = birdweather_station_id_value($value[$key]);
            if ($stationId !== null) return $stationId;
        }
    }
    if (isset($value['station']) && is_array($value['station']) && array_key_exists('id', $value['station'])) {
        $stationId = birdweather_station_id_value($value['station']['id']);
        if ($stationId !== null) return $stationId;
    }
    foreach ($value as $nested) {
        if (!is_array($nested)) continue;
        $stationId = birdweather_find_station_id($nested, $depth + 1);
        if ($stationId !== null) return $stationId;
    }
    return null;
}

function birdweather_http_get(string $url): array {
    if (!function_exists('curl_init')) {
        return ['state' => 'unavailable', 'status' => 0, 'body' => null];
    }
    $handle = curl_init($url);
    if ($handle === false) {
        return ['state' => 'unavailable', 'status' => 0, 'body' => null];
    }
    $body = '';
    curl_setopt_array($handle, [
        CURLOPT_RETURNTRANSFER => false,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT => 7,
        CURLOPT_HTTPHEADER => ['Accept: application/json'],
        CURLOPT_USERAGENT => 'BirdNET-Pi AvianVisitors',
        CURLOPT_PROXY => '',
        CURLOPT_NOPROXY => '*',
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
        CURLOPT_WRITEFUNCTION => static function ($curl, string $chunk) use (&$body): int {
            if (strlen($body) + strlen($chunk) > AVIAN_BIRDWEATHER_RESPONSE_MAX) return 0;
            $body .= $chunk;
            return strlen($chunk);
        },
    ]);
    if (defined('CURLOPT_PROTOCOLS') && defined('CURLPROTO_HTTPS')) {
        curl_setopt($handle, CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);
    }
    $completed = curl_exec($handle);
    $status = (int)curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
    curl_close($handle);
    if ($completed !== true) {
        return ['state' => 'unavailable', 'status' => $status, 'body' => null];
    }
    $decoded = json_decode($body, true);
    if ($status < 200 || $status >= 300 || !is_array($decoded)) {
        return [
            'state' => in_array($status, [401, 403, 404], true) ? 'invalid' : 'unavailable',
            'status' => $status,
            'body' => null,
        ];
    }
    if (array_key_exists('success', $decoded) && $decoded['success'] !== true) {
        return ['state' => 'invalid', 'status' => $status, 'body' => null];
    }
    return ['state' => 'connected', 'status' => $status, 'body' => $decoded];
}

function birdweather_probe(string $token): array {
    if (!birdweather_token_is_valid($token)) return ['state' => 'invalid'];
    $base = AVIAN_BIRDWEATHER_API . '/' . rawurlencode($token);
    $connected = false;
    $unavailable = false;
    foreach (['detections?limit=1', 'soundscapes?limit=1'] as $resource) {
        $response = birdweather_http_get($base . '/' . $resource);
        if ($response['state'] === 'invalid') return ['state' => 'invalid'];
        if ($response['state'] !== 'connected') {
            $unavailable = true;
            continue;
        }
        $connected = true;
        $stationId = birdweather_find_station_id($response['body']);
        if ($stationId !== null) {
            return [
                'state' => 'connected',
                'station_id' => $stationId,
                'station_url' => AVIAN_BIRDWEATHER_PUBLIC . '/stations/' . $stationId,
            ];
        }
    }
    if ($connected) return ['state' => 'connected', 'station_id' => null, 'station_url' => null];
    return ['state' => $unavailable ? 'unavailable' : 'invalid'];
}

function birdweather_validate_update(array $body, array $conf): array {
    $allowed = ['enabled', 'upload_audio', 'token', 'forget_token', 'privacy_threshold'];
    foreach (array_keys($body) as $key) {
        if (!is_string($key) || !in_array($key, $allowed, true)) {
            return ['ok' => false, 'status' => 400, 'error' => 'unknown setting'];
        }
    }
    if (!array_key_exists('enabled', $body) || !is_bool($body['enabled'])) {
        return ['ok' => false, 'status' => 400, 'error' => 'enabled must be true or false'];
    }
    if (array_key_exists('upload_audio', $body) && !is_bool($body['upload_audio'])) {
        return ['ok' => false, 'status' => 400, 'error' => 'upload_audio must be true or false'];
    }
    if (array_key_exists('privacy_threshold', $body)
        && (!is_int($body['privacy_threshold'])
            || $body['privacy_threshold'] < 0
            || $body['privacy_threshold'] > 3)) {
        return ['ok' => false, 'status' => 400, 'error' => 'privacy_threshold must be 0 through 3'];
    }
    if (array_key_exists('forget_token', $body) && $body['forget_token'] !== true) {
        return ['ok' => false, 'status' => 400, 'error' => 'forget_token must be true'];
    }
    if (!empty($body['forget_token']) && array_key_exists('token', $body)) {
        return ['ok' => false, 'status' => 400, 'error' => 'cannot replace and forget the token together'];
    }
    if (!empty($body['forget_token']) && $body['enabled']) {
        return ['ok' => false, 'status' => 409, 'error' => 'turn sharing off before forgetting the token'];
    }

    $effective = birdweather_effective_config($conf);
    $newToken = null;
    if (array_key_exists('token', $body)) {
        if (!is_string($body['token']) || !birdweather_token_is_valid($body['token'])) {
            return ['ok' => false, 'status' => 400, 'error' => 'station token is invalid'];
        }
        $newToken = $body['token'];
    }
    $hasUsableToken = $newToken !== null
        || ($effective['token_configured'] && $effective['configuration_valid']);
    if ($body['enabled'] && !$hasUsableToken) {
        return ['ok' => false, 'status' => 409, 'error' => 'add a BirdWeather station token first'];
    }

    if (array_key_exists('upload_audio', $body)) {
        $uploadAudio = $body['upload_audio'];
    } elseif ($newToken !== null && !$effective['token_configured']) {
        // A new opt-in is detections-only unless the person explicitly grants
        // permission for full recording uploads.
        $uploadAudio = false;
    } else {
        $uploadAudio = $effective['upload_audio'];
    }
    $updates = [
        'BIRDWEATHER_ENABLED' => $body['enabled'] ? '1' : '0',
        'BIRDWEATHER_UPLOAD_AUDIO' => $uploadAudio ? '1' : '0',
    ];
    if ($newToken !== null) $updates['BIRDWEATHER_ID'] = $newToken;
    if (!empty($body['forget_token'])) {
        $updates['BIRDWEATHER_ID'] = '';
        $updates['BIRDWEATHER_UPLOAD_AUDIO'] = '0';
    }
    if (array_key_exists('privacy_threshold', $body)) {
        $updates['PRIVACY_THRESHOLD'] = (string)$body['privacy_threshold'];
    } elseif ($newToken !== null && !$effective['token_configured']) {
        $updates['PRIVACY_THRESHOLD'] = '1';
    }
    return ['ok' => true, 'updates' => $updates, 'new_token' => $newToken];
}

function birdweather_validate_new_token(array $validation, callable $probe): array {
    $token = $validation['new_token'] ?? null;
    if (!is_string($token)) return ['ok' => true, 'station' => null];
    $station = $probe($token);
    $state = is_array($station) ? ($station['state'] ?? '') : '';
    if ($state === 'connected') return ['ok' => true, 'station' => $station];
    if ($state === 'invalid') {
        return ['ok' => false, 'status' => 422, 'error' => 'BirdWeather rejected the station token'];
    }
    return ['ok' => false, 'status' => 503, 'error' => 'BirdWeather could not verify the station token'];
}

function birdweather_run_admin_control(string $control, array $arguments, string $input): array {
    if (!is_executable($control)) {
        return ['ok' => false, 'error' => 'admin control is not installed'];
    }
    $command = ['/usr/bin/sudo', '-n', $control];
    foreach ($arguments as $argument) $command[] = (string)$argument;
    $pipes = [];
    $process = proc_open($command, [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ], $pipes, null, null, ['bypass_shell' => true]);
    if (!is_resource($process)) {
        return ['ok' => false, 'error' => 'could not start admin control'];
    }
    $offset = 0;
    $inputLength = strlen($input);
    $writeOk = true;
    while ($offset < $inputLength) {
        $written = @fwrite($pipes[0], substr($input, $offset));
        if (!is_int($written) || $written < 1) {
            $writeOk = false;
            break;
        }
        $offset += $written;
    }
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    // Do not surface stderr. It may contain a token-bearing URL from a future
    // helper implementation even though this helper currently performs only
    // local config writes and service restarts.
    stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    $status = proc_close($process);
    if (!$writeOk) return ['ok' => false, 'error' => 'could not send settings to admin control'];
    $decoded = json_decode(is_string($stdout) ? $stdout : '', true);
    if ($status !== 0 || !is_array($decoded) || empty($decoded['ok'])) {
        return ['ok' => false, 'error' => 'admin control failed'];
    }
    return ['ok' => true];
}

function birdweather_main(): void {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    avian_require_admin();

    $method = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));
    $confPath = birdweather_conf_path();
    $conf = birdweather_read_conf($confPath);
    if ($conf === [] && !is_readable($confPath)) {
        birdweather_response(503, ['ok' => false, 'error' => 'station config is unavailable']);
    }

    if ($method === 'GET') {
        $probeValue = $_GET['probe'] ?? '0';
        if (!is_string($probeValue) || !in_array($probeValue, ['0', '1'], true)) {
            birdweather_response(400, ['ok' => false, 'error' => 'invalid probe setting']);
        }
        $status = birdweather_public_status($conf);
        if ($probeValue === '1') {
            $token = trim((string)($conf['BIRDWEATHER_ID'] ?? ''));
            $status['station'] = $token === ''
                ? ['state' => 'not_configured']
                : birdweather_probe($token);
            $token = '';
        }
        birdweather_response(200, $status);
    }

    avian_require_json_action();
    $body = json_decode((string)file_get_contents('php://input'), true);
    if (!is_array($body) || array_is_list($body)) {
        birdweather_response(400, ['ok' => false, 'error' => 'expected a JSON object']);
    }
    $validation = birdweather_validate_update($body, $conf);
    if (empty($validation['ok'])) {
        birdweather_response((int)$validation['status'], [
            'ok' => false,
            'error' => (string)$validation['error'],
        ]);
    }
    $probeCheck = birdweather_validate_new_token($validation, 'birdweather_probe');
    if (empty($probeCheck['ok'])) {
        birdweather_response((int)$probeCheck['status'], [
            'ok' => false,
            'error' => (string)$probeCheck['error'],
        ]);
    }

    $updates = $validation['updates'];
    $payload = '';
    foreach ($updates as $key => $value) $payload .= $key . "\0" . $value . "\0";
    if (isset($body['token'])) $body['token'] = '';
    $control = getenv('AV_ADMIN_CONTROL') ?: '/usr/local/sbin/avian-admin-control';
    $write = birdweather_run_admin_control(
        $control,
        ['config-set-stdin', (string)count($updates)],
        $payload
    );
    $payload = '';
    if (empty($write['ok'])) {
        birdweather_response(503, ['ok' => false, 'error' => $write['error']]);
    }
    $next = $conf;
    foreach ($updates as $key => $value) $next[$key] = $value;
    $restart = birdweather_run_admin_control($control, ['restart', 'birdnet_analysis'], '');
    if (empty($restart['ok'])) {
        birdweather_response(500, [
            'ok' => false,
            'saved' => true,
            'settings' => birdweather_public_status($next),
            'error' => 'settings saved, but birdnet_analysis did not restart',
        ]);
    }

    $response = birdweather_public_status($next);
    if (is_array($probeCheck['station'] ?? null)) $response['station'] = $probeCheck['station'];
    birdweather_response(200, $response);
}

if (!defined('AVIAN_BIRDWEATHER_LIBRARY_ONLY')) birdweather_main();
