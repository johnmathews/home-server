# Upgrade Procedures

How to upgrade the various components of the home server infrastructure.

## Docker Image Version Bumps

Most services run as Docker containers with pinned image versions in role defaults.

### Per-service upgrade

1. Check the current version in `roles/<service>/defaults/main.yml`
2. Check the upstream release notes for breaking changes
3. Update the version variable (e.g., `tubearchivist_version: "v0.5.10"`)
4. Pull the new image on the host: `ssh <host> "cd /srv/<stack> && docker compose pull <service>"`
5. Deploy: `make <service>`
6. Verify the service starts and works correctly
7. Check logs: `ssh <service>` then `docker logs <container_name>`

**Note:** Ansible handlers use `pull: never` — they will not pull images automatically.
You must pull new images manually (step 4) before deploying. This prevents unexpected
image changes during config-only deploys.

### Monitoring sidecar upgrades

Monitoring sidecars (node-exporter, cadvisor, alloy) run on every service host, but their
versions are **not** centralized — each role pins its own in
`roles/<role>/defaults/main.yml` (`node_exporter_version`, `cadvisor_version`,
`alloy_version`), and the values differ per role (some pin e.g. `v1.8.2`/`v0.49.1`/`v1.5.1`,
others use `latest`). The exception is `jellyfin_lxc`, which uses static files rather than
templates, so its sidecar versions are hardcoded in the role's compose file. Only
`atuin_version` is global in `group_vars/all/main.yml`.

To upgrade sidecars, update the version in each role's `defaults/main.yml` (and the
jellyfin_lxc static compose file) and run `make <service>` per host, or `make site` after
updating all roles.

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

### Library (document store)

The `library` app (`ghcr.io/johnmathews/library`, replaced Paperless-ngx in July 2026) is
pinned via `library_version` in `roles/document_library_lxc/defaults/main.yml`. Deploy with
`make document-library`. Never let the deployed version pin drop below the running image —
a downgrade can corrupt the database (see the Paperless LXC recreate landmine notes).
Ensure the PostgreSQL container is healthy before upgrading.

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
