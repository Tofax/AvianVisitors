<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/avian/api/admin-auth.php';

$failures = 0;
$checks = 0;

function check(bool $condition, string $label): void {
    global $failures, $checks;
    $checks++;
    if ($condition) return;
    $failures++;
    fwrite(STDERR, "FAIL: $label\n");
}

function request(array $overrides = []): array {
    return array_merge([
        'REQUEST_METHOD' => 'GET',
        'REMOTE_ADDR' => '203.0.113.10',
        'HTTP_HOST' => 'birds.example.com',
    ], $overrides);
}

function basic(string $user, string $password): string {
    return 'Basic ' . base64_encode($user . ':' . $password);
}

function endpoint_json(string $path, array $server, array $query = []): ?array {
    $code = 'putenv("AV_ADMIN_PASSWORD=correct");'
        . ' $_SERVER=' . var_export($server, true) . ';'
        . ' $_GET=' . var_export($query, true) . ';'
        . ' include ' . var_export($path, true) . ';';
    $output = shell_exec(escapeshellarg(PHP_BINARY) . ' -r ' . escapeshellarg($code));
    return is_string($output) ? json_decode($output, true) : null;
}

putenv('AV_REQUIRE_AUTH');

$direct = request(['REMOTE_ADDR' => '192.168.1.20', 'HTTP_HOST' => 'birdnet.local']);
check(avian_admin_auth_decision($direct, '')['allowed'], 'direct LAN request is allowed without a password');
check(avian_admin_auth_decision(request(['REMOTE_ADDR' => '::1', 'HTTP_HOST' => '[::1]:8080']), '')['allowed'], 'loopback IPv6 is local');
check(avian_admin_auth_decision(request(['REMOTE_ADDR' => '192.168.1.20', 'HTTP_HOST' => '192.168.1.20']), '')['allowed'], 'private IPv4 Host is local');
check(avian_admin_auth_decision(request(['REMOTE_ADDR' => 'fd00::20', 'HTTP_HOST' => '[fd00::20]']), '')['allowed'], 'unique-local IPv6 Host is local');
check(!avian_admin_auth_decision(request(['REMOTE_ADDR' => '192.168.1.20', 'HTTP_HOST' => '8.8.8.8']), 'correct')['allowed'], 'public IPv4 literal still requires auth');
check(!avian_admin_auth_decision(request(['REMOTE_ADDR' => '192.168.1.20', 'HTTP_HOST' => '[2001:4860::1]']), 'correct')['allowed'], 'public IPv6 literal still requires auth');
check(!avian_admin_auth_decision(request(['REMOTE_ADDR' => '192.168.1.20', 'HTTP_HOST' => 'birds.example.com']), 'correct')['allowed'], 'public Host on LAN still requires auth');
check(!avian_admin_auth_decision(request(['REMOTE_ADDR' => '192.168.1.20', 'HTTP_HOST' => 'birdnet.local', 'HTTP_FORWARDED' => 'for=198.51.100.2']), 'correct')['allowed'], 'Forwarded disables LAN bypass');
check(!avian_admin_auth_decision(request(['REMOTE_ADDR' => '192.168.1.20', 'HTTP_HOST' => 'birdnet.local', 'HTTP_X_FORWARDED_PROTO' => 'https']), 'correct')['allowed'], 'X-Forwarded disables LAN bypass');
check(!avian_admin_auth_decision(request(['REMOTE_ADDR' => '127.0.0.1', 'HTTP_HOST' => 'birdnet.local', 'HTTP_CF_CONNECTING_IP' => '198.51.100.2']), 'correct')['allowed'], 'Cloudflare header disables LAN bypass');
check(avian_admin_auth_decision(request([
    'REMOTE_ADDR' => '127.0.0.1',
    'HTTP_HOST' => 'birdnet.local',
    'HTTP_X_FORWARDED_FOR' => '192.168.1.20',
    'HTTP_X_FORWARDED_HOST' => 'birdnet.local',
    'HTTP_X_FORWARDED_PROTO' => 'http',
    'AVIAN_DIRECT_LOCAL' => '1',
]), '')['allowed'], 'Caddy direct-local marker permits its FastCGI transport headers');
check(!avian_admin_auth_decision(request([
    'REMOTE_ADDR' => '127.0.0.1',
    'HTTP_HOST' => 'birdnet.local',
    'AVIAN_DIRECT_LOCAL' => '0',
]), 'correct')['allowed'], 'Caddy nonlocal marker disables LAN bypass');
check(!avian_admin_auth_decision(request([
    'REMOTE_ADDR' => '127.0.0.1',
    'HTTP_HOST' => 'birds.example.com',
    'AVIAN_DIRECT_LOCAL' => '1',
]), 'correct')['allowed'], 'Caddy marker cannot bypass the local Host check');
check(!avian_admin_auth_decision(request([
    'REMOTE_ADDR' => '203.0.113.10',
    'HTTP_HOST' => 'birdnet.local',
    'AVIAN_DIRECT_LOCAL' => '1',
]), 'correct')['allowed'], 'Caddy marker cannot bypass the private-peer check');

check(!avian_admin_auth_decision(request(), 'correct')['allowed'], 'missing authorization is denied');
check(!avian_admin_auth_decision(request(['HTTP_AUTHORIZATION' => 'Basic']), 'correct')['allowed'], 'malformed Basic header is denied');
check(!avian_admin_auth_decision(request(['HTTP_AUTHORIZATION' => 'Bearer anything']), 'correct')['allowed'], 'non-Basic header is denied');
check(!avian_admin_auth_decision(request(['HTTP_AUTHORIZATION' => basic('birdnet', 'anything')]), 'correct')['allowed'], 'arbitrary password is denied');
check(!avian_admin_auth_decision(request(['HTTP_AUTHORIZATION' => basic('birdnet', 'wrong')]), 'correct')['allowed'], 'wrong password is denied');
check(!avian_admin_auth_decision(request(['HTTP_AUTHORIZATION' => basic('other', 'correct')]), 'correct')['allowed'], 'wrong user is denied');
check(avian_admin_auth_decision(request(['HTTP_AUTHORIZATION' => basic('birdnet', 'correct')]), 'correct')['allowed'], 'valid Basic credentials are allowed');
check(!avian_admin_auth_decision(request(['HTTP_AUTHORIZATION' => basic('birdnet', '')]), '')['allowed'], 'blank configured password cannot authenticate');

putenv('AV_REQUIRE_AUTH=1');
check(!avian_admin_auth_decision($direct, 'correct')['allowed'], 'forced auth disables direct LAN bypass');
check(avian_admin_auth_decision(array_merge($direct, ['HTTP_AUTHORIZATION' => basic('birdnet', 'correct')]), 'correct')['allowed'], 'forced auth accepts valid Basic credentials');
putenv('AV_REQUIRE_AUTH');

$post = request([
    'REQUEST_METHOD' => 'POST',
    'CONTENT_TYPE' => 'application/json; charset=UTF-8',
    'HTTP_X_AVIAN_ACTION' => '1',
]);
check(avian_json_action_decision($post)['allowed'], 'JSON POST with action header is allowed');
check(!avian_json_action_decision(array_merge($post, ['REQUEST_METHOD' => 'GET']))['allowed'], 'mutating GET is denied');
check(avian_json_action_decision(array_merge($post, ['REQUEST_METHOD' => 'GET']))['status'] === 405, 'mutating GET returns 405');
check(!avian_json_action_decision(array_merge($post, ['CONTENT_TYPE' => 'text/plain']))['allowed'], 'text/plain POST is denied');
check(!avian_json_action_decision(array_merge($post, ['CONTENT_TYPE' => 'application/jsonp']))['allowed'], 'JSON-like content type is denied');
check(!avian_json_action_decision(array_merge($post, ['HTTP_X_AVIAN_ACTION' => '0']))['allowed'], 'wrong action header is denied');
check(!avian_json_action_decision(array_merge($post, ['HTTP_X_AVIAN_ACTION' => null]))['allowed'], 'missing action header is denied');

$api = dirname(__DIR__) . '/avian/api';
$localPost = [
    'REQUEST_METHOD' => 'POST',
    'REMOTE_ADDR' => '192.168.1.20',
    'HTTP_HOST' => 'birdnet.local',
    'CONTENT_TYPE' => 'application/json',
];
foreach ([
    'config.php' => [],
    'generate.php' => ['action' => 'start'],
    'archive.php' => [],
    'maintenance.php' => [],
] as $endpoint => $query) {
    $body = endpoint_json("$api/$endpoint", $localPost, $query);
    check(is_array($body) && ($body['error'] ?? '') === 'missing action header', "$endpoint wires the action-header gate");
}
$body = endpoint_json("$api/birdnet-status.php", array_merge($localPost, [
    'REQUEST_METHOD' => 'GET',
    'HTTP_X_AVIAN_ACTION' => '1',
]), ['action' => 'restart', 'unit' => 'birdnet_analysis']);
check(is_array($body) && ($body['error'] ?? '') === 'POST required', 'birdnet restart is POST-only');
$body = endpoint_json("$api/birdnet-status.php", array_merge($localPost, [
    'CONTENT_TYPE' => 'text/plain',
    'HTTP_X_AVIAN_ACTION' => '1',
]), ['action' => 'restart', 'unit' => 'birdnet_analysis']);
check(is_array($body) && ($body['error'] ?? '') === 'expected application/json', 'birdnet restart wires the JSON gate');

$sessionDir = sys_get_temp_dir() . '/avian-auth-session-' . bin2hex(random_bytes(6));
check(mkdir($sessionDir, 0700), 'temporary session directory is created');
session_save_path($sessionDir);
$_COOKIE = [];
$httpsServer = request(['HTTPS' => 'on', 'SERVER_PORT' => '443']);
check(avian_start_admin_session($httpsServer, false), 'admin session can be started');
$beforeRegenerate = session_id();
check(avian_create_admin_session('correct', $httpsServer), 'valid Basic authentication creates a session');
$createdSessionId = session_id();
check($createdSessionId !== '' && $createdSessionId !== $beforeRegenerate, 'Basic authentication regenerates the session ID');
check(isset($_SESSION[AVIAN_ADMIN_SESSION_KEY]), 'session contains a password fingerprint');
check(strpos(json_encode($_SESSION) ?: '', 'correct') === false, 'session does not contain the plaintext password');
$cookie = session_get_cookie_params();
check(($cookie['httponly'] ?? false) === true, 'session cookie is HttpOnly');
check(strtolower((string)($cookie['samesite'] ?? '')) === 'strict', 'session cookie is SameSite Strict');
check(($cookie['secure'] ?? false) === true, 'session cookie is Secure on HTTPS');
check(($cookie['path'] ?? '') === '/avian/', 'session cookie is limited to AvianVisitors');
check(session_status() === PHP_SESSION_NONE, 'created session releases its file lock');

$_COOKIE = [AVIAN_ADMIN_SESSION_NAME => $createdSessionId];
session_id($createdSessionId);
check(avian_admin_session_valid('correct', $httpsServer), 'password-bound session is reusable');
check(session_status() === PHP_SESSION_NONE, 'reused session releases its file lock');
$reusedSessionId = session_id();
putenv('AV_ADMIN_PASSWORD=correct');
$_SERVER = array_merge($httpsServer, ['HTTP_AUTHORIZATION' => basic('birdnet', 'correct')]);
avian_require_admin();
check(session_id() === $reusedSessionId, 'cached Basic credentials reuse an existing valid session');
putenv('AV_ADMIN_PASSWORD');

$_COOKIE = [AVIAN_ADMIN_SESSION_NAME => $createdSessionId];
session_id($createdSessionId);
check(!avian_admin_session_valid('changed', $httpsServer), 'password change invalidates the session');

$_COOKIE = [];
session_id('');
check(!avian_admin_session_valid('', $httpsServer), 'blank password cannot reuse a session');
check(session_status() === PHP_SESSION_NONE, 'blank password does not open a session');
check(!avian_create_admin_session('', $httpsServer), 'blank password cannot create a session');
check(session_status() === PHP_SESSION_NONE, 'blank password creates no session state');
check(!avian_request_is_https(request()), 'plain HTTP does not set the Secure flag');
check(avian_request_is_https(request(['HTTP_X_FORWARDED_PROTO' => 'https'])), 'forwarded HTTPS sets the Secure flag');
check(avian_request_is_https(request(['HTTP_CF_VISITOR' => '{"scheme":"https"}'])), 'Cloudflare HTTPS sets the Secure flag');
check(!avian_request_is_https(request(['HTTP_CF_VISITOR' => '{"scheme":"http"}'])), 'Cloudflare HTTP does not set the Secure flag');

foreach (glob($sessionDir . '/*') ?: [] as $sessionFile) unlink($sessionFile);
rmdir($sessionDir);

$tmp = tempnam(sys_get_temp_dir(), 'avian-auth-');
if ($tmp === false) {
    check(false, 'create temporary config');
} else {
    file_put_contents($tmp, "# ignored\nCADDY_PWD=\"safe123\" # station password\n");
    check(avian_conf_value($tmp, 'CADDY_PWD') === 'safe123', 'quoted config password is parsed as data');
    file_put_contents($tmp, "CADDY_PWD=\$(printf unsafe)\n");
    check(avian_conf_value($tmp, 'CADDY_PWD') === null, 'ambiguous unquoted shell syntax fails closed');
    file_put_contents($tmp, "CADDY_PWD=\$(id)\n");
    check(avian_conf_value($tmp, 'CADDY_PWD') === null, 'unquoted shell expansion fails closed');
    file_put_contents($tmp, "CADDY_PWD=\"\$HOME\"\n");
    check(avian_conf_value($tmp, 'CADDY_PWD') === null, 'quoted shell expansion fails closed');
    file_put_contents($tmp, "CADDY_PWD='literal\$HOME'\n");
    check(avian_conf_value($tmp, 'CADDY_PWD') === 'literal$HOME', 'single-quoted password stays literal');
    file_put_contents($tmp, "CADDY_PWD=old\nCADDY_PWD=new\n");
    check(avian_conf_value($tmp, 'CADDY_PWD') === 'new', 'last config assignment wins');
    file_put_contents($tmp, "CADDY_PWD=old\nCADDY_PWD=\n");
    check(avian_conf_value($tmp, 'CADDY_PWD') === '', 'last blank assignment fails closed');
    unlink($tmp);
}

// Exercise the real menu endpoint in a fresh process. A syntactically valid
// but arbitrary Authorization header must not return its private menu items.
$menu = dirname(__DIR__) . '/avian/api/menu.php';
$server = var_export(request(['HTTP_AUTHORIZATION' => basic('birdnet', 'arbitrary')]), true);
$code = 'putenv("AV_ADMIN_PASSWORD=correct"); $_SERVER=' . $server . '; include ' . var_export($menu, true) . ';';
$command = escapeshellarg(PHP_BINARY) . ' -r ' . escapeshellarg($code);
$output = shell_exec($command);
$decoded = is_string($output) ? json_decode($output, true) : null;
check(is_array($decoded) && ($decoded['error'] ?? '') === 'unauthorized', 'menu rejects arbitrary Basic credentials');
check(is_array($decoded) && !isset($decoded['items']), 'unauthorized menu response contains no items');

$server = var_export(request(['HTTP_AUTHORIZATION' => basic('birdnet', 'correct')]), true);
$code = 'putenv("AV_ADMIN_PASSWORD=correct"); $_SERVER=' . $server . '; include ' . var_export($menu, true) . ';';
$output = shell_exec(escapeshellarg(PHP_BINARY) . ' -r ' . escapeshellarg($code));
$decoded = is_string($output) ? json_decode($output, true) : null;
check(is_array($decoded) && count($decoded['items'] ?? []) === 4, 'menu accepts the configured Basic password');

$code = 'putenv("AV_ADMIN_PASSWORD="); $_SERVER=' . $server . '; include ' . var_export($menu, true) . ';';
$output = shell_exec(escapeshellarg(PHP_BINARY) . ' -r ' . escapeshellarg($code));
$decoded = is_string($output) ? json_decode($output, true) : null;
check(is_array($decoded) && ($decoded['error'] ?? '') === 'unauthorized', 'menu fails closed when the configured password is blank');

if ($failures > 0) {
    fwrite(STDERR, "$failures of $checks checks failed\n");
    exit(1);
}
echo "$checks checks passed\n";
