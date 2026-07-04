# Paperless-ngx Document Store

**Status:** superseded — paperless decommissioned in favour of the `library` app (2026-07-04).
The ansible layer was renamed `paperless_lxc → document_library_lxc` (role, playbook, host_vars,
inventory group, `make document-library` target); the runtime hostname stays `paperless` (CT/117)
for metric/backup continuity. Paperless data was left in place (not destroyed). See
`journal/260705-decommission-paperless-app.md` for the decommission record.

## Purpose

Self-hosted document management system. Scans, OCRs, and classifies documents. Trains a classifier
to automatically tag and categorize incoming documents.

## Quick Reference

```
+-----------------------+--------------------------------------------------+
| Host                  | paperless_lxc (192.168.2.117)                    |
| SSH                   | ssh paperless                                    |
| Web UI                | paperless.itsa-pizza.com                         |
| Alt URL               | documents.itsa-pizza.com                         |
| Port                  | 8000                                             |
| Docker compose dir    | /srv/apps                                        |
| Ansible               | make paperless                                   |
| Role                  | roles/paperless_lxc                              |
+-----------------------+--------------------------------------------------+
```

## Docker Containers

```
+----------------------+--------------------------------------+-------+
| Container            | Image                                | Port  |
+----------------------+--------------------------------------+-------+
| paperless-webserver  | paperless-ngx/paperless-ngx:latest   | 8000  |
| paperless-db         | postgres:17                          | -     |
| paperless-broker     | redis:8                              | -     |
| node_exporter        | node-exporter:latest                 | 9100  |
| alloy                | grafana/alloy:latest                 | 12345 |
| cadvisor             | cadvisor:latest                      | 18080 |
+----------------------+--------------------------------------+-------+
```

### Container Details

- **paperless-webserver**: Main application. Depends on healthy PostgreSQL and Redis before starting.
  Runs as PUID/PGID 1001. Configuration via `.env` file and inline environment variables.
- **paperless-db**: PostgreSQL 17 database. Data stored at `/srv/apps/paperless/pgdata`. Health check
  uses `pg_isready`.
- **paperless-broker**: Redis 8 for task queue (document processing, classification). Data stored at
  `/srv/apps/paperless/redisdata`. Health check uses `redis-cli ping`.

## Storage

### NFS Mounts

All document data stored on TrueNAS via NFS:

- `/mnt/nfs/paperless/media` — Processed documents (PDFs, thumbnails)
- `/mnt/nfs/paperless/export` — Document exports
- `/mnt/nfs/paperless/consume` — Inbox for new documents (drop files here to auto-import)

### SMB Configuration

SMB is configured for external clients (phones, laptops) to connect directly to the TrueNAS
paperless datastore. The Paperless service itself uses NFS. SMB credentials are stored at
`/etc/smb-media-credentials` with SMBv3.1.1 and NTLMSSP authentication.

### Local Storage

- `/srv/apps/paperless/pgdata` — PostgreSQL database
- `/srv/apps/paperless/redisdata` — Redis data
- `/srv/apps/paperless/data` — Paperless internal data (search index, etc.)

## Training and Classification

Paperless automatically trains its document classifier and re-indexes documents on a schedule:

```
Training:  */20 10-20 * * *   (every 20 minutes, 10am-8pm)
Indexing:  */20 10-20 * * *   (every 20 minutes, 10am-8pm)
Sanity:    0 11 * * 1         (weekly, Monday at 11am)
```

Training runs during daytime hours to avoid HDD wakeups during quiet hours. The sanity check
runs weekly to detect data integrity issues.

## External Access

Accessible via Cloudflare Tunnel with Zero Access protection (not via Traefik):

- `paperless.itsa-pizza.com` → `192.168.2.117:8000`
- `documents.itsa-pizza.com` → `192.168.2.117:8000`

## Ansible Configuration

### Defaults (`roles/paperless_lxc/defaults/main.yml`)

- Uses centralized `docker_compose_dir: /srv/apps`
- SMB mount configuration with credentials file, NTLMv2, systemd automount
- PUID/GUID: 1001
- **Image versions track `latest`** (`paperless_version`, `node_exporter_version`,
  `alloy_version`, `cadvisor_version`). They previously held stale pins below the
  images actually running on the host; re-rendering compose against them attempted
  a destructive paperless downgrade. If re-pinning to explicit versions, first
  pull and verify the image on the host, and never pin paperless below the
  deployed version (schema downgrades are unsupported and corrupt the DB).

### Tasks

- `tasks/main.yml` — Docker compose deployment, alloy config, .env file
- `tasks/mount-smb.yml` — SMB credential file and fstab mount setup

## Vault Variables Used

- SMB credentials (via `vault_smb_media_vm_password`)
- `vault_library_db_password` — Postgres password for the co-hosted Library
  stack (`library-db`, user/db `library`). Rendered into `.env` as
  `LIBRARY_DB_PASSWORD` and interpolated by compose into both the DB container
  and the app DSN.
- `vault_library_anthropic_api_key` (optional) — Claude API key for Library
  metadata extraction; templated only when defined.
- Other secrets in `.env.j2` template

### Rotating the Library DB password

Postgres only reads `POSTGRES_PASSWORD` on first volume init, so changing the
vault value alone does **not** update the role on the existing `pgdata` volume.
Full rotation:

1. Update `vault_library_db_password`:
   `ansible-vault edit group_vars/all/vault.yml --vault-password-file=.vault_pass.txt`
2. Render the new `.env` to the host: `make paperless TAGS=docker`
3. Alter the live role (local socket is trust auth):
   `ssh paperless 'docker exec library-db psql -U library -d library -c "ALTER USER library WITH PASSWORD '\''<new>'\''"'`
4. Recreate the Library services so they reconnect with the new credential:
   `ssh paperless 'cd /srv/apps && docker compose up -d --pull never library-db library-migrate library-webserver library-worker'`
5. Verify: `library-migrate` exits 0, `library-webserver` `/healthz` returns 200,
   the new password authenticates and the old one is rejected.

Use an alphanumeric password — the value flows through both `.env` `${...}`
interpolation and the `postgresql+asyncpg://library:<pw>@library-db/library` DSN,
so URL/shell metacharacters will break it.

## Backup Strategy

- **Documents (media, export)**: On TrueNAS NFS — backed up via ZFS snapshots
- **Database**: PostgreSQL in `/srv/apps/paperless/pgdata` — backed up via PBS (whole LXC backup)
- **Search index**: In `/srv/apps/paperless/data` — can be rebuilt from documents

## Troubleshooting

- **Documents not processing**: Check Redis broker health: `ssh paperless && docker logs paperless-broker`
- **Consume directory not picking up files**: Verify NFS mount is active: `mount | grep paperless`
- **Classification not working**: Check training schedule and logs: `docker logs paperless-webserver | grep -i train`
- **SMB mount issues**: Verify credentials file at `/etc/smb-media-credentials` and test with `smbclient`

## Upgrading

Database migrations run automatically on container startup. Ensure the PostgreSQL container is healthy
before upgrading the Paperless container:

1. Check release notes at the Paperless-ngx GitHub repository
2. Update the image tag in the docker-compose template (currently `:latest`)
3. Run `make paperless`
4. Check logs: `ssh paperless && docker logs paperless-webserver`
