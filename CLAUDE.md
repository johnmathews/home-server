**Status:** current — verified 2026-08-22 · covers: live, inventory.ini, makefile
The network table and the guest list were read from `pve` on that date; the make targets,
role layout and documentation index trace to this repo.

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
make requirements   # Install Ansible roles, collections and Python deps
make lint           # ansible-lint over the WHOLE repo. BLOCKING: exits 2 on any failure.
make check-ports    # Render every compose template, fail on a duplicate host port
make check-docs     # Parse every doc's **Status:** stamp, fail on a stale or missing one
make test           # pytest + bats. Needs docker, bats, jq, curl.
make ci-offline     # lint + check-ports + check-docs + test. No network, SSH or vault — what CI runs.
make check          # --check dry-run of site.yml against the LIVE fleet (needs SSH + vault)
make ci             # ci-offline + check. Operator-only; cannot run on a CI runner.
make site           # Execute full provisioning
```

`make lint` is **not** "warnings only". It exits 2 when ansible-lint reports any
failure, and because make stops at the first failed prerequisite, a failing `lint`
aborts `ci`/`ci-offline` before their later stages run. Warnings (the `warn_list`
in `.ansible-lint`) do not fail it; failures do.

`make help` lists every target.

**Running single targets:** `make <target>` (e.g., `make media`, `make traefik`) with optional flags:

- `TAGS=tagname` or `t=tagname` — run specific tag
- `SKIP=tagname` or `s=tagname` — skip specific tag
- `LIMIT=hostname` or `l=hostname` — limit to one host
- `EXTRA="--diff -vv"` — anything else to pass straight to `ansible-playbook`

`make check` accepts the same flags, so a scoped dry run is
`make check LIMIT=<host> EXTRA="--diff"`.

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

**VMs vs LXCs.** Hosts ending in `_vm` (`nas_vm`, `media-vm`, `infra-vm`) are full VMs;
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
- **Variables**: Prefix every role variable with `<role>_` (`var-naming[no-role-prefix]`); all roles comply as of 2026-08-23
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
| nas_vm               | 192.168.2.104  |                  | TrueNAS (NFS/SMB shares)             |
| media-vm             | 192.168.2.105  |                  | Sonarr, Radarr, qBittorrent, etc.    |
| infra-vm             | 192.168.2.106  |                  | Grafana, Prometheus, Loki, etc.      |
| agent_lxc            | 192.168.2.107  | 100.125.185.47   | NanoClaw v2 (Slack via TS Funnel)    |
| traefik_lxc          | 192.168.2.108  |                  | Reverse proxy (Traefik)              |
| jellyfin_lxc         | 192.168.2.110  |                  | Jellyfin media server                |
| immich_lxc           | 192.168.2.113  |                  | Immich photo management              |
| music_lxc            | 192.168.2.109  |                  | Navidrome music streaming :4533      |
| prometheus_lxc       | 192.168.2.115  |                  | Prometheus metrics                   |
| tubearchivist_lxc    | 192.168.2.116  |                  | TubeArchivist                        |
| document_library_lxc | 192.168.2.117  |                  | Library doc store (host: paperless)  |
| open_webui_lxc       | 192.168.2.119  |                  | Open WebUI                           |
| family_finances_lxc  | 192.168.2.120  |                  | Family finances app :8080            |
| key_server           | 192.168.2.201  |                  | TrueNAS encryption key server        |
+----------------------+----------------+------------------+--------------------------------------+
```

Not in `inventory.ini` and **not Ansible-managed**, but part of the estate — you will need
these and they are otherwise undiscoverable from this file. The first three are Proxmox guests
on `pve` (so `pct`/`qm` and PBS backups apply to them, and they appear in `proxmox_list_guests`);
the last three are third-party devices on the LAN:

```
+----------------------+----------------+------------------+--------------------------------------+
| Host                 | Local IP       | Managed by       | Key Services                         |
+----------------------+----------------+------------------+--------------------------------------+
| librespeed-rust      | 192.168.2.100  | CT 100 on pve    | LAN speed test                       |
|   (CT 100)           |                |   (not Ansible)  |                                      |
| adguard (CT 111)     | 192.168.2.111  | CT 111 on pve    | AdGuard Home DNS :53, web UI :80     |
|                      |                |   (not Ansible)  |   (see adguard-unbound.md)           |
| home assistant (VM   | 192.168.2.102  | its own /config  | HA :8123, Mosquitto :1883,           |
|   102, HAOS)         |                |   git repo       |   zigbee2mqtt, go2rtc :1984          |
| bosch dishwasher     | 192.168.2.39   | Home Connect     | Home Connect local protocol :443     |
|                      |                |   cloud + a Nous |   (PSK-only TLS)                     |
|                      |                |   metering plug  |                                      |
| voldt ev cable       | 192.168.2.29   | tuya-local via HA| EV charging (see ev_charging doc)    |
| reolink doorbell     | 192.168.2.35   | HA + go2rtc      | Doorbell, two-way audio              |
+----------------------+----------------+------------------+--------------------------------------+
```

## SSH Aliases

`~/.ssh/config` defines host aliases for all hosts (e.g., `ssh agent` = `john@192.168.2.107`). Use the short
alias names when SSH-ing. Run `grep "^Host " ~/.ssh/config` to list all aliases.

## Documentation Index

Service-specific guides in `/documentation/`. Read the relevant doc before working on a service.
Unprefixed names below are relative to `documentation/`; anything outside it is written with its
path. To confirm this list is still complete:
`diff <(grep -o '`[^`]*\.md`' CLAUDE.md | tr -d '`' | sort -u) <(cd documentation && ls *.md archive/*.md | sort)`

**Outside `documentation/`:**

- `readme.md` (repo root) — Project overview and entry point; where plans and backlogs live, and
  where the documentation freshness-stamp convention that `make check-docs` enforces is defined
- `building.md` (repo root) — Running notes on in-flight problems and their fixes; scratch, not a guide
- `README-TAILSCALE.md` (repo root) — Tailscale quick-start: get remote Ansible/SSH working in ~30 min
- `tests/README.md` — The `sleep_hours` end-to-end test suite: what it covers and how to run it
- `tests/IMPLEMENTATION_SUMMARY.md` — How that test framework was built (completed 2025-11-22)

**In `documentation/`:**

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
- `document_library_lxc.md` — The `library` document store (guest is still named `paperless`); the repo's reference Docker role
- `disks.md` — Proxmox host disk management and backup storage
- `family_finances_lxc.md` — Family finances app: SHA-pinned private images, encrypted per-household DBs, why Tailscale is omitted
- `doorbell.md` — Reolink video doorbell: usage guide (non-technical), notifications, two-way audio, HA/go2rtc setup
- `grafana-alerting.md` — Grafana alert rules, concise Pushover notification templates, API access
- `home_assistant_dishwasher.md` — Bosch dishwasher: LAN discovery, why Home Connect gives no kWh, metering plug, Home Connect integration, per-cycle energy attribution
- `home_assistant_energy.md` — HA energy monitoring: P1 meter, powercalc, Energy dashboard, config repo, backlog
- `home_assistant_lighting.md` — Zigbee lighting: JETSTRÖM panels + STYRBAR remotes, why binding beats HA automations, per-zone migration runbook and traps
- `home_assistant_ev_charging.md` — EV charging, both halves: Voldt granny cable (tuya-local over the LAN; the DP 27 refresh trick) + Skoda Enyaq (MySkoda), entities, charging-efficiency calc
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
- `archive/home-assistant-doorbell.md` — Doorbell two-way audio via go2rtc/WebRTC (superseded by `doorbell.md`, 2026-07-04)
- `archive/paperless.md` — Paperless-ngx document store (decommissioned 2026-07-04, superseded by the `library` app on the same LXC)
- `pbs.md` — Proxmox Backup Server: datastore, schedule, retention, restore procedure
- `portainer.md` — Portainer server + fleet-wide Ansible-managed agents, endpoint registration, upgrades
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
- `jellyfin_health_fitness_library.md` — the Health & Fitness Shows library (show = subgenre, season = sub-subgenre): layout, nfo/thumbcard conventions, scripts, runbooks for adding videos/seasons/shows and setting thumbcards, landmines
- `journal_agent.md` — Journal agent and ChromaDB on media VM (MCP journaling, vector search)
- `proxmox_host_tuning.md` — ZFS ARC, KSM, VM ballooning, memory management
- `truenas.md` — TrueNAS scripts: share refresh, disk spindown, exporter
- `upgrade-procedures.md` — How to upgrade Docker images, Proxmox, TrueNAS, and dependencies; update notifications
- `ups.md` — UPS monitoring via Network UPS Tools (NUT)
- `vault.md` — Ansible Vault: layout, conventions, edit/rotate, recovery considerations

## Decision Log — `journal/`

`journal/` is this repo's **de-facto ADR log**, and nothing else links to it. If you are asking
"why is it built this way" and `documentation/` does not say, the answer is usually here.

- One file per working session, named `yymmdd-descriptive-name.md` (e.g.
  `260704-jellyfin-brownouts-ffprobe-oom-root-cause.md`). 55 entries spanning 2026-03-19 to
  2026-08-22 at last count — `ls journal/*.md | wc -l` for the current number.
- **Append-only.** Entries are never rewritten to reflect later knowledge; a wrong call stays
  on the record next to the entry that corrects it.
- **A journal entry records what was true *then*; `documentation/` records what is true *now*.**
  When the two disagree, `documentation/` wins for current state and the journal explains how
  the state got there. Never "fix" a journal entry to match today's reality.
- Searchable through the `docs` MCP server (`search_docs`, `query_docs`) alongside
  `documentation/`, which is usually faster than grepping.

Write an entry whenever you make a decision, hit a non-obvious failure, or change live state —
see the "Development Journal" rules in the global instructions for the format.

## Editing Guardrails

**Safe to edit:**

- `/roles/*/` — Custom roles (atuin, immich_lxc, key_server, etc.)
- `/playbooks/` — All playbook files
- `group_vars/all/main.yml` — Global variables
- `host_vars/*/` — Host-specific overrides
- `/documentation/` — Service guides

**Never edit:**

- `~/.ansible/roles/` — External Galaxy roles, e.g. `geerlingguy.docker`, `geerlingguy.pip` (installed
  during `make requirements`; `ansible.cfg` puts them on `roles_path` after `./roles`). They are **not**
  in this repo — there is no `roles/geerlingguy.*/`. Pin versions in `requirements.yml` instead.
- `~/.ansible/collections/` — External collections (managed by ansible-galaxy, installed during `make requirements`)
- `.ansible-lint` — Only with maintainer approval
- `ansible.cfg` — Core config (coordinate before changes)
- `requirements.yml` — Specifies collection/role versions (changes require `make requirements` to reinstall)
