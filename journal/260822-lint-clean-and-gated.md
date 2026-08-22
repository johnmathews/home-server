# 2026-08-22 — Lint clean, then gated (tidy-up session 2)

Second of nine sessions in the engineering-team tidy-up cycle. Units W10, W11,
W5, W6. PR #83.

The order was load-bearing: clear the lint failures first, then land the gate, so
the gate is green on merge and red only on a regression. Landing it the other way
round would have meant merging a workflow that was red on arrival, and the usual
response to that is to weaken the gate.

## What changed

**W10 — 21 blocking lint failures → 0.** Fifteen were whitespace, brackets, tabs
and indentation, including one in `.ansible-lint` itself: the lint config was
failing lint. Six were `risky-shell-pipe`. Three rules are annotated with `# noqa`
rather than "fixed", each with the reason inline — most importantly
`document_library_lxc`'s missing `mode:`, which is deliberate because the
document-store dataset uses NFSv4 ACLs and rejects `chmod` over NFS.

**W11 — `make lint` scope, and `ci` split.** `make lint` was scoped to
`playbooks/ roles/`, hiding 6 failures. `ci: lint check-ports check` never reached
its last two stages, because `lint` exits 2 and make stops at the first failed
prerequisite. Split into `ci-offline` (this checkout only) and `ci`
(`ci-offline` + the live dry run).

**W5 — the enable-gate inverted, and 523 un-gated files gated.** Details below.

**W6 — the sleep_hours suite proved green on `ubuntu-latest`.** F35 refuted.

## The three things worth remembering

### `set -o pipefail` alone would have broken all six shell-pipe sites

Debian's `/bin/sh` is dash, which has no `pipefail`. Adding the option without
also setting `executable: /bin/bash` turns each hardened task into a syntax error.
The plan described these as "one-line additions"; they are two. The repo already
had the correct shape at `roles/shell_environment/tasks/uv.yml` — `set -eo
pipefail` **and** `executable: /bin/bash` — which is what made the omission
obvious once compared.

### A guard that names a path nothing writes never fires

`roles/pve/tasks/pve_exporter.yml` had `creates: /root/.cargo/bin/uv` while the
very next task symlinked from `/root/.local/bin/uv`. uv moved its install
location; the guard was never updated. So `curl -LsSf https://astral.sh/uv/install.sh | sh`
re-ran as root on **every single play** — and without `pipefail`, an error page
piped into `sh` exits 0 and the task reports `ok`. Both halves had to be wrong for
this to be invisible, and both were.

Confirmed fixed against the live host rather than by reading: `make pve
EXTRA="--check" TAGS=metrics` now reports `Install uv (if not already present)` as
`ok` instead of running it. The task that wrote the same abandoned `.cargo/bin`
path into `/root/.profile` was deleted with it. **The stale `export PATH` line
remains in `/root/.profile` on pve** — it points at a directory that does not
exist, so it is inert, but it will not remove itself and Ansible no longer manages
it.

### `roles/tailscale/tasks/proxmox-lxc-setup.yml` is orphaned

Nothing in `playbooks/` or `roles/` references it with `include_tasks` or
`import_tasks`. The evaluation graded its unguarded `pct list | awk` as a
medium-severity silent-failure path (F20); it is unreachable on any live code
path. Fixed anyway — the file is linted, and a future wire-up would inherit the
bug — but W25 should decide whether the file survives at all.

## The gate that could not fail

`.github/workflows/test.yml` decided whether to run anything by grepping
`host_vars/` for `sleep_hours_enabled:\s*true`. All four host_vars set it to
`false`, so the grep never matched, every real step reported `skipped`, and the
job reported success. From 2026-01-27 to today. Seven months of green checks on
`main` and on PRs, attesting to nothing — including on session 1's own PR #81.

The failure mode was unsafe by default in the precise sense: a renamed variable, a
typo, and a deliberately-disabled feature all produced the same answer, and the
answer was "green".

Kept and inverted, per the Phase 2 decision. `scripts/check-sleep-hours-gate.py`
returns three outcomes where the grep returned two:

| outcome | condition |
| --- | --- |
| run | some targeted host declares `sleep_hours_enabled: true` |
| skip | every targeted host declares it `false` — a *verified* skip |
| ERROR | missing/unparseable `host_vars/`, a targeted host with no declaration, or a value that is not a YAML boolean |

"Targeted host" is derived, not hardcoded: it is the `hosts:` of every playbook
applying `roles/sleep_hours`. Add the role to a fifth playbook and that host is
required to declare the variable from then on.

`workflow_dispatch` gains a boolean `force`, so the suite can be exercised without
fabricating a commit or editing `host_vars`.

## 523 of 580 files triggered nothing

`test.yml`'s paths filter covers `roles/sleep_hours/**` and `tests/**` — 57 files,
9.8%. The other 523 — 23 of 24 roles, all 22 playbooks, every Jinja template, the
whole of `scripts/` — could be changed with no workflow starting at all. That is
the structural reason the lint debt accumulated unnoticed.

`.github/workflows/lint.yml` is new and has **no `paths:` filter**, deliberately.
It runs `make lint`, `--syntax-check` over all 22 playbooks, `make check-ports`,
`pytest`, and the gate validator, on every push and every PR.

It builds its venv at `.venv` on purpose: the makefile invokes
`.venv/bin/ansible-lint` and friends by absolute path, so building the venv where
the makefile expects it means CI runs the operator's commands verbatim rather than
a re-implementation that can drift from them. That drift is exactly what the
`make lint` scope bug was.

## Every gate shipped with proof it goes red

A green CI run is not evidence a gate works; this repo is the proof of that. Both
gates were driven to red on scratch branches, watched, and the branches deleted.

| Gate | Injected fault | Result |
| --- | --- | --- |
| lint | 3 trailing spaces in `host_vars/pve.yml:1` | RED, [32573116700](https://github.com/johnmathews/home-server/actions/runs/32573116700) — `make lint` fails, rest skipped |
| enable-gate | `sleep_hours_enabled` → `sleep_hours_active` in one host_vars | RED, [32573284420](https://github.com/johnmathews/home-server/actions/runs/32573284420) (dispatch) and [32573342370](https://github.com/johnmathews/home-server/actions/runs/32573342370) (PR trigger) |

`host_vars/pve.yml` was chosen for the first because `host_vars/` is exactly what
the old `make lint` scope excluded — so it proves the scope fix, not merely that
the workflow runs.

**The red proof found a defect in the fix itself.** `host_vars/media-vm.yml`
matched none of `test.yml`'s paths, so the edit that breaks the gate would not
have run the gate's own workflow. `host_vars/**` and `playbooks/**` are now in the
filter — both feed the gate. This is the argument for constructing the failing
input rather than reasoning about it: the reasoning was right about the gate and
wrong about whether anything would reach it.

## W6: F35 refuted

F35 was graded `[SUSPECTED]` — "the sleep_hours suite may still fail on
`ubuntu-latest` after the `LOCK_DIR` fix" — inferred from `/run` being root-owned
on the runner and never observed. The specific reason for the suspicion was that
the last real CI run of this suite, on 2026-01-27, **failed**, and nobody recorded
why.

Dispatched with `force=true`:
[32572928371](https://github.com/johnmathews/home-server/actions/runs/32572928371).
`Total test files: 6 / Passed: 6 / Failed: 0`, 2m07s against 7–13s for the seven
months of no-op runs. `regression_enable_bug` — the test protecting the
2025-11-22 "shares never re-enabled" bug, and one of the 18 that were red before
W4 — passes.

W4's fix was sufficient. The `/run` worry never materialised because the harness
now points `LOCK_DIR` at a writable path rather than relying on `/run` at all.

## Correction to the improvement plan

**W10's "the profile line advances beyond `min`" is unreachable in the session
that owns it**, and has been moved to W24. ansible-lint computes the profile from
*all* matches, warnings included — not from blocking failures. So clearing the 21
failures gives `Passed: 0 failure(s)` but leaves the profile at `min`, because
`var-naming[no-role-prefix]` (217) and `yaml[line-length]` (11) are `warn_list`
entries *and* `basic`-profile rules:

```console
$ .venv/bin/ansible-lint --nocolor --skip-list "var-naming,yaml[line-length]"
Passed: 0 failure(s), 15 warning(s) ... Last profile that met the validation
criteria was 'moderate'. Rating: 2/5 star
```

`var-naming` is W20–W24 (sessions 6–8). `yaml[line-length]` is owned by no unit;
W24 should absorb it. The achievable ceiling is `moderate`, 2/5 stars — worth
knowing before S8 sets its own acceptance bar.

## Smaller things

- `actions/setup-python` v4 → v7. Python now comes from `.python-version` rather
  than a hardcoded `'3.14'` that disagreed with the file saying `3.13`.
- `pytest==9.0.2` pinned into `requirements.txt`, and `make test` moved onto
  `.venv/bin/python`. pytest was previously whatever the ambient `python3` had —
  the same non-determinism W1 removed from everything else.
- `make requirements` split into `requirements-python` (uv) and
  `requirements-galaxy` (ansible-galaxy). CI needs the galaxy half on its own,
  because `--syntax-check` resolves every `roles:` entry and fails on
  `geerlingguy.docker` without it. The first lint run went red for exactly this;
  fixing it is why the composite target had to be split rather than duplicated.
- `make help` went from 16 documented targets to all 33.
- `.gitignore` gains `.engineering-team/runs/`.
