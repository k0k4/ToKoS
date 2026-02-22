#!/bin/bash
# =============================================================================
# /usr/local/bin/tor-router
# Tor Security Router — Unified CLI
#
# Usage:
#   tor-router start          Start all services + apply firewall
#   tor-router stop           Stop all services + flush firewall
#   tor-router restart        Restart all services
#   tor-router status         Show status of all components
#   tor-router new-circuit    Request a new Tor exit IP
#   tor-router firewall       Reload iptables rules
#   tor-router logs [svc]     Tail logs (svc: tor|dnsmasq|nginx|wan|all)
#   tor-router vpn connect <profile>
#   tor-router vpn disconnect
# =============================================================================

set -uo pipefail

SCRIPTS_D="/usr/local/bin/tor-router.d"
LOG="/var/log/tor-router.log"

# Detect PHP-FPM service name dynamically
PHP_VER="8.4"
[[ -f /etc/tor-router/php_version ]] && PHP_VER=$(cat /etc/tor-router/php_version)
PHP_FPM="php${PHP_VER}-fpm"

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

_log() { echo -e "$(date '+%F %T') $*" | tee -a "$LOG"; }
ok()   { echo -e " ${G}✔${N}  $*"; }
fail() { echo -e " ${R}✘${N}  $*"; }
info() { echo -e " ${C}»${N}  $*"; }
warn() { echo -e " ${Y}!${N}  $*"; }
hdr()  { echo -e "\n${W}$*${N}"; }

# ── Services managed by tor-router ───────────────────────────────────────────
SERVICES=(dnscrypt-proxy pihole-FTL tor@default dnsmasq nginx $PHP_FPM wan-failover)

svc_status() {
    local s="$1"
    systemctl is-active --quiet "$s" 2>/dev/null && echo "active" || echo "inactive"
}

svc_start() {
    local s="$1"
    systemctl start "$s" 2>/dev/null && ok "$s started" || fail "Failed to start $s"
}

svc_stop() {
    local s="$1"
    systemctl stop "$s" 2>/dev/null && ok "$s stopped" || warn "$s was not running"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_start() {
    hdr "Starting Tor Security Router..."
    _log "[start] tor-router starting"

    # Ensure LAN interfaces have their static IPs
    info "Setting up LAN interfaces..."
    ip addr add 192.168.10.1/24 dev eth1 2>/dev/null || true
    ip addr add 192.168.20.1/24 dev eth2 2>/dev/null || true
    ip addr add 192.168.30.1/24 dev eth3 2>/dev/null || true
    ip link set eth1 up 2>/dev/null || true
    ip link set eth2 up 2>/dev/null || true
    ip link set eth3 up 2>/dev/null || true

    info "Applying firewall rules..."
    /usr/local/bin/firewall.sh && ok "Firewall applied" || { fail "Firewall failed"; exit 1; }

    for svc in "${SERVICES[@]}"; do
        svc_start "$svc"
    done

    # Give Tor a moment then print the exit IP
    info "Waiting for Tor bootstrap..."
    local waited=0
    while [[ $waited -lt 45 ]]; do
        sleep 3; waited=$((waited+3))
        if journalctl -u tor@default --since "1 minute ago" -n 30 --no-pager 2>/dev/null \
               | grep -q 'Bootstrapped 100%'; then
            ok "Tor bootstrapped"
            break
        fi
    done
    [[ $waited -ge 45 ]] && warn "Tor may still be bootstrapping (check: tor-router status)"

    _log "[start] tor-router started"
    echo ""
    cmd_status
}

cmd_stop() {
    hdr "Stopping Tor Security Router..."
    _log "[stop] tor-router stopping"

    for svc in "${SERVICES[@]}"; do
        svc_stop "$svc"
    done

    info "Flushing firewall rules..."
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    ok "Firewall flushed"

    _log "[stop] tor-router stopped"
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

cmd_status() {
    hdr "═══ Tor Security Router ═══"

    # ── Services ──
    printf "\n  %-20s %s\n" "SERVICE" "STATUS"
    printf "  %-20s %s\n" "──────────────────" "──────"
    for svc in dnscrypt-proxy pihole-FTL tor@default dnsmasq nginx $PHP_FPM wan-failover; do
        st=$(svc_status "$svc")
        if [[ "$st" == "active" ]]; then
            printf "  ${G}●${N} %-19s ${G}%s${N}\n" "$svc" "active"
        else
            printf "  ${R}●${N} %-19s ${R}%s${N}\n" "$svc" "inactive"
        fi
    done

    # ── WAN State ──
    echo ""
    local wan_state="unknown"
    [[ -f /run/tor-router/wan_state ]] && wan_state=$(cat /run/tor-router/wan_state)
    printf "  %-20s " "WAN state:"
    case "$wan_state" in
        normal)   echo -e "${G}normal${N} (eth0 primary, wlan0 standby)" ;;
        failover) echo -e "${Y}failover${N} (eth0 down → using wlan0)" ;;
        nowan)    echo -e "${R}NO WAN${N} — both links down!" ;;
        manual)   echo -e "${C}manual override${N}" ;;
        *)        echo -e "${Y}unknown${N}" ;;
    esac

    # ── Tor exit IP ──
    echo ""
    printf "  %-20s " "Tor exit IP:"
    local exit_ip
    exit_ip=$(curl -s --socks5-hostname 127.0.0.1:9050 --max-time 10 \
              https://api.ipify.org 2>/dev/null || echo "unavailable")
    if [[ "$exit_ip" == "unavailable" ]]; then
        echo -e "${R}$exit_ip${N}"
    else
        echo -e "${G}$exit_ip${N}"
    fi

    # ── VPN ──
    echo ""
    local wg_ifaces openvpn_running
    wg_ifaces=$(wg show interfaces 2>/dev/null | tr '\n' ' ')
    openvpn_running=$(pgrep -x openvpn > /dev/null 2>&1 && echo "yes" || echo "no")
    printf "  %-20s " "VPN (WireGuard):"
    [[ -n "$wg_ifaces" ]] && echo -e "${G}${wg_ifaces}${N}" || echo -e "${Y}not connected${N}"
    printf "  %-20s " "VPN (OpenVPN):"
    [[ "$openvpn_running" == "yes" ]] && echo -e "${G}running${N}" || echo -e "${Y}not connected${N}"

    # ── Interfaces ──
    echo ""
    printf "\n  %-10s %-22s %s\n" "IFACE" "IP" "ROLE"
    printf "  %-10s %-22s %s\n" "─────────" "──────────────────────" "──────────────"
    declare -A ROLES=(
        [eth0]="WAN 1 (primary)"
        [wlan0]="WAN 2 (failover)"
        [eth1]="LAN Standard (Pi-hole)"
        [eth2]="LAN Tor 1 (anonymous)"
        [eth3]="LAN Tor 2 (anonymous)"
    )
    for iface in eth0 wlan0 eth1 eth2 eth3; do
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        ip_addr="${ip_addr:-(no IP)}"
        printf "  %-10s %-22s %s\n" "$iface" "$ip_addr" "${ROLES[$iface]:-}"
    done

    # ── Resources ──
    echo ""
    local cpu_idle cpu_use mem_total mem_avail mem_use mem_pct
    cpu_use=$(top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{print $2}' | cut -d'%' -f1 || echo "?")
    mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    mem_use=$(( (mem_total - mem_avail) / 1024 ))
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    printf "\n  CPU: ${W}%s%%${N}   Memory: ${W}%s MB used${N} (%s%%)\n" \
        "${cpu_use:-?}" "$mem_use" "$mem_pct"

    echo ""
}

cmd_new_circuit() {
    info "Requesting new Tor circuit..."
    "$SCRIPTS_D/new_tor_circuit.sh" && ok "New circuit requested. Exit IP will change shortly." \
                                  || fail "Failed to request new circuit."
}

cmd_firewall() {
    info "Reloading firewall..."
    /usr/local/bin/firewall.sh && ok "Firewall reloaded." || fail "Firewall reload failed."
}

cmd_logs() {
    local target="${1:-all}"
    case "$target" in
        tor)      journalctl -u tor@default -f ;;
        dnsmasq)  journalctl -u dnsmasq -f ;;
        nginx)    journalctl -u nginx -f ;;
        wan)      journalctl -u wan-failover -f ;;
        pihole)   journalctl -u pihole-FTL -f ;;
        all)      journalctl -u tor@default -u dnsmasq -u nginx -u wan-failover -f ;;
        *)        journalctl -u "$target" -f ;;
    esac
}

cmd_vpn() {
    local sub="${1:-}"
    case "$sub" in
        connect)
            local profile="${2:-}"
            [[ -z "$profile" ]] && { fail "Usage: tor-router vpn connect <profile>"; exit 1; }
            "$SCRIPTS_D/connect_vpn.sh" "$profile" && ok "VPN connected: $profile" || fail "VPN connect failed."
            ;;
        disconnect)
            "$SCRIPTS_D/disconnect_vpn.sh" && ok "VPN disconnected." || fail "VPN disconnect failed."
            ;;
        list)
            hdr "VPN Profiles:"
            ls /etc/tor-router/vpn/ 2>/dev/null || warn "No profiles found in /etc/tor-router/vpn/"
            ;;
        *)
            fail "Usage: tor-router vpn connect <profile> | disconnect | list"
            exit 1
            ;;
    esac
}

usage() {
    echo -e "${W}Tor Security Router${N} — control utility\n"
    echo -e "  ${C}tor-router start${N}               Start all services + firewall"
    echo -e "  ${C}tor-router stop${N}                Stop all services + flush firewall"
    echo -e "  ${C}tor-router restart${N}             Restart all services"
    echo -e "  ${C}tor-router status${N}              Show full status"
    echo -e "  ${C}tor-router new-circuit${N}         Request new Tor exit IP"
    echo -e "  ${C}tor-router firewall${N}            Reload iptables rules"
    echo -e "  ${C}tor-router logs [svc]${N}          Tail logs (tor|dnsmasq|nginx|wan|all)"
    echo -e "  ${C}tor-router vpn connect <name>${N}  Connect VPN profile"
    echo -e "  ${C}tor-router vpn disconnect${N}      Disconnect VPN"
    echo -e "  ${C}tor-router vpn list${N}            List available profiles"
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

case "${1:-}" in
    start)        cmd_start ;;
    stop)         cmd_stop ;;
    restart)      cmd_restart ;;
    status)       cmd_status ;;
    new-circuit)  cmd_new_circuit ;;
    firewall)     cmd_firewall ;;
    logs)         cmd_logs "${2:-all}" ;;
    vpn)          cmd_vpn "${2:-}" "${3:-}" ;;
    ""|help|--help|-h) usage ;;
    *)            fail "Unknown command: $1"; usage; exit 1 ;;
esac
