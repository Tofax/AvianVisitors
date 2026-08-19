<?php
// AvianVisitors - drawer menu items.
//
// Returns the list of links shown in the side drawer when a user clicks
// the menu button. The live JS expects {items: [{label, href, native}]}.
//
// Direct requests on the station's private address are available without a
// password. Forwarded and public-host requests verify BirdNET-Pi's configured
// admin password here, then use a password-bound HttpOnly session.

declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

require_once __DIR__ . '/admin-auth.php';
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
]);
