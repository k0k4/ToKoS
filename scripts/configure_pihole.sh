#!/bin/bash
# =============================================================================
# /usr/local/bin/tor-router.d/configure_pihole.sh
# Installs dnscrypt-proxy (DoH/DoT) and sets Pi-hole upstream to it.
# Called automatically by install.sh; safe to re-run.
# =============================================================================

set -euo pipefail

log() { echo "[pihole-config] $*"; }

install_dnscrypt() {
    log "Installing dnscrypt-proxy (DoH resolver)..."
    DEBIAN_FRONTEND=noninteractive apt install -y dnscrypt-proxy
    log "dnscrypt-proxy installed."
}

configure_dnscrypt() {
    log "Configuring dnscrypt-proxy on 127.0.0.1:5053..."

    local CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    [[ -f "$CONF" ]] || { log "ERROR: dnscrypt-proxy config not found"; exit 1; }

    # Listen on 127.0.0.1:5053 only
    sed -i "s|^listen_addresses = .*|listen_addresses = ['127.0.0.1:5053']|" "$CONF"

    # Use Cloudflare DoH
    sed -i "s|^server_names = .*|server_names = ['cloudflare', 'cloudflare-ipv6']|" "$CONF"

    # Disable socket activation
    systemctl disable dnscrypt-proxy.socket 2>/dev/null || true
    systemctl stop dnscrypt-proxy.socket 2>/dev/null || true

    systemctl enable dnscrypt-proxy.service
    systemctl restart dnscrypt-proxy.service
    sleep 2

    # Verify
    if dig @127.0.0.1 -p 5053 google.com +short > /dev/null 2>&1; then
        log "dnscrypt-proxy working on port 5053."
    else
        log "WARNING: dnscrypt-proxy may not be resolving yet. Check: journalctl -u dnscrypt-proxy"
    fi
}

configure_pihole_upstream() {
    log "Setting Pi-hole upstream DNS to dnscrypt-proxy (127.0.0.1#5053)..."

    if command -v pihole-FTL &>/dev/null; then
        # Pi-hole v6+
        pihole-FTL --config dns.port 5335
        pihole-FTL --config dns.upstreams '["127.0.0.1#5053"]'
        pihole-FTL --config dns.listeningMode "BIND"
        # Move Pi-hole web UI to port 8080 (nginx uses port 80 for dashboard)
        pihole-FTL --config webserver.port "8080,[::]:8080"
        systemctl restart pihole-FTL
        log "Pi-hole FTL: DNS port 5335, web port 8080, upstream → dnscrypt-proxy (DoH)."
    elif command -v pihole &>/dev/null; then
        # Pi-hole v5 (legacy)
        local PIHOLE_CONF="/etc/pihole/setupVars.conf"
        if [[ -f "$PIHOLE_CONF" ]]; then
            sed -i '/^PIHOLE_DNS_/d' "$PIHOLE_CONF"
            echo "PIHOLE_DNS_1=127.0.0.1#5053" >> "$PIHOLE_CONF"
            pihole restartdns
            log "Pi-hole upstream set to dnscrypt-proxy (DoH)."
        else
            log "WARNING: Pi-hole config not found."
        fi
    else
        log "WARNING: Pi-hole not installed. Skipping upstream config."
    fi
}

main() {
    [[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
    install_dnscrypt
    configure_dnscrypt
    configure_pihole_upstream
    log "Done. DNS chain: dnsmasq → Pi-hole(5335) → dnscrypt-proxy(5053) → Cloudflare DoH"
}

main "$@"
