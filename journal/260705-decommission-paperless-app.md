# Decommission paperless app; rename ansible layer to document_library

**Date:** 2026-07-05. Executed the plan in [260704-decommission-paperless-app.md](260704-decommission-paperless-app.md).
Branch `library/decommission-paperless`, merged fast-forward to `main`.

## What changed

**Ansible layer renamed `paperless_lxc → document_library_lxc`** (identifiers use underscores;
the Makefile target uses a hyphen — `make document-library` — matching `open-webui → open_webui_lxc`):

- `git mv` role dir, playbook, host_vars.
- `inventory.ini` + `inventory-tailscale.ini`: group `[paperless] → [document_library]`,
  host `paperless_lxc → document_library_lxc` (kept `ansible_host=192.168.2.117` / tailscale
  `100.100.7.47`), and every `:children` membership.
- `playbooks/site.yml`, playbook `hosts`/`name`/role, `makefile` target + `.PHONY`.
- `scripts/collect-tailscale-ips.sh` label.

**Paperless app removed from the role:**

- Compose template: deleted the (commented) `paperless-db`/`-webserver`/`-broker` services; fixed the
  header comment. Kept all `library-*` + `node_exporter`/`alloy`/`cadvisor`.
- `.env.j2`: dropped the whole Paperless-ngx section and the now-unused `PUID`/`PGID` lines (no remaining
  compose service consumes them). Kept `TZ` and the Library block.
- `tasks/main.yml`: removed the paperless user/group creation, the `/srv/apps/paperless/*` dirs, the
  `mount-smb.yml` import, and the consumer-health cron. Added a `state: absent` task to strip the stale
  cron from the host crontab (verified it removed the real entry). Repointed the alloy config-upload
  ownership to `root:root` (the paperless uid 1001 is no longer created locally).
- `handlers/main.yml`: removed the `Restart paperless` handler; added `remove_orphans: true` to
  `Restart all containers` so the deploy drops the stopped paperless containers. Repointed the `.env`
  task's notify to `Restart all containers`.
- `defaults/main.yml`: removed `paperless_version` and the unused SMB block.
- `host_vars/document_library_lxc.yml`: removed the paperless `nfs_shares`/`smb_shares` entries, the
  commented paperless `sleep_hours_stop_containers`, the `paperless-graceful.sh` plugin, and the
  `sleep_hours_kuma_map` paperless-webserver monitor (now `{}`).
- `git rm` `roles/sleep_hours/files/plugins/paperless-graceful.sh` and the role's `mount-smb.yml`.

**Monitoring / homepage / docs:**

- Homepage `services.yaml.j2`/`bookmarks.yaml.j2`: replaced the Paperless tile+bookmark (dead `:8000`)
  with Library (`:8010`); renamed "Paperless Alloy" → "Library Alloy".
- `mkdocs.yml.j2`: dropped the `paperless.md` nav entry.
- `documentation/paperless.md` → `documentation/archive/paperless.md` with a superseded header.
- `CLAUDE.md`: network table host + services, the naming-convention example (switched to `immich_lxc`),
  the "good reference" line, and the doc index.

## What was deliberately kept

- **Runtime hostname `paperless`** (`NODE_HOSTNAME`, `hostname="paperless"` metric labels, Proxmox
  guest CT/117, PBS backup identity) — untouched, so metric/backup continuity holds.
- **All paperless data** — TrueNAS `tank/paperless` dataset + NFS/SMB shares,
  `/srv/apps/paperless/{pgdata,redisdata,data}`, `/mnt/nfs/paperless/*`. No `rm`/`zfs destroy` run.
- Prometheus host-level scrape targets and the Grafana guest variable (guest not renamed) — the
  `hostname="paperless"` targets still resolve to the library host.
- Shared vars `puid`/`guid` in `group_vars/all/main.yml`.

## Left as follow-ups (out of this brief's scope — flagged, not changed)

These still reference paperless but point at resources that are intentionally still alive, or belong to
other roles:

- `roles/cloudflared_lxc/defaults/main.yml` + `scripts/cf-create-dns-records.sh`: `paperless.*` and
  `documents.*` still route/resolve to the dead app port `:8000`. Removing or repointing them to library
  is a routing decision, not part of "decommission the app".
- `roles/nas/defaults/main.yml` `refresh_shares_nfs_path: tank/paperless` — still a valid share.
- `roles/open_webui_lxc` `smb_shares` paperless entry + a stale header comment.

## Verification (all green)

- `ansible-lint` clean (no findings in `document_library_lxc`); `pytest` 7 passed.
- `--check --diff --tags docker` rendered with no paperless services and no undefined vars.
- `make document-library tags=docker`: `failed=0`.
- On the box: `docker ps` shows only `library-*` + `node_exporter`/`alloy`/`cadvisor` (no `paperless-*`,
  orphans dropped); `curl :8010/api/settings` = 401; `/healthz` = 200; worker watching `/consume`.
- Prometheus `up{hostname="paperless"}` = 1 for both cadvisor and node_exporter.
