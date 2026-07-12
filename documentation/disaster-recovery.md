# Disaster Recovery

How to recover the home server infrastructure from various failure scenarios.

## Backup Architecture

### Proxmox Backup Server (PBS)

- **Host:** 192.168.2.200 (`ssh pbs`)
- **Purpose:** Automated backups of all VMs and LXCs
- **Storage:** Dedicated disk on the PBS host (192.168.2.200)
- **Schedule:** Configured in Proxmox UI under Datacenter > Backup

PBS stores full and incremental backups of each VM/LXC. Each backup includes the
complete disk image and configuration.

### What Is Backed Up

| Component       | Backup Method          | Location              |
|-----------------|------------------------|-----------------------|
| VMs (media, infra, nas; mailcow retired) | PBS automated backup | Proxmox Backup Server |
| LXCs (all)      | PBS automated backup   | Proxmox Backup Server |
| Ansible config  | Git (this repository)  | GitHub                |
| Vault secrets   | Git (encrypted)        | GitHub (vault.yml)    |
| TrueNAS data    | ZFS snapshots + PBS    | TrueNAS + PBS         |
| Docker volumes  | Inside VM/LXC backups  | PBS (via VM backup)   |

### What Is NOT Backed Up (Ephemeral)

- Docker images (re-pulled on deploy)
- Log data in Loki (can be regenerated from Alloy)
- Prometheus metrics history (loss acceptable for home server)
- Cached data (Jellyfin metadata, Immich thumbnails — regenerated automatically)

## Recovery Scenarios

### Scenario 1: Single LXC/VM Failure

The most common scenario. A container or VM stops working, gets corrupted, or
needs to be rebuilt.

**Option A: Restore from PBS backup**

1. Open Proxmox UI at `https://192.168.2.214:8006`
2. Go to Datacenter > Storage > select the PBS storage
3. Find the backup for the failed VM/LXC
4. Click Restore, select the target node and storage
5. Start the restored VM/LXC
6. Verify networking (static IP should be preserved in the backup)
7. Verify services: `ssh <host>` then `docker ps`

**Option B: Rebuild from Ansible**

If the backup is stale or you want a clean rebuild:

1. Create a new LXC/VM in Proxmox UI with the same VMID and network config
2. Ensure SSH access works: `ssh <host>`
3. Run the Ansible playbook: `make <service>`
4. Ansible will install Docker, deploy all containers, and configure everything

Note: Option B gives you a clean state but loses any data stored in Docker volumes
that isn't on NFS mounts. For services with persistent data (databases, config), prefer
Option A.

### Scenario 2: Proxmox Host Failure

If the Proxmox host itself fails (hardware failure, corrupted OS).

**Recovery steps:**

1. Install Proxmox VE on the replacement hardware
2. Configure networking (static IP 192.168.2.214)
3. Add the PBS storage to the new Proxmox installation
4. Restore all VMs and LXCs from PBS backups
5. Verify all services come up correctly

**If PBS backups are unavailable:**

1. Install Proxmox VE
2. Create all LXCs/VMs manually (use `inventory.ini` for IP assignments)
3. Run `make site` to provision everything from scratch
4. Restore data from TrueNAS NFS shares (media, photos, documents are on TrueNAS)

### Scenario 3: TrueNAS Failure

TrueNAS hosts all persistent data (media, photos, documents) on ZFS pools.

**If the TrueNAS VM is corrupted but disks are fine:**

1. Restore the TrueNAS VM from PBS backup
2. Import the existing ZFS pools
3. Verify shares are accessible from other VMs/LXCs

**If ZFS pool is degraded (disk failure):**

1. Access TrueNAS UI
2. Check pool status: Storage > Pools
3. Replace the failed disk and resilver
4. ZFS mirrors/RAIDZ will rebuild automatically

**If encryption keys are needed:**

The key server at 192.168.2.201 serves TrueNAS dataset encryption keys.
See `documentation/key_server.md` for details.

### Scenario 4: Network Failure (Cloudflare Tunnel)

If external access stops working:

1. Check Cloudflare dashboard for tunnel status
2. SSH to cloudflared LXC: `ssh cloudflared`
3. Check service: `systemctl status cloudflared`
4. Check logs: `journalctl -u cloudflared -f`
5. Restart if needed: `systemctl restart cloudflared`
6. If the tunnel credential is lost, recreate: see `documentation/cloudflared.md`

Local network access (192.168.2.x) is independent of Cloudflare and should still work.

### Scenario 5: Complete Infrastructure Loss

Worst case: everything is gone. Recovery order:

1. **Proxmox host** — Install Proxmox VE, configure networking
2. **TrueNAS VM** — Create VM, install TrueNAS, import ZFS pools (if disks survived)
3. **Cloudflared LXC** — `make cloudflared` (restores external access)
4. **Infra VM** — `make infra` (restores monitoring, so you can track remaining recovery)
5. **Remaining services** — `make site` or deploy individually

The Ansible repository is the recovery runbook. As long as you have:
- This git repository
- The vault password (`.vault_pass.txt`)
- Access to the hardware

You can rebuild everything.

## Recovery Time Expectations

| Scenario                    | Expected Recovery Time |
|-----------------------------|------------------------|
| Single LXC from PBS backup | 5-15 minutes           |
| Single LXC from Ansible    | 10-30 minutes          |
| Proxmox host reinstall     | 1-2 hours              |
| Full infrastructure rebuild | 4-8 hours             |

## Testing Backups

Periodically verify that backups are actually restorable:

1. Check PBS backup status in Proxmox UI
2. Test-restore a non-critical LXC to verify the process works
3. Verify the vault password decrypts `vault.yml`: `ansible-vault view group_vars/all/vault.yml`

## Critical Files to Protect

These files are essential for recovery and must not be lost:

- `.vault_pass.txt` — Ansible vault password (not in git, store securely offline)
- `~/.ssh/john_macbook` — SSH private key for all hosts
- This git repository — the complete infrastructure definition
- PBS datastore — VM/LXC backups
