# var-naming refactor complete; dead code out; ansible-lint profile

**Date:** 2026-08-23
**Units:** W24b, W24c, W25 (engineering-team cycle, session 9 of 9 — the last)
**PR:** eng-tidy-up-s9

## 1. Where it started

Session 8 left `ansible-lint var-naming[no-role-prefix]` at **64**, all in the three
largest roles: `pve` 29, `media_vm` 18, `infra_vm` 17. Eighteen of twenty roles were
prefixed; `documentation/river.md` carried a paragraph listing which roles were
through the rename and which were not, and `upgrade-procedures.md` hedged its grep
"because the var-naming refactor renames these role by role". The plan called the
half-renamed state the worst place to stop.

## 2. What was done

### 2.1 W24b, W24c — the last three roles

Same procedure as sessions 6 and 8: a word-boundary regex
(`(?<![A-Za-z0-9_])OLD(?![A-Za-z0-9_])`) applied longest-name-first, scoped to
`roles/<role>/`, skipping `files/`. Names are mechanical `<role>_<old>`, so
`media_vm_media_stack_user` and `pve_node_exporter_version` exist and ship.

```
role      vars   notable
infra_vm    17   three register: names (filebrowser_files/dirs, homepage_config_uploads)
media_vm    18   media_stack_* used 48 times across tasks/handlers/.env/compose
pve         29   nut_upsmon_pollfreq / nut_upsmon_pollfreqalert — longest-first keeps them distinct
```

`no-role-prefix`: **64 -> 0**. Across the whole refactor: 216 (session 6 start) -> 34
deleted (W20) -> 0.

### 2.2 The proofs, and a tooling trap

Per role: the four collision greps (`sidecar_<role>_`, `<role>_sidecar`,
`vault_<role>_`, nested double prefix) were empty; the pure-rename proof (every `+`
line in `git diff -U0 -- roles/` contains the new prefix) held; and the
literal-position audit — strip `{{ }}`/`{% %}`, strip the mapping key, skip
`register:/when:/loop:/…`, flag any renamed token still standing — produced **4 flags
total** (infra_vm 0, media_vm 2, pve 2), all comments, all read by hand:

```
roles/media_vm/templates/.env.j2:10,14   comments naming media_stack_mount_dir  (RENDERED — see 2.4)
roles/pve/defaults/main.yml:15,26        commented-out alternative values       (not rendered)
```

**`grep` on this machine is `ugrep 7.8.4`**, and it does not honour the
`(^|[^A-Za-z0-9_])` guard the proof relies on — it excluded nothing and made the
pve proof look like every `+` line had survived. `/usr/bin/grep` and a python
re-check agree with each other and with the expected result. Use `/usr/bin/grep`
or python for anything that matters.

### 2.3 Acceptance: rendered-file diff blocks, not byte-identity

`make check EXTRA="--diff" SKIP=shell,shell_env,terminal,tailscale,sleep` before
and after, ~34 minutes each (the `SKIP=shell` that session 8 made work is what
brought it down from 45). Sixteen hosts reached, zero unreachable, zero failed; `pbs`
is the seventeenth inventory host and is only touched by the skipped plays — nothing
renamed runs there.

Compared three ways, mechanically:

- **Rendered-file `--diff` blocks as a multiset**: baseline 15, after 16. All 15
  baseline blocks are present unchanged in the after log. The one extra block is
  `/srv/media/.env` and contains exactly the two comment lines from the audit:
  `# media_stack_mount_dir ...` -> `# media_vm_media_stack_mount_dir ...`.
- **Per-host PLAY RECAP**: 15 of 16 lines identical. `media-vm` went
  `ok=94 changed=3` -> `ok=95 changed=5`: the `.env` template task (ok -> changed)
  plus the `Restart media stack` handler it notifies.
- **Every remaining differing line, categorised**: the raw unified diff of the two
  logs had 227 differing lines. Splitting both logs into their 634 TASK/HANDLER
  sections and comparing each section's lines as a *multiset* leaves exactly two
  sections that differ — the `.env` task and the recap — plus one section present
  only in the after log, the handler. Everything else was host-order permutation
  inside multi-host tasks (`ok: [music_lxc]` / `ok: [immich_lxc]` in a different
  order), which is Ansible's fork scheduling, not the code. **Unexplained: 0.**

Session 8's other two categories (`debug: var:` output keys, warning column
numbers) did not appear this time — none of the three roles prints a variable
name.

Six of the folded expressions (cloudflared's API URL, and the tailscale /
shell_environment ×3 / proxmox_lxc_tun ones) sit in tasks the check skipped — by
`when: not ansible_check_mode` or by the SKIP tags — so the check proves nothing
about them. They are proven separately: parse old and new YAML, and the values are
identical once whitespace inside the `{{ }}` tag is collapsed (all eight; atuin's
shell differs only by a newline after `&&`).

### 2.4 W25 — dead code, and the eight header comments

Deleted: `roles/mail_vm/` (no playbook, makefile or inventory reference),
`host_vars/mailcow-vm.yml` (host absent from the inventory), the four
`cloud_image_*` variables at the top of `group_vars/all/main.yml` (referenced by
nothing), the commented-out qBittorrent password hash at
`roles/media_vm/defaults/main.yml:24` — per the recorded decision, the hash is not
being rotated and the 2025-05-07 commit stays in history; removing the comment is
the only action on F8 — and `roles/pve/tasks/node_exporter.yml`, a file that was
100% commented out with a commented-out import ("use container instead"), plus its
commented defaults. `requirements.yml:12` still says `community.general`'s only
consumer is `roles/mail_vm`; that file is on the never-edit list so it is left as a
maintainer follow-up: the collection now has no consumer in the repo.

**The eight compose header comments were fixed.** Session 7 fixed them, saw that a
comment change re-renders the compose file on eight hosts and fires their restart
handlers, and reverted so the cost could be weighed here. Weighed, and then measured
with a `--check --diff` limited to the eight hosts and compared per host against the
after-run above: on every host the only change is the compose template task going
`ok` -> `changed` with a one-line hunk (the header), plus whatever it notifies:

```
document_library_lxc  Restart all containers        recreate: always   -> stack recreated once
media_vm              Restart media stack           recreate: always   -> already firing for .env (2.2); pays once
open_webui_lxc        Restart all containers        recreate: always   -> stack recreated once
prometheus_lxc        Restart docker compose stack  recreate: always   -> stack recreated once
traefik_lxc           Restart docker compose stack  recreate: always   -> stack recreated once
tubearchivist_lxc     Restart docker compose stack  recreate: always   -> stack recreated once
infra_vm              Update docker compose stack   recreate: auto     -> handler ran, `ok`; no container change
pve                   (no notify; Start apps runs every time, recreate auto) -> file re-rendered, no container change
```

So **six stacks recreate once, at the next real `make <host>` on each** — not at merge.
Containers that recreate on every version bump anyway; the benefit is that two
templates stop claiming to be `jellyfin_lxc/files/docker-compose.yml`, a file W26
deleted. Bundle it with the next real change to each host rather than running a bare
`make site` to "converge". `roles/pve/templates/ipmi.yml.j2` also carries a stale
`# proxmox_node/...` header and was left alone — it was not part of the deferred
decision and re-rendering it restarts ipmi_exporter.

### 2.5 The ansible-lint profile

`ansible-lint` computes the profile it "met" as the first profile with zero matches,
in order min → basic → moderate → safety → shared → production. `basic` contains
`var-naming` and `yaml`, so it failed on any `no-role-prefix`, on the one
`var-naming[pattern]` (`TZ` in `group_vars`) and on any `yaml[line-length]`.
Clearing all three:

- `TZ` → `tz` in `group_vars/all/main.yml` and its seven `{{ TZ }}` consumers
  (`media_vm`, `document_library_lxc`, `family_finances_lxc` ×3, `music_lxc`,
  `open_webui_lxc`). Rendered `TZ=Europe/Amsterdam` lines unchanged; the literal
  `TZ=` env lines in other templates were never Ansible variables.
- 12 `yaml[line-length]` sites folded with `>-` block scalars. The two URLs and the
  systemd `ExecStart` cannot be folded at a space without corrupting the token, so
  they break *inside* a `{{ }}` tag, where whitespace is insignificant to Jinja.
  The 13th site was the dead `node_exporter.yml`, deleted in W25.

Result: `Last profile that met the validation criteria was 'moderate'. Rating: 2/5
star` — up from `min`, 1/5. Warnings 93 -> 15; what remains is all `safety` and
above (`package-latest` 3, `risky-file-permissions` 2, `no-changed-when` 9, `fqcn`
1) and none of it is in the plan.

## 3. Decisions worth keeping

- **Comments inside rendered templates are production state.** A var name in a
  comment in `.env.j2` or `docker-compose.yml.j2` re-renders the file when renamed;
  the literal-position audit is what surfaces it, and it has to be read, not counted.
- The "pure rename" proof and the collision greps are only as good as the `grep`
  binary. Pin to `/usr/bin/grep` or python.
- The refactor's docs scaffolding — river.md's roster, upgrade-procedures' hedge,
  CLAUDE.md's "incrementally" — was deleted, not updated to say "none". Scaffolding
  that outlives the work it scaffolded is the next stale doc.
