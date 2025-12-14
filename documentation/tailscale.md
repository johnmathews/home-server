# Tailscale Remote Access Setup

This guide covers setting up Tailscale VPN for remote SSH/Ansible access to your homelab while traveling.

## What is Tailscale?

Tailscale is a zero-config mesh VPN built on WireGuard that creates direct encrypted connections between your devices. It allows you to access your homelab from anywhere (coffee shops, hotels, airports) as if you were on your local network.

**Key benefits**:
- **Zero configuration**: Install, authenticate, and it works
- **Direct connections**: Peer-to-peer when possible (fast)
- **Works everywhere**: Automatic NAT traversal through firewalls
- **Transparent to apps**: SSH and Ansible work without modification
- **Secure**: WireGuard encryption, no exposed ports on your router

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

### 2. Deploy Tailscale to All Hosts

Run the playbook to install and configure Tailscale on all VMs and LXCs:

```bash
# Deploy to all hosts
make tailscale

# Or deploy to specific host
make tailscale LIMIT=media_vm

# Or use Ansible directly
ansible-playbook -i inventory.ini playbooks/tailscale.yml --vault-password-file=.vault_pass.txt
```

This will:
- Install Tailscale on each host
- Authenticate with your Tailscale network
- Start the Tailscale daemon
- Display the assigned Tailscale IP

### 3. Collect Tailscale IP Addresses

After deployment, get the Tailscale IP for each host:

```bash
# From your local machine
ssh john@192.168.2.105 "tailscale ip -4"
# Output: 100.64.0.5

# Or SSH to each host and run:
tailscale status
```

### 4. Update Tailscale Inventory

Edit `inventory-tailscale.ini` and replace the placeholder IPs (100.x.x.x) with actual Tailscale IPs:

```ini
[media]
media_vm ansible_host=100.64.0.5 ansible_user=john ansible_ssh_private_key_file=~/.ssh/john_macbook

[infra]
infra_vm ansible_host=100.64.0.8 ansible_user=john ansible_ssh_private_key_file=~/.ssh/john_macbook
```

### 5. Install Tailscale on Your Laptop

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

**Windows**:
Download installer from: https://tailscale.com/download/windows

### 6. Test Remote Access

Test SSH access using Tailscale IPs:

```bash
# Test SSH to Proxmox
ssh root@100.64.0.1

# Test SSH to Media VM
ssh john@100.64.0.5

# Test Ansible
ansible all -i inventory-tailscale.ini -m ping
```

## Usage

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
# Prometheus (not exposed via Cloudflare)
open http://100.64.0.7:9090

# Grafana
open http://100.64.0.8:3000

# Proxmox UI
open https://100.64.0.1:8006
```

### MagicDNS (Optional)

Tailscale provides automatic DNS for your devices. Enable MagicDNS in the admin console:
https://login.tailscale.com/admin/dns

Then access hosts by name:
```bash
ssh john@media-vm
ssh root@proxmox-host
open http://prometheus-lxc:9090
```

## Advanced Configuration

### Subnet Routing

To access the entire local network (192.168.2.x) through Tailscale, configure Proxmox as a subnet router:

Edit `host_vars/proxmox_host.yml`:
```yaml
tailscale_advertise_routes: "192.168.2.0/24"
```

Redeploy:
```bash
make tailscale LIMIT=proxmox_host
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

### Exit Node

Route all your laptop traffic through your homelab (useful for privacy on untrusted networks):

Configure Proxmox as exit node in `host_vars/proxmox_host.yml`:
```yaml
tailscale_exit_node: true
```

Enable on your laptop:
```bash
tailscale up --exit-node=proxmox-host
```

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

Restrict which devices can access which services using Tailscale ACLs:
https://login.tailscale.com/admin/acls

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

## Troubleshooting

### Check Tailscale Status

```bash
# On any host
tailscale status

# Get IP addresses
tailscale ip -4
tailscale ip -6

# View network map
tailscale netcheck

# Check logs
journalctl -u tailscaled -f
```

### Connection Issues

If direct connections fail, Tailscale falls back to DERP relays (higher latency but still works):

```bash
# Check connection type
tailscale status
# Look for "relay" vs "direct" in output
```

### Restart Tailscale

```bash
systemctl restart tailscaled
tailscale up  # Re-authenticate if needed
```

### Remove a Device

```bash
# On the device
tailscale down

# Or remove from admin console:
# https://login.tailscale.com/admin/machines
```

## Monitoring

Tailscale integrates with your existing Prometheus setup via node_exporter. The Tailscale interface appears as `tailscale0` in network metrics.

Add custom metrics (optional):
```yaml
# In prometheus config
- job_name: 'tailscale'
  static_configs:
    - targets:
      - '100.64.0.1:9100'  # Proxmox
      - '100.64.0.5:9100'  # Media
      - '100.64.0.8:9100'  # Infra
```

## Security Considerations

1. **Auth key rotation**: Regenerate keys periodically (every 90 days recommended)
2. **Device approval**: Review and approve new devices in admin console
3. **Key expiry**: Set reasonable expiration on auth keys
4. **MFA**: Enable 2FA on your Tailscale account
5. **ACLs**: Implement least-privilege access policies
6. **Audit logs**: Review connection logs in admin console periodically

## Hybrid Architecture

You now have two access methods:

**Cloudflare Tunnel** (existing):
- Web services: Immich, Jellyfin
- Public access with Zero Trust authentication
- HTTPS with automatic certs

**Tailscale** (new):
- SSH and Ansible management
- Direct access to all services (including internal ones)
- Private network, no public exposure

Keep both! They serve different purposes:
- Cloudflare for sharing services with others
- Tailscale for your private management access

## Cost

- **Free tier**: Up to 100 devices, 3 users (sufficient for homelab)
- **Personal Pro**: $48/year (more devices, better support)
- **Teams**: Starting at $5/user/month (advanced features)

For homelab use, the free tier is more than adequate.

## Additional Resources

- Official docs: https://tailscale.com/kb
- Admin console: https://login.tailscale.com/admin
- Status page: https://status.tailscale.com
- Community forum: https://forum.tailscale.com
