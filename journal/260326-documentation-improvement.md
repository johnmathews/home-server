# Documentation Improvement — 2026-03-26

## What Changed

Merged the unmerged `eng-lint-and-security-fixes` worktree from the 2026-03-25 engineering
evaluation (6 commits: security fixes, lint cleanup, Docker version pinning, variable
centralization). Then implemented the documentation improvement plan. All Tier 1, 2, and 3
items completed.

### New Documentation Files (7 created)

- `infra_vm.md` — Full inventory of 20 containers, service groups, memory limits, data dirs
- `prometheus_lxc.md` — All 16 scrape jobs, retention config, how to add hosts/exporters
- `open_webui_lxc.md` — OpenAI backend config, Docker setup, access method
- `tubearchivist_lxc.md` — ES/Redis stack, NFS mounts, quiet hours, Jellyfin integration
- `adding-a-new-service.md` — Step-by-step guide with 13-item checklist
- `disaster-recovery.md` — 5 recovery scenarios, backup architecture, critical files
- `upgrade-procedures.md` — Docker, Proxmox, TrueNAS, Ansible upgrade procedures

### Expanded Documentation (3 files)

- `paperless.md` — From 3 lines to 128 lines (Docker stack, NFS/SMB, training, backups)
- `immich_lxc.md` — From 19 lines to 148 lines (full stack, ML, public proxy, env vars)
- `traefik.md` — From 41 lines to 159 lines (routing, middleware, rate limiting, adding services)

### Updated Files

- `CLAUDE.md` — Documentation index updated with all new and expanded entries
- `documentation-improvement-plan.md` — Marked Tiers 1-3 as complete

## Key Decisions

- All docs follow a consistent template: purpose, quick reference table, containers table,
  storage, external access, Ansible tags, vault vars, troubleshooting, upgrading
- Used ASCII tables (not markdown) per project convention
- Cross-referenced existing docs where relevant (e.g., infra_vm.md links to river.md and
  docserver.md rather than duplicating content)
- Documented operational knowledge that isn't obvious from code (e.g., TubeArchivist containers
  must be stopped not paused because Elasticsearch doesn't handle pause gracefully)

## Remaining

Only Tier 4 items remain (low priority):
- proxmox_lxc_tun docs (small utility role)
- Expand pve role docs
- mail_vm (retired, skip)
