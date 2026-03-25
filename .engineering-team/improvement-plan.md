# Improvement Plan: Proxmox Home Server Ansible Project

**Date:** 2026-03-25
**Based on:** Evaluation report from same date
**Approach:** Prioritized work units, dependencies noted. Code changes require user approval.

---

## Work Units

### WU-1: Fix Hardcoded API Key (Critical)

**Priority:** Critical
**Files:**
- `roles/media_vm/templates/gluetun/gluetun_auth.toml.j2` — replace hardcoded apikey with vault variable
- `group_vars/all/vault.yml` — add `vault_gluetun_api_key` (encrypted)

**Changes:**
- Line 23: Change `apikey = "plumbers9splendid_TONI"` to `apikey = "{{ vault_gluetun_api_key }}"`
- Add vault variable (will need user to provide new rotated key value)

**Dependencies:** None
**Acceptance criteria:** No plaintext secrets in any template file. `grep -r "plumbers9splendid" roles/` returns nothing.

---

### WU-2: Add `no_log: true` to Sensitive API Calls (Critical)

**Priority:** Critical
**Files:**
- `roles/cloudflared_lxc/tasks/main.yml` — add `no_log: true` to all URI tasks with Authorization headers

**Changes:**
- Add `no_log: true` to every `ansible.builtin.uri` task that includes `cloudflared_api_token` in headers

**Dependencies:** None
**Acceptance criteria:** `ansible-lint` + manual review confirms no task leaks tokens to stdout.

---

### WU-3: Fix `partial-become` Bugs (Critical)

**Priority:** Critical
**Files:**
- `roles/infra_vm/tasks/main.yml:35` — add `become: true`
- `roles/key_server/tasks/main.yml:29, 55, 71` — add `become: true` to each

**Changes:**
- Add `become: true` at the same level as each `become_user:` directive

**Dependencies:** None
**Acceptance criteria:** `ansible-lint playbooks/ roles/ 2>&1 | grep partial-become` returns nothing.

---

### WU-4: Fix Jinja2 Spacing Errors (High)

**Priority:** High
**Files:** 5 files with jinja[spacing] violations

**Changes:**
- Fix spacing in Jinja2 expressions (e.g., `{{vault_tailscale_auth_key }}` -> `{{ vault_tailscale_auth_key }}`)

**Dependencies:** None
**Acceptance criteria:** `ansible-lint` reports 0 jinja[spacing] violations.

---

### WU-5: Name All Plays in site.yml (High)

**Priority:** High
**Files:**
- `playbooks/site.yml` — cannot add names to `import_playbook` directives (Ansible limitation)
- Individual playbooks that are missing play names (e.g., `playbooks/nfs.yml`)

**Changes:**
- Add `name:` to each play in individual playbooks where missing
- Note: `import_playbook` in site.yml cannot take a `name:` — these are false positives from ansible-lint.
  The real fix is ensuring each imported playbook's play block has a name.

**Dependencies:** None
**Acceptance criteria:** Plays in individual playbooks all have names. The site.yml import_playbook
warnings can be suppressed if desired (they're an ansible-lint limitation).

---

### WU-6: Fix YAML Truthy Values (High)

**Priority:** High
**Files:** 44 locations across multiple roles

**Changes:**
- Replace `True`/`False` with `true`/`false` throughout
- Replace `yes`/`no` with `true`/`false` where used as booleans

**Dependencies:** None
**Acceptance criteria:** `ansible-lint` reports 0 yaml[truthy] violations.

---

### WU-7: Fix Trailing Spaces and Empty Lines (Medium)

**Priority:** Medium
**Files:** 43 trailing-spaces + 8 empty-lines violations

**Changes:**
- Remove trailing whitespace from all YAML files
- Fix empty line violations

**Dependencies:** None
**Acceptance criteria:** `ansible-lint` reports 0 yaml[trailing-spaces] and yaml[empty-lines] violations.

---

### WU-8: Fix Handler and Task Name Casing (Medium)

**Priority:** Medium
**Files:** 59 name[casing] violations across multiple roles

**Changes:**
- Capitalize first letter of all task and handler names
- e.g., `restart docker compose stack` -> `Restart docker compose stack`

**Dependencies:** WU-5 (play names done first to avoid conflicts)
**Acceptance criteria:** `ansible-lint` reports 0 name[casing] violations.

---

### WU-9: Add `.PHONY` Declarations to Makefile (Medium)

**Priority:** Medium
**Files:**
- `makefile:46`

**Changes:**
- Expand `.PHONY` to include all targets: pve, mail, media, infra, key, traefik, immich, tube,
  prometheus, paperless, media-dl, music, jelly, open-webui, cloudflared, agent, dev, atuin, shell,
  share_drive_probe, tailscale, lint-paths, requirements, check, lint, clean, ci

**Dependencies:** None
**Acceptance criteria:** All Makefile targets declared as .PHONY.

---

### WU-10: Add Missing Makefile Targets (Medium)

**Priority:** Medium
**Files:**
- `makefile` — add `nfs:` and `n8n:` targets

**Changes:**
```makefile
nfs:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/nfs.yml $(VAULT) $(ANSIBLE_OPTS)

n8n:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/n8n_lxc.yml $(VAULT) $(ANSIBLE_OPTS)
```

**Dependencies:** WU-9 (add to .PHONY at same time)
**Acceptance criteria:** `make nfs` and `make n8n` work.

---

### WU-11: Fix Documentation Errors (Medium)

**Priority:** Medium
**Files:**
- `readme.md:231` — fix Infra VM IP from 192.168.2.105 to 192.168.2.106
- `documentation/index.md:20-21` — update domain migration status to "complete"

**Dependencies:** None
**Acceptance criteria:** No factual errors in readme.md or index.md.

---

### WU-12: Centralize Duplicate Variables (Medium)

**Priority:** Medium
**Files:**
- `group_vars/all/main.yml` — add centralized `default_puid`, `default_guid`, `default_tz`,
  `loki_write_endpoint`, `docker_compose_base_dir`
- Multiple role `defaults/main.yml` — reference group_vars instead of defining locally

**Changes:**
- Add common variables to group_vars/all/main.yml
- Update role defaults to reference the centralized vars (or remove duplicates)

**Dependencies:** None (but test with `make check` after)
**Acceptance criteria:** `puid`, `guid`, `TZ` defined once. Roles inherit from group_vars.

---

### WU-13: Pin Docker Image Versions (Medium)

**Priority:** Medium
**Files:** Multiple docker-compose templates across roles

**Changes:**
- Replace `:latest` with specific version tags for:
  - cadvisor, alloy, node-exporter, syncthing, flaresolverr
- Add version variables to role defaults (pattern from n8n_lxc which already does this correctly)

**Dependencies:** None
**Acceptance criteria:** `grep -r ":latest" roles/*/templates/docker-compose*` returns only
intentionally unpinned images (if any, with documented reason).

---

### WU-14: FQCN Migration for Most Common Modules (Low)

**Priority:** Low (179 violations — do incrementally)
**Files:** Across all roles

**Changes:**
- Replace bare module names with FQCN equivalents:
  - `copy` -> `ansible.builtin.copy`
  - `template` -> `ansible.builtin.template`
  - `file` -> `ansible.builtin.file`
  - `service` -> `ansible.builtin.service`
  - `command` -> `ansible.builtin.command`
  - `shell` -> `ansible.builtin.shell`
  - etc.

**Dependencies:** None
**Acceptance criteria:** `ansible-lint` fqcn[action-core] count drops significantly.
Full migration can be done incrementally per-role.

---

### WU-15: Add `var-naming` Role Prefixes (Low — Incremental)

**Priority:** Low (161 violations — do incrementally per role)
**Files:** Role defaults across all roles

**Changes:**
- Prefix role-internal variables with `<role_name>_` prefix
- Start with roles that have the most violations (traefik_lxc, tubearchivist_lxc, media_vm)

**Dependencies:** WU-12 (centralize shared vars first, then prefix role-specific ones)
**Acceptance criteria:** Steady reduction in var-naming violations over time.

---

## Work Units NOT Included (Out of Scope for This Round)

These are noted as improvements but deferred:

- **Prometheus config refactoring** (hardcoded IPs -> Jinja2 loops) — Large change, requires careful
  testing. Worth doing but should be its own focused session.
- **GitHub Actions CI pipeline** — Would be valuable (`make ci` on push) but requires setting up
  vault secrets in GitHub, which is a separate workflow.
- **Documentation for 13 undocumented roles** — Important but large scope. Better done incrementally
  as each role is next touched.
- **Molecule testing** — Would improve confidence but is a significant setup effort for a home server project.

---

## Execution Order

```
Phase 1 (Critical fixes — do first):
  WU-1  Hardcoded API key          (independent)
  WU-2  no_log on cloudflared      (independent)
  WU-3  partial-become bugs        (independent)

Phase 2 (Lint errors — do second):
  WU-4  Jinja spacing              (independent)
  WU-5  Play names                 (independent)
  WU-6  YAML truthy                (independent)

Phase 3 (Lint warnings + ops — do third):
  WU-7  Trailing spaces            (independent)
  WU-8  Name casing                (after WU-5)
  WU-9  Makefile .PHONY            (independent)
  WU-10 Makefile targets           (with WU-9)
  WU-11 Doc fixes                  (independent)
  WU-12 Centralize vars            (independent)
  WU-13 Pin Docker versions        (independent)

Phase 4 (Long tail — incremental):
  WU-14 FQCN migration             (after phases 1-3)
  WU-15 var-naming prefixes         (after WU-12)
```

**Estimated lint reduction:** WU-4 through WU-8 should eliminate ~160 violations (jinja, truthy,
trailing-spaces, empty-lines, name[casing]). WU-14 and WU-15 would address the remaining ~340
(fqcn + var-naming) but are better done incrementally.
