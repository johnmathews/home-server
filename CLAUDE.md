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
make check         # Dry-run of full site.yml (no changes)
make ci            # lint + check (pre-commit validation)
make site          # Execute full provisioning
```

**Running single targets:** `make <target>` (e.g., `make media`, `make traefik`) with optional flags:

- `TAGS=tagname` or `t=tagname` — run specific tag
- `SKIP=tagname` or `s=tagname` — skip specific tag
- `LIMIT=hostname` or `l=hostname` — limit to one host

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
+-------------------+----------------+------------------+--------------------------------------+
| Host              | Local IP       | Tailscale IP     | Key Services                         |
+-------------------+----------------+------------------+--------------------------------------+
| pve               | 192.168.2.214  |                  | Proxmox UI :8006                     |
| pbs               | 192.168.2.200  |                  | Proxmox Backup Server                |
| cloudflared_lxc   | 192.168.2.101  |                  | Cloudflare Tunnel                    |
| mailcow-vm        | 192.168.2.103  |                  | Mailcow (retired)                    |
| nas_vm            | 192.168.2.104  |                  | TrueNAS (NFS/SMB shares)            |
| media-vm          | 192.168.2.105  |                  | Sonarr, Radarr, qBittorrent, etc.   |
| infra-vm          | 192.168.2.106  |                  | Grafana, Prometheus, Loki, etc.      |
| agent_lxc         | 192.168.2.107  | 100.125.185.47   | Gateway :18789, Canvas :18793        |
| traefik_lxc       | 192.168.2.108  |                  | Reverse proxy (Traefik)              |
| jellyfin_lxc      | 192.168.2.110  |                  | Jellyfin media server                |
| immich_lxc        | 192.168.2.113  |                  | Immich photo management              |
| music_lxc         | 192.168.2.109  |                  | Navidrome music streaming :4533      |
| prometheus_lxc    | 192.168.2.115  |                  | Prometheus metrics                   |
| tubearchivist_lxc | 192.168.2.116  |                  | TubeArchivist                        |
| paperless_lxc     | 192.168.2.117  |                  | Paperless-ngx document store         |
| open_webui_lxc    | 192.168.2.119  |                  | Open WebUI                           |
| key_server        | 192.168.2.201  |                  | TrueNAS encryption key server        |
+-------------------+----------------+------------------+--------------------------------------+
```

## SSH Aliases

`~/.ssh/config` defines host aliases for all hosts (e.g., `ssh agent` = `john@192.168.2.107`). Use the short
alias names when SSH-ing. Run `grep "^Host " ~/.ssh/config` to list all aliases.

## Documentation Index

Service-specific guides in `/documentation/`. Read the relevant doc before working on a service.

- `adguard-unbound.md` — DNS privacy and ad blocking (MikroTik → AdGuard → Unbound → Quad9)
- `ansible_build_commands.md` — Make commands and tags quick reference
- `cloudflare-api.md` — Cloudflare API reference for DNS, Tunnel, Access, and Redirect automation
- `cloudflared.md` — Cloudflare Tunnel setup, proxied services, DNS routes, architecture
- `domain-migration.md` — Migration plan from itsa.pizza to itsa-pizza.com (multi-session project)
- `disks.md` — Proxmox host disk management and backup storage
- `immich_lxc.md` — Immich photo management, environment variables, vault config
- `index.md` — Top-level project overview and conventions
- `iperf3-speedtest.md` — Network speed testing between server and clients
- `key_server.md` — TrueNAS dataset encryption key server
- `media_vm.md` — Media VM services (Mullvad VPN, qBittorrent, Sonarr, Radarr)
- `mikrotik-exporter.md` — MikroTik router Prometheus exporter (MKTXP)
- `monitor_nfs_smb_mounts.md` — NFS/SMB mount health monitoring
- `navidrome.md` — Navidrome music streaming, NFS mount, Subsonic API clients
- `agent.md` — OpenClaw architecture, LXC setup, macOS app, Tailscale, known issues
- `paperless.md` — Paperless-ngx document store and training schedule
- `quiet_hours.md` — Night-time container pausing for HDD spindown
- `river.md` — Grafana Alloy (River config language) log shipping to Loki
- `share_drives_nfs_smb.md` — NFS/SMB share setup and Ansible automation
- `shell_environment.md` — Zsh, Powerlevel10k, CLI tools across all hosts
- `systemd.md` — systemd service management reference
- `tailscale.md` — VPN setup, DNS privacy, remote Ansible access
- `traefik.md` — Traefik reverse proxy dashboard and API
- `jellyfin_lxc.md` — Jellyfin LXC setup, plugins, NFS monitoring issue, 10.11.x known issues
- `proxmox_host_tuning.md` — ZFS ARC, KSM, VM ballooning, memory management
- `truenas.md` — TrueNAS scripts: share refresh, disk spindown, exporter
- `ups.md` — UPS monitoring via Network UPS Tools (NUT)

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
