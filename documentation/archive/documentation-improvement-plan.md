# Documentation Improvement Plan

**Status:** completed — Tiers 1–3 done 2026-03-26; Tier 4 folded into normal doc upkeep. Archived 2026-07-12.

Incremental plan for bringing all roles up to documentation parity. Work on a role's docs whenever
that role is touched in a session, or pick items from this list when there's time.

## Current State (updated 2026-03-26)

```
+---------------------+-------------------------+--------+---------------------------------------+
| Role                | Doc file                | Status | Notes                                 |
+---------------------+-------------------------+--------+---------------------------------------+
| agent_lxc           | agent.md                | Good   | 27k, thorough                         |
| cloudflared_lxc     | cloudflared.md          | Good   | 5.6k, accurate (verified 2026-03-26)  |
| immich_lxc          | immich_lxc.md           | Good   | Expanded 2026-03-26 (was 19 lines)    |
| infra_vm            | infra_vm.md             | Good   | Created 2026-03-26                    |
| jellyfin_lxc        | jellyfin_lxc.md         | Good   | 4.2k, accurate (verified 2026-03-26)  |
| key_server          | key_server.md           | OK     | 1.4k, covers basics                   |
| mail_vm             | (none)                  | N/A    | Retired service, skip                 |
| media_vm            | media_vm.md             | Good   | 8.9k, thorough                        |
| music_lxc           | navidrome.md            | Good   | 10k, accurate (verified 2026-03-26)   |
| nas                 | truenas.md              | Good   | 11k, thorough                         |
| nfs_client          | share_drives_nfs_smb.md | OK     | Covers NFS/SMB setup, not role-specific|
| open_webui_lxc      | open_webui_lxc.md       | Good   | Created 2026-03-26                    |
| paperless_lxc       | paperless.md            | Good   | Expanded 2026-03-26 (was 3 lines)     |
| prometheus_lxc      | prometheus_lxc.md       | Good   | Created 2026-03-26                    |
| proxmox_lxc_tun     | (none)                  | Minor  | Small utility role, low priority       |
| pve                 | proxmox_host_tuning.md  | Partial| Tuning covered, role setup not         |
| share_drive_probe   | monitor_nfs_smb_mounts.md| OK    | Covers monitoring setup                |
| shell_environment   | shell_environment.md    | Good   | 9.3k                                  |
| sleep_hours         | quiet_hours.md          | Good   | 28k, very thorough                    |
| tailscale           | tailscale.md            | Good   | 22k                                   |
| traefik_lxc         | traefik.md              | Good   | Expanded 2026-03-26 (was 41 lines)    |
| tubearchivist_lxc   | tubearchivist_lxc.md    | Good   | Created 2026-03-26                    |
+---------------------+-------------------------+--------+---------------------------------------+
```

## Completed Items

### Tier 1: Create missing docs for major services -- DONE

All four Tier 1 items completed on 2026-03-26:

1. **infra_vm.md** -- Created. Covers all 20 containers, service groups, memory limits,
   data directories, external access, related docs.
2. **prometheus_lxc.md** -- Created. Covers all 16 scrape jobs, retention config,
   how to add hosts/exporters, AdGuard client mapping.
3. **open_webui_lxc.md** -- Created. Covers OpenAI backend, Docker setup, access method.
4. **tubearchivist_lxc.md** -- Created. Covers ES/Redis stack, NFS mounts, quiet hours,
   Jellyfin integration.

### Tier 2: Expand sparse existing docs -- DONE

All three Tier 2 items completed on 2026-03-26:

5. **paperless.md** -- Expanded from 3 lines to full doc covering Docker stack, NFS/SMB,
   training schedule, backup strategy, troubleshooting.
6. **immich_lxc.md** -- Expanded from 19 lines to full doc covering Docker stack, NFS,
   ML, public proxy, env vars, backup strategy, upgrading.
7. **traefik.md** -- Expanded from 41 lines to full doc covering routing architecture,
   middleware details, rate limiting, how to add services.

### Tier 3: Cross-cutting operational guides -- DONE

All three Tier 3 items completed on 2026-03-26:

8. **disaster-recovery.md** -- Created. Covers backup architecture, 5 recovery scenarios,
   recovery time expectations, critical files to protect.
9. **adding-a-new-service.md** -- Created. Step-by-step with checklist: role, inventory,
   playbook, makefile, vault, NFS, cloudflared, prometheus, docs.
10. **upgrade-procedures.md** -- Created. Covers Docker images, Ansible deps, Proxmox,
    TrueNAS, service-specific notes, rollback procedures.

## Remaining Items (Tier 4: Low Priority)

11. **proxmox_lxc_tun** -- Small utility role, document inline or brief note
12. **pve role docs** -- Expand proxmox_host_tuning.md to cover the full pve role
13. **mail_vm** -- Retired, skip entirely or add one-line "retired" note

## How to Use This Plan

- **When touching a role**: Check if its docs are current. Update as part of the session.
- **Template**: Each service doc should cover at minimum:
  - Purpose and what it does
  - IP, ports, access method
  - Docker containers and their relationships
  - NFS/SMB mounts if applicable
  - Configuration files managed by Ansible
  - Known issues and troubleshooting
  - How to update/upgrade
