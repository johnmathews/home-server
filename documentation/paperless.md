# Paperless-ngx Document Store

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

### Tasks

- `tasks/main.yml` — Docker compose deployment, alloy config, .env file
- `tasks/mount-smb.yml` — SMB credential file and fstab mount setup

## Vault Variables Used

- SMB credentials (via `vault_smb_media_vm_password`)
- Other secrets in `.env.j2` template

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
