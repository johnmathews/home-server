# Disaster Recovery

**Status:** current — verified 2026-08-22 · covers: live
Backup coverage, PBS retention and the restore procedure describe running systems, not
repo state — re-read them from PBS and `pve` rather than trusting the numbers.

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
| VMs (media, infra, nas, **home assistant**; mailcow retired) | PBS automated backup | Proxmox Backup Server |
| HA config (`/config`) | Git, separate private repo | GitHub (`johnmathews/home-assistant-config`) |
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
3. Run `make site` to provision everything from scratch. This includes Traefik —
   `playbooks/site.yml` omitted `traefik_lxc.yml` until 2026-08-22, so a rebuild
   run before that date left the reverse proxy undeployed and every public
   hostname 502ing
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

### Scenario 5: Reverse Proxy (Traefik) Failure

Traefik on `traefik_lxc` (192.168.2.108) is the **origin for every externally
reachable hostname**. Cloudflare Tunnel terminates at Traefik, not at the
individual services, so if Traefik is down or unconfigured *every* public
hostname returns 502 while the services behind it are perfectly healthy — and
the tunnel itself will look green in the Cloudflare dashboard.

The routed hostnames are defined in
`roles/traefik_lxc/templates/routers.yml.j2`, which is the source of truth:
`immich`, `share`, `jelly`, `navidrome`, `finances`, `music`, `timer`, `docs`,
`uptime`, `speed`, `sre`, `stats`, and the apex domain (`homepage`). Grafana is
proxied as a backend service. The Traefik dashboard is bound to the LAN address
only.

**Diagnosis — every public hostname 502s at once:**

1. `ssh traefik` then `docker compose ps` — is the `traefik` container up?
2. `docker compose logs traefik --tail 100` — look for router/TLS config errors
3. Check the local dashboard from the LAN: `http://192.168.2.108/dashboard/`
4. Confirm the service behind it is actually healthy (e.g. `ssh immich`,
   `docker compose ps`) before blaming the backend — a 502 here almost always
   means Traefik, not the service

**Recovery:** `make traefik` redeploys the container and re-renders
`routers.yml`. Traefik holds no persistent state that needs restoring from
backup; the whole configuration is templated from this repository.

### Scenario 6: Complete Infrastructure Loss

Worst case: everything is gone. Recovery order:

1. **Proxmox host** — Install Proxmox VE, configure networking
2. **TrueNAS VM** — Create VM, install TrueNAS, import ZFS pools (if disks survived)
3. **Cloudflared LXC** — `make cloudflared` (restores the tunnel)
4. **Traefik LXC** — `make traefik`. External access is *not* restored until this
   runs: the tunnel terminates at Traefik, so until it exists every public
   hostname 502s (see Scenario 5)
5. **Infra VM** — `make infra` (restores monitoring, so you can track remaining recovery)
6. **Remaining services** — `make site` or deploy individually

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
- `/config/.git-ssh/id_deploy` on the HA VM — write-scoped deploy key for the HA config repo.
  Gitignored by design, so it exists **only** inside VM 102 and its PBS backups.

### Home Assistant (VM 102) — a special case

HA is **not** managed by this Ansible repo, so it has two independent recovery paths:

1. **Restore VM 102 from PBS** (21 snapshots, daily — verified 2026-08-13). This is the normal
   path and recovers everything, including `.storage`, which holds integration credentials and
   Lovelace dashboards. Neither is in any git repo.
2. **Rebuild from scratch.** Config YAML comes from the private `johnmathews/home-assistant-config`
   repo, but `.storage` does not — so integration credentials must be re-entered. The Ansible
   vault holds `vault_home_connect_client_id` / `_secret` specifically so the Bosch Home Connect
   application does not have to be re-registered at developer.home-connect.com. Other
   integrations' credentials are **not** vaulted and would need re-authenticating.

Path 1 is strongly preferred. Path 2 exists because a corrupted-but-restorable `.storage` is a
plausible failure that a whole-VM restore does not always fix.
