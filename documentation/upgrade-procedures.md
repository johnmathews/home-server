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

### Update notifications

Update visibility comes from the **container-status-exporter** (infra VM): every 6h
it compares each running container's image digest against its registry. Three
surfaces, all fed by the same data:

1. **Image Freshness dashboard** — `charts.itsa-pizza.com/d/image-freshness`:
   current vs available for all ~108 containers on 12 hosts, auto-discovered (no
   watch list to maintain).
2. **"App update available" alert** — Pushover within a day when a *tracked app's
   running* image falls behind: immich_server, jellyfin, navidrome, open-webui
   (edit the `container_name` regex in the Grafana rule to change the set).
3. **"Container image stale" alert** — weekly Pushover digest of anything >30 days
   behind, as the safety net for the long tail.

(Diun was retired 2026-07-13 — it duplicated this with a hand-maintained watch
list and no knowledge of running state.)

**Known blind spot:** jellyfin runs a locally-built image
(`jellyfin-with-yt-dlp`), so the exporter reports it as `local` and can never mark
it outdated — no automatic signal exists for new Jellyfin releases. Run
`make jelly-upgrade` periodically, or add base-image freshness for local builds to
the exporter (tracked as a follow-up).

When a notification arrives:

- **Jellyfin** → `make jelly-upgrade` (pull base, rebuild local image, recreate,
  health-check)
- **Immich** → read the release notes, then `make immich-upgrade`
- **Anything else** → `ssh <host> 'docker pull <image>'` then `make <host>`
  (handlers use `pull: never`, so pulling first is required)

### Monitoring sidecar upgrades

Monitoring sidecars (node-exporter, cadvisor, alloy) run on every service host. Since
2026-07-12 the pinned versions are single-sourced in `group_vars/all/main.yml`:
`sidecar_alloy_version`, `sidecar_node_exporter_version`, `sidecar_cadvisor_version`.
The roles that pin (immich, infra_vm, pve, media_vm, open_webui, tubearchivist)
reference these in their own defaults (`alloy_version: "{{ sidecar_alloy_version }}"`).

Two exceptions:

- Roles that deliberately track `latest` keep their own literal defaults and are
  unaffected by the `sidecar_*` values: agent, music, prometheus, traefik,
  document_library.
- `jellyfin_lxc` deploys a static `files/docker-compose.yml` (not a template), so its
  sidecar pins are literal in that file — update it by hand when bumping `sidecar_*`.

To upgrade sidecars: bump the `sidecar_*` versions in `group_vars/all/main.yml`, edit
the jellyfin static compose to match, then `make <service>` per host (or `make site`).
Note the compose handlers use `pull: never` — pre-pull new images on each host (or
temporarily allow pulling) before recreating.

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

Jellyfin tracks `latest` — but only at image-pull time. The app image is a local build
(`jellyfin-with-yt-dlp:latest`, `FROM jellyfin/jellyfin:latest` + yt-dlp + the ffprobe
ulimit wrapper), and the handlers use `pull: never`, so the base stays frozen until you
pull. To upgrade:

```sh
ssh jelly
docker pull jellyfin/jellyfin:latest
cd /srv/apps && docker compose build jellyfin && docker compose up -d jellyfin
```

Major version upgrades (e.g., 10.10.x to 10.11.x) can introduce breaking changes —
check the release notes. Known issues per version are in `documentation/jellyfin_lxc.md`.

### Immich

Immich server + machine-learning track the official rolling `release` tag
(`IMMICH_VERSION=release` in the .env). Same pull-time caveat: `make immich` recreates
onto whatever `release` image is cached locally. To upgrade:

```sh
ssh immich
docker pull ghcr.io/immich-app/immich-server:release
docker pull ghcr.io/immich-app/immich-machine-learning:release
```

then `make immich` from the repo. Read the release notes first — Immich still ships
breaking changes, and the mobile app generally wants a matching server version. The
ML model may re-index after upgrades. Do NOT move `immich_postgres` (pinned
`14-vectorchord`) or valkey to newer tags casually — database major upgrades need a
migration plan.

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
