Always use context7 when I need code generation, setup or configuration steps, or library/API documentation. This means
you should automatically use the Context7 MCP tools to resolve library id and get library docs without me having to
explicitly ask.

When you output a table, do not use markdown. Instead, draw a plain ASCII table. Columns must be vertically aligned in a
monospace terminal.

## Project Purpose

Ansible playbooks and roles for provisioning a Proxmox-based home server with VMs/LXCs for storage (TrueNAS), media
streaming (Jellyfin, Sonarr, Radarr, qBittorrent), monitoring (Prometheus, Grafana), and other services. Automates
deployment, configuration, and updates using a Makefile-driven workflow.

## Architecture & Structure

- **Root**: Ansible playbooks in `/playbooks/`, roles in `/roles/`
- **Collections**: Community Ansible collections and Prometheus collection (installed to `~/.ansible/collections/`)
- **Configuration**: `inventory.ini` (hosts), `group_vars/all/` (global vars), `host_vars/` (per-host overrides)
- **Documentation**: `/documentation/` directory with service-specific guides. When working on a service, always read
  its documentation file first (e.g., `documentation/agent.md` for the Agent LXC, `documentation/cloudflared.md` for
  Cloudflare Tunnel). These contain hard-won operational details, known issues, and troubleshooting notes.
- **Key files**: `ansible.cfg` (roles path), `makefile` (all commands), `.ansible-lint` (lint rules), `requirements.yml`
  (collection versions)

## Testing & Validation

**Build/Lint/Test Commands:**

```sh
make requirements   # Install Ansible + Python deps
make lint          # Run ansible-lint (warnings only, non-blocking)
make check         # Dry-run of full site.yml (no changes) — KNOWN LIMITATION: several
                   # roles' probe->install chains are not check-mode-safe (e.g. tailscale
                   # status parse), so expect false failures; validate per-host instead:
                   # ansible-playbook playbooks/<host>.yml --check
make ci            # lint + check (pre-commit validation)
make site          # Execute full provisioning
```

**Running single targets:** `make <target>` (e.g., `make media`, `make traefik`) with optional flags:

- `TAGS=tagname` or `t=tagname` — run specific tag
- `SKIP=tagname` or `s=tagname` — skip specific tag
- `LIMIT=hostname` or `l=hostname` — limit to one host

## Deployment Model

**Everything is deployed by Ansible. Never hand-edit config on a host — it gets overwritten on the next run.**

The naming convention ties the whole repo together. For a host like `immich_lxc`:

```
make immich  ->  playbooks/immich_lxc.yml  ->  roles/immich_lxc/  ->  host immich_lxc
```

`make <target>` runs one playbook, which imports one (sometimes more) role. Target names are
abbreviated (`make jelly`, `make tube`, `make media`); the playbook and role keep the full name. Run
`grep -E '^[a-z_-]+:' makefile` to see every target, or read `documentation/ansible_build_commands.md`
for targets + common tags.

**Docker services follow one pattern.** Dockerized hosts have
`roles/<host>/templates/docker-compose.yml.j2` (and usually `.env.j2`). On `make <host>`, Ansible
renders these into the host's compose dir and a handler/task runs `docker compose up -d` to apply the
change. So:

- To change a container (image, env, ports, volumes), edit the role's `docker-compose.yml.j2` / `.env`
  vars, then `make <host>` — do **not** `ssh` in and edit the compose file directly.
- Vars come from `group_vars/all/`, `host_vars/<host>/`, and Ansible Vault (secrets — see
  `documentation/vault.md`).
- `roles/document_library_lxc` is a good reference for the template-then-restart shape.
  (Note: its `make` target is hyphenated — `make document-library` — matching the
  `open-webui → open_webui_lxc` precedent where the abbreviated target uses a hyphen.)

**VMs vs LXCs.** Hosts ending in `_vm` (`nas_vm`, `media-vm`, `infra-vm`, `mailcow-vm`) are full VMs;
`*_lxc` are LXC containers; `pve` is the Proxmox host itself and `pbs` the backup server. LXCs are
defined/managed on `pve`. The distinction matters when investigating: you SSH to the guest for its
services, but to `pve` for guest lifecycle (start/stop/config).

## Investigating Live State

Prefer the connected MCP servers over ad-hoc SSH when answering "what's happening" questions — they're
faster and read-only:

- **`sre-agent` MCP** — Proxmox guest list/config (`proxmox_*`), Loki logs (`loki_query_logs`),
  Prometheus metrics (`prometheus_*`), TrueNAS (`truenas_*`), PBS backups (`pbs_*`), Grafana
  (`grafana_*`), and `runbook_search`. Use this first to inspect logs, metrics, and host/guest status.
- **`docs` MCP** — searchable index of this project's docs and journals (`search_docs`, `query_docs`).
  Use for "how does X work / why was Y done" before grepping files.

When you do need a shell, SSH via the aliases below (`ssh <host>`), then the usual `docker compose ps`,
`docker compose logs`, `journalctl -u <svc>`, `systemctl status`. Note NanoClaw runs as a **user**
systemd unit — use `systemctl --user` on the agent host (see `documentation/agent.md`).

## Code Style Guidelines

- **YAML formatting**: Follow `.ansible-lint` warn_list (trailing spaces, empty lines, line-length)
- **Task naming**: Use sentence case, enforce via `name[casing]` rule
- **Modules**: Gradual migration to fully qualified collection names (FQCN) — warn on violations
- **Variables**: Prefix internal role variables incrementally per `var-naming` rule
- **Booleans**: Use lowercase `true/false` (not `True/False`)
- **File permissions**: Always set `mode:` on sensitive files
- **Error handling**: Use `changed_when:` clauses where needed (warnings enforced)

## Network Quick Reference

Host IPs are assigned statically on the MikroTik router. Source of truth: `inventory.ini`.

```
+----------------------+----------------+------------------+--------------------------------------+
| Host                 | Local IP       | Tailscale IP     | Key Services                         |
+----------------------+----------------+------------------+--------------------------------------+
| pve                  | 192.168.2.214  |                  | Proxmox UI :8006                     |
| pbs                  | 192.168.2.200  |                  | Proxmox Backup Server                |
| cloudflared_lxc      | 192.168.2.101  |                  | Cloudflare Tunnel                    |
| mailcow-vm           | 192.168.2.103  |                  | Mailcow (retired)                    |
| nas_vm               | 192.168.2.104  |                  | TrueNAS (NFS/SMB shares)             |
| media-vm             | 192.168.2.105  |                  | Sonarr, Radarr, qBittorrent, etc.    |
| infra-vm             | 192.168.2.106  |                  | Grafana, Prometheus, Loki, etc.      |
| agent_lxc            | 192.168.2.107  | 100.125.185.47   | NanoClaw Gateway :18790              |
| traefik_lxc          | 192.168.2.108  |                  | Reverse proxy (Traefik)              |
| jellyfin_lxc         | 192.168.2.110  |                  | Jellyfin media server                |
| immich_lxc           | 192.168.2.113  |                  | Immich photo management              |
| music_lxc            | 192.168.2.109  |                  | Navidrome music streaming :4533      |
| prometheus_lxc       | 192.168.2.115  |                  | Prometheus metrics                   |
| tubearchivist_lxc    | 192.168.2.116  |                  | TubeArchivist                        |
| document_library_lxc | 192.168.2.117  |                  | Library doc store (host: paperless)  |
| open_webui_lxc       | 192.168.2.119  |                  | Open WebUI                           |
| key_server           | 192.168.2.201  |                  | TrueNAS encryption key server        |
+----------------------+----------------+------------------+--------------------------------------+
```

## SSH Aliases

`~/.ssh/config` defines host aliases for all hosts (e.g., `ssh agent` = `john@192.168.2.107`). Use the short
alias names when SSH-ing. Run `grep "^Host " ~/.ssh/config` to list all aliases.

## Documentation Index

Service-specific guides in `/documentation/`. Read the relevant doc before working on a service.

- `adding-a-new-service.md` — Step-by-step guide for adding a new service to the infrastructure
- `adguard-unbound.md` — DNS privacy and ad blocking (MikroTik → AdGuard → Unbound → Quad9)
- `ansible_build_commands.md` — Make commands and tags quick reference
- `archive/cloudflare-api.md` — Cloudflare API research notes from the domain migration (superseded by `cloudflared.md`, which documents the live API sync)
- `cloudflared.md` — Cloudflare Tunnel setup, proxied services, DNS routes, architecture
- `archive/documentation-improvement-plan.md` — Doc overhaul plan, Tiers 1–3 completed 2026-03 (archived 2026-07-12)
- `archive/traefik-log-resilience-plan.md` — Traefik log rotation plan; Option B implemented (archived 2026-07-12)
- `disaster-recovery.md` — Backup architecture, recovery scenarios, and rebuild procedures
- `archive/domain-migration.md` — Completed migration from itsa.pizza to itsa-pizza.com (archived 2026-07-12)
- `docserver.md` — Documentation MCP server on infra VM (indexing, search, MCP)
- `disks.md` — Proxmox host disk management and backup storage
- `doorbell.md` — Reolink video doorbell: usage guide (non-technical), notifications, two-way audio, HA/go2rtc setup
- `grafana-alerting.md` — Grafana alert rules, concise Pushover notification templates, API access
- `immich_lxc.md` — Immich photo management, Docker stack, NFS mounts, ML, mobile app
- `index.md` — Top-level project overview and conventions
- `infra_vm.md` — Infrastructure VM services (Grafana, Loki, Homepage, Portainer, Atuin, etc.)
- `iperf3-speedtest.md` — Network speed testing between server and clients
- `key_server.md` — TrueNAS dataset encryption key server
- `media_vm.md` — Media VM services (Mullvad VPN, qBittorrent, Sonarr, Radarr)
- `mikrotik-exporter.md` — MikroTik router Prometheus exporter (MKTXP)
- `monitor_nfs_smb_mounts.md` — NFS/SMB mount health monitoring
- `navidrome.md` — Navidrome music streaming, NFS mount, Subsonic API clients
- `agent.md` — NanoClaw architecture, LXC setup, macOS app, Tailscale, known issues
- `open_webui_lxc.md` — Open WebUI LLM chat interface, OpenAI backend, Docker setup
- `archive/paperless.md` — Paperless-ngx document store (decommissioned 2026-07-04, superseded by the `library` app on the same LXC)
- `pbs.md` — Proxmox Backup Server: datastore, schedule, retention, restore procedure
- `prometheus_lxc.md` — Prometheus metrics collection, scrape targets, retention, adding hosts
- `quiet_hours.md` — Night-time container pausing for HDD spindown
- `river.md` — Grafana Alloy (River config language) log shipping to Loki
- `share_drives_nfs_smb.md` — NFS/SMB share setup and Ansible automation
- `shell_environment.md` — Zsh, Powerlevel10k, CLI tools across all hosts
- `systemd.md` — systemd service management reference
- `tailscale.md` — VPN setup, DNS privacy, remote Ansible access
- `traefik.md` — Traefik reverse proxy, routing architecture, rate limiting, adding services
- `tubearchivist_lxc.md` — TubeArchivist YouTube archiver, Elasticsearch, Jellyfin integration
- `jellyfin_lxc.md` — Jellyfin LXC setup, plugins, NFS monitoring issue, 10.11.x known issues
- `journal_agent.md` — Journal agent and ChromaDB on media VM (MCP journaling, vector search)
- `proxmox_host_tuning.md` — ZFS ARC, KSM, VM ballooning, memory management
- `truenas.md` — TrueNAS scripts: share refresh, disk spindown, exporter
- `upgrade-procedures.md` — How to upgrade Docker images, Proxmox, TrueNAS, and dependencies; Diun update notifications
- `ups.md` — UPS monitoring via Network UPS Tools (NUT)
- `vault.md` — Ansible Vault: layout, conventions, edit/rotate, recovery considerations

## Editing Guardrails

**Safe to edit:**

- `/roles/*/` — Custom roles (atuin, immich_lxc, key_server, etc.)
- `/playbooks/` — All playbook files
- `group_vars/all/main.yml` — Global variables
- `host_vars/*/` — Host-specific overrides
- `/documentation/` — Service guides

**Never edit:**

- `/roles/geerlingguy.*/` — External roles (managed by ansible-galaxy, installed during `make requirements`)
- `~/.ansible/collections/` — External collections (managed by ansible-galaxy, installed during `make requirements`)
- `.ansible-lint` — Only with maintainer approval
- `ansible.cfg` — Core config (coordinate before changes)
- `requirements.yml` — Specifies collection/role versions (changes require `make requirements` to reinstall)
