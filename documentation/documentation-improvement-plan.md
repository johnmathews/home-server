# Documentation Improvement Plan

Incremental plan for bringing all roles up to documentation parity. Work on a role's docs whenever
that role is touched in a session, or pick items from this list when there's time.

## Current State

```
+---------------------+-------------------------+--------+---------------------------------------+
| Role                | Doc file                | Status | Notes                                 |
+---------------------+-------------------------+--------+---------------------------------------+
| agent_lxc           | agent.md                | Good   | 27k, thorough                         |
| cloudflared_lxc     | cloudflared.md          | Good   | 5.6k, accurate (verified 2026-03-26)  |
| immich_lxc          | immich_lxc.md           | Sparse | 19 lines, env vars only               |
| infra_vm            | (none)                  | Missing| Major gap - hosts Grafana/Prometheus/  |
|                     |                         |        | Loki/Alloy/Homepage/Docserver         |
| jellyfin_lxc        | jellyfin_lxc.md         | Good   | 4.2k, accurate (verified 2026-03-26)  |
| key_server          | key_server.md           | OK     | 1.4k, covers basics                   |
| mail_vm             | (none)                  | N/A    | Retired service, skip                 |
| media_vm            | media_vm.md             | Good   | 8.9k, thorough                        |
| music_lxc           | navidrome.md            | Good   | 10k, accurate (verified 2026-03-26)   |
| nas                 | truenas.md              | Good   | 11k, thorough                         |
| nfs_client          | share_drives_nfs_smb.md | OK     | Covers NFS/SMB setup, not role-specific|
| open_webui_lxc      | (none)                  | Missing| LLM web interface                     |
| paperless_lxc       | paperless.md            | Sparse | 3 lines, only mentions training sched |
| prometheus_lxc      | (none)                  | Missing| Metrics collection                    |
| proxmox_lxc_tun     | (none)                  | Minor  | Small utility role, low priority       |
| pve                 | proxmox_host_tuning.md  | Partial| Tuning covered, role setup not         |
| share_drive_probe   | monitor_nfs_smb_mounts.md| OK    | Covers monitoring setup                |
| shell_environment   | shell_environment.md    | Good   | 9.3k                                  |
| sleep_hours         | quiet_hours.md          | Good   | 28k, very thorough                    |
| tailscale           | tailscale.md            | Good   | 22k                                   |
| traefik_lxc         | traefik.md              | Sparse | 1.5k, minimal                         |
| tubearchivist_lxc   | (none)                  | Missing| YouTube archiving                     |
+---------------------+-------------------------+--------+---------------------------------------+
```

## Priority Tiers

### Tier 1: Create missing docs for major services

These roles are complex and actively used. No documentation exists. Create these first,
ideally when the role is next touched.

1. **infra_vm.md** — Highest priority. This role deploys Grafana, Prometheus, Loki, Alloy,
   Homepage, Docserver, and File Browser. Should cover:
   - Service inventory (what runs, what port, what purpose)
   - Docker compose structure and container relationships
   - Loki/Alloy log pipeline architecture
   - Homepage dashboard configuration
   - Grafana datasource setup
   - Known issues and troubleshooting

2. **prometheus_lxc.md** — Second highest. Prometheus is the metrics backbone. Should cover:
   - Scrape target architecture (currently 255+ hardcoded IPs)
   - How to add/remove a monitored host
   - Alert rules if any
   - Retention and storage
   - Relationship to infra_vm's Grafana

3. **open_webui_lxc.md** — LLM web interface. Should cover:
   - What models/backends are configured
   - Docker setup and volumes
   - Access method (direct, tunnel, traefik?)

4. **tubearchivist_lxc.md** — YouTube archiving. Should cover:
   - TubeArchivist + Elasticsearch + Redis stack
   - NFS mount for media storage
   - Download scheduling and configuration

### Tier 2: Expand sparse existing docs

These have documentation files but they're too thin to be useful.

5. **paperless.md** (3 lines) — Expand to cover:
   - Docker stack (Paperless + Redis + PostgreSQL)
   - SMB mount for document ingestion
   - NFS mount for storage
   - Training schedule and document classification
   - Backup considerations

6. **immich_lxc.md** (19 lines) — Expand to cover:
   - Full Docker stack (server, microservices, ML, Redis, PostgreSQL)
   - NFS mount for photo library
   - Machine learning features and GPU passthrough if applicable
   - Mobile app configuration
   - Backup strategy for database vs photos

7. **traefik.md** (41 lines) — Expand to cover:
   - Entrypoints and routing architecture
   - Dynamic config file structure (routers.yml, middlewares.yml)
   - How cloudflared connects to Traefik
   - Dashboard access and security (currently insecure: true)
   - How to add a new proxied service
   - TLS/certificate handling

### Tier 3: Cross-cutting operational guides

These are not tied to a single role but are important operational knowledge.

8. **disaster-recovery.md** — How to rebuild from backups:
   - PBS backup restoration procedure
   - Per-VM/LXC recovery steps
   - RTO/RPO expectations
   - What's backed up vs what's ephemeral

9. **adding-a-new-service.md** — Template for new roles:
    - Create role skeleton (defaults, tasks, handlers, templates)
    - Add to inventory, playbook, site.yml, makefile
    - Wire up monitoring (node-exporter, alloy, cadvisor)
    - Add cloudflared tunnel route if external
    - Add Traefik routing if needed
    - Create documentation file

10. **upgrade-procedures.md** — How to upgrade:
    - Proxmox host OS updates
    - Ansible and Python dependency updates
    - Docker image version bumps (now easier with pinned versions)
    - Service-specific upgrade notes (e.g., Jellyfin major versions)

### Tier 4: Low priority

11. **proxmox_lxc_tun** — Small utility role, document inline or brief note
12. **pve role docs** — Expand proxmox_host_tuning.md to cover the full pve role
13. **mail_vm** — Retired, skip entirely or add one-line "retired" note

## How to Use This Plan

- **When touching a role**: Check if it's in Tier 1 or 2. If so, write/expand its docs
  as part of the session.
- **Dedicated doc sessions**: Pick the next Tier 1 item and create it. Read the role
  thoroughly first — compare actual code against any existing docs.
- **Template**: Each service doc should cover at minimum:
  - Purpose and what it does
  - IP, ports, access method
  - Docker containers and their relationships
  - NFS/SMB mounts if applicable
  - Configuration files managed by Ansible
  - Known issues and troubleshooting
  - How to update/upgrade
