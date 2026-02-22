#!/bin/bash
# =============================================================================
# Tor Security Router — Automated Installer
# Target: Kali Linux, Quad-core, 8GB RAM, 120GB SSD
# Interfaces: eth0 (WAN1), wlan0 (WAN2), eth1 (LAN), eth2 (Tor1), eth3 (Tor2)
#
# After installation, manage with:
#   tor-router start | stop | status | restart
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/tor-router-install.log"
WEB_ROOT="/var/www/tor-router"
SCRIPTS_D="/usr/local/bin/tor-router.d"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
log()   { echo -e "${G}[+]${N} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${Y}[!]${N} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${R}[✗]${N} $*" | tee -a "$LOG_FILE"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || error "Run as root: sudo $0"; }

# ── Phase 1: Packages ──────────────────────────────────────────────────────────
phase1_packages() {
    log "Phase 1: Installing packages..."
    apt update -qq
    apt upgrade -y -qq
    # Detect PHP version available on this system
    PHP_VER=$(apt-cache search 'php[0-9].*-fpm' | head -1 | grep -oP 'php\K[0-9]+\.[0-9]+' || echo "8.4")
    log "Detected PHP version: $PHP_VER"

    # iptables-persistent will ask to save rules — pre-answer "yes"
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

    DEBIAN_FRONTEND=noninteractive apt install -y \
        tor \
        dnsmasq \
        iptables \
        iptables-persistent \
        netfilter-persistent \
        nginx \
        "php${PHP_VER}-fpm" \
        "php${PHP_VER}-curl" \
        openvpn \
        wireguard-tools \
        curl \
        jq \
        net-tools \
        procps \
        vnstat \
        netcat-openbsd \
        xxd

    # Export PHP_VER so later phases can use it
    export PHP_VER
    systemctl enable --now vnstat 2>/dev/null || true
    log "Packages installed."
}

# ── Phase 2: Network interfaces ───────────────────────────────────────────────
phase2_network() {
    log "Phase 2: Configuring network interfaces..."
    cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s) 2>/dev/null || true
    install -m 644 "$SCRIPT_DIR/config/interfaces" /etc/network/interfaces

    # Assign static IPs immediately (interfaces file takes effect on reboot)
    ip addr add 192.168.10.1/24 dev eth1 2>/dev/null || true
    ip addr add 192.168.20.1/24 dev eth2 2>/dev/null || true
    ip addr add 192.168.30.1/24 dev eth3 2>/dev/null || true
    ip link set eth1 up 2>/dev/null || true
    ip link set eth2 up 2>/dev/null || true
    ip link set eth3 up 2>/dev/null || true

    # Create sysctl.conf if missing, then configure
    touch /etc/sysctl.conf

    # IP forwarding
    sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf \
        || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

    # IPv6 leak prevention
    for key in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6; do
        grep -q "^$key" /etc/sysctl.conf || echo "$key=1" >> /etc/sysctl.conf
    done

    # Also write to sysctl.d for systems that don't read sysctl.conf
    cat > /etc/sysctl.d/99-tor-router.conf <<'SYSEOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
SYSEOF

    sysctl --system > /dev/null 2>&1
    log "Network interfaces configured."
}

# ── Phase 3: dnsmasq ──────────────────────────────────────────────────────────
phase3_dnsmasq() {
    log "Phase 3: Configuring dnsmasq..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true

    mkdir -p /etc/NetworkManager/conf.d
    echo -e "[main]\ndns=none" > /etc/NetworkManager/conf.d/no-dns.conf

    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null || true
    install -m 644 "$SCRIPT_DIR/config/dnsmasq.conf" /etc/dnsmasq.conf

    # During install, use public DNS as upstream (cloudflared not yet available)
    sed -i 's|^server=192.168.10.1#5335|server=1.1.1.1\nserver=1.0.0.1|' /etc/dnsmasq.conf
    # Disable DNSSEC during install (re-enabled when cloudflared is set up)
    sed -i 's/^dnssec/#dnssec/' /etc/dnsmasq.conf

    mkdir -p /var/lib/misc
    systemctl enable dnsmasq
    systemctl restart dnsmasq || true

    # Point system resolver to dnsmasq now that it's running
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true

    log "dnsmasq configured and running."
}

# ── Phase 4: Tor ──────────────────────────────────────────────────────────────
phase4_tor() {
    log "Phase 4: Configuring Tor..."
    cp /etc/tor/torrc /etc/tor/torrc.bak 2>/dev/null || true
    install -m 644 "$SCRIPT_DIR/config/torrc" /etc/tor/torrc

    # Add www-data to debian-tor group so the web UI can read the auth cookie
    usermod -aG debian-tor www-data 2>/dev/null || true

    systemctl enable tor
    log "Tor configured."
}

# ── Phase 5: Firewall ─────────────────────────────────────────────────────────
phase5_firewall() {
    log "Phase 5: Installing firewall script..."
    install -m 750 "$SCRIPT_DIR/scripts/firewall.sh" /usr/local/bin/firewall.sh
    log "Firewall script installed (applied on 'tor-router start')."
}

# ── Phase 6: Helper scripts ───────────────────────────────────────────────────
phase6_scripts() {
    log "Phase 6: Installing helper scripts..."
    mkdir -p "$SCRIPTS_D"

    # Install all scripts except firewall.sh (already at /usr/local/bin/)
    for f in "$SCRIPT_DIR"/scripts/*.sh; do
        [[ "$(basename "$f")" == "firewall.sh" ]] && continue
        dst="$SCRIPTS_D/$(basename "$f")"
        install -m 750 "$f" "$dst"
    done

    # Install the main CLI as /usr/local/bin/tor-router
    install -m 755 "$SCRIPT_DIR/scripts/tor-router-cli.sh" /usr/local/bin/tor-router

    # Sudoers for web backend
    cat > /etc/sudoers.d/tor-router <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/firewall.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/tor-router.d/connect_vpn.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/tor-router.d/disconnect_vpn.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/tor-router.d/new_tor_circuit.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/tor-router.d/wan_manager.sh
www-data ALL=(root) NOPASSWD: /usr/bin/systemctl restart tor
www-data ALL=(root) NOPASSWD: /usr/bin/systemctl start tor
www-data ALL=(root) NOPASSWD: /usr/bin/systemctl stop tor
www-data ALL=(root) NOPASSWD: /usr/bin/systemctl restart dnsmasq
EOF
    chmod 440 /etc/sudoers.d/tor-router
    log "Helper scripts installed."
}

# ── Phase 7: Pi-hole (unattended) ─────────────────────────────────────────────
phase7_pihole() {
    log "Phase 7: Installing Pi-hole (unattended)..."

    if command -v pihole &>/dev/null; then
        warn "Pi-hole already installed, skipping."
        return
    fi

    # Pre-seed Pi-hole configuration
    mkdir -p /etc/pihole
    cat > /etc/pihole/setupVars.conf <<'EOF'
PIHOLE_INTERFACE=eth1
IPV4_ADDRESS=192.168.10.1/24
IPV6_ADDRESS=
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=false
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=false
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=single
BLOCKING_ENABLED=true
WEBTHEME=default-dark
EOF

    # Run unattended installer
    curl -fsSL https://install.pi-hole.net -o /tmp/pihole_install.sh
    bash /tmp/pihole_install.sh --unattended
    rm -f /tmp/pihole_install.sh

    # Set web password (change after install)
    pihole setpassword "TorRouter" 2>/dev/null || pihole -a -p "TorRouter" 2>/dev/null || true
    warn "Pi-hole web password: TorRouter  ← change with: pihole setpassword <newpassword>"

    log "Pi-hole installed."
}

# ── Phase 8: DNS-over-HTTPS (dnscrypt-proxy) ──────────────────────────────────
phase8_doh() {
    log "Phase 8: Installing dnscrypt-proxy (DNS-over-HTTPS)..."
    "$SCRIPTS_D/configure_pihole.sh"

    # Restore dnsmasq upstream to Pi-hole (was using public DNS during install)
    install -m 644 "$SCRIPT_DIR/config/dnsmasq.conf" /etc/dnsmasq.conf
    systemctl restart dnsmasq

    log "DoH configured. DNS chain: dnsmasq → Pi-hole(5335) → dnscrypt(5053) → Cloudflare DoH"
}

# ── Phase 9: Web interface ────────────────────────────────────────────────────
phase9_web() {
    log "Phase 9: Setting up web interface..."
    PHP_VER="${PHP_VER:-8.4}"
    PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"

    mkdir -p "$WEB_ROOT" /etc/tor-router/vpn
    cp -r "$SCRIPT_DIR/web/"* "$WEB_ROOT/"
    chown -R www-data:www-data "$WEB_ROOT" /etc/tor-router
    chmod -R 755 "$WEB_ROOT"

    # Generate nginx config with correct PHP socket path
    sed "s|php8\.[0-9]-fpm\.sock|php${PHP_VER}-fpm.sock|g" \
        "$SCRIPT_DIR/config/nginx.conf" > /etc/nginx/sites-available/tor-router
    ln -sf /etc/nginx/sites-available/tor-router /etc/nginx/sites-enabled/tor-router
    rm -f /etc/nginx/sites-enabled/default

    # Write detected PHP version for CLI to use
    echo "$PHP_VER" > /etc/tor-router/php_version

    systemctl enable "php${PHP_VER}-fpm" nginx
    log "Web interface configured (http://192.168.10.1)."
}

# ── Phase 10: WAN failover service ────────────────────────────────────────────
phase10_failover() {
    log "Phase 10: Configuring WAN failover service..."
    install -m 644 "$SCRIPT_DIR/config/wan-failover.service" \
        /etc/systemd/system/wan-failover.service
    systemctl daemon-reload
    systemctl enable wan-failover
    log "WAN failover service registered."
}

# ── Phase 11: tor-router systemd service ──────────────────────────────────────
phase11_service() {
    log "Phase 11: Registering tor-router systemd service..."
    install -m 644 "$SCRIPT_DIR/config/tor-router.service" \
        /etc/systemd/system/tor-router.service
    systemctl daemon-reload
    systemctl enable tor-router

    # Disable individual services from auto-starting on boot
    # tor-router.service orchestrates all of them
    systemctl disable tor@default dnsmasq nginx "php${PHP_VER:-8.4}-fpm" \
        dnscrypt-proxy pihole-FTL wan-failover 2>/dev/null || true

    log "tor-router.service registered."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    require_root
    mkdir -p "$(dirname "$LOG_FILE")"

    echo -e "\n${G}╔══════════════════════════════════════╗${N}"
    echo -e "${G}║   Tor Security Router — Installer    ║${N}"
    echo -e "${G}╚══════════════════════════════════════╝${N}\n"

    phase1_packages
    phase2_network
    phase3_dnsmasq
    phase4_tor
    phase5_firewall
    phase6_scripts
    phase7_pihole
    phase8_doh
    phase9_web
    phase10_failover
    phase11_service

    echo ""
    echo -e "${G}╔══════════════════════════════════════╗${N}"
    echo -e "${G}║        Installation Complete!        ║${N}"
    echo -e "${G}╚══════════════════════════════════════╝${N}"
    echo ""
    echo -e "  ${Y}Start the router:${N}  tor-router start"
    echo -e "  ${Y}Check status:${N}     tor-router status"
    echo -e "  ${Y}View logs:${N}        tor-router logs"
    echo -e "  ${Y}Dashboard:${N}        http://192.168.10.1  (from eth1)"
    echo -e "  ${Y}Pi-hole admin:${N}    http://192.168.10.1/admin"
    echo -e "  ${Y}Pi-hole pass:${N}     TorRouter@$(hostname)  (change with: pihole -a -p <pw>)"
    echo ""
    echo -e "  ${Y}Or start on boot automatically:${N}"
    echo -e "  systemctl enable --now tor-router"
    echo ""
    log "Installation complete."
}

main "$@"
