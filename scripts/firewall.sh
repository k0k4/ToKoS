#!/bin/bash
# =============================================================================
# /usr/local/bin/firewall.sh
# Tor Security Router - iptables Ruleset
# Run as root. Called on boot and from web UI.
# =============================================================================

set -euo pipefail

# --- Tor transparent proxy ports ---
TOR_TRANS_PORT=9040
TOR_DNS_PORT=9053
TOR_USER="debian-tor"          # User Tor runs as (adjust if different)

# --- Network ranges ---
LAN_STD="192.168.10.0/24"      # eth1 - Standard LAN
LAN_TOR1="192.168.20.0/24"     # eth2 - Tor LAN 1
LAN_TOR2="192.168.30.0/24"     # eth3 - Tor LAN 2

GW_TOR1="192.168.20.1"
GW_TOR2="192.168.30.1"

echo "[firewall] Flushing existing rules..."

# ============================================================
# FLUSH all tables
# ============================================================
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# ============================================================
# DEFAULT POLICIES: drop everything, whitelist what we need
# ============================================================
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT   # Router itself can reach internet

# ============================================================
# INPUT CHAIN (traffic destined for the router itself)
# ============================================================

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DHCP (from LAN interfaces only)
iptables -A INPUT -i eth1 -p udp --dport 67 -j ACCEPT
iptables -A INPUT -i eth2 -p udp --dport 67 -j ACCEPT
iptables -A INPUT -i eth3 -p udp --dport 67 -j ACCEPT

# Allow DNS from all LAN clients
iptables -A INPUT -i eth1 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i eth1 -p tcp --dport 53 -j ACCEPT
# eth2/eth3 DNS is handled by iptables REDIRECT to Tor

# Allow Tor transparent proxy ports (from Tor LANs only)
iptables -A INPUT -i eth2 -p tcp --dport "$TOR_TRANS_PORT" -j ACCEPT
iptables -A INPUT -i eth3 -p tcp --dport "$TOR_TRANS_PORT" -j ACCEPT
iptables -A INPUT -i eth2 -p udp --dport "$TOR_DNS_PORT" -j ACCEPT
iptables -A INPUT -i eth3 -p udp --dport "$TOR_DNS_PORT" -j ACCEPT

# Allow web dashboard from Standard LAN only
iptables -A INPUT -i eth1 -p tcp --dport 80 -j ACCEPT

# Allow SSH from Standard LAN only (adjust port if needed)
iptables -A INPUT -i eth1 -p tcp --dport 22 -j ACCEPT

# Drop everything else to router
iptables -A INPUT -j DROP

# ============================================================
# FORWARD CHAIN
# ============================================================

# Allow established/related
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --- Standard LAN (eth1) -> WAN ---
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth1 -o wlan0 -j ACCEPT

# --- Tor LANs: block direct internet forwarding ---
# Traffic from Tor LANs must go through Tor (via REDIRECT below), not directly.
iptables -A FORWARD -i eth2 -j DROP
iptables -A FORWARD -i eth3 -j DROP

# --- Client Isolation: block intra-LAN traffic on Tor networks ---
# (Devices on the same Tor LAN cannot talk to each other)
iptables -A FORWARD -s "$LAN_TOR1" -d "$LAN_TOR1" -j DROP
iptables -A FORWARD -s "$LAN_TOR2" -d "$LAN_TOR2" -j DROP

# Also block cross-LAN communication between Tor segments
iptables -A FORWARD -s "$LAN_TOR1" -d "$LAN_TOR2" -j DROP
iptables -A FORWARD -s "$LAN_TOR2" -d "$LAN_TOR1" -j DROP

# Block Tor LANs from reaching Standard LAN
iptables -A FORWARD -s "$LAN_TOR1" -d "$LAN_STD" -j DROP
iptables -A FORWARD -s "$LAN_TOR2" -d "$LAN_STD" -j DROP

# ============================================================
# NAT TABLE - PREROUTING (Redirect before routing)
# ============================================================

# --- Tor LAN 1 (eth2) transparent DNS redirect ---
iptables -t nat -A PREROUTING -i eth2 -p udp --dport 53 \
    -j DNAT --to-destination "$GW_TOR1:$TOR_DNS_PORT"
iptables -t nat -A PREROUTING -i eth2 -p tcp --dport 53 \
    -j DNAT --to-destination "$GW_TOR1:$TOR_DNS_PORT"

# --- Tor LAN 2 (eth3) transparent DNS redirect ---
iptables -t nat -A PREROUTING -i eth3 -p udp --dport 53 \
    -j DNAT --to-destination "$GW_TOR2:$TOR_DNS_PORT"
iptables -t nat -A PREROUTING -i eth3 -p tcp --dport 53 \
    -j DNAT --to-destination "$GW_TOR2:$TOR_DNS_PORT"

# --- Tor LAN 1 (eth2) transparent TCP redirect ---
# Don't redirect traffic from Tor itself (avoids loops)
iptables -t nat -A PREROUTING -i eth2 -p tcp \
    ! -d "$GW_TOR1" \
    --syn \
    -j REDIRECT --to-ports "$TOR_TRANS_PORT"

# --- Tor LAN 2 (eth3) transparent TCP redirect ---
iptables -t nat -A PREROUTING -i eth3 -p tcp \
    ! -d "$GW_TOR2" \
    --syn \
    -j REDIRECT --to-ports "$TOR_TRANS_PORT"

# ============================================================
# NAT TABLE - POSTROUTING (Masquerade for Standard LAN)
# ============================================================

# NAT for Standard LAN outbound via WAN interfaces
iptables -t nat -A POSTROUTING -s "$LAN_STD" -o eth0  -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$LAN_STD" -o wlan0 -j MASQUERADE

# ============================================================
# OUTPUT CHAIN - Prevent Tor user traffic from leaking
# ============================================================
# Allow Tor process to connect to the internet (for circuits)
iptables -A OUTPUT -m owner --uid-owner "$TOR_USER" -j ACCEPT
# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
# Allow established outbound from router
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Allow router's own DNS, NTP, etc.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -p udp --dport 123 -j ACCEPT   # NTP
iptables -A OUTPUT -p tcp --dport 80  -j ACCEPT   # HTTP  (apt, updates)
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT   # HTTPS (apt, updates)
# All other OUTPUT allowed (policy ACCEPT above) - tighten if desired

echo "[firewall] Rules applied successfully."
