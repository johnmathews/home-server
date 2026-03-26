# Upgrade Procedures

How to upgrade the various components of the home server infrastructure.

## Docker Image Version Bumps

Most services run as Docker containers with pinned image versions in role defaults.

### Per-service upgrade

1. Check the current version in `roles/<service>/defaults/main.yml`
2. Check the upstream release notes for breaking changes
3. Update the version variable (e.g., `jellyfin_version: "10.10.6"`)
4. Deploy: `make <service>`
5. Verify the service starts and works correctly
6. Check logs: `ssh <service>` then `docker logs <container_name>`

### Monitoring sidecar upgrades

Monitoring sidecars (node-exporter, cadvisor, alloy) are shared across all services.
Their versions are centralized in `group_vars/all/main.yml`:

```yaml
node_exporter_version: "v1.9.0"
cadvisor_version: "v0.51.0"
alloy_version: "v1.6.1"
```

To upgrade all sidecars at once, update the version in `group_vars/all/main.yml` and
run `make site`. To upgrade one host at a time, use `make <service>` for each.

## Ansible and Python Dependencies

### Ansible collections and roles

Versions are pinned in `requirements.yml`. To upgrade:

1. Edit `requirements.yml` — update the version for the collection/role
2. Run `make requirements` to install the new version
3. Test with `make check` (dry run) before applying

### Python packages

Python dependencies are in `requirements.txt`, managed with `uv`:

```sh
uv pip install -r requirements.txt
```

## Proxmox Host OS Updates

Proxmox updates are applied directly on the host, not via Ansible.

```sh
ssh pve
apt update && apt dist-upgrade -y
```

**Before upgrading:**
- Check the Proxmox release notes for breaking changes
- Ensure PBS backups are current
- Consider scheduling a maintenance window (services will be briefly unavailable during reboot)

**After upgrading:**
- Verify all VMs/LXCs started: `qm list` and `pct list`
- Check ZFS pool status: `zpool status`
- Verify PBS backups still run

### Proxmox major version upgrades

Follow the official Proxmox upgrade guide. Major version upgrades (e.g., 8.x to 9.x)
require careful planning:

1. Read the official migration guide thoroughly
2. Ensure full PBS backup of all VMs/LXCs
3. Test the upgrade on a non-production system if possible
4. Run the Proxmox upgrade checklist script if provided

## LXC/VM OS Updates

For Debian-based LXCs and VMs, OS updates are applied directly:

```sh
ssh <host>
apt update && apt upgrade -y
```

This is separate from the Ansible-managed service configuration. Ansible manages the
application layer (Docker containers, config files), not the base OS packages (except
for dependencies it installs).

## TrueNAS Updates

TrueNAS updates are applied through the TrueNAS web UI:

1. Access TrueNAS UI at `192.168.2.104` or `nas.itsa-pizza.com`
2. Go to System > Update
3. Review release notes
4. Create a boot environment snapshot (automatic)
5. Apply the update

**Before upgrading:**
- Verify all shares are accessible
- Check pool health: Storage > Pools
- Ensure the encryption key server is accessible

## Service-Specific Upgrade Notes

### Jellyfin

Jellyfin major version upgrades (e.g., 10.9.x to 10.10.x) can introduce breaking
changes. Check the Jellyfin release notes carefully. Known issues with specific
versions are documented in `documentation/jellyfin_lxc.md`.

### Immich

Immich releases frequently with breaking changes. Always read the release notes.
The machine learning model may need to re-index after upgrades.

### Paperless-ngx

Database migrations run automatically on container startup. Ensure the PostgreSQL
container is healthy before upgrading the Paperless container.

### Grafana / Prometheus / Loki

These are deployed on the infra VM. Upgrade them together when possible to avoid
version compatibility issues. Check the Grafana compatibility matrix.

## Rollback Procedure

### Docker services

Rolling back a Docker service is straightforward:

1. Revert the version variable in `roles/<service>/defaults/main.yml`
2. Run `make <service>`
3. Docker will pull the previous image version and restart

### Proxmox host

If a Proxmox update causes issues:
- Boot into the previous kernel from the GRUB menu
- Or restore from PBS backup

### TrueNAS

TrueNAS creates boot environment snapshots before updates. To roll back:
- System > Boot > Select previous boot environment > Activate

## Pre-Upgrade Checklist

```
[ ] Check upstream release notes for breaking changes
[ ] Verify PBS backups are current
[ ] Note current working versions (in case rollback is needed)
[ ] Plan maintenance window if service downtime is expected
[ ] Test in dry-run mode where possible (make check)
[ ] Deploy the upgrade
[ ] Verify service health
[ ] Check Prometheus targets are all UP
[ ] Check Grafana dashboards for anomalies
[ ] Update version in documentation if applicable
```
