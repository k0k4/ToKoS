#!/bin/bash
# =============================================================================
# /usr/local/bin/tor-router/disconnect_vpn.sh
# Disconnect all active VPN connections (OpenVPN and WireGuard).
# =============================================================================

set -euo pipefail

# Disconnect all WireGuard interfaces
for iface in $(wg show interfaces 2>/dev/null); do
    echo "Bringing down WireGuard interface: $iface"
    wg-quick down "$iface" 2>/dev/null || true
done

# Stop all OpenVPN daemon instances
if pgrep -x openvpn > /dev/null 2>&1; then
    pkill -TERM openvpn 2>/dev/null || true
    sleep 2
    pgrep -x openvpn > /dev/null 2>&1 && pkill -KILL openvpn 2>/dev/null || true
    echo "OpenVPN disconnected."
else
    echo "No OpenVPN instances running."
fi

echo "VPN disconnected."
