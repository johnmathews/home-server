# Tailscale Setup Quick Start

This guide gets you up and running with Tailscale remote access in ~30 minutes.

## What You'll Get

After following this guide, you can run Ansible playbooks and SSH into your homelab from anywhere in the world (coffee shops, hotels, airports) as if you were at home.

## Prerequisites

- [ ] Tailscale account (free): https://tailscale.com
- [ ] SSH access to your homelab (currently on local network)

## Step-by-Step Setup

### 1. Generate Tailscale Auth Key (2 minutes)

Visit: https://login.tailscale.com/admin/settings/keys

Click "Generate auth key" with these settings:
- **Expiration**: 90 days
- **Reusable**: ✓ (checked)
- **Ephemeral**: ✗ (unchecked)
- **Tags**: Leave empty

Copy the key (starts with `tskey-auth-...`)

### 2. Add Key to Vault (2 minutes)

Edit your vault file:
```bash
ansible-vault edit group_vars/all/vault.yml
```

Add this line:
```yaml
tailscale_auth_key: "tskey-auth-PASTE-YOUR-KEY-HERE"
```

Save and exit.

### 3. Prepare LXC Containers (2 minutes)

**IMPORTANT**: LXC containers need special configuration to support VPN software. Run this ONCE:

```bash
# Prepare all LXCs for Tailscale (adds TUN device access)
make tailscale-prep
```

This configures all LXC containers and reboots them. Only needed once.

### 4. Deploy Tailscale to Homelab (5-10 minutes)

```bash
# From your homelab (on local network)
make tailscale
```

This installs Tailscale on all your VMs and LXCs. Wait for it to complete.

### 4. Collect Tailscale IPs (2 minutes)

```bash
./scripts/collect-tailscale-ips.sh
```

This shows a table like:
```
┌──────────────────────┬─────────────────┬───────────────────┐
│ Host                 │ Local IP        │ Tailscale IP      │
├──────────────────────┼─────────────────┼───────────────────┤
│ proxmox_host         │ 192.168.2.214   │ 100.64.0.1        │
│ media_vm             │ 192.168.2.105   │ 100.64.0.5        │
│ infra_vm             │ 192.168.2.106   │ 100.64.0.8        │
...
```

### 5. Update Inventory File (3 minutes)

Edit `inventory-tailscale.ini` and replace the placeholder IPs (100.x.x.x) with the actual Tailscale IPs from the table above.

Example:
```ini
[media]
media_vm ansible_host=100.64.0.5 ansible_user=john ansible_ssh_private_key_file=~/.ssh/john_macbook
```

### 6. Install Tailscale on Your Laptop (3 minutes)

**macOS**:
```bash
brew install tailscale
sudo tailscale up
```

**Linux**:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Windows**:
Download from: https://tailscale.com/download/windows

A browser will open - sign in with the same account you used in step 1.

### 7. Test It! (2 minutes)

Test SSH:
```bash
ssh root@100.64.0.1  # Proxmox (use actual IP from step 4)
ssh john@100.64.0.5  # Media VM (use actual IP from step 4)
```

Test Ansible:
```bash
ansible all -i inventory-tailscale.ini -m ping
```

If you see green "SUCCESS" messages, you're done!

## Using Tailscale

### At Home (Local Network)

```bash
# Use regular inventory
make media
make site
```

### While Traveling (Remote Access)

```bash
# Use Tailscale inventory
ansible-playbook -i inventory-tailscale.ini playbooks/media_vm.yml --vault-password-file=.vault_pass.txt

# Or for specific playbooks
ansible-playbook -i inventory-tailscale.ini playbooks/site.yml --vault-password-file=.vault_pass.txt
```

### Accessing Web Services

You can also access web services directly via Tailscale:

```bash
# Prometheus (not publicly exposed)
open http://100.64.0.7:9090

# Grafana
open http://100.64.0.8:3000

# Proxmox UI
open https://100.64.0.1:8006
```

## Troubleshooting

**"Connection refused" when testing SSH?**
- Check Tailscale is running: `tailscale status`
- Verify you're using the correct Tailscale IP from step 4

**Ansible ping fails?**
- Double-check IPs in `inventory-tailscale.ini` match output from step 4
- Ensure SSH keys are correct (`~/.ssh/john_macbook`)

**Need to regenerate auth key?**
- Keys expire based on the expiration you set (default 90 days)
- Generate a new one at: https://login.tailscale.com/admin/settings/keys
- Update `group_vars/all/vault.yml` and run `make tailscale` again

## Full Documentation

See `documentation/tailscale.md` for:
- Advanced configuration (subnet routing, exit nodes, ACLs)
- Security hardening (SSH restrictions, MFA)
- Monitoring integration
- Troubleshooting guide

## Getting Help

- Tailscale docs: https://tailscale.com/kb
- Admin console: https://login.tailscale.com/admin
- Your homelab docs: `documentation/tailscale.md`
