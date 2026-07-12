# Lint and Security Fixes

**Date:** 2026-03-26
**Scope:** Full codebase evaluation, lint cleanup, security fixes, variable centralization, Docker version pinning

## Context

Ran the engineering-team skill to evaluate the project. Found 584 ansible-lint violations (28 actual errors,
rest warnings), a hardcoded API key in version control, missing `no_log` on Cloudflare API calls, and
`become_user` without `become: true` in several tasks. Also identified significant variable duplication
across roles and widespread use of `:latest` Docker image tags.

## Changes Made

### Security (Critical)

- **Hardcoded API key removed** — `roles/media_vm/templates/gluetun/gluetun_auth.toml.j2:23` had a plaintext
  API key. Replaced with `{{ vault_gluetun_api_key }}`. The key needs to be rotated and added to vault.
- **`no_log: true` added** to all 4 `ansible.builtin.uri` tasks in `roles/cloudflared_lxc/tasks/main.yml`
  that send `Authorization: Bearer {{ cloudflared_api_token }}` headers. Previously the token was visible
  in Ansible output.
- **`become: true` added** to tasks with `become_user:` in `roles/infra_vm/tasks/main.yml:35` and
  `roles/key_server/tasks/main.yml:29,55,71`. Without `become: true`, the `become_user` directive was
  silently ignored.

### Lint Fixes (584 -> 232 violations, zero errors remaining)

| Rule                  | Before | After | What was done                                      |
|-----------------------|--------|-------|----------------------------------------------------|
| fqcn[action-core]     |    179 |     0 | Migrated all bare module names to FQCN (36 files)  |
| name[casing]          |     59 |     0 | Capitalized task/handler names + updated notify refs|
| yaml[truthy]          |     44 |     0 | yes/no -> true/false (21 files)                    |
| yaml[trailing-spaces] |     43 |     0 | Removed trailing whitespace                        |
| name[play]            |     18 |     0 | Added noqa to site.yml import_playbook lines       |
| var-naming[pattern]   |     12 |     0 | TZ vars removed from role defaults (centralized)   |
| yaml[empty-lines]     |      8 |     0 | Fixed extra blank lines                            |
| jinja[spacing]        |      5 |     0 | Fixed Jinja2 variable spacing                      |
| partial-become        |      4 |     0 | Added become: true (see security section)          |
| name[template]        |      3 |     0 | Moved Jinja out of middle of task names            |
| yaml[comments]        |      2 |     0 | Added space after # in comments                    |
| load-failure          |      1 |     0 | Excluded nvim test YAML from linting               |
| key-order             |      1 |     0 | Reordered task keys (tags before block)            |

Remaining 232 are all warnings: 188 var-naming[no-role-prefix], 11 yaml[line-length], 2 fqcn[action].

### Variable Centralization

Added to `group_vars/all/main.yml`:
```yaml
TZ: Europe/Amsterdam
puid: 1001
guid: 1001
docker_user: john
docker_compose_dir: "/srv/apps"
proxmox_api_user: "api@pve"
loki_write_endpoint: "http://192.168.2.106:3100/loki/api/v1/push"
infra_vm_ip: "192.168.2.106"
```

Removed matching definitions from 13 role `defaults/main.yml` files. `roles/infra_vm` keeps its own
`docker_compose_dir: /srv/infra` (different value).

### Docker Version Pinning

Replaced `:latest` tags with pinned versions across 13 roles:
- cadvisor: `v0.49.1`
- alloy: `v1.5.1`
- node-exporter: `v1.8.2`

Version variables added to each role's defaults for easy updates. Static file
`roles/jellyfin_lxc/files/docker-compose.yml` uses literal versions (can't use Jinja2).

### Makefile and Documentation

- Added all targets to `.PHONY` declaration (was only 6, now all ~30)
- Added `make nfs` and `make n8n` targets for previously unreachable playbooks
- Fixed Infra VM IP in `readme.md:231` (was .105, should be .106)
- Updated `documentation/index.md` domain migration status from "planned" to "complete"

### .ansible-lint Updates

- Added `roles/shell_environment/files/nvim-custom/` to exclude_paths (intentional YAML errors)
- Removed fully-fixed rules from warn_list (truthy, casing, trailing-spaces, empty-lines)

## Issues Discovered During Implementation

- The FQCN migration agent incorrectly renamed `group:` and `shell:` **parameters** of the `file`/`user`
  modules to `ansible.builtin.group:` and `ansible.builtin.shell:`. These are module parameters, not
  module invocations. Fixed 91 occurrences across 23 files. Lesson: automated FQCN migration needs
  context-aware tooling that distinguishes module calls from module parameters.

- Two pre-existing `--check` mode failures exist: `shell_environment` Node.js version assertion and
  `tailscale` status parsing both get empty input in dry-run mode. Not addressed in this session.

## Remaining Work (Deferred)

- **var-naming[no-role-prefix]** (188 warnings): Role variables should be prefixed with `<role_name>_`.
  Best done incrementally per-role.
- **Prometheus config refactoring**: 255+ hardcoded IPs in `roles/prometheus_lxc/templates/prometheus/prometheus.yml.j2`.
  Should be generated from variables with Jinja2 loops. Large change needing its own session.
- **GitHub Actions CI**: No automated `make ci` on push. Requires vault secrets in GitHub.
- **Documentation**: See `documentation/archive/documentation-improvement-plan.md` for incremental plan (completed, archived 2026-07-12).
- **vault_gluetun_api_key**: Needs to be created in vault and the old key rotated.

### Cleanup

- Deleted `roles/n8n_lxc/`, `playbooks/n8n_lxc.yml`, `host_vars/n8n_lxc.yml`, and `make n8n` target.
  Service no longer exists; role was orphaned (not in inventory).

## Validation

- `ansible-lint`: 232 violations (all warnings, zero errors)
- `ansible-playbook --syntax-check`: passes
- `make -n nfs`: new target resolves correctly
