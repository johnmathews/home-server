# Var-naming, part one: the deletions, then ten roles

**Date:** 2026-08-22
**Units:** W20, W21, W22 (engineering-team cycle, session 6 of 9)
**PR:** eng-tidy-up-s6

## 1. What this was

`ansible-lint` reported 218 `var-naming[no-role-prefix]` warnings across 20 roles.
The user asked for the full rename, role by role, each one verified with `--check`.
This session did the part that has to come first — the deletions — and then the
first ten roles.

Result: **218 → 141**. Ten roles at zero. Every affected role's `--check --diff`
against all 17 live hosts is byte-identical to a baseline captured before the
first edit.

## 2. The 34 that had to be deleted, not renamed

Planning had already established that 34 of the 218 are deletions, and that
renaming *those* is the only way this refactor could have caused a production
regression. Six are shadowed by `group_vars` / `host_vars`; renaming them
un-shadows them.

`atuin_version` is the one that would actually have broken something.
`roles/infra_vm/defaults/main.yml` said `v18.4.0`. It is dead today because
`group_vars/all/main.yml` says `v18.13.3` and outranks it. Prefix it to
`infra_vm_atuin_version` and the role default stops being shadowed, wins, and the
Atuin **server** silently downgrades nine minor versions while the client stays
current — with no error at apply time, because the variable is defined, just
wrong. Deleted instead. Verified after:
`ansible infra-vm -m debug -a var=atuin_version` → `v18.13.3`, and the running
image is `ghcr.io/atuinsh/atuin:v18.13.3`.

The other five (`docker_user`, `docker_compose_dir`, `proxmox_api_user`, `puid`,
`guid`) hold identical values in both places, so deleting the role copy is a
no-op. The `group_vars` originals are untouched — `docker_compose_dir` in
particular is consumed by `playbooks/refresh_sidecars.yml` and eleven other roles.

The remaining 28 are orphan defaults: declared in a role, referenced nowhere in
it. Each was checked repo-wide, not just inside its own role, and every hit
outside the role turned out to be another role's own copy of the same name and
the same value.

The `nas` `safe_reboot_*` cluster is the instructive one. Six knobs that read as
configuration — `safe_reboot_enabled`, `safe_reboot_log_file`,
`safe_reboot_lock_file`, `safe_reboot_pushover_enabled`,
`safe_reboot_log_max_size_mb`, `safe_reboot_log_keep_count` — and every one of
them is hardcoded in `safe_reboot.sh.j2` (lines 38–44). Changing the default
changed nothing. `nut_admin_pass` is the same shape: `upsd.users.j2` interpolates
`vault_nut_admin_pass` directly and never reads the default that wraps it.

Deleting them is a separate commit from every rename, on purpose, so a bisect can
tell "we deleted something that mattered" from "we mis-renamed something".

## 3. The rename procedure, and why `sed` is not adequate

BSD `sed` has no `\b`. Two collisions in this repo corrupt *self-consistently* —
the result looks internally coherent and survives a naive check:

- `alloy_version` is a substring of `sidecar_alloy_version` **on the same line**:
  `alloy_version: "{{ sidecar_alloy_version }}"`. A naive replace produces
  `<role>_alloy_version: "{{ sidecar_<role>_alloy_version }}"` — a variable that
  does not exist, in a file that still parses.
- `nut_upsmon_pollfreq` is a substring of `nut_upsmon_pollfreqalert` on adjacent
  lines of both `roles/pve/defaults/main.yml` and its template. (Not touched this
  session; it is waiting in W24.)

What was used instead, scoped to `roles/<role>/` and longest name first:

```
perl-equivalent: s/(?<![A-Za-z0-9_])OLD(?![A-Za-z0-9_])/NEW/g
```

and after each role, four greps that must return nothing:
`sidecar_<role>_`, `<role>_sidecar`, `vault_<role>_`, and a nested double-prefix
pattern. All nine `sidecar_*_version` references in the renamed roles survived
untouched.

One caveat worth remembering: `vault_<role>_` is a false-positive generator for a
role literally named `key_server`, whose legitimate vault variables are
`vault_key_server_port` and `vault_key_server_auth_token`. Check the diff, not
just the grep.

Naming is mechanical — `<role>_<oldname>` — which yields clunkers like
`prometheus_lxc_prometheus_version` and
`immich_lxc_immich_public_proxy_version`. That is deliberate. A per-variable
judgement call would have broken the collision greps, which are the only thing
making a 141-variable refactor checkable.

## 4. Zero diff is the acceptance test, and it needs a pre-edit baseline

`make check EXTRA="--diff"` across all 17 hosts, captured **before** the first
edit and byte-compared after each unit. Same 75 changed tasks, same 30 diff
hunks, zero failed tasks, zero `AnsibleUndefinedVariable`, no host unreachable.
The only textual difference between two runs is ansible's per-run temp directory
name, which is normalised out.

`prometheus_lxc`'s "Copy docker-compose.yml" is the sharpest single check in the
set: it renders the template holding all four renamed pins and reported
`changed=0` before and after.

### 4.1 The makefile had to be fixed first

`make check` was the one playbook target missing `$(ANSIBLE_OPTS)`. Every flag
handed to it was silently dropped: `make check LIMIT=<host>` ran the whole fleet
anyway, and `make check EXTRA="--diff"` produced no diffs at all. Nothing errored
— the run just ignored you. Ten minutes were spent watching a "scoped" baseline
run tasks it had been told to skip before the cause was obvious. Fixed in its own
commit.

### 4.2 A hunk that was not ours

The post-W22 comparison showed one new diff hunk: family-finances image tags,
repo pinning `90eebb46` and the live host running `4947065`. It was not the
rename. PR #91 had merged and been deployed mid-session, moving `origin/main`
underneath this branch. Rebasing onto the new `origin/main` removed the hunk and
restored byte-identity. Worth writing down because the failure mode is
indistinguishable from a real regression until you look at the host's file mtime.

## 5. Documentation

Ten docs named a variable this session renamed and now name the new one:
`immich_lxc.md`, `document_library_lxc.md`, `open_webui_lxc.md`,
`tubearchivist_lxc.md` and `agent.md` for per-role image tables;
`media_vm.md` and `open_webui_lxc.md` for the deleted variables they described as
still present; `river.md` and `upgrade-procedures.md` for the cross-role
sidecar-pin convention; and `adding-a-new-service.md`, whose worked example now
shows the prefixed form so a new role does not inherit the violation on day one.

`upgrade-procedures.md` carried a verification grep anchored `^alloy_version:`
that would have silently missed every renamed role. It now allows a prefix.

No status stamp moved. Every affected doc already read `verified 2026-08-22` and
was re-read against the role before being edited — the point of the gate is that
the date is a claim somebody checked, not a number you bump to make CI quiet.

## 6. What is left

141 warnings across ten roles: `pve` (29), `shell_environment` (19), `media_vm`
(18), `infra_vm` (17), `family_finances_lxc` (14), `nfs_client` (12), `nas` (11),
`cloudflared_lxc` (10), `tailscale` (5), `proxmox_lxc_tun` (5), `sleep_hours` (1).
W23 and W24 own them. `pve` holds the `nut_upsmon_pollfreq` collision described in
§3; do that one last and check the rendered `upsmon.conf`, not just the grep.

Two smaller things noticed and left alone:

- `jellyfin_lxc`'s `smb_username` / `smb_server` are referenced only from
  commented-out tasks. They were renamed, not deleted, because they were not in
  W20's verified orphan set. They are deletion candidates.
- `playbooks/shell_environment.yml` gives its role no tag, so
  `make check SKIP=shell` cannot skip it inside `site.yml`. Harmless, but it is
  why a "skip the slow roles" dry run still takes fifteen minutes.
