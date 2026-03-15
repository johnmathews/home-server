# DNS Privacy & Ad Blocking Setup

The home network uses a layered DNS setup for privacy, security, and ad blocking:

**Router (MikroTik hAP ax3)** → **AdGuard** → **Unbound** → **Quad9 (encrypted)**

## Architecture Overview

### Layer 1: Router DHCP Configuration

- **MikroTik router** advertises `192.168.2.111` (AdGuard LXC running on Proxmox) as the DNS server via DHCP
- All devices on the home network automatically use this DNS

### Layer 2: AdGuard LXC (192.168.2.111)

- **Ad blocking**: AdGuard blocks ads and trackers at the DNS level - it has a list of bad domains and if it receives a
  DNS request for one of those domains, it doesn't return anything.
- **Upstream DNS**: AdGuard forwards (good) DNS requests to Unbound at `127.0.0.1:5335`. Unbound runs on the same LXC as
  AdGuard.
- **LXC Container**: The AdGuard LXC runs on Proxmox at `192.168.2.111`. It is not running Docker and AdGuard is not a
  Docker service.
- **Tailscale IP**: Tailscale is installed on the LXC and authenticated. Therefore it has a Tailscale IP address
  `100.108.0.112` as well as a local IP address `192.168.2.111`.
- **AdGuard Web UI**: http://192.168.2.111

**How DNS-level ad blocking works:**

- Blocks DNS lookups for known ad/tracker domains (e.g., `ads.google.com`, `doubleclick.net`)
- Cannot block ads served from the same domain as content (e.g., YouTube ads from `googlevideo.com`)
- Works network-wide without per-device configuration

### Layer 3: Unbound (127.0.0.1:5335)

- **Runs on AdGuard LXC on port 5335**
- **DNS-over-TLS encryption**: Encrypts queries to upstream DNS provider
- **Upstream provider**: Quad9 (`9.9.9.9@853#dns.quad9.net`, `149.112.112.112@853#dns.quad9.net`)
- **Why Quad9**: Privacy-focused non-profit based in Switzerland, doesn't sell data
- **Certificate location**: `/etc/ssl/certs/ca-certificates.crt`
- **DNSSEC validation**: Verifies DNS responses are legitimate and unmodified

**Privacy guarantee:**

- Your ISP can only see encrypted traffic to Quad9
- Your ISP **cannot** see which domains you're looking up
- Quad9 sees your queries but has strong privacy commitments

## Tailscale Integration

AdGuard Home is accessible both locally and remotely via Tailscale:

**At home (local network):**

- Devices use `192.168.2.111` (direct connection)
- Fast, no VPN overhead

**When traveling (via Tailscale VPN):**

- The Tailscale app should be running and connected on your laptop, phone, etc.
- Go to Tailscale > Settings > Use Tailscale DNS Settings.
- Ensure that in the Tailscale Admin console (https://login.tailscale.com/admin/dns) the Global Nameservers include the
  Tailscale IP address of the AdGuard LXC and that "Override DNS Servers" is checked.
- Devices use AdGuard's Tailscale IP (`100.108.0.112`)
- DNS queries tunnel through Tailscale to your home network
- Full ad blocking and encryption even when using café/hotel WiFi

**Tailscale DNS configuration:**

- Web console: https://login.tailscale.com/admin/dns
- Global nameservers: `100.108.0.112` (AdGuard's Tailscale IP)
- MagicDNS: `100.100.100.100` (handles Tailscale hostname resolution)
- On Mac: Tailscale app → Settings → "Use Tailscale DNS settings" should be **checked**

## System Check-up

SSH into the AdGuard LXC (`ssh root@192.168.2.111` or `ssh root@100.108.0.112`):

### 1. Check Unbound is running

```bash
systemctl status unbound
```

Should show: `Active: active (running)`

### 2. Check DNS-over-TLS is working

```bash
# Test DNS resolution through Unbound
dig @127.0.0.1 -p 5335 google.com

# Check for SSL errors in logs
journalctl -u unbound -n 20 --no-pager | grep -i "ssl\|error"
```

Should see: No SSL handshake errors. If you see `ssl handshake failed` or `certificate verify failed`, the encryption is
broken.

### 3. Verify Quad9 upstream

```bash
cat /etc/unbound/unbound.conf | grep forward-addr
```

Should show:

```
forward-addr: 9.9.9.9@853#dns.quad9.net
forward-addr: 149.112.112.112@853#dns.quad9.net
```

### 4. Test DNSSEC validation

```bash
dig @127.0.0.1 -p 5335 dnssec-failed.org
```

Should see: `status: SERVFAIL` (if it returns an IP, DNSSEC is not working)

### 5. Check AdGuard is processing queries

- Open web UI: http://192.168.2.111
- Go to Query Log
- Should see recent queries from your devices

### 6. Verify end-to-end privacy

From any device on your network, visit: https://www.dnsleaktest.com/

**Expected result:**

- ISP: **Windstream Communications** or **Quad9** or **PCH** (Packet Clearing House)
- **NOT** your actual ISP (KPN)

If you see KPN, your DNS is leaking!

### 7. Check Unbound stats

```bash
unbound-control stats_noreset
```

Key metrics:

- `total.num.queries`: Total queries processed
- `total.num.cachehits`: Queries answered from cache (should be high)
- `total.num.cachemiss`: Queries that needed upstream lookup
- `time.up`: Uptime in seconds (if low, cache will be cold)

## Host DNS Configuration

Different hosts get their DNS configuration in different ways:

**VMs (media-vm, infra-vm, etc.):** Use `systemd-resolved`, which gets the DNS server from MikroTik DHCP
(`192.168.2.111`). No Ansible management needed.

**LXCs (agent, traefik, prometheus, etc.):** Proxmox writes `/etc/resolv.conf` at container creation with
`192.168.2.111`. No Ansible management needed.

**PVE host:** Static IP, no DHCP — manages `/etc/resolv.conf` directly. Ansible deploys a template with a primary and
fallback DNS server:

```
nameserver 192.168.2.111   # AdGuard Home (primary)
nameserver 9.9.9.9         # Quad9 direct (fallback)
```

The fallback ensures PVE can still resolve DNS if the AdGuard LXC is down (e.g., during Proxmox maintenance or LXC
migration). The fallback skips ad blocking but keeps the host functional.

**Ansible variables** (in `group_vars/all/main.yml`):

- `dns_primary: "192.168.2.111"` — AdGuard Home
- `dns_fallback: "9.9.9.9"` — Quad9 (matches Unbound upstream)

**Ansible task:** `roles/pve/tasks/main.yml` deploys `roles/pve/templates/resolv.conf.j2` (tagged `dns`).

To apply: `make pve t=dns`

## Configuration Files

### AdGuard Home Config

```bash
/opt/AdGuardHome/AdGuardHome.yaml
```

Key setting: `upstream_dns: ["127.0.0.1:5335"]`

### Unbound Config

```bash
/etc/unbound/unbound.conf
```

Critical settings:

- `tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"` (enables DNS-over-TLS)
- `forward-tls-upstream: yes` (encrypts upstream queries)
- `forward-addr: 9.9.9.9@853#dns.quad9.net` (Quad9 upstream)

## Troubleshooting

### Problem: Internet works but ads aren't blocked

**Diagnosis:** Device isn't using AdGuard DNS

```bash
# On the device
nslookup google.com
```

Should show `Server: 192.168.2.111` (at home) or `Server: 100.108.0.112` (via Tailscale)

**Fix:**

- At home: Check MikroTik DHCP settings (IP → DHCP Server → Networks)
- Via Tailscale: Enable "Use Tailscale DNS settings" in Tailscale app

### Problem: DNS leak test shows KPN

**Diagnosis:** DNS queries aren't encrypted or aren't going through your setup

**Fix:**

1. Check Unbound logs for SSL errors: `journalctl -u unbound | grep -i error`
2. Verify certificate bundle exists: `ls -la /etc/ssl/certs/ca-certificates.crt`
3. Restart Unbound: `systemctl restart unbound`
4. Test again: dig @127.0.0.1 -p 5335 google.com`

### Problem: Slow DNS resolution

**Diagnosis:** Cache is cold or upstream is slow

**Check cache stats:**

```bash
unbound-control stats_noreset | grep cache
```

**Fix:**

- Wait for cache to warm up (happens naturally with use)
- Check upstream connectivity: `journalctl -u unbound -f` (watch for errors)

### Problem: Can't access AdGuard when traveling

**Diagnosis:** Tailscale DNS not configured

**Fix:**

1. Check Tailscale is connected: `tailscale status`
2. Enable "Use Tailscale DNS settings" in Tailscale app
3. Verify DNS: `nslookup google.com` should show AdGuard's Tailscale IP

## Privacy vs Cloudflare vs Your ISP

**Before this setup:**

- KPN (your ISP) could see every domain you looked up
- Plain text DNS queries

**With this setup:**

- KPN sees: Encrypted traffic to Quad9 (IP addresses only)
- KPN cannot see: Which domains you're visiting
- Quad9 sees: Your DNS queries (but has strong privacy policy, Swiss jurisdiction)

**Alternative upstream providers:**

```bash
# Edit /etc/unbound/unbound.conf

# Cloudflare (faster, US-based, collects some data)
forward-addr: 1.1.1.1@853#cloudflare-dns.com
forward-addr: 1.0.0.1@853#cloudflare-dns.com

# Mullvad (VPN company, extreme privacy focus)
forward-addr: 194.242.2.2@853#dns.mullvad.net

# Pure recursive (no upstream, slowest, maximum privacy)
# Comment out the entire forward-zone section
```

After changing, restart: `systemctl restart unbound`

## Additional Resources

- AdGuard Home docs: [https://github.com/AdguardTeam/AdGuardHome/wiki](https://github.com/AdguardTeam/AdGuardHome/wiki)
- Unbound docs: [https://unbound.docs.nlnetlabs.nl/](https://unbound.docs.nlnetlabs.nl/)
- Quad9 privacy policy: [https://www.quad9.net/privacy/policy](https://www.quad9.net/privacy/policy)
- DNS leak testing: [https://www.dnsleaktest.com/](https://www.dnsleaktest.com/)
