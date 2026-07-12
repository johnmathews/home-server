# Tailscale Remote Access & DNS Privacy Setup

This guide covers setting up Tailscale VPN for remote SSH/Ansible access to your homelab and configuring encrypted DNS
that works both at home and while traveling.

## What is Tailscale?

Tailscale is a zero-config mesh VPN built on WireGuard that creates direct encrypted connections between your devices. It
allows you to access your homelab from anywhere (coffee shops, hotels, airports) as if you were on your local network.

**Key benefits**:

- **Zero configuration**: Install, authenticate, and it works
- **Direct connections**: Peer-to-peer when possible (fast)
- **Works everywhere**: Automatic NAT traversal through firewalls
- **Transparent to apps**: SSH and Ansible work without modification
- **Secure**: WireGuard encryption, no exposed ports on your router
- **DNS privacy**: Routes DNS queries to your home AdGuard setup when traveling

## Architecture Overview

### Network Topology

**At home (local network):**

```
Device (192.168.2.x)
    ↓ (via MikroTik DHCP)
AdGuard Home (192.168.2.111)
    ↓
Unbound → Quad9 (encrypted DNS-over-TLS)
```

**When traveling (via Tailscale):**

```
Device (any WiFi)
    ↓ (via Tailscale VPN tunnel)
AdGuard Home (100.108.0.112 Tailscale IP)
    ↓
Unbound → Quad9 (encrypted DNS-over-TLS)
```

### Tailscale Components

The Tailscale setup consists of:

1. **`roles/tailscale/`** - Installs and configures Tailscale on any Debian/Ubuntu host
2. **`roles/proxmox_lxc_tun/`** - Configures Proxmox LXC containers to support VPN software
3. **`playbooks/tailscale.yml`** - Deploys Tailscale to all hosts
4. **`inventory-tailscale.ini`** - Inventory file with Tailscale IPs for remote access
5. **Tailscale DNS** - Routes DNS queries to home AdGuard for privacy and ad blocking

### DNS: accept-dns must be false on server hosts

**Critical:** The `accept-dns` setting (called `CorpDNS` internally) must be `false` on all server hosts (VMs and LXCs).
The Ansible role default is `tailscale_accept_dns: false` — do not override this to `true` for server hosts.

**Why this matters:**

The primary DNS resolver for all server hosts is **AdGuard Home (192.168.2.111)**, which provides the DNS chain:

```
Server host → AdGuard (192.168.2.111) → Unbound → Quad9 (encrypted DNS-over-TLS)
```

When `accept-dns` is `true`, Tailscale tells `systemd-resolved` to use MagicDNS (`100.100.100.100`) with a `~.`
catch-all domain, which silently overrides AdGuard for **all** DNS queries — not just `*.ts.net` names. If MagicDNS
has any connectivity issues (e.g. after a reboot, network instability, or Tailscale service degradation), **all DNS
resolution breaks**, taking down apt, Docker image pulls, and any service that needs to resolve hostnames.

On hosts without `systemd-resolved` (most LXCs), Tailscale writes `100.100.100.100` directly into `/etc/resolv.conf`,
completely replacing AdGuard with no fallback.

**The rule:**

- **Server hosts** (VMs, LXCs): `accept-dns: false` — use AdGuard via local network
- **Client devices** (laptop, phone): `accept-dns: true` — use Tailscale DNS for privacy when traveling

The `tailscale set --accept-dns=false` command is enforced on every Ansible run via the Tailscale role, even on
already-authenticated hosts.

### LXC Container Requirements

Proxmox LXC containers are sandboxed and cannot create `/dev/net/tun` devices by default. The `proxmox_lxc_tun` role adds
TUN device support to all LXC containers on the Proxmox host. This is automatically handled when you run `make pve`.

## Prerequisites

1. **Tailscale account**: Sign up at https://tailscale.com (free for personal use, up to 100 devices)
2. **Auth key**: Generate at https://login.tailscale.com/admin/settings/keys
   - Recommended settings:
     - Expiration: 90 days or longer
     - ✓ Reusable (if you plan to reinstall)
     - ✗ Ephemeral (unless you want auto-cleanup of offline devices)
     - ✗ Pre-authorized (let admins approve devices)

## Installation Steps

### 1. Add Auth Key to Vault

Edit `group_vars/all/vault.yml` and add your Tailscale auth key:

```yaml
# Tailscale
tailscale_auth_key: "tskey-auth-XXXXXXXXXXXXXXXXXXXXX"
```

Encrypt the vault:

```bash
ansible-vault encrypt group_vars/all/vault.yml
```

### 2. Configure Proxmox and LXCs

**Important:** Run this first to prepare LXC containers for VPN software:

```bash
# This will:
# - Add TUN device support to all LXC containers
# - Install Tailscale on the Proxmox host
make pve
```

The `proxmox_lxc_tun` role (included in `make pve`) adds these lines to each LXC config:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

This only needs to be run once and is idempotent (safe to run multiple times).

### 3. Tailscale on the AdGuard LXC (manual — not Ansible-managed)

**Critical:** The AdGuard LXC must have its own Tailscale instance for DNS to work remotely.

The AdGuard LXC (192.168.2.111) is **not managed by Ansible** — it appears in neither `inventory.ini` nor
`inventory-tailscale.ini`, so `make tailscale` never touches it. Its Tailscale instance was installed and
authenticated manually on the LXC (`curl -fsSL https://tailscale.com/install.sh | sh` then `tailscale up`).

To check or retrieve the AdGuard Tailscale IP:

```bash
ssh root@192.168.2.111 "tailscale ip -4"
# Output: 100.108.0.112 (save this for DNS configuration)
```

### 4. Deploy Tailscale to All Other Hosts

Deploy to remaining VMs and LXCs:

```bash
# Deploy to all hosts
make tailscale

# Or deploy to specific host (inventory.ini uses hyphens, e.g. media-vm;
# inventory-tailscale.ini uses underscores, e.g. media_vm)
make tailscale LIMIT=media-vm

# Or use Ansible directly
ansible-playbook -i inventory.ini playbooks/tailscale.yml --vault-password-file=.vault_pass.txt
```

This will:

- Install Tailscale on each host
- Authenticate with your Tailscale network
- Start the Tailscale daemon
- Display the assigned Tailscale IP

### Note: NanoClaw LXC (manual install)

Tailscale on the NanoClaw LXC (`192.168.2.107`) was installed **manually**, not via the Ansible `tailscale` role.
Debian 13 (Trixie) does not ship `apt-key`, so the standard Tailscale install script fails. The workaround uses the
modern signed-by keyring method:

```bash
# As root on the NanoClaw LXC:
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  | tee /etc/apt/sources.list.d/tailscale.list > /dev/null
apt-get update && apt-get install -y tailscale
tailscale up
```

Tailscale IP: `100.125.185.47` / MagicDNS: `openclaw.flicker-enigmatic.ts.net` (hostname predates NanoClaw rename)

If other Debian 13 LXCs need Tailscale in the future, the Ansible role should be updated with this keyring method.

### 5. Collect Tailscale IP Addresses

After deployment, get the Tailscale IP for each host:

```bash
# From your local machine
ssh john@192.168.2.105 "tailscale ip -4"
# Output: 100.88.114.14

# Or SSH to each host and run:
tailscale status
```

### 6. Configure Tailscale DNS

This enables ad blocking and encrypted DNS when traveling.

**In Tailscale admin console** (https://login.tailscale.com/admin/dns):

1. Navigate to DNS settings
2. Under **Nameservers** section:
   - `100.100.100.100` - MagicDNS (locked, required for Tailscale hostname resolution)
   - Add: `100.108.0.112` - Your AdGuard LXC Tailscale IP (from step 3)
3. **Do NOT enable "Override local DNS"** - this breaks connectivity
4. Save changes

**On your laptop/devices:**

Enable Tailscale DNS in the app:

- **macOS/Windows**: Tailscale app → Settings → ✓ "Use Tailscale DNS settings"
- **Linux**: DNS is automatically configured
- **iOS/Android**: DNS is automatically configured

### 7. Update Tailscale Inventory

Edit `inventory-tailscale.ini` and keep the `ansible_host` values in sync with the actual Tailscale IPs
(`scripts/collect-tailscale-ips.sh` can gather them). The file is the source of truth; current entries look like:

```ini
[proxmox]
proxmox_host ansible_host=100.99.115.121 ansible_user=root ansible_ssh_private_key_file=~/.ssh/john_macbook

[media]
media_vm ansible_host=100.88.114.14 ansible_user=john ansible_ssh_private_key_file=~/.ssh/john_macbook

[infra]
infra_vm ansible_host=100.64.76.3 ansible_user=john ansible_ssh_private_key_file=~/.ssh/john_macbook
```

Note: the AdGuard LXC is not in this inventory (not Ansible-managed), and host names here use underscores
(`media_vm`) whereas `inventory.ini` uses hyphens (`media-vm`).

### 8. Install Tailscale on Your Laptop

**macOS**:

```bash
brew install tailscale
sudo tailscale up
```

Or download from: https://tailscale.com/download/mac

**Linux**:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Windows**: Download installer from: https://tailscale.com/download/windows

### 9. Test Remote Access

Test SSH access using Tailscale IPs:

```bash
# Test SSH to Proxmox
ssh root@100.99.115.121

# Test SSH to AdGuard
ssh root@100.108.0.112

# Test SSH to Media VM
ssh john@100.88.114.14

# Test Ansible
ansible all -i inventory-tailscale.ini -m ping
```

### 10. Verify DNS Privacy

**Test DNS is working:**

```bash
# Should show AdGuard's Tailscale IP or 100.100.100.100 (MagicDNS)
nslookup google.com
```

**Test privacy is maintained:**

1. Visit: https://www.dnsleaktest.com/
2. Run standard or extended test
3. Expected results:
   - ISP: **Windstream Communications** or **Quad9** or **PCH**
   - **NOT** your actual ISP or café/hotel network

If you see your ISP or the local network's provider, DNS is leaking!

**Check AdGuard is processing your queries:**

1. Open AdGuard web UI: http://100.108.0.112 (AdGuard's Tailscale IP)
2. Go to Query Log
3. You should see queries from your laptop's Tailscale IP (100.Y.Y.Y)

## Usage

### DNS Behavior by Context

**At home on local WiFi (Tailscale disconnected):**

- DNS: `192.168.2.111` (direct to AdGuard, no VPN overhead)
- Privacy: ✅ Encrypted DNS via Quad9
- Ad blocking: ✅ Full ad blocking
- Speed: Fastest (local network)

**At home on local WiFi (Tailscale connected):**

- DNS: `100.108.0.112` or `100.100.100.100` (AdGuard via Tailscale)
- Privacy: ✅ Encrypted DNS via Quad9
- Ad blocking: ✅ Full ad blocking
- Speed: Fast (VPN overhead is minimal on local network)

**Traveling on café/hotel WiFi (Tailscale disconnected):**

- DNS: Whatever the network provides (e.g., café's ISP)
- Privacy: ❌ No encryption, café/ISP can see DNS queries
- Ad blocking: ❌ No ad blocking
- Speed: Depends on network

**Traveling on café/hotel WiFi (Tailscale connected):**

- DNS: `100.108.0.112` or `100.100.100.100` (tunnels to home AdGuard)
- Privacy: ✅ Encrypted DNS via Quad9, café/ISP cannot see DNS queries
- Ad blocking: ✅ Full ad blocking
- Speed: Good (VPN tunnel adds latency but DNS is cached)

**Key takeaway:** Keep Tailscale connected when on untrusted networks for privacy and ad blocking!

### Running Playbooks Remotely

When traveling, use the Tailscale inventory instead of the local one:

```bash
# Local network (at home)
make media  # Uses inventory.ini with 192.168.2.x IPs

# Remote access (traveling)
ansible-playbook -i inventory-tailscale.ini playbooks/media_vm.yml --vault-password-file=.vault_pass.txt

# Or update Makefile to use INVENTORY variable
make media INVENTORY="-i inventory-tailscale.ini"
```

### Accessing Web Services

You can also access web services directly via Tailscale IPs:

```bash
# AdGuard Home
open http://100.108.0.112

# Prometheus
open http://100.108.161.119:9090

# Grafana (infra VM)
open http://100.64.76.3:3000

# Proxmox UI
open https://100.99.115.121:8006
```

### MagicDNS (Optional)

Tailscale provides automatic DNS for your devices. This is already enabled and provides the `100.100.100.100` resolver.

Access hosts by their Tailscale hostnames:

```bash
ssh john@media-vm
ssh root@proxmox-host
ssh root@adguard
open http://prometheus-lxc:9090
```

## Verification & Troubleshooting

### Check Tailscale Connection Status

```bash
# On any host
tailscale status

# Get your device's Tailscale IP
tailscale ip -4

# Check connection quality
tailscale netcheck

# View logs
journalctl -u tailscaled -f
```

### Verify DNS is Working

**Test 1: Check DNS server in use**

```bash
nslookup google.com
```

Expected output when Tailscale is connected:

- `Server: 100.100.100.100` (MagicDNS forwarding to your AdGuard)
- OR `Server: 100.108.0.112` (directly to AdGuard)

Wrong output:

- `Server: 192.168.43.1` (café/hotel router - DNS not tunneling through Tailscale!)

**Test 2: DNS leak test** Visit: https://www.dnsleaktest.com/

Expected: Windstream Communications / Quad9 / PCH Wrong: Your actual ISP, café name, hotel network, etc.

**Test 3: Check AdGuard is receiving queries**

1. Open AdGuard web UI: http://100.108.0.112 (via Tailscale)
2. Go to Query Log
3. Look for queries from your device's Tailscale IP

**Test 4: Verify ad blocking is working** Visit: https://ads-blocker.com/testing/ Expected: Ads should be blocked

### Common Issues

#### Problem: Tailscale connected but DNS shows local network

**Symptoms:**

```bash
nslookup google.com
Server: 192.168.43.1  # Local café router
```

**Diagnosis:** Tailscale DNS settings not enabled

**Fix (macOS/Windows):**

1. Open Tailscale app
2. Go to Settings
3. Enable ✓ "Use Tailscale DNS settings"
4. Restart Tailscale app

**Fix (Linux client devices only — NOT server hosts):**

```bash
# Check if DNS is configured
resolvectl status

# Force DNS update (only on client devices like laptops, NOT on server VMs/LXCs)
sudo tailscale down
sudo tailscale up --accept-dns
```

**Note:** On server hosts, `accept-dns` must remain `false`. See "DNS: accept-dns must be false on server hosts" above.

#### Problem: DNS leak test shows café/hotel ISP

**Symptoms:** dnsleaktest.com shows local network's provider instead of Quad9

**Diagnosis:** DNS queries not tunneling through Tailscale

**Fix:**

1. Verify Tailscale is connected: `tailscale status`
2. Check DNS settings in Tailscale admin console
3. Verify AdGuard Tailscale IP is correct
4. Enable "Use Tailscale DNS settings" in app
5. Restart device if needed

#### Problem: Can't connect to Tailscale

**Symptoms:** `tailscale status` shows "Logged out" or connection fails

**Fix:**

```bash
# Re-authenticate
sudo tailscale up

# Check firewall isn't blocking
# Tailscale needs UDP port 41641 and HTTPS (443) access

# Check logs
journalctl -u tailscaled -n 50
```

#### Problem: Slow DNS resolution when traveling

**Symptoms:** Websites take long to load, DNS timeouts

**Possible causes:**

1. Poor connection between you and home
2. AdGuard/Unbound issues at home
3. Quad9 upstream issues

**Diagnosis:**

```bash
# Test direct connectivity to home
ping 100.108.0.112  # AdGuard Tailscale IP

# Test DNS directly
dig @100.108.0.112 google.com

# Check if using DERP relay (slower than direct)
tailscale status  # Look for "relay" vs "direct" in output
```

**Fix:**

- If using relay: Wait for direct connection to establish, or restart Tailscale
- If AdGuard is slow: SSH to AdGuard and check logs
- If persistent: Temporarily disable Tailscale DNS to use local network

#### Problem: AdGuard web UI not accessible via Tailscale

**Symptoms:** http://100.108.0.112 times out

**Diagnosis:**

```bash
# Can you ping AdGuard?
ping 100.108.0.112

# Is AdGuard listening on all interfaces?
ssh root@192.168.2.111  # Local IP
ss -tlnp | grep 80
# Should show: *:80 (not 127.0.0.1:80 or 192.168.2.111:80)
```

**Fix:** If AdGuard is only listening on specific IP:

1. Open AdGuard web UI (http://192.168.2.111)
2. Settings → General Settings
3. Set "Bind host" to "All interfaces" or add Tailscale IP
4. Restart AdGuard

### Connection Quality

If direct connections fail, Tailscale falls back to DERP relays (higher latency but still works):

```bash
# Check connection type
tailscale status
# Look for "relay" vs "direct" in output
```

Direct connections are preferred but relays ensure it always works.

### Restart Tailscale

```bash
# On any host
systemctl restart tailscaled
tailscale up  # Re-authenticate if needed

# On macOS
# Quit and reopen Tailscale app
```

### Remove a Device

```bash
# On the device
tailscale down

# Or remove from admin console:
# https://login.tailscale.com/admin/machines
```

## Advanced Configuration

### Subnet Routing

To access the entire local network (192.168.2.x) through Tailscale, configure Proxmox as a subnet router:

Edit `host_vars/pve.yml`:

```yaml
tailscale_advertise_routes: "192.168.2.0/24"
```

Redeploy:

```bash
make tailscale LIMIT=pve
```

Approve routes in admin console: https://login.tailscale.com/admin/machines

Then enable route acceptance on your laptop:

```bash
tailscale up --accept-routes
```

Now you can access local IPs directly:

```bash
ssh john@192.168.2.105  # Works via Proxmox subnet route
```

**Note:** With subnet routing, you can use `192.168.2.111` for AdGuard instead of the Tailscale IP when traveling.
However, the Tailscale IP approach is more explicit and doesn't require subnet routing to be configured.

### Exit Node

Route all your laptop traffic through your homelab (useful for privacy on untrusted networks):

Configure Proxmox as exit node in `host_vars/pve.yml`:

```yaml
tailscale_exit_node: true
```

Enable on your laptop:

```bash
tailscale up --exit-node=proxmox-host
```

**With exit node enabled:**

- ALL internet traffic routes through your home connection
- Your public IP appears as your home IP (188.142.8.214)
- Slower (all traffic has VPN overhead)
- Maximum privacy on untrusted networks

**Without exit node (current setup):**

- Only DNS queries route through home
- Your public IP is the local network's IP
- Faster (only DNS has VPN overhead)
- Good privacy for most use cases

### SSH Hardening

Restrict SSH to only accept connections from Tailscale interface.

Edit `/etc/ssh/sshd_config` on each host:

```
# Only listen on Tailscale interface
ListenAddress 100.64.0.X  # Replace with actual Tailscale IP
ListenAddress 127.0.0.1   # Keep localhost for local access
```

Restart SSH:

```bash
systemctl restart sshd
```

**WARNING**: Test thoroughly before disabling local SSH. If Tailscale breaks, you'll lose SSH access.

### Access Control Lists (ACLs)

Restrict which devices can access which services using Tailscale ACLs: https://login.tailscale.com/admin/acls

Example ACL:

```json
{
 "acls": [
  {
   "action": "accept",
   "src": ["tag:laptop"],
   "dst": ["tag:homelab:*"]
  },
  {
   "action": "accept",
   "src": ["tag:homelab"],
   "dst": ["tag:homelab:*"]
  }
 ],
 "tagOwners": {
  "tag:laptop": ["your-email@example.com"],
  "tag:homelab": ["your-email@example.com"]
 }
}
```

## Monitoring

Tailscale integrates with your existing Prometheus setup via node_exporter. The Tailscale interface appears as
`tailscale0` in network metrics.

Add custom metrics (optional):

```yaml
# In prometheus config
- job_name: "tailscale"
  static_configs:
   - targets:
      - "100.99.115.121:9100" # Proxmox
      - "100.108.0.112:9100" # AdGuard
      - "100.88.114.14:9100" # Media
      - "100.64.76.3:9100" # Infra
```

## Security Considerations

1. **Auth key rotation**: Regenerate keys periodically (every 90 days recommended)
2. **Device approval**: Review and approve new devices in admin console
3. **Key expiry**: Set reasonable expiration on auth keys
4. **MFA**: Enable 2FA on your Tailscale account
5. **ACLs**: Implement least-privilege access policies
6. **Audit logs**: Review connection logs in admin console periodically
7. **DNS privacy**: Verify DNS leak tests regularly when traveling
8. **Exit node usage**: Only enable when needed (adds latency)

## Privacy Summary

**What your ISP (KPN) can see:**

- At home: Encrypted traffic to Quad9 (IP addresses only)
- Traveling: Encrypted Tailscale VPN traffic to your home IP

**What your ISP (KPN) cannot see:**

- Which domains you're looking up (DNS queries are encrypted)
- Which websites you're visiting (HTTPS encrypts the connection)
- Contents of your traffic (all encrypted)

**What café/hotel WiFi can see (with Tailscale connected):**

- Encrypted Tailscale VPN traffic to your home IP
- Cannot see: DNS queries, websites, or any traffic contents

**What Quad9 can see:**

- Your DNS queries (which domains you look up)
- But: Quad9 is a privacy-focused non-profit, doesn't sell data, Swiss jurisdiction

**What Tailscale can see:**

- Which devices are connected to your network
- Connection metadata (when devices connect)
- Cannot see: Your traffic contents (end-to-end encrypted)

## Hybrid Architecture

You now have two access methods:

**Cloudflare Tunnel** (existing):

- Web services: Immich, Jellyfin
- Public access with Zero Trust authentication
- HTTPS with automatic certs
- No VPN required for users

**Tailscale** (new):

- SSH and Ansible management
- Direct access to all services (including internal ones)
- Private network, no public exposure
- DNS privacy and ad blocking when traveling

Keep both! They serve different purposes:

- Cloudflare for sharing services with others
- Tailscale for your private management access and DNS privacy

## Cost

- **Free tier**: Up to 100 devices, 3 users (sufficient for homelab)
- **Personal Pro**: $48/year (more devices, better support)
- **Teams**: Starting at $5/user/month (advanced features)

For homelab use, the free tier is more than adequate.

## Quick Reference Commands

```bash
# Check Tailscale status
tailscale status

# Get your Tailscale IP
tailscale ip -4

# Test DNS
nslookup google.com

# Check DNS privacy
# Visit: https://www.dnsleaktest.com/

# Check AdGuard is working
# Visit: http://100.108.0.112 (AdGuard web UI)

# Restart Tailscale
sudo systemctl restart tailscaled

# Re-authenticate
sudo tailscale up

# Check accept-dns setting (should be false on server hosts)
tailscale debug prefs | grep CorpDNS

# Check connection quality
tailscale netcheck
```

## Additional Resources

- Official docs: https://tailscale.com/kb
- Admin console: https://login.tailscale.com/admin
- DNS settings: https://login.tailscale.com/admin/dns
- Status page: https://status.tailscale.com
- Community forum: https://forum.tailscale.com
- DNS leak testing: https://www.dnsleaktest.com/
- AdGuard docs: https://github.com/AdguardTeam/AdGuardHome/wiki
