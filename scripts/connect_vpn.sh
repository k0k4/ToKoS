#!/bin/bash
# =============================================================================
# /usr/local/bin/tor-router/connect_vpn.sh
# Connect to a VPN profile (OpenVPN or WireGuard).
# Usage: connect_vpn.sh <profile_name>
#   profile_name: filename without extension in /etc/tor-router/vpn/
#                 e.g. "myvpn" -> /etc/tor-router/vpn/myvpn.conf (OpenVPN)
#                              or /etc/tor-router/vpn/myvpn.conf (WireGuard)
# =============================================================================

set -euo pipefail

VPN_DIR="/etc/tor-router/vpn"
PROFILE="${1:-}"

[[ -z "$PROFILE" ]] && { echo "Usage: $0 <profile_name>" >&2; exit 1; }

# Sanitize profile name (no path traversal)
PROFILE=$(basename "$PROFILE")

CONF_FILE="$VPN_DIR/$PROFILE"

[[ -f "$CONF_FILE" ]] || { echo "ERROR: Profile not found: $CONF_FILE" >&2; exit 1; }

# Detect type by extension
case "$CONF_FILE" in
    *.conf)
        # Could be WireGuard or OpenVPN - detect by content
        if grep -q '^\[Interface\]' "$CONF_FILE" 2>/dev/null; then
            # WireGuard
            IFACE_NAME=$(basename "$CONF_FILE" .conf)
            wg-quick up "$CONF_FILE"
            echo "WireGuard VPN connected: $IFACE_NAME"
        else
            # OpenVPN
            # Kill any existing openvpn instances for this profile
            pkill -f "openvpn.*$PROFILE" 2>/dev/null || true
            sleep 1
            openvpn --config "$CONF_FILE" --daemon --log /var/log/openvpn-"$PROFILE".log
            echo "OpenVPN connected: $PROFILE (daemon mode)"
        fi
        ;;
    *.ovpn)
        pkill -f "openvpn.*$PROFILE" 2>/dev/null || true
        sleep 1
        openvpn --config "$CONF_FILE" --daemon --log /var/log/openvpn-"$PROFILE".log
        echo "OpenVPN connected: $PROFILE"
        ;;
    *)
        echo "ERROR: Unknown profile format: $CONF_FILE" >&2
        exit 1
        ;;
esac
