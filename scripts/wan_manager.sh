#!/bin/bash
# =============================================================================
# /usr/local/bin/tor-router/wan_manager.sh
# WAN Failover / Load-Balance Manager
# Monitors WAN links and adjusts routing table accordingly.
# Runs as a daemon via systemd wan-failover.service
#
# Strategy:
#   - eth0  = primary WAN   (metric 100)
#   - wlan0 = secondary WAN (metric 200)
#   - Probe: ping a reliable host via each WAN interface.
#   - If primary fails -> promote secondary to metric 100.
#   - If primary recovers -> restore original metrics.
#
# Usage:
#   wan_manager.sh [start|status|set-primary <eth0|wlan0>]
# =============================================================================

set -uo pipefail

PROBE_HOST="8.8.8.8"
PROBE_COUNT=3
PROBE_TIMEOUT=5
CHECK_INTERVAL=15   # seconds between checks
STATE_FILE="/run/tor-router/wan_state"

log() { logger -t wan-manager "$*"; echo "$*"; }

mkdir -p /run/tor-router

check_link() {
    local iface="$1"
    # Check interface is up and has an IP
    ip link show "$iface" 2>/dev/null | grep -q "UP" || return 1
    ip addr show "$iface" 2>/dev/null | grep -q "inet " || return 1
    # Try to ping via this interface
    ping -I "$iface" -c "$PROBE_COUNT" -W "$PROBE_TIMEOUT" -q "$PROBE_HOST" \
        > /dev/null 2>&1
}

set_route_metric() {
    local iface="$1"
    local metric="$2"
    local gw
    gw=$(ip route show dev "$iface" default 2>/dev/null | awk '/default/{print $3}' | head -1)
    [[ -z "$gw" ]] && {
        # Try to get GW from DHCP lease
        gw=$(ip route show dev "$iface" 2>/dev/null | awk '/default/{print $3}' | head -1)
    }
    [[ -z "$gw" ]] && return 0
    ip route del default via "$gw" dev "$iface" 2>/dev/null || true
    ip route add default via "$gw" dev "$iface" metric "$metric" 2>/dev/null || true
    log "Set $iface metric=$metric via $gw"
}

read_state() { cat "$STATE_FILE" 2>/dev/null || echo "normal"; }
write_state() { echo "$1" > "$STATE_FILE"; }

monitor_loop() {
    log "WAN monitor starting. Primary=eth0 (metric 100), Secondary=wlan0 (metric 200)"
    while true; do
        ETH0_OK=0; WLAN0_OK=0
        check_link eth0  && ETH0_OK=1
        check_link wlan0 && WLAN0_OK=1

        CURRENT=$(read_state)

        if [[ $ETH0_OK -eq 1 ]]; then
            if [[ "$CURRENT" != "normal" ]]; then
                log "eth0 recovered. Restoring primary routing."
                set_route_metric eth0  100
                set_route_metric wlan0 200
                write_state "normal"
            fi
        elif [[ $WLAN0_OK -eq 1 ]]; then
            if [[ "$CURRENT" != "failover" ]]; then
                log "eth0 down. Failing over to wlan0."
                set_route_metric wlan0 100
                set_route_metric eth0  200
                write_state "failover"
            fi
        else
            [[ "$CURRENT" != "nowan" ]] && log "WARNING: Both WAN links are DOWN."
            write_state "nowan"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

status_cmd() {
    echo "=== WAN Status ==="
    for iface in eth0 wlan0; do
        if check_link "$iface"; then
            echo "  $iface: UP"
        else
            echo "  $iface: DOWN"
        fi
    done
    echo "  Active state: $(read_state)"
    echo ""
    echo "=== Routing Table ==="
    ip route show | grep default
}

set_primary_cmd() {
    local primary="${1:-eth0}"
    local secondary
    [[ "$primary" == "eth0" ]] && secondary="wlan0" || secondary="eth0"
    set_route_metric "$primary"  100
    set_route_metric "$secondary" 200
    write_state "manual"
    log "Manual override: primary=$primary secondary=$secondary"
}

case "${1:-start}" in
    start)   monitor_loop ;;
    status)  status_cmd ;;
    set-primary) set_primary_cmd "${2:-eth0}" ;;
    *) echo "Usage: $0 [start|status|set-primary <eth0|wlan0>]"; exit 1 ;;
esac
