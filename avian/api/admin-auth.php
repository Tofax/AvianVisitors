<?php
// Shared authentication, password-bound sessions, and cross-site request
// checks for AvianVisitors' private station APIs. This file parses
// birdnet.conf as data; it never sources or evaluates it.

declare(strict_types=1);

const AVIAN_ADMIN_SESSION_NAME = 'avian_admin';
const AVIAN_ADMIN_SESSION_KEY = 'password_fingerprint';

function avian_api_fail(int $status, string $error): void {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(['ok' => false, 'error' => $error]);
    exit;
}

/**
 * Parse one simple shell assignment without invoking a shell.
 *
 * BirdNET-Pi's password UI writes an alphanumeric value, usually quoted.
 * Ambiguous shell syntax fails closed instead of being interpreted here.
 */
function avian_has_unescaped_shell_expansion(string $value): bool {
    $backslashes = 0;
    $length = strlen($value);
    for ($i = 0; $i < $length; $i++) {
        $char = $value[$i];
        if ($char === '\\') {
            $backslashes++;
            continue;
        }
        if (($char === '$' || $char === '`') && ($backslashes % 2) === 0) return true;
        $backslashes = 0;
    }
    return false;
}

function avian_conf_value(string $path, string $key): ?string {
    if (!is_readable($path) || !preg_match('/^[A-Z_][A-Z0-9_]*$/', $key)) {
        return null;
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) return null;

    $found = false;
    $result = null;
    foreach ($lines as $line) {
        if (!preg_match('/^\s*(?:export\s+)?' . preg_quote($key, '/') . '\s*=\s*(.*?)\s*$/', $line, $m)) {
            continue;
        }

        $found = true;
        $raw = $m[1];
        if ($raw === '') {
            $result = '';
            continue;
        }

        $quote = $raw[0] ?? '';
        if ($quote === "'" || $quote === '"') {
            $pattern = $quote === "'"
                ? "/^'([^']*)'\\s*(?:#.*)?$/"
                : '/^"((?:\\\\.|[^"\\\\])*)"\\s*(?:#.*)?$/';
            if (!preg_match($pattern, $raw, $valueMatch)) {
                $result = null;
                continue;
            }
            $value = $valueMatch[1];
            if ($quote === '"') {
                if (avian_has_unescaped_shell_expansion($value)) {
                    $result = null;
                    continue;
                }
                // In a shell double-quoted value, only these four escaped
                // characters lose their leading backslash.
                $value = preg_replace('/\\\\([\\\\"$`])/', '$1', $value) ?? '';
            }
        } else {
            // The supported BirdNET-Pi password format has no whitespace.
            // A whitespace-separated comment is accepted; other syntax is
            // intentionally rejected rather than partially interpreted.
            if (!preg_match('/^([A-Za-z0-9._+,:@%\/=\-]*)(?:\s+#.*)?$/', $raw, $valueMatch)) {
                $result = null;
                continue;
            }
            $value = $valueMatch[1];
        }

        if (strlen($value) > 512 || strpbrk($value, "\0\r\n") !== false) {
            $result = null;
            continue;
        }
        $result = $value;
    }

    return $found ? $result : null;
}

function avian_admin_password(): ?string {
    // Used by the focused CLI tests and by deployments that inject secrets
    // into php-fpm. An explicitly empty override still means "no password".
    $override = getenv('AV_ADMIN_PASSWORD');
    if ($override !== false) {
        $override = (string)$override;
        if (strlen($override) > 512 || strpbrk($override, "\0\r\n") !== false) return null;
        return $override;
    }
    return avian_conf_value('/etc/birdnet/birdnet.conf', 'CADDY_PWD');
}

function avian_private_address(string $address): bool {
    $packed = @inet_pton($address);
    if ($packed === false) return false;

    if (strlen($packed) === 4) {
        $first = ord($packed[0]);
        $second = ord($packed[1]);
        return $first === 10
            || ($first === 172 && $second >= 16 && $second <= 31)
            || ($first === 192 && $second === 168)
            || $first === 127
            || ($first === 169 && $second === 254);
    }

    // ::1, fc00::/7 (unique-local), and fe80::/10 (link-local).
    if ($packed === str_repeat("\0", 15) . "\1") return true;
    $first = ord($packed[0]);
    $second = ord($packed[1]);
    return (($first & 0xFE) === 0xFC)
        || ($first === 0xFE && ($second & 0xC0) === 0x80);
}

function avian_local_host(string $value): bool {
    $host = strtolower(trim($value));
    if ($host === '' || strpbrk($host, "\r\n,/@") !== false) return false;

    if ($host[0] === '[') {
        $end = strpos($host, ']');
        if ($end === false) return false;
        $literal = substr($host, 1, $end - 1);
        $rest = substr($host, $end + 1);
        if ($rest !== '' && !preg_match('/^:\d{1,5}$/', $rest)) return false;
        return filter_var($literal, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false
            && avian_private_address($literal);
    }

    // Remove a port from an IPv4 literal or hostname. Bare IPv6 literals
    // contain multiple colons and are handled by filter_var below.
    if (substr_count($host, ':') === 1) {
        [$candidate, $port] = explode(':', $host, 2);
        if ($port === '' || !ctype_digit($port)) return false;
        $host = $candidate;
    }

    return $host === 'localhost'
        || str_ends_with($host, '.local')
        || (filter_var($host, FILTER_VALIDATE_IP) !== false
            && avian_private_address($host));
}

function avian_has_forwarding_headers(array $server): bool {
    foreach ($server as $key => $value) {
        if ($value === null || $value === '') continue;
        $name = strtoupper((string)$key);
        if ($name === 'HTTP_FORWARDED'
            || $name === 'HTTP_X_REAL_IP'
            || str_starts_with($name, 'HTTP_X_FORWARDED_')
            || str_starts_with($name, 'HTTP_CF_')) {
            return true;
        }
    }
    return false;
}

function avian_is_direct_local_request(array $server): bool {
    // Caddy's FastCGI transport adds X-Forwarded-* fields of its own. When
    // the managed Caddy route supplies this marker, use its decision about
    // the raw request and do not mistake Caddy's transport fields for an
    // inbound proxy. A request header cannot set a FastCGI environment value.
    if (array_key_exists('AVIAN_DIRECT_LOCAL', $server)) {
        return hash_equals('1', (string)$server['AVIAN_DIRECT_LOCAL'])
            && avian_private_address((string)($server['REMOTE_ADDR'] ?? ''))
            && avian_local_host((string)($server['HTTP_HOST'] ?? ''));
    }

    if (avian_has_forwarding_headers($server)) return false;
    return avian_private_address((string)($server['REMOTE_ADDR'] ?? ''))
        && avian_local_host((string)($server['HTTP_HOST'] ?? ''));
}

/** @return array{0:string,1:string}|null */
function avian_basic_credentials(array $server): ?array {
    $header = $server['HTTP_AUTHORIZATION'] ?? $server['REDIRECT_HTTP_AUTHORIZATION'] ?? null;
    if (!is_string($header)) return null;

    $header = trim($header);
    if (strlen($header) > 2048) return null;
    if (!preg_match('/^Basic[ \t]+([A-Za-z0-9+\/]+={0,2})$/D', $header, $m)) return null;
    $decoded = base64_decode($m[1], true);
    if (!is_string($decoded) || strpbrk($decoded, "\0\r\n") !== false) return null;

    $colon = strpos($decoded, ':');
    if ($colon === false) return null;
    return [substr($decoded, 0, $colon), substr($decoded, $colon + 1)];
}

function avian_has_authorization_header(array $server): bool {
    return array_key_exists('HTTP_AUTHORIZATION', $server)
        || array_key_exists('REDIRECT_HTTP_AUTHORIZATION', $server);
}

function avian_request_is_https(array $server): bool {
    $https = strtolower(trim((string)($server['HTTPS'] ?? '')));
    if ($https !== '' && $https !== 'off' && $https !== '0') return true;
    if ((string)($server['SERVER_PORT'] ?? '') === '443') return true;

    // A proxy marker can only make the cookie more restrictive. A forged
    // value on plain HTTP results in a Secure cookie the browser will not
    // return; it can never downgrade a genuinely HTTPS request.
    $forwardedProto = strtolower(trim(explode(',', (string)($server['HTTP_X_FORWARDED_PROTO'] ?? ''), 2)[0]));
    if ($forwardedProto === 'https') return true;
    if (preg_match('/(?:^|[;,]\s*)proto\s*=\s*"?https"?(?:[;,]|$)/i', (string)($server['HTTP_FORWARDED'] ?? '')) === 1) {
        return true;
    }

    // Cloudflare Tunnel preserves the public scheme in CF-Visitor while its
    // local hop to Caddy is HTTP. A forged value only makes the cookie more
    // restrictive, so accepting "https" here cannot weaken authentication.
    $visitor = json_decode((string)($server['HTTP_CF_VISITOR'] ?? ''), true);
    return is_array($visitor) && strtolower((string)($visitor['scheme'] ?? '')) === 'https';
}

function avian_admin_session_fingerprint(string $password, string $sessionId): string {
    return hash_hmac('sha256', 'avian-admin-session-v1:' . $sessionId, $password);
}

function avian_start_admin_session(array $server, bool $requireCookie): bool {
    if (session_status() === PHP_SESSION_ACTIVE) {
        return session_name() === AVIAN_ADMIN_SESSION_NAME;
    }
    if (session_status() === PHP_SESSION_DISABLED || headers_sent()) return false;

    if ($requireCookie) {
        $cookie = $_COOKIE[AVIAN_ADMIN_SESSION_NAME] ?? null;
        if (!is_string($cookie)
            || strlen($cookie) < 16
            || strlen($cookie) > 128
            || !preg_match('/^[A-Za-z0-9,-]+$/D', $cookie)) {
            return false;
        }
    }

    if (@ini_set('session.use_strict_mode', '1') === false
        || @ini_set('session.use_only_cookies', '1') === false
        || @ini_set('session.use_trans_sid', '0') === false) {
        return false;
    }
    if (!session_name(AVIAN_ADMIN_SESSION_NAME)) return false;
    if (!session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/avian/',
        'domain' => '',
        'secure' => avian_request_is_https($server),
        'httponly' => true,
        'samesite' => 'Strict',
    ])) {
        return false;
    }
    return @session_start();
}

function avian_destroy_admin_session(array $server): void {
    if (session_status() !== PHP_SESSION_ACTIVE || session_name() !== AVIAN_ADMIN_SESSION_NAME) return;
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        setcookie(AVIAN_ADMIN_SESSION_NAME, '', [
            'expires' => time() - 42000,
            'path' => '/avian/',
            'domain' => '',
            'secure' => avian_request_is_https($server),
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
    }
    @session_destroy();
}

function avian_create_admin_session(string $password, array $server): bool {
    if ($password === '' || strlen($password) > 512) return false;
    if (!avian_start_admin_session($server, false)) return false;
    if (!session_regenerate_id(true)) {
        avian_destroy_admin_session($server);
        return false;
    }
    $_SESSION = [
        AVIAN_ADMIN_SESSION_KEY => avian_admin_session_fingerprint($password, session_id()),
    ];
    // No endpoint mutates session state after authentication. Release the
    // file lock now so a long CSV or recordings download cannot stall the
    // rest of the admin interface.
    return session_write_close();
}

function avian_admin_session_valid(string $password, array $server): bool {
    // Do not open or create a PHP session when no admin password exists.
    if ($password === '' || strlen($password) > 512) return false;
    if (!avian_start_admin_session($server, true)) return false;

    $stored = $_SESSION[AVIAN_ADMIN_SESSION_KEY] ?? null;
    $expected = avian_admin_session_fingerprint($password, session_id());
    $valid = is_string($stored) && hash_equals($expected, $stored);
    if ($valid) session_write_close();
    else avian_destroy_admin_session($server);
    return $valid;
}

/** @return array{allowed:bool,status:int,error:?string,mode:string} */
function avian_admin_auth_decision(?array $server = null, ?string $password = null): array {
    $server = $server ?? $_SERVER;
    $forced = getenv('AV_REQUIRE_AUTH') === '1';
    if (!$forced && avian_is_direct_local_request($server)) {
        return ['allowed' => true, 'status' => 200, 'error' => null, 'mode' => 'local'];
    }

    $expected = $password ?? avian_admin_password();
    $credentials = avian_basic_credentials($server);
    $user = $credentials[0] ?? '';
    $provided = $credentials[1] ?? '';

    // Evaluate both comparisons for every syntactically valid attempt.
    $userOk = hash_equals('birdnet', $user);
    $passwordOk = is_string($expected) && $expected !== ''
        ? hash_equals($expected, $provided)
        : false;
    if ($credentials !== null && $userOk && $passwordOk) {
        return ['allowed' => true, 'status' => 200, 'error' => null, 'mode' => 'basic'];
    }

    return ['allowed' => false, 'status' => 401, 'error' => 'unauthorized', 'mode' => 'denied'];
}

function avian_require_admin(): void {
    $server = $_SERVER;
    if (getenv('AV_REQUIRE_AUTH') !== '1' && avian_is_direct_local_request($server)) return;

    $password = avian_admin_password();
    if (!is_string($password) || $password === '') avian_api_fail(401, 'unauthorized');

    // An explicit Authorization header must stand on its own. A malformed or
    // wrong Basic attempt never falls through to an older valid session.
    if (avian_has_authorization_header($server)) {
        $decision = avian_admin_auth_decision($server, $password);
        if (!$decision['allowed']) avian_api_fail($decision['status'], (string)$decision['error']);
        // Browsers may keep sending cached Basic credentials after login.
        // Reuse an already-valid session so parallel API requests do not race
        // through repeated session-ID rotations.
        if (avian_admin_session_valid($password, $server)) return;
        if (!avian_create_admin_session($password, $server)) {
            avian_api_fail(503, 'authentication session unavailable');
        }
        return;
    }

    if (avian_admin_session_valid($password, $server)) return;
    avian_api_fail(401, 'unauthorized');
}

/** @return array{allowed:bool,status:int,error:?string} */
function avian_json_action_decision(?array $server = null): array {
    $server = $server ?? $_SERVER;
    if (strtoupper((string)($server['REQUEST_METHOD'] ?? 'GET')) !== 'POST') {
        return ['allowed' => false, 'status' => 405, 'error' => 'POST required'];
    }

    $type = strtolower(trim(explode(';', (string)($server['CONTENT_TYPE'] ?? ''), 2)[0]));
    if ($type !== 'application/json') {
        return ['allowed' => false, 'status' => 415, 'error' => 'expected application/json'];
    }
    if (($server['HTTP_X_AVIAN_ACTION'] ?? null) !== '1') {
        return ['allowed' => false, 'status' => 403, 'error' => 'missing action header'];
    }
    return ['allowed' => true, 'status' => 200, 'error' => null];
}

function avian_require_json_action(): void {
    $decision = avian_json_action_decision();
    if (!$decision['allowed']) {
        if ($decision['status'] === 405) header('Allow: POST');
        avian_api_fail($decision['status'], (string)$decision['error']);
    }
}
