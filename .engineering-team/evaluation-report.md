# Evaluation Report: Proxmox Home Server Ansible Project

**Date:** 2026-03-25
**Scope:** Full codebase evaluation — structure, quality, security, deployment, documentation

---

## Executive Summary

This is a well-structured, actively maintained Ansible project provisioning ~20 services across a Proxmox home
server. The Makefile workflow is solid and the role/playbook organization is clean. The main areas needing
attention are: **584 lint violations** (mostly warnings, but some real errors), a **hardcoded API key** in
version control, **missing `no_log` on sensitive API calls**, and **significant documentation gaps** for half
the roles. The Prometheus config template has **255+ hardcoded IPs** that should be generated from variables.

---

## Lint Results

**584 total violations** (ansible-lint). Breakdown by rule:

```
+-------+----------------------------+----------+----------------------------------------------+
| Count | Rule                       | Severity | Description                                  |
+-------+----------------------------+----------+----------------------------------------------+
|   179 | fqcn[action-core]          | warning  | Use fully qualified module names              |
|   161 | var-naming[no-role-prefix]  | warning  | Role vars need role_ prefix                  |
|    59 | name[casing]               | warning  | Names should start uppercase                 |
|    44 | yaml[truthy]               | warning  | True/False vs true/false                     |
|    43 | yaml[trailing-spaces]      | warning  | Trailing whitespace                          |
|    18 | name[play]                 | ERROR    | Unnamed plays in site.yml + nfs.yml          |
|    12 | var-naming[pattern]        | warning  | TZ variable naming convention                |
|    11 | yaml[line-length]          | warning  | Lines > 160 chars                            |
|     8 | yaml[empty-lines]          | warning  | Extra blank lines                            |
|     5 | jinja[spacing]             | error    | Bad Jinja2 spacing                           |
|     4 | partial-become[task]       | ERROR    | become_user without become (security risk)   |
|     3 | name[template]             | warning  | Name uses Jinja2 templates                   |
|     2 | yaml[comments]             | warning  | Comment formatting                           |
|     2 | fqcn[action]               | warning  | Non-core FQCN                                |
|     1 | load-failure[runtimeerror] | ERROR    | Failed to load test YAML in shell_env role   |
|     1 | key-order[task]            | warning  | Task key ordering                            |
+-------+----------------------------+----------+----------------------------------------------+
```

**Actual errors (not warnings):**
- 18 unnamed plays in `playbooks/site.yml` (all `import_playbook` lines)
- 5 Jinja spacing issues (e.g., `{{vault_tailscale_auth_key }}` missing leading space)
- 4 partial-become issues in `roles/infra_vm/tasks/main.yml:35` and `roles/key_server/tasks/main.yml:29,55,71`
- 1 load-failure on `roles/shell_environment/files/nvim-custom/test/yaml/test_sample.yaml`

---

## Strengths

1. **Clean role/playbook organization** — 23 custom roles, each with proper structure (defaults, tasks,
   handlers, templates). All roles referenced in site.yml.

2. **Solid Makefile workflow** — Intuitive targets (`make media`, `make agent`), shorthand aliases
   (`t=`, `s=`, `l=`), vault integration, lint/check/ci targets.

3. **Good secrets management** — Vault-encrypted `group_vars/all/vault.yml` with consistent `vault_*`
   prefix. `.vault_pass.txt` in `.gitignore`. Sensitive `.env` files deployed with `mode: '0600'`.

4. **Active documentation** — 29 docs in `/documentation/`, 3 recent journal entries. CLAUDE.md network
   table verified accurate against inventory.ini.

5. **Consistent template patterns** — Docker-compose templates use proper env var interpolation, vault
   variables for secrets, and appropriate file permissions.

---

## Critical Findings

### 1. Hardcoded API Key in Version Control [VERIFIED]

**File:** `roles/media_vm/templates/gluetun/gluetun_auth.toml.j2:23`
```toml
apikey = "plumbers9splendid_TONI"
```

A plaintext API key is committed to the repository. The `basic` role above it correctly uses
`{{ vault_gluetun_user }}` and `{{ vault_gluetun_password }}`, but the `api` role has a hardcoded key.

**Fix:** Move to vault as `vault_gluetun_api_key` and rotate the exposed key.

### 2. Missing `no_log` on Cloudflared API Token [VERIFIED]

**File:** `roles/cloudflared_lxc/tasks/main.yml` — multiple `ansible.builtin.uri` tasks send
`Authorization: Bearer {{ cloudflared_api_token }}` in headers without `no_log: true`. This means
the API token appears in Ansible output logs.

Compare to `roles/tailscale/tasks/main.yml:89` which correctly uses `no_log: true`.

**Fix:** Add `no_log: true` to all cloudflared URI tasks with auth headers.

### 3. `partial-become` — `become_user` Without `become` [VERIFIED]

**Files:**
- `roles/infra_vm/tasks/main.yml:35`
- `roles/key_server/tasks/main.yml:29, 55, 71`

Tasks set `become_user:` without a corresponding `become: true` at the same level. This means the
privilege escalation may not work as intended — the task runs as the connection user, ignoring `become_user`.

**Fix:** Add `become: true` alongside each `become_user:`.

### 4. Traefik Dashboard Insecure Mode [VERIFIED]

**File:** `roles/traefik_lxc/templates/traefik.yml.j2:22`
```yaml
api:
  dashboard: true
  insecure: true
```

The Traefik dashboard is enabled without authentication. It's only accessible via the local network
(Traefik listens on 192.168.2.108), but anyone on the LAN can access the full dashboard including
router/service/middleware configuration.

**Risk level:** Medium for a home network. Low if the network is fully trusted.

---

## High Priority Findings

### 5. Hardcoded IPs in Prometheus Config [SUSPECTED]

**File:** `roles/prometheus_lxc/templates/prometheus/prometheus.yml.j2` — 330 lines with 50+ hardcoded
IP:port targets. Every scrape target is a literal IP. Adding or removing a monitored host requires
manually editing this template.

**Fix:** Generate scrape configs from variables or inventory using Jinja2 loops.

### 6. Docker Image Tags — Widespread Use of `:latest` [VERIFIED]

Multiple docker-compose templates use `:latest` instead of pinned versions:
- `gcr.io/cadvisor/cadvisor:latest` (used across 13+ roles)
- `grafana/alloy:latest` (multiple roles)
- `quay.io/prometheus/node-exporter:latest` (multiple roles)

This causes unpredictable behavior on container recreation.

### 7. Readme IP Address Error [VERIFIED]

**File:** `readme.md:231` — Infra VM IP listed as `192.168.2.105` but inventory.ini confirms it's
`192.168.2.106`. Lines 189-198 also reference `.105` for what appears to be the Media VM section
(which is correct — media-vm IS .105).

### 8. Documentation Gaps — 13 Roles Without Docs [VERIFIED]

Roles without dedicated documentation files:
infra_vm, music_lxc, n8n_lxc, prometheus_lxc, open_webui_lxc, tubearchivist_lxc, nas, mail_vm,
pve, nfs_client, proxmox_lxc_tun, share_drive_probe, sleep_hours

### 9. Documentation Inaccuracy [VERIFIED]

**File:** `documentation/index.md:20-21` — States domain migration to `itsa-pizza.com` is "planned"
but it's actually complete (Stages 0-4 done per domain-migration.md).

---

## Medium Priority Findings

### 10. Missing `.PHONY` Declarations

**File:** `makefile:46` — Only declares `all site nas cloud_image media help` as PHONY. The remaining
~18 targets (infra, key, traefik, immich, tube, prometheus, paperless, etc.) are missing PHONY
declarations.

### 11. Services Binding to 0.0.0.0

- `roles/agent_lxc/templates/docker-compose.yml.j2:65` — Grafana Alloy on `0.0.0.0:12345`
- `roles/media_vm/templates/docker-compose.yml.j2:14` — `MCP_HOST=0.0.0.0`
- `roles/media_vm/templates/docker-compose.yml.j2:356` — Alloy on `0.0.0.0:12345`

Should bind to `127.0.0.1` unless external access is specifically needed.

### 12. Duplicate Variables Across Roles

`puid`, `guid`, `TZ`, `docker_compose_dir`, `proxmox_api_user` defined independently in 10+ role
defaults with identical values. Should be centralized in `group_vars/all/`.

### 13. Docker Handler Inconsistency

Some handlers use `community.docker.docker_compose_v2` with `recreate: always`, others use
`ansible.builtin.service`. The `recreate: always` pattern forces unnecessary container restarts.

### 14. Missing Makefile Targets

Playbooks `nfs.yml` and `n8n_lxc.yml` exist in `playbooks/` but have no Makefile targets.

---

## Assessment Dimensions

```
+-------------------------------+-------+----------------------------------------------------+
| Dimension                     | Score | Justification                                      |
+-------------------------------+-------+----------------------------------------------------+
| Simplicity                    | 4/5   | Clean role structure. Prometheus template is the    |
|                               |       | main complexity outlier with hardcoded IPs.         |
+-------------------------------+-------+----------------------------------------------------+
| Robustness                    | 3/5   | Missing changed_when on shell tasks, partial-become |
|                               |       | bugs, no rescue blocks for Docker/API operations.   |
+-------------------------------+-------+----------------------------------------------------+
| Security                      | 3/5   | Vault usage is good. Hardcoded API key and missing  |
|                               |       | no_log are real issues. TLS verification disabled   |
|                               |       | in several places (acceptable for home lab).        |
+-------------------------------+-------+----------------------------------------------------+
| Flexibility                   | 3/5   | 255+ hardcoded IPs, duplicate vars across roles.    |
|                               |       | Adding a host requires editing many files manually. |
+-------------------------------+-------+----------------------------------------------------+
| Test coverage                 | 1/5   | No tests. This is an Ansible project so traditional |
|                               |       | unit tests don't apply, but molecule tests, lint    |
|                               |       | in CI, or --check validation are absent from CI.    |
+-------------------------------+-------+----------------------------------------------------+
| Documentation accuracy        | 3/5   | Core docs verified accurate (cloudflared, agent,    |
|                               |       | navidrome, jellyfin). Two factual errors found.     |
|                               |       | Domain migration status outdated.                   |
+-------------------------------+-------+----------------------------------------------------+
| Documentation completeness    | 2/5   | 13 of 23 roles have no dedicated documentation.     |
|                               |       | No disaster recovery, upgrade, or new-service       |
|                               |       | guides. Paperless doc is 3 lines.                   |
+-------------------------------+-------+----------------------------------------------------+
| Deployment quality            | 3/5   | Makefile workflow is solid. No CI/CD pipeline.       |
|                               |       | Missing PHONY declarations. No GitHub Actions       |
|                               |       | workflow for validation or Docker builds.            |
+-------------------------------+-------+----------------------------------------------------+
```

---

## Bug Candidates

| # | Location | Description | Status |
|---|----------|-------------|--------|
| 1 | `roles/key_server/tasks/main.yml:29,55,71` | `become_user` without `become: true` — tasks may not escalate privileges | [VERIFIED] |
| 2 | `roles/infra_vm/tasks/main.yml:35` | Same partial-become issue | [VERIFIED] |
| 3 | `readme.md:231` | Infra VM IP wrong (105 vs 106) | [VERIFIED] |
| 4 | `documentation/index.md:20-21` | Domain migration status says "planned" but is complete | [VERIFIED] |
| 5 | `roles/shell_environment/files/nvim-custom/test/yaml/test_sample.yaml` | Fails to load (lint load-failure) | [SUSPECTED] |

---

## Architectural Assessment

**Overall:** The architecture is sound for a home server project. Roles map cleanly to services,
playbooks target individual hosts, and the Makefile provides a good operator interface.

**Concern — Prometheus config approach:** The 330-line hardcoded Prometheus config is the biggest
architectural smell. The standard Ansible approach is to generate scrape configs from inventory
or variables using Jinja2 loops, which makes adding/removing hosts automatic.

**Concern — No CI pipeline:** For an infrastructure-as-code project managing 20+ services, having
no automated validation (even just `make ci` in GitHub Actions) means lint regressions and
playbook syntax errors can accumulate. The 584 lint violations suggest this has already happened.

**Positive — Cloudflared single source of truth:** The recent refactoring to manage all tunnel
routes from a single `cloudflared_ingress` variable (documented in journal) is a good architectural
pattern that should be replicated for Prometheus targets and other cross-cutting configs.
