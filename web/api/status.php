<?php
// =============================================================================
// /var/www/tor-router/api/status.php
// Returns JSON with system status for the dashboard.
// =============================================================================

header('Content-Type: application/json');
header('Cache-Control: no-cache');

// Security: only allow requests from localhost (nginx proxies from LAN)
// The nginx config already enforces LAN-only access.

function service_status(string $name): string {
    exec("systemctl is-active " . escapeshellarg($name) . " 2>/dev/null", $out, $rc);
    return ($rc === 0) ? 'active' : 'inactive';
}

function vpn_status(): array {
    $wg_ifaces = [];
    exec("wg show interfaces 2>/dev/null", $wg_ifaces);
    $openvpn_running = (shell_exec("pgrep -x openvpn 2>/dev/null") !== null);
    return [
        'wireguard_interfaces' => array_filter($wg_ifaces),
        'openvpn' => $openvpn_running ? 'active' : 'inactive',
        'connected' => (!empty($wg_ifaces) || $openvpn_running),
    ];
}

function tor_exit_ip(): string {
    // Query via SOCKS5 proxy with a short timeout
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => 'https://api.ipify.org?format=json',
        CURLOPT_PROXY          => 'socks5h://127.0.0.1:9050',
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
        CURLOPT_CONNECTTIMEOUT => 10,
    ]);
    $res = curl_exec($ch);
    $err = curl_error($ch);
    curl_close($ch);
    if ($res && !$err) {
        $data = json_decode($res, true);
        return $data['ip'] ?? 'unknown';
    }
    return 'unavailable';
}

function cpu_usage(): float {
    // Read two samples of /proc/stat for accurate CPU %
    $stat1 = file('/proc/stat')[0];
    usleep(200000); // 200ms sample
    $stat2 = file('/proc/stat')[0];

    $parse = function(string $line): array {
        $parts = preg_split('/\s+/', trim($line));
        array_shift($parts); // remove "cpu" label
        return array_map('intval', $parts);
    };

    $s1 = $parse($stat1);
    $s2 = $parse($stat2);

    $idle1 = $s1[3] + ($s1[4] ?? 0);
    $idle2 = $s2[3] + ($s2[4] ?? 0);
    $total1 = array_sum($s1);
    $total2 = array_sum($s2);

    $diff_total = $total2 - $total1;
    $diff_idle  = $idle2  - $idle1;

    return $diff_total > 0 ? round((($diff_total - $diff_idle) / $diff_total) * 100, 1) : 0.0;
}

function memory_usage(): array {
    $data = [];
    foreach (file('/proc/meminfo') as $line) {
        [$key, $val] = explode(':', $line, 2);
        $data[trim($key)] = (int) trim($val);
    }
    $total = $data['MemTotal'] ?? 0;
    $avail = $data['MemAvailable'] ?? 0;
    $used  = $total - $avail;
    return [
        'total_mb' => round($total / 1024),
        'used_mb'  => round($used  / 1024),
        'free_mb'  => round($avail / 1024),
        'percent'  => $total > 0 ? round(($used / $total) * 100, 1) : 0,
    ];
}

function network_stats(): array {
    $stats = [];
    $ifaces = ['eth0', 'wlan0', 'eth1', 'eth2', 'eth3'];
    foreach (file('/proc/net/dev') as $line) {
        $line = trim($line);
        if (!str_contains($line, ':')) continue;
        [$iface, $data] = explode(':', $line, 2);
        $iface = trim($iface);
        if (!in_array($iface, $ifaces)) continue;
        $fields = preg_split('/\s+/', trim($data));
        $stats[$iface] = [
            'rx_bytes' => (int)$fields[0],
            'tx_bytes' => (int)$fields[8],
            'rx_mb'    => round((int)$fields[0] / 1048576, 2),
            'tx_mb'    => round((int)$fields[8] / 1048576, 2),
        ];
    }
    return $stats;
}

function pihole_stats(): array {
    // Pi-hole v6 API on port 8080
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => 'http://127.0.0.1:8080/api/stats/summary',
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 5,
    ]);
    $res = curl_exec($ch);
    curl_close($ch);
    if (!$res) return ['available' => false];
    $data = json_decode($res, true) ?? [];
    return [
        'available'          => true,
        'dns_queries_today'  => $data['queries']['total'] ?? $data['dns_queries_today'] ?? 0,
        'ads_blocked_today'  => $data['queries']['blocked'] ?? $data['ads_blocked_today'] ?? 0,
        'ads_percentage'     => $data['queries']['percent_blocked'] ?? $data['ads_percentage_today'] ?? 0,
    ];
}

function wan_state(): string {
    $f = '/run/tor-router/wan_state';
    return file_exists($f) ? trim(file_get_contents($f)) : 'unknown';
}

function vpn_profiles(): array {
    $dir = '/etc/tor-router/vpn';
    if (!is_dir($dir)) return [];
    $files = glob("$dir/*.{conf,ovpn}", GLOB_BRACE) ?: [];
    return array_map('basename', $files);
}

// === Build response ===
$response = [
    'services' => [
        'tor'      => service_status('tor'),
        'dnsmasq'  => service_status('dnsmasq'),
        'nginx'    => service_status('nginx'),
        'pihole'   => service_status('pihole-FTL'),
        'openvpn'  => service_status('openvpn'),
    ],
    'vpn'         => vpn_status(),
    'vpn_profiles'=> vpn_profiles(),
    'tor_exit_ip' => tor_exit_ip(),
    'cpu_percent' => cpu_usage(),
    'memory'      => memory_usage(),
    'network'     => network_stats(),
    'pihole'      => pihole_stats(),
    'wan_state'   => wan_state(),
    'timestamp'   => time(),
];

echo json_encode($response, JSON_PRETTY_PRINT);
