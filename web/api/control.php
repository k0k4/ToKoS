<?php
// =============================================================================
// /var/www/tor-router/api/control.php
// Executes control actions requested by the dashboard.
// =============================================================================

header('Content-Type: application/json');

$SCRIPTS = '/usr/local/bin/tor-router.d';

function json_response(bool $ok, string $message, array $extra = []): void {
    echo json_encode(array_merge(['ok' => $ok, 'message' => $message], $extra));
    exit;
}

// Only accept POST
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    json_response(false, 'Method not allowed');
}

$body   = json_decode(file_get_contents('php://input'), true) ?? [];
$action = $body['action'] ?? '';

switch ($action) {

    // ---- Tor: new circuit / restart ----
    case 'tor_new_circuit':
        exec("sudo $SCRIPTS/new_tor_circuit.sh 2>&1", $out, $rc);
        json_response($rc === 0, implode("\n", $out));
        break;

    case 'tor_restart':
        exec("sudo /usr/bin/systemctl restart tor 2>&1", $out, $rc);
        json_response($rc === 0, $rc === 0 ? 'Tor restarted.' : implode("\n", $out));
        break;

    // ---- VPN: connect / disconnect ----
    case 'vpn_connect':
        $profile = basename($body['profile'] ?? '');
        if (empty($profile)) {
            json_response(false, 'No profile specified.');
        }
        exec("sudo $SCRIPTS/connect_vpn.sh " . escapeshellarg($profile) . " 2>&1", $out, $rc);
        json_response($rc === 0, implode("\n", $out));
        break;

    case 'vpn_disconnect':
        exec("sudo $SCRIPTS/disconnect_vpn.sh 2>&1", $out, $rc);
        json_response($rc === 0, $rc === 0 ? 'VPN disconnected.' : implode("\n", $out));
        break;

    // ---- VPN: upload profile ----
    case 'vpn_upload':
        $vpn_dir = '/etc/tor-router/vpn';
        if (!isset($_FILES['file'])) {
            json_response(false, 'No file uploaded.');
        }
        $fname = basename($_FILES['file']['name']);
        // Only allow .conf and .ovpn
        if (!preg_match('/\.(conf|ovpn)$/', $fname)) {
            json_response(false, 'Only .conf and .ovpn files allowed.');
        }
        $dest = "$vpn_dir/$fname";
        if (move_uploaded_file($_FILES['file']['tmp_name'], $dest)) {
            chmod($dest, 0600);
            json_response(true, "Profile '$fname' uploaded.");
        } else {
            json_response(false, 'Upload failed.');
        }
        break;

    // ---- WAN: set primary ----
    case 'wan_set_primary':
        $iface = $body['interface'] ?? 'eth0';
        if (!in_array($iface, ['eth0', 'wlan0'])) {
            json_response(false, 'Invalid interface.');
        }
        exec("sudo $SCRIPTS/wan_manager.sh set-primary " . escapeshellarg($iface) . " 2>&1", $out, $rc);
        json_response($rc === 0, implode("\n", $out));
        break;

    // ---- Firewall: reload ----
    case 'firewall_reload':
        exec("sudo /usr/local/bin/firewall.sh 2>&1", $out, $rc);
        json_response($rc === 0, $rc === 0 ? 'Firewall reloaded.' : implode("\n", $out));
        break;

    default:
        http_response_code(400);
        json_response(false, "Unknown action: $action");
}
