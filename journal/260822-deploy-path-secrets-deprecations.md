# 2026-08-22 — Deploy path, secrets, deprecations (tidy-up session 3)

Third session of the engineering-team tidy-up cycle. Units **W7, W8, W9, W12,
W13** — five of five, nothing abandoned. PR #87.

The batch had a theme that only became obvious partway through: every unit in it
was about **something the repo asserts that the fleet does not actually do**. The
runbook said `make site` rebuilds everything; it never deployed Traefik. The repo
said the Immich key was a managed file; it was one untracked copy on one laptop.
The role said Docker came from `jammy`; the host had been noble for sixteen
months. In each case the code and the reality had quietly diverged and nothing
was watching the gap.

## What changed

- **W7** — `playbooks/site.yml` imported 19 playbooks and omitted
  `traefik_lxc.yml`. Added the import (now 20) and deleted the `vars: foo: bar`
  placeholder that had sat in `playbooks/traefik_lxc.yml` since the playbook was
  revived in 2025. Added Scenario 5 to `documentation/disaster-recovery.md` and
  put Traefik into the recovery order.
- **W8** — `roles/immich_lxc/files/immich_api_key.secret` replaced by
  `templates/immich_api_key.secret.j2`, rendered from a vaulted variable, `0600`,
  `no_log: true`.
- **W9** — `/etc/environment` on `immich_lxc` and `media-vm` is now `0600` and its
  task carries `no_log: true`. The `pve_exporter` systemd unit, which embeds the
  Proxmox API password, moved `0644` → `0600`.
- **W12** — pve docker-apps, nodesource and tailscale converted from
  `apt_repository` to `deb822_repository`.
- **W13** — `infra_vm`'s Docker repo rebuilt on a scoped keyring with a templated
  suite; the legacy global-keyring key evicted by fingerprint.

`--syntax-check` deprecation warnings: **5 → 0**.

## The things worth remembering

### `| tail` and `| grep` hide a failing exit code, and that is how a broken file shipped for twenty minutes

Session 3 edited `roles/pve/tasks/pve_exporter.yml` to add `no_log: true`, and the
line landed *between* `mode:` and `content:` — inside the module's arguments
rather than at task level. That is a YAML structure error: `pve.yml` no longer
parsed.

It went unnoticed because the check that would have caught it was run as
`make lint 2>&1 | tail -20`, which printed a reassuring
`Passed: 0 failure(s), 244 warning(s)` — a line from an *earlier* invocation's
summary format — while `ansible-lint` was in fact exiting 2. **A shell pipeline
returns the exit status of its last command**, so `make lint | tail` reports
`tail`'s success no matter what the linter did.

It surfaced when `make ci-offline` was run bare and exited 2. So session 2's CI
work paid for itself on its first real use, one session after it landed:

```console
$ .venv/bin/ansible-lint > /tmp/lint.log 2>&1; echo "exit=$?"
exit=2
$ grep -E "Failed" /tmp/lint.log
ERROR    Failed to load pve.yml playbook due to failing syntax check.
Failed: 2 failure(s), 243 warning(s) in 296 files processed of 465 encountered.
```

Run gates bare. If a pipe is unavoidable, check `${PIPESTATUS[0]}`.

### Removing a task does not remove what it wrote — three times in one session

This was flagged in the session brief and it still bit three separate ways:

1. `apt_repository` writes `/etc/apt/sources.list.d/<name>.list`;
   `deb822_repository` writes `<name>.sources`. Swapping the module leaves the
   `.list` behind, so the host ends up with the repository configured **twice**.
   Every migrated site now deletes its own `.list`.
2. `apt_key` puts the signing key in `/etc/apt/trusted.gpg`, where it is trusted
   for every repository on the host — which *is* the F16 security defect. Dropping
   the `apt_key` task changes nothing about the key already installed. `infra_vm`
   now deletes it by fingerprint (`9DC858229FC7DD38854AE2D88D81803C0EBFCD88`,
   in `defaults/main.yml`), guarded by a read-only `gpg --list-keys` probe.
3. Less obviously: `apt_repository` **refreshed the apt cache** whenever it changed
   a repo, and `deb822_repository` does not. Nothing about the module swap
   announces this. Left alone, `apt: state=latest` would have been resolving
   against a cache that predated the repository it was meant to read. Each site now
   refreshes explicitly, and the two sites with `cache_valid_time: 3600` compute it
   as `{{ 0 if <repo> is changed else 3600 }}` so a changed repo always forces one.

### F16 was not a latent risk. It had already happened, in April 2025

The evaluation graded F16 as a *potential* problem: an OS upgrade past 22.04
"**would** silently keep pulling jammy packages". Reading the host settled it in
the other direction:

```console
$ ssh infra '. /etc/os-release; echo "$ID $VERSION_ID $VERSION_CODENAME"'
ubuntu 24.04 noble
$ ssh infra 'apt-cache policy docker-ce | head -3'
docker-ce:
  Installed: 5:29.6.1-1~ubuntu.22.04~jammy
```

The sequence is worth recording because it is a general failure mode, not a Docker
one. Ubuntu's release-upgrader did exactly the right thing in April 2025: it
disabled the Docker source and wrote a `noble` replacement
(`download_docker_com_linux_ubuntu.sources`, `Enabled: no`, still on disk).
**Ansible then overwrote that correct decision on the next `make infra`**, and on
every run for sixteen months. Configuration management reasserting a stale literal
is stronger than a one-off manual fix, which is normally the point — and is
precisely the hazard when the literal is wrong.

Filed as **F30**. The consequence W13's risk note had not anticipated is that
*fixing* it is not free: templating the suite migrates the host's Docker packages
from the jammy build to the noble build, which restarts the daemon and every
container on the monitoring VM. That was put to the user as a decision rather than
absorbed silently. Converged with approval; `docker-ce` is now
`5:29.7.2-1~ubuntu.24.04~noble`, `apt-get update` is warning-free, and all 21
containers came back.

### The plan's fix for W9 would have broken a live consumer

W9's plan text said to move the secrets "to a `0600` file under `/etc/profile.d/`".
Files in `/etc/profile.d/` are sourced by the *user's* shell — at `0600 root:root`
the user cannot read them, so the variables would simply have vanished. The
consumer is `media-vm:/home/john/extract-photos/bin/epm`, which reads
`IMMICH_API_KEY` and the Pushover pair from its environment as user `john`, and it
is not Ansible-managed.

What actually works is leaving the delivery mechanism alone and tightening the file:
`pam_env` reads `/etc/environment` **as root** during PAM session setup, before
privileges drop. So `0600 root:root` still reaches every login shell while removing
other local accounts' read access. That was verified on the host before adopting it,
not reasoned about:

```console
$ ssh media 'sudo chmod 600 /etc/environment'
$ ssh media 'echo "user=$(whoami)"; echo "IMMICH_SHARE_USER=[${IMMICH_SHARE_USER:-UNSET}]"; \
             cat /etc/environment >/dev/null 2>&1 && echo READABLE || echo NOT-READABLE'
user=john
IMMICH_SHARE_USER=[John]
NOT-READABLE
```

Variable delivered, file unreadable. Exactly the intended split.

### The Immich secret was already vaulted, under a different name

W8's plan said to render the file from `vault_immich_cli_api_key`. It does not
match. Comparing SHA-256 rather than printing anything:

| artifact | sha256 (newline stripped) |
| --- | --- |
| `roles/immich_lxc/files/immich_api_key.secret` | `1b6e1b82…aca1b00` |
| `vault_immich_key` | `1b6e1b82…aca1b00` |
| `vault_immich_cli_api_key` | `5651bb11…0b3c5206` |

Both candidates are 42 characters, so length told us nothing — only the hash did.
The deployed copy on the host hashes identically to the repo file, so three
independent artifacts agreed and there was never a question of *which* key was
live; the plan had simply named the wrong variable. Proven after converge: the
deployed file's sha256 is unchanged at `0f894a77…`, and only its mode moved.

The untracked file was **not** deleted. It is redundant now, but deleting the last
on-disk copy of a credential is the user's call.

## A leak, caused by the verification step itself

W9's acceptance criterion contains an explicit warning: *"Do not verify by running
the play with `-vv` and reading the secrets into the transcript."* That path was
correctly avoided — `no_log` was confirmed by the task reporting
`changed: [immich_lxc] => (item=(censored due to no_log))`.

Then the secrets were leaked anyway, by an ad-hoc check run *after* the play:

```sh
# WRONG — prints the value whenever the variable is set
echo "API_KEY_present=[${IMMICH_API_KEY:+yes}${IMMICH_API_KEY:-NO}]"
```

`${VAR:-fallback}` expands to **the value** when the variable is set; the fallback
only appears when it is unset. The intent was a presence test and the construct is
a value test. Two live credentials — `vault_immich_media_vm_api_key` and
`vault_pushover_media_vm_app_api_token` — went into the transcript in cleartext
and **need rotating**. Filed as **F32**.

The safe form, for future use:

```sh
[ -n "$VAR" ] && echo present || echo absent
```

The lesson is narrower than "be careful with secrets". It is that the *controls* in
a plan were written against the anticipated risk (verbose Ansible output) and the
leak came through an unanticipated channel a few seconds later. A `no_log` on the
task does nothing about the shell you type next.

## Corrections to the improvement plan

Recorded in `improvement-plan.md` before implementation began, as C1–C4:

- **C1** — W12's criterion said `--syntax-check` goes "5 → 1 … only `infra_vm`'s
  two remain". One and two cannot both be right; it is **5 → 2**. Its title,
  "the four mechanical `apt_repository` sites", is also off by one: there are four
  such sites in total but one belongs to W13, so W12 owns three.
- **C2** — W8 named the wrong vault variable (above).
- **C3** — W13 understated the defect and its blast radius (above).
- **C4** — W9's prescribed mechanism would have broken `epm` (above).

This is the third consecutive session to find an acceptance criterion that could
not do its job. The failure mode has now appeared in two distinct shapes: a
criterion that **cannot pass** in the session that owns it (sessions 1 and 2), and
a criterion that **cannot fail** regardless of the defect. Session 4's DONE-WHEN
contains an example of the second — "`grep -c '^\`\`\`' CLAUDE.md` is even" is
already true, at 8, while the fences are still broken — so it has been replaced in
the handover with one that discriminates.

## Follow-up filed but not fixed

**F31** — `INJECT_FACTS_AS_VARS` is deprecated and removed in ansible-core
**2.24**, which is *earlier* than the 2.25 removal that motivated W12/W13. So the
repo has now cleared the later deadline while the earlier one is untouched: 19
sites (`ansible_env` ×6, `ansible_hostname` ×5, `ansible_distribution_release` ×4,
`ansible_distribution` ×3, `ansible_os_family` ×1).

It does not appear in `--syntax-check`, only at task runtime, which is why the
Phase 1 deprecation sweep — which counted syntax-check warnings — reported five
and not twenty-four. Worth a work unit; the migration itself is mechanical.

## Smaller things

- `make site` runs `shell_environment` and `tailscale` against each host **twice**:
  once via the host's own playbook `roles:` list, once via the standalone
  `shell_environment.yml` / `tailscale.yml` imports. W7 makes `traefik_lxc` the
  17th host to do this rather than introducing an anomaly, so it was left alone —
  but it is real duplicated work on every full run.
- Two tasks gained `check_mode: false`: the new gpg probe, and the pre-existing
  "Check if Node.js is already installed". Both are read-only, and the `command`
  module skips itself under `--check`, so without it the fact they register is
  empty and **every task gated on it is reported as changed in a dry run when it
  would really skip**. `make check` was quietly lying about the nodejs path.
- Nothing on the Immich host reads `/srv/apps/immich/immich_api_key.secret` —
  a `grep -rl` across `/srv /etc /usr/local /root /home` found no references. It is
  deployed and, as far as that host is concerned, unread. Not investigated further;
  noted in case a later session wonders whether it can go.
