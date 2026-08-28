<?php
// AvianVisitors - drawer menu items.
//
// Returns the list of links shown in the side drawer when a user clicks
// the menu button. The live JS expects {items: [{label, href, native}]}.
//
// Direct requests can be password protected by the station owner. Forwarded
// and public-host requests always verify the same configured password.

declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

require_once __DIR__ . '/admin-auth.php';

$menuAction = (string)($_GET['action'] ?? '');

if ($menuAction === 'lock') {
    avian_require_json_action();
    avian_logout_admin_session($_SERVER);
    echo json_encode(['ok' => true]);
    exit;
}

if ($menuAction === 'activity') {
    avian_require_json_action();
    $activityState = avian_admin_state();
    if (empty($activityState['valid']) || empty($activityState['configured'])) {
        avian_admin_password_missing_fail();
    }
    if (!avian_admin_session_valid($_SERVER, $activityState, true)) {
        avian_api_fail(401, 'unauthorized');
    }
    echo json_encode(['ok' => true]);
    exit;
}

if ($menuAction === 'idle-lock') {
    avian_require_json_action();
    $idleState = avian_admin_state();
    echo json_encode([
        'ok' => true,
        'recovery' => empty($idleState['valid']) || empty($idleState['configured']),
    ] + avian_idle_lock_admin_session($_SERVER));
    exit;
}

if ($menuAction === 'download-grant') {
    avian_require_json_action();
    avian_require_admin();
    $grantBody = json_decode((string)file_get_contents('php://input'), true);
    $scope = is_array($grantBody) ? (string)($grantBody['scope'] ?? '') : '';
    $token = avian_create_admin_download_grant($_SERVER, $scope);
    if (!is_string($token)) avian_api_fail(400, 'invalid download request');
    echo json_encode(['ok' => true, 'token' => $token, 'expires_in' => 30]);
    exit;
}

$adminState = avian_admin_state();
$passwordRequired = avian_lan_admin_auth_required()
    || !avian_is_direct_local_request($_SERVER);
if ($passwordRequired
    && (empty($adminState['valid']) || empty($adminState['configured']))) {
    http_response_code(401);
    echo json_encode([
        'ok' => false,
        'error' => 'admin credential state is missing or invalid',
        'recovery' => true,
    ]);
    exit;
}
avian_require_admin();

// Count of instant (chroma) cutouts awaiting the full-quality upgrade
// pass - drives the notification dot on the menu button and the
// settings entry. See generate.php / generate_one.py.
$cuts = dirname(__DIR__) . '/assets/illustrations/cuts.json';
$chroma = 0;
if (is_readable($cuts)) {
    $j = json_decode((string)file_get_contents($cuts), true);
    if (is_array($j)) {
        foreach ($j as $kind) { if ($kind === 'chroma') $chroma++; }
    }
}

// All four items are in-app overlays. `native: true` tells the FE to
// route via `#admin=<section>` rather than opening a new window. We
// deliberately don't link out to BirdNET-Pi's stock pages - those stay
// reachable at /index.php, and the github link lives in the drawer
// footer next to "built by teddy".
echo json_encode([
    'items' => [
        ['label' => 'settings', 'href' => '/#admin=settings', 'native' => true, 'dot' => $chroma > 0],
        ['label' => 'system',   'href' => '/#admin=system',   'native' => true],
        ['label' => 'logs',     'href' => '/#admin=logs',     'native' => true],
        ['label' => 'tools',    'href' => '/#admin=tools',    'native' => true],
    ],
    'chroma' => $chroma,
    'auth' => [
        'required' => $passwordRequired,
        'lan_policy' => avian_lan_admin_auth_required(),
        'password_configured' => !empty($adminState['valid'])
            && !empty($adminState['configured']),
        'recovery' => empty($adminState['valid']),
    ],
]);
