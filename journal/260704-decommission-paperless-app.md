# Decommission paperless app, rename ansible layer to library

**Status:** planned brief for a fresh session (written 2026-07-04). Not yet executed.

## 1. Goal & decisions

Cut over 100% to the **library** app and remove the **paperless** application from the
`proxmox-setup` repo. Two scoping decisions were made:

1. **Rename scope = "rename the ansible layer, keep the runtime hostname".** Rename the
   role/playbook/inventory-group/host_vars/Makefile-target `paperless_lxc → document_library_lxc`
   (ansible identifiers use underscores; the Makefile target uses a hyphen: `document-library`).
   Only the ANSIBLE LAYER is renamed — the app itself stays `library` (the `library-*` containers,
   `LIBRARY_*` env, `/srv/apps/library`, `document-store` are unchanged). Keep the container's
   **runtime hostname `paperless`** so all monitoring labels
   (`hostname="paperless"` in Prometheus/Loki/Grafana/cadvisor), `NODE_HOSTNAME`, and the
   **PBS backup group CT/117** stay intact. Do NOT rename the Proxmox guest.
2. **Data = leave everything in place.** Remove only ansible config/deploy references.
   Do NOT delete or destroy any paperless data.

## 2. State of the world (context)

- The LXC is Proxmox **CT/117**, hostname `paperless`, `192.168.2.117`, `ssh paperless` = root.
  It runs BOTH the (now-defunct) paperless stack and the live **library** stack, plus
  monitoring (node_exporter, alloy, cadvisor).
- **Library is live and healthy.** Its document file store was migrated earlier today from
  `/mnt/nfs/paperless/library` to a dedicated TrueNAS dataset `tank/document-store`, NFS-mounted
  at `/mnt/nfs/document-store` (`data/`→`/data`, `consume/`→`/consume`). Committed + pushed to
  `main` (commit `d28fef4`). `library-db` pgdata is LOCAL at `/srv/apps/library/pgdata`.
- The deployed compose is **ansible-templated**: `roles/paperless_lxc/templates/docker-compose.yml.j2`
  → `/srv/apps/docker-compose.yml`. Deploy = `make paperless tags=docker` today (becomes
  `make document-library tags=docker` after the rename). The deploy handler recreates ALL services.
- The user has **already commented out** the paperless services in the compose template and the
  paperless entries in `host_vars` sleep_hours — finish the job by deleting them cleanly.
- **Backups (both halves already covered):** pgdata via daily verified PBS backup of CT/117;
  document files via TrueNAS `tank` daily snapshots + `tank → backup` replication.

## 3. Guardrails — do NOT touch

1. Runtime hostname `paperless`, `NODE_HOSTNAME: "paperless"` (alloy), and any `hostname="paperless"`
   metric label / Grafana variable. Metric continuity depends on this.
2. PBS backup identity (CT/117) and the Proxmox guest config.
3. Any paperless **data**: TrueNAS `tank/paperless` dataset + its NFS/SMB shares, `/srv/apps/paperless/{pgdata,redisdata,data}`,
   `/mnt/nfs/paperless/*` contents. (Removing the ansible *mount config* for `/mnt/nfs/paperless`
   is fine — the data + TrueNAS shares stay. But run no `rm`/`zfs destroy`.)
4. The `library-*` services and the `document-store` mounts — keep exactly as-is.
5. Shared vars `puid`/`pgid`/`guid` (= 1001) live in `group_vars/all/main.yml` and are ALSO used by
   the alloy config-upload task and the (unused) SMB opts — see gotcha 5.1.

## 4. Change plan

Work on a branch off `main` (e.g. `library/decommission-paperless`). Re-grep before each edit —
`grep -rilI paperless . --exclude-dir=.git --exclude-dir=.venv --exclude-dir=.mypy_cache --exclude-dir=.pytest_cache`
— the survey below was taken 2026-07-04 and may drift.

### 4.1 Rename the ansible layer (use `git mv` to preserve history)

Naming: ansible identifiers use **underscores** (`document_library_lxc`, group `document_library`) to
avoid ansible's invalid-group-name warning on hyphens; the **Makefile target uses a hyphen**
(`document-library`), matching the existing `open-webui → open_webui_lxc` precedent. Rename ONLY the
ansible layer — the app's own identifiers (`library-*` containers, `LIBRARY_*` env, `/srv/apps/library`,
`document-store`) stay `library`.

- `git mv roles/paperless_lxc roles/document_library_lxc`
- `git mv playbooks/paperless_lxc.yml playbooks/document_library_lxc.yml`
- `git mv host_vars/paperless_lxc.yml host_vars/document_library_lxc.yml`
- `inventory.ini` and `inventory-tailscale.ini`: rename group `[paperless] → [document_library]`; rename
  the host `paperless_lxc → document_library_lxc` (keep `ansible_host=192.168.2.117`); update every
  `children` group membership that lists `paperless` (nfs_clients, share_drive_clients, alloy_clients,
  shell_environment_clients, etc.) to `document_library`. **The host_vars filename must match the
  inventory host name** — both become `document_library_lxc`.
- `playbooks/document_library_lxc.yml`: `hosts: paperless_lxc → document_library_lxc`; the play `name:`;
  and `- role: paperless_lxc → document_library_lxc`.
- `playbooks/site.yml`: update the import of the paperless playbook + play name.
- `Makefile` (note: lowercase `makefile` is the real file): rename the `paperless:` target → `document-library:`,
  update the `.PHONY` list, and the playbook path. Deploy verb becomes `make document-library tags=...`.
- Confirm `docker_compose_dir` (= `/srv/apps`) is NOT derived from the role name (it isn't — leave it).

### 4.2 Remove the paperless app from the (now) `document_library_lxc` role

- `templates/docker-compose.yml.j2`: delete the commented-out `paperless-db`, `paperless-webserver`,
  `paperless-broker` service blocks entirely. Keep `library-*`, `node_exporter`, `alloy`, `cadvisor`.
- `templates/.env.j2`: delete the entire "Paperless-ngx settings" section (`PAPERLESS_*`, `USERMAP_*`).
  Keep the "Library settings" section. `PUID`/`PGID` at the top can go too **only after** confirming no
  remaining compose service uses `${PUID}`/`${PGID}` (paperless was the only consumer).
- `tasks/main.yml`: remove the paperless-specific tasks — create paperless user/group (uid/gid puid/pgid),
  create `/srv/apps/paperless/{data,pgdata,redisdata}` dirs, the "paperless consumer health check" cron,
  and the `mount-smb.yml` import (`when: false`). KEEP: the library data-dir creation on document-store,
  the `/srv/apps/library/pgdata` dir, the alloy config dirs + upload, the compose copy. See gotcha 5.1
  about the alloy task's `owner: puid`.
- `tasks/mount-smb.yml`: delete the file.
- `handlers/main.yml`: remove the `Restart paperless` handler (and `Restart alloy`/`Restart all`/`Restart library`
  stay). Ensure the compose-copy task still notifies a valid handler.
- `defaults/main.yml`: remove `paperless_version`, and the SMB block (`smb_media_vm_username`, `smb_server`,
  `smb_opts_items`, `smb_opts`) IF nothing else references them (grep first). Keep `pgid`, the monitoring
  image versions, and `library_version`.
- `host_vars/document_library_lxc.yml`: remove the `paperless` entry from `nfs_shares` (`/mnt/nfs/paperless`) and from
  `smb_shares`; delete the already-commented paperless entries under `sleep_hours_stop_containers` and the
  `paperless-graceful.sh` line under `sleep_hours_plugins`; drop any `paperless` key in `sleep_hours_kuma_map`.
  Keep the `document-store` nfs/smb entries.
- `roles/sleep_hours/files/plugins/paperless-graceful.sh`: `git rm`. Check `roles/sleep_hours/files/truenas-shares.sh`
  (+ `.backup`) for hardcoded paperless refs — the share-control list is derived from `nfs_shares`/`smb_shares`
  targets in `truenas-nfs-shares.list.j2`, so removing the host_vars paperless entries should suffice; verify.

### 4.3 Monitoring & homepage (in `roles/infra_vm` and `roles/prometheus_lxc`)

- `roles/infra_vm/files/grafana/dashboards/home-server.json`: remove paperless-specific panels/rows. Leave any
  panel keyed on `hostname="paperless"` that represents the *host* (still valid — it's the library host now).
- `roles/infra_vm/templates/homepage/{bookmarks,services}.yaml.j2`: remove paperless links (or repoint to library
  at `http://192.168.2.117:8010` if a library tile is wanted).
- `roles/infra_vm/templates/mkdocs.yml.j2`: drop the `paperless.md` nav entry (see docs below).
- `roles/prometheus_lxc/templates/prometheus/prometheus.yml.j2`: check for a paperless-app scrape target. The
  node_exporter target for host `paperless` STAYS (hostname unchanged). Only remove an app-specific job if present.
- uptime-kuma: remove any paperless monitor referenced via `sleep_hours_kuma_map`.

### 4.4 Docs (follow the user's archive convention)

- `git mv documentation/paperless.md documentation/archive/paperless.md`, add a top header
  `**Status:** superseded — paperless decommissioned in favour of library (2026-07-04).`, and update inbound links.
- Passing mentions in `documentation/{cloudflared,disks,domain-migration,quiet_hours,share_drives_nfs_smb,truenas,upgrade-procedures,prometheus_lxc,open_webui_lxc}.md`:
  update or note as historical. Don't rewrite history in old journal entries — leave `journal/*` as-is.
- Add a journal entry recording the decommission when done.

### 4.5 Tests

- `tests/mocks/{kuma_mock,truenas_mock}.py` and any test asserting on `paperless`: since the paperless TrueNAS
  dataset/shares are LEFT in place, mocks referencing `/mnt/tank/paperless` may still be valid. Update only what
  breaks. Run the suite (`.venv/bin/pytest` / `make test` if defined) and fix fallout.

## 5. Gotchas

1. **`puid`/`pgid`/`guid` are shared, not paperless-only.** They're defined in `group_vars/all/main.yml`
   (puid 1001, guid 1001) and the role's `defaults` (pgid 1001), and used by the **alloy config-upload task**
   (`owner: "{{ puid }}", group: "{{ guid }}"`) and the unused SMB opts. Do NOT delete the vars. When you remove
   the paperless *user-creation* task, the alloy task's `owner: 1001` still works numerically, but consider
   repointing alloy config ownership to `root:root` for cleanliness. The uid 1001 does NOT need to exist locally
   for the document-store NFS Mapall (that mapping is server-side on TrueNAS).
2. **Removing services from compose leaves orphan containers.** After deleting the paperless services, the deploy
   must drop the old `paperless-db`/`-webserver`/`-broker` containers. Either add `remove_orphans: true` to the
   `docker_compose_v2` handler for this deploy, or `ssh paperless 'cd /srv/apps && docker compose up -d --remove-orphans'`
   / `docker rm` the stopped paperless containers manually. They're already stopped/commented, so this is cleanup.
3. **Runtime hostname stays `paperless`.** Do not "fix" `NODE_HOSTNAME` or metric labels. The ansible *host* is
   renamed `document_library_lxc` but it still targets `192.168.2.117` and the box still reports itself as `paperless`.
4. **`/mnt/nfs/paperless` mount removal is config-only.** Removing it from `nfs_shares` unmounts it from the LXC
   on next `tags=nfs` run; the TrueNAS share + data are untouched and other clients keep their SMB access.
5. **The compose template top comment** says `# paperless_lxc/files/docker-compose.yml` — update to `document_library_lxc`.

## 6. Verify & deploy

1. `ansible-lint` and `yamllint` clean (repo has `.ansible-lint`); `ruff`/`pytest` for the python bits.
2. Render/dry-run: `.venv/bin/ansible-playbook -i inventory.ini playbooks/document_library_lxc.yml --vault-password-file=.vault_pass.txt --check --diff --tags docker` (docker_compose_v2 won't fully check, but catches undefined vars / template errors). At minimum confirm the compose template renders with no paperless services and no undefined vars.
3. Deploy: `make document-library tags=docker` (renders compose + recreates the stack). Add `--remove-orphans` handling per gotcha 5.2.
4. Confirm on the box: `ssh paperless 'docker ps --format "{{.Names}}"'` shows only `library-*` + `node_exporter`/`alloy`/`cadvisor`, no `paperless-*`; `curl -s -o /dev/null -w "%{http_code}" http://192.168.2.117:8010/api/settings` = 401; open the app and load a document.
5. Confirm monitoring still green for host `paperless` (Grafana/Prometheus) — labels unchanged.
6. Commit on a branch, merge to `main` (fast-forward), push. No PR needed (user preference).

## 7. Rollback

Everything is in git and no data is deleted. If a deploy misbehaves: `git revert`/reset the branch and
re-run `make document-library tags=docker` (or `make paperless` from the previous commit). The paperless containers
can be restored by un-commenting the services and redeploying, since their data/dataset are all intact.
