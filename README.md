# ToKoS — Tor Kali Operating System Router

A security-focused router that transforms a Kali Linux box into a multi-LAN gateway with **Tor anonymity**, **Pi-hole ad blocking**, **DNS-over-HTTPS**, **VPN support**, and a **web dashboard** — all managed by a single CLI command.

```
tor-router start | stop | restart | status
```

## Network Architecture

```
Internet
   │
   ├── eth0  (WAN 1 — primary, DHCP)
   ├── wlan0 (WAN 2 — failover, DHCP)
   │
   ├── eth1  → 192.168.10.0/24  LAN Standard  (Pi-hole DNS filtering)
   ├── eth2  → 192.168.20.0/24  LAN Tor 1     (all traffic through Tor)
   └── eth3  → 192.168.30.0/24  LAN Tor 2     (all traffic through Tor)
```

| Feature | Implementation |
|---------|---------------|
| Tor transparent proxy | `iptables` REDIRECT → TransPort 9040 / DNSPort 9053 |
| DNS filtering | Pi-hole FTL (port 5335) with 80k+ blocked domains |
| Encrypted DNS | dnscrypt-proxy → Cloudflare DoH |
| WAN failover | Automatic failover monitor (eth0 ↔ wlan0) |
| Client isolation | iptables DROP rules between Tor LAN clients |
| IPv6 leak prevention | Globally disabled |
| VPN support | OpenVPN + WireGuard (connect/disconnect via CLI or web) |
| Web dashboard | nginx + PHP on `http://192.168.10.1` |

## Quick Start

```bash
# Clone
git clone https://github.com/k0k4/ToKoS.git
cd ToKoS

# Install (fully automated, run as root)
chmod +x install.sh scripts/*.sh
sudo ./install.sh

# Start the router
tor-router start

# Enable auto-start on boot
systemctl enable tor-router
```

## CLI Reference

```
tor-router start               Start all 7 services + apply firewall
tor-router stop                Stop everything + flush iptables
tor-router restart             Full restart
tor-router status              Services, Tor exit IP, WAN state, resources
tor-router new-circuit         New Tor exit IP (no restart needed)
tor-router firewall            Reload iptables rules
tor-router logs [svc]          Tail logs (tor|dnsmasq|nginx|wan|pihole|all)
tor-router vpn connect <file>  Connect VPN profile
tor-router vpn disconnect      Disconnect all VPNs
tor-router vpn list            List profiles in /etc/tor-router/vpn/
```

## Services Managed

| Service | Port | Role |
|---------|------|------|
| `dnscrypt-proxy` | 5053 | DNS-over-HTTPS (Cloudflare) |
| `pihole-FTL` | 5335 (DNS) / 8080 (web) | Ad blocking + DNS filtering |
| `tor@default` | 9040/9053 | Transparent proxy + DNS for Tor LANs |
| `dnsmasq` | 53 | DHCP + DNS for all LANs |
| `nginx` | 80 | Web dashboard (eth1 only) |
| `php8.4-fpm` | socket | Dashboard backend |
| `wan-failover` | — | WAN link monitor |

## DNS Chain

```
Client → dnsmasq (53) → Pi-hole (5335) → dnscrypt-proxy (5053) → Cloudflare DoH
```

Tor LANs bypass this chain — DNS goes directly through the Tor network.

## Web Dashboard

Accessible from any device on **eth1** at `http://192.168.10.1`:

- Live service status indicators
- Current Tor exit IP
- CPU / memory / network traffic
- Pi-hole statistics
- Controls: new Tor circuit, restart Tor, VPN connect/disconnect, WAN management
- VPN profile upload

Pi-hole admin: `http://192.168.10.1:8080/admin`

## Hardware Requirements

- Mini-PC with **4+ Ethernet ports** + Wi-Fi
- Quad-core CPU, 8 GB RAM, 120 GB SSD
- Kali Linux installed

## Documentation

See [INSTALL.md](INSTALL.md) for detailed step-by-step installation, verification procedures, troubleshooting, and file reference.

## License

MIT
