# AGENTS.md

Use the context7 MCP server when reading documentation or github repos etc.

## Project Purpose

Ansible playbooks and roles for provisioning a Proxmox-based home server with VMs/LXCs for storage (TrueNAS), media
streaming (Jellyfin, Sonarr, Radarr, qBittorrent), monitoring (Prometheus, Grafana), and other services. Automates
deployment, configuration, and updates using a Makefile-driven workflow.

## Architecture & Structure

- **Root**: Ansible playbooks in `/playbooks/`, roles in `/roles/`
- **Collections**: Community Ansible collections and Prometheus collection (installed to `~/.ansible/collections/`)
- **Configuration**: `inventory.ini` (hosts), `group_vars/all/` (global vars), `host_vars/` (per-host overrides)
- **Documentation**: `/documentation/` directory with service-specific guides
- **Key files**: `ansible.cfg` (roles path), `makefile` (all commands), `.ansible-lint` (lint rules), `requirements.yml` (collection versions)

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
