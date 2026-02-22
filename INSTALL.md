# Tor Security Router — Installation Guide

## Hardware Requirements
- Quad-core mini-computer, 8 GB RAM, 120 GB SSD
- **5 network interfaces**: `eth0`, `eth1`, `eth2`, `eth3` (built-in), `wlan0` (Wi-Fi)
- OS: Kali Linux (fresh installation recommended)

## Network Architecture

| Interface | Role          | Subnet           | Traffic                          |
|-----------|---------------|------------------|----------------------------------|
| `eth0`    | WAN 1         | DHCP from modem  | Primary internet uplink          |
| `wlan0`   | WAN 2         | DHCP from Wi-Fi  | Failover / load-balance          |
| `eth1`    | LAN Standard  | 192.168.10.1/24  | Normal internet + Pi-hole DNS    |
| `eth2`    | LAN Tor 1     | 192.168.20.1/24  | All traffic routed through Tor   |
| `eth3`    | LAN Tor 2     | 192.168.30.1/24  | All traffic routed through Tor   |

---

## Step 1 — Physical Setup

1. Connect **eth0** to your modem/router (WAN uplink).
2. Connect **wlan0** to an upstream Wi-Fi AP (optional failover).
3. Connect client devices/switches to **eth1**, **eth2**, or **eth3**.
4. Boot into Kali Linux as root.

---

## Step 2 — Transfer Project Files

```bash
# Via scp from another machine:
scp -r tor-router/ root@<ROUTER_IP>:/opt/tor-router

# Or from USB:
cp -r /media/usb/tor-router /opt/tor-router
```

---

## Step 3 — Run the Installer (fully automated)

```bash
cd /opt/tor-router
chmod +x install.sh scripts/*.sh
sudo ./install.sh
```

The installer handles everything **without interaction**:

| Phase | What happens |
|-------|-------------|
| 1 | Update packages; install tor, dnsmasq, nginx, php8.4-fpm, openvpn, wireguard, vnstat |
| 2 | Static IPs on eth1–3; DHCP on eth0/wlan0; enable IP forwarding; disable IPv6 |
| 3 | Deploy dnsmasq (DHCP + DNS for all 3 LANs) |
| 4 | Deploy torrc (TransPort + DNSPort per Tor LAN) |
| 5 | Install firewall script (applied on service start) |
| 6 | Install CLI at `/usr/local/bin/tor-router`; configure sudoers |
| 7 | Install Pi-hole **unattended** (pre-seeded config) |
| 8 | Install cloudflared; set Pi-hole upstream to DNS-over-HTTPS |
| 9 | Deploy web dashboard at `/var/www/tor-router` |
| 10 | Register `wan-failover.service` |
| 11 | Register `tor-router.service` |

---

## Step 4 — Start the Router

```bash
tor-router start
```

To start automatically on every boot:

```bash
systemctl enable --now tor-router
```

---

## `tor-router` CLI Reference

```
tor-router start                Start all services + apply firewall
tor-router stop                 Stop all services + flush firewall
tor-router restart              Restart everything
tor-router status               Full status: services, IPs, WAN, VPN, resources
tor-router new-circuit          Request a new Tor exit IP
tor-router firewall             Reload iptables rules without restarting
tor-router logs [svc]           Tail logs  (svc: tor | dnsmasq | nginx | wan | all)
tor-router vpn connect <name>   Connect a VPN profile
tor-router vpn disconnect       Disconnect all VPNs
tor-router vpn list             List available profiles in /etc/tor-router/vpn/
```

---

## Step 5 — Verification

### eth1 (Standard LAN) — from a connected client
```bash
# Gets IP in 192.168.10.50–150 range
ip addr

# Shows YOUR real ISP IP (not Tor)
curl https://api.ipify.org

# DNS filtered by Pi-hole
nslookup doubleclick.net        # should be blocked → 0.0.0.0
```

### eth2 / eth3 (Tor LANs) — from a connected client
```bash
# Gets IP in 192.168.20.x or 192.168.30.x
ip addr

# Shows a Tor exit node IP — NOT your real IP
curl https://api.ipify.org

# Confirms Tor usage
curl https://check.torproject.org/api/ip
```

### Client isolation (Tor LANs)
```bash
# From one device on eth2, ping another on eth2 — must fail
ping 192.168.20.51    # ← unreachable
```

---

## Web Dashboard

Open from any **eth1** device:

```
http://192.168.10.1          — Main dashboard
http://192.168.10.1/admin    — Pi-hole admin
```

Default Pi-hole password: `TorRouter@<hostname>` — change immediately:
```bash
pihole -a -p <newpassword>
```

---

## VPN Profiles

Copy `.conf` (WireGuard or OpenVPN) files to `/etc/tor-router/vpn/`, then:

```bash
tor-router vpn list
tor-router vpn connect myvpn.conf
tor-router vpn disconnect
```

Or use the web dashboard to upload profiles directly.

---

## File Reference

```
/opt/tor-router/
├── install.sh                         Automated installer
├── config/
│   ├── interfaces                     → /etc/network/interfaces
│   ├── dnsmasq.conf                   → /etc/dnsmasq.conf
│   ├── torrc                          → /etc/tor/torrc
│   ├── nginx.conf                     → /etc/nginx/sites-available/tor-router
│   ├── wan-failover.service           → /etc/systemd/system/
│   └── tor-router.service             → /etc/systemd/system/
├── scripts/
│   ├── tor-router-cli.sh              → /usr/local/bin/tor-router   (main CLI)
│   ├── firewall.sh                    → /usr/local/bin/firewall.sh
│   ├── new_tor_circuit.sh             → /usr/local/bin/tor-router.d/
│   ├── connect_vpn.sh                 → /usr/local/bin/tor-router.d/
│   ├── disconnect_vpn.sh              → /usr/local/bin/tor-router.d/
│   ├── wan_manager.sh                 → /usr/local/bin/tor-router.d/
│   └── configure_pihole.sh            → /usr/local/bin/tor-router.d/
└── web/
    ├── index.html                     Dashboard UI
    ├── api/status.php                 GET → JSON system status
    ├── api/control.php                POST → service control
    └── assets/{style.css,app.js}      Dashboard frontend

Runtime paths:
/usr/local/bin/tor-router              Main CLI command
/usr/local/bin/tor-router.d/           Helper scripts
/var/www/tor-router/                   Web root
/etc/tor-router/vpn/                   VPN profiles
/run/tor-router/wan_state              WAN failover state
/etc/iptables/rules.v4                 Persisted firewall (backup)
/var/log/tor-router-install.log        Installer log
/var/log/tor-router.log                Runtime log
```

---

## Troubleshooting

| Symptom | Command |
|---------|---------|
| Services not starting | `tor-router status` |
| No DHCP on LAN | `systemctl status dnsmasq` / `journalctl -u dnsmasq` |
| Tor LAN shows real IP | `tor-router logs tor` — wait for "Bootstrapped 100%" |
| Dashboard unreachable | `systemctl status nginx php8.4-fpm` |
| Firewall rules lost | `tor-router firewall` |
| WAN not failing over | `journalctl -u wan-failover -n 50` |

---

## Security Notes

- Dashboard accessible **only from eth1** (192.168.10.0/24).
- SSH restricted to eth1 by default firewall rules.
- Tor LANs use **`IsolateClientAddr`** — each source IP gets a separate circuit.
- Devices on eth2/eth3 **cannot communicate with each other** (iptables DROP rules).
- **IPv6 disabled globally** to prevent bypass leaks.
- Pi-hole DNS queries are encrypted via **DNS-over-HTTPS** (cloudflared → 1.1.1.1).
- Tor DNS queries resolve **inside the Tor network** — no DNS leaks on eth2/eth3.


## Hardware Requirements
- Quad-core mini-computer, 8 GB RAM, 120 GB SSD
- **5 network interfaces**: `eth0`, `eth1`, `eth2`, `eth3` (built-in), `wlan0` (Wi-Fi)
- OS: Kali Linux (fresh installation recommended)

## Network Architecture

| Interface | Role          | Subnet           | Traffic                          |
|-----------|---------------|------------------|----------------------------------|
| `eth0`    | WAN 1         | DHCP from modem  | Primary internet uplink          |
| `wlan0`   | WAN 2         | DHCP from Wi-Fi  | Failover / load-balance          |
| `eth1`    | LAN Standard  | 192.168.10.1/24  | Normal internet + Pi-hole DNS    |
| `eth2`    | LAN Tor 1     | 192.168.20.1/24  | All traffic routed through Tor   |
| `eth3`    | LAN Tor 2     | 192.168.30.1/24  | All traffic routed through Tor   |

---

## Step 1 — Physical Setup

1. Connect **eth0** to your modem/router (WAN uplink).
2. Connect **wlan0** to an upstream Wi-Fi AP (optional failover — configure `wpa_supplicant` if needed).
3. Connect client devices/switches to **eth1**, **eth2**, or **eth3** as desired.
4. Boot the machine into Kali Linux and log in as root (or a sudo-enabled user).

---

## Step 2 — Clone / Transfer Project Files

Transfer the `tor-router/` directory to the device:

```bash
# From another machine via scp:
scp -r tor-router/ root@<ROUTER_IP>:/opt/tor-router

# Or copy from USB:
cp -r /media/usb/tor-router /opt/tor-router
```

---

## Step 3 — Run the Main Installer

```bash
cd /opt/tor-router
chmod +x install.sh scripts/*.sh
sudo ./install.sh
```

The installer will:
1. Update packages and install: `tor`, `dnsmasq`, `iptables-persistent`, `nginx`, `php8.4-fpm`, `openvpn`, `wireguard-tools`, `vnstat`
2. Configure network interfaces (static IPs on eth1–eth3, DHCP on eth0/wlan0)
3. Deploy `dnsmasq` (DHCP server for all three LANs)
4. Configure Tor (transparent proxy + DNS port per Tor LAN)
5. Apply iptables firewall rules (NAT, Tor redirection, client isolation)
6. Install the web dashboard at `http://192.168.10.1`
7. Enable WAN failover monitor service

**Expected runtime:** 5–10 minutes (depends on download speed).

---

## Step 4 — Install Pi-hole (Interactive)

Pi-hole requires an interactive installer. After `install.sh` completes:

```bash
curl -sSL https://install.pi-hole.net | bash
```

**During the Pi-hole setup wizard:**
- **Interface**: select `eth1`
- **IP Address**: confirm `192.168.10.1/24`
- **Gateway**: your WAN default gateway
- **Upstream DNS**: choose any option — you will replace it with DoH in the next step
- Enable the web admin interface
- Install the web server component

---

## Step 5 — Configure Pi-hole with DNS-over-HTTPS

After Pi-hole is installed, run:

```bash
sudo /usr/local/bin/tor-router/configure_pihole.sh
```

This script:
1. Downloads and installs **cloudflared** (Cloudflare's DoH proxy)
2. Configures cloudflared to listen on `127.0.0.1:5335` and forward queries to `1.1.1.1` and `1.0.0.1` over HTTPS
3. Sets Pi-hole's upstream to `127.0.0.1#5335`

> **Alternative DoH providers:** Edit `/etc/default/cloudflared` and replace the `--upstream` URLs with:
> - NextDNS: `https://dns.nextdns.io/<your-id>/dns-query`
> - Quad9:   `https://dns.quad9.net/dns-query`

---

## Step 6 — Configure Wi-Fi Upstream (wlan0 as WAN 2)

If using wlan0 as a secondary WAN (connecting to an upstream AP):

```bash
# Create WPA supplicant config
wpa_passphrase "YourSSID" "YourPassword" > /etc/wpa_supplicant/wpa_supplicant.conf

# Connect
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
dhclient wlan0
```

Uncomment the `wpa-conf` line in `/etc/network/interfaces` to persist across reboots.

---

## Step 7 — Verification

### Verify each LAN

**eth1 (Standard LAN) — from a connected client:**
```bash
# Should receive IP in 192.168.10.50–150 range
ip addr

# Should reach internet and show YOUR real ISP IP
curl https://api.ipify.org

# DNS should be filtered by Pi-hole (test an ad domain)
nslookup doubleclick.net
```

**eth2 / eth3 (Tor LANs) — from a connected client:**
```bash
# Should receive IP in 192.168.20.x or 192.168.30.x range
ip addr

# Should return a Tor exit node IP (not your real IP)
curl https://api.ipify.org

# DNS should resolve via Tor (no Pi-hole)
nslookup check.torproject.org
```

**Client isolation (Tor LANs):**
```bash
# From one device on eth2, try to ping another device on eth2 — should fail
ping 192.168.20.51   # ← should be unreachable
```

### Verify Tor transparency
Visit `https://check.torproject.org` from a device on eth2 or eth3 — it should confirm you are using Tor.

### Verify firewall
```bash
# From a Tor LAN client, direct TCP/80 should be redirected (not direct):
curl --interface eth2 http://example.com   # Works via Tor

# Port 22 on router only accessible from eth1:
ssh root@192.168.20.1   # Should be blocked
ssh root@192.168.10.1   # Should work
```

---

## Step 8 — Access the Dashboard

Open a browser on a device connected to **eth1**:

```
http://192.168.10.1
```

The dashboard provides:
- Live service status (Tor, dnsmasq, Pi-hole, VPN)
- Current Tor exit IP
- WAN failover state
- CPU / memory usage
- Per-interface network traffic
- Pi-hole query statistics
- Buttons: New Tor Circuit, Restart Tor, Connect/Disconnect VPN, Set Primary WAN
- VPN profile upload (.conf / .ovpn)

---

## File Reference

```
/opt/tor-router/
├── install.sh                        Main installer
├── config/
│   ├── interfaces                    /etc/network/interfaces
│   ├── dnsmasq.conf                  /etc/dnsmasq.conf
│   ├── torrc                         /etc/tor/torrc
│   ├── nginx.conf                    /etc/nginx/sites-available/tor-router
│   └── wan-failover.service          /etc/systemd/system/wan-failover.service
├── scripts/
│   ├── firewall.sh                   Firewall rules (also at /usr/local/bin/)
│   ├── new_tor_circuit.sh            Request new Tor exit circuit
│   ├── connect_vpn.sh                Connect OpenVPN/WireGuard profile
│   ├── disconnect_vpn.sh             Disconnect all VPNs
│   ├── wan_manager.sh                WAN failover daemon
│   └── configure_pihole.sh           Post-install Pi-hole + DoH setup
└── web/
    ├── index.html                    Dashboard UI
    ├── api/
    │   ├── status.php                GET  /api/status.php  → JSON status
    │   └── control.php               POST /api/control.php → actions
    └── assets/
        ├── style.css                 Dashboard styles
        └── app.js                    Dashboard logic

Runtime paths:
/usr/local/bin/tor-router/           Installed scripts
/var/www/tor-router/                 Web root
/etc/tor-router/vpn/                 VPN profile storage
/run/tor-router/wan_state            WAN failover state
/etc/iptables/rules.v4               Persisted firewall rules
/var/log/tor-router-install.log      Installer log
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No DHCP on LAN | `systemctl status dnsmasq` — check `/var/log/dnsmasq.log` |
| Tor LAN has direct internet | `iptables -t nat -L PREROUTING -n -v` — verify REDIRECT rules |
| Tor exit IP shows real IP | `systemctl status tor` — wait for full bootstrap |
| Dashboard not loading | `systemctl status nginx php8.4-fpm` |
| VPN profile not listed | Check `/etc/tor-router/vpn/` permissions (www-data readable) |
| WAN failover stuck | `systemctl status wan-failover` — check `journalctl -u wan-failover` |

### Reload firewall manually
```bash
sudo /usr/local/bin/firewall.sh
```

### Request new Tor circuit manually
```bash
sudo /usr/local/bin/tor-router/new_tor_circuit.sh
```

### Check Tor bootstrap status
```bash
journalctl -u tor -n 30 --no-pager | grep Bootstrap
```

---

## Security Notes

- The web dashboard is only accessible from **eth1** (192.168.10.0/24). Never expose it on WAN interfaces.
- SSH access is restricted to eth1 by the firewall. Adjust `firewall.sh` if you need remote administration.
- Tor LANs use **client isolation** (`IsolateClientAddr`) so each source IP gets a separate Tor circuit.
- Devices on eth2/eth3 **cannot communicate with each other** (iptables client isolation rules).
- IPv6 is **disabled globally** to prevent IPv6 leak bypassing Tor.
- All Tor DNS queries are resolved inside the Tor network — no DNS leaks on eth2/eth3.
- Pi-hole on eth1 uses DNS-over-HTTPS so your ISP cannot see DNS queries from the standard LAN.
