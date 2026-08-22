# Documentation corrected against live state (tidy-up session 4)

**Date:** 2026-08-22
**Units:** W14, W15, W16, W17 of the tidy-up improvement plan
**Branch:** `eng-tidy-up-s4`

## What this session was for

Batch 4 of the tidy-up plan: correct documentation content. The governing finding
from the evaluation was that **doc age predicted nothing**. The oldest doc in the
repo (`mikrotik-exporter.md`, 215 days) is entirely correct. Every doc that was
*wrong* described live state **outside** the repo — state git can never see. So
this was not an age-based sweep; every claim was checked against the code or a live
read, and never against another document.

Where a doc stated a mutable external number, the number was replaced with **the
command that reads it**, plus a dated "at last verification" figure. A number rots;
a command does not.

## The material find: backup retention was wrong

`documentation/pbs.md` said retention was configured on the PVE side only — "not in
PBS prune.cfg, which uses defaults" — and listed last 14 / daily 31 / weekly 26 /
monthly 12 / yearly 1.

That is not what is kept. **PBS runs its own prune job** at 12:00 keeping daily 14 /
weekly 4 / monthly 3. It is both later than the PVE vzdump job (10:00) and stricter,
so it is the binding policy. Confirmed decisively: every guest backed up for longer
than 21 days holds **exactly 21** snapshots (14+4+3), not the ~84 the documented
policy implies.

**Real retention is 21 snapshots per guest, roughly 3 months, with no yearly copy.**
Anyone reading the old doc during a restore would have believed a year-old backup
existed. `documentation/disaster-recovery.md:203` already recorded "21 snapshots,
daily — verified 2026-08-13", so the two docs had disagreed for over a week without
anyone noticing — which is exactly why doc-to-doc consistency is not evidence.

Also corrected there: datastore usage said 77%, live is 42.2% (386 of 915 GiB). The
phrase "As of last check" carried no date, which is why it could never be aged out.

## Other corrections

- `proxmox_host_tuning.md` — the infra VM row was wrong in **two** columns, not the
  one the plan flagged: 2048 MB -> 6144 MB, and balloon "none" -> "0 (off)". The
  distinction matters and the doc now records it: an absent `balloon:` key leaves
  the driver enabled at full target, while `balloon: 0` disables it outright
  (`man qm`). The other three rows verified correct and were left alone.
- `CLAUDE.md` — the code fences were broken. Notably, **the acceptance criterion
  written for this defect could not detect it**: "the fence count is even" was
  already true (8) with the file broken, and stays true under every wrong
  arrangement. The real defect was a missing closer, which put prose inside a fence
  and left the second network table outside any fence, losing the ASCII alignment
  `CLAUDE.md:5-6` itself mandates. Replaced the criterion with one that can fail:
  every `^\+---` border must lie strictly inside a fenced block, and no block may
  be empty.
- `CLAUDE.md` never referenced `journal/` — 54 entries, the de-facto ADR log,
  unreachable from the entry-point file. `grep journal CLAUDE.md` returned three
  hits and none was the directory (the docs MCP, `journalctl`, and a doc *named*
  `journal_agent.md`). Added a Decision Log section.
- `CLAUDE.md` claimed the agent LXC runs "NanoClaw Gateway :18790". NanoClaw v2
  (running 2.1.16) removed the TCP gateway; `ss` shows no listener on 18790.
  `documentation/agent.md` already had this right and was left alone.
- `river.md` cited `loki.process.drop_old`, which exists nowhere. The real
  component is `drop_logs`.
- The claim that six roles "deliberately track `:latest`" was **false and
  duplicated** across `group_vars/all/main.yml` and `playbooks/refresh_sidecars.yml`.
  Every one of them pins a literal version; there are six not five
  (`family_finances` was missing); and `traefik` has no node-exporter at all.
  `upgrade-procedures.md` already had the right story and is what the others now
  converge on. Removing the claim from one file would not have removed the copy in
  the other — grep for the claim, do not just fix the file in front of you.
- `prometheus_lxc.md` listed 16 scrape jobs against the template's 17 (the
  `library` job was missing), and undercounted node_exporter (12 -> 13) and cadvisor
  (11 -> 12) hosts. The absentee in all three was `family_finances`.
- `cloudflared.md` sent readers to `/etc/cloudflared/config.yml` — the file
  `CLAUDE.md` forbids editing — for the route list, contradicting its own Ansible
  section. Redirected to `cloudflared_ingress` in the role defaults.
- Wrote the two missing role docs: `document_library_lxc.md` (which `CLAUDE.md`
  calls the repo's reference Docker implementation, and which had nothing to read)
  and `family_finances_lxc.md`.

## F36 — `vault_tailscale_auth_key` is expired

Encountered while writing `family_finances_lxc.md`. **This is an operational defect,
not a documentation bug, and it is explicitly a non-goal of the tidy-up plan. It was
NOT fixed.** Recording it so it is not lost.

`playbooks/family_finances_lxc.yml:21-36` explains why the `tailscale` role is
omitted from that host. Two reasons, and the second is the live one:

1. The guest was cloned, so it arrived holding the document-library host's Tailscale
   node key — same node ID, same `100.100.7.47`, same `paperless.*.ts.net` name.
   Tailnet traffic for `paperless` landed on whichever machine connected last. That
   state has been wiped on the finances host.
2. Re-registering it needs a working auth key, and **`vault_tailscale_auth_key` is
   expired**: it returns "API key does not exist". The `tailscale` role calls
   `fail()` when authentication does not work, so including it would make
   `make finances` red on every run.

**Why this has gone unnoticed:** every existing host is already authenticated, so
the role's registration block is skipped for them. The dead key only bites a *new*
host — or a rebuild of an existing one, which makes it a latent disaster-recovery
problem, not just an inconvenience.

Confirmed live on 2026-08-22: `tailscale status` on `192.168.2.120` reports no
running `tailscaled`.

**Needs a decision:** refresh the key in the vault, then decide whether to add the
`tailscale` role back to `playbooks/family_finances_lxc.yml`. The app itself does not
need the tailnet — it is reached over the Cloudflare tunnel.

## F34 — `make site` unblocked (fixed here, with approval)

`playbooks/tailscale.yml` targeted `all:!nas`, which overrode
`family_finances_lxc`'s deliberate omission of the `tailscale` role. The role
calls `fail()` when authentication does not work, and with F36's key expired the
play died on that host — killing `make site` for the whole fleet. This was raised
rather than absorbed, and fixed on approval.

The host pattern is now `all:!nas:!family_finances`. Excluding by **group** matches
the existing `!nas` convention (`nas` is the group; `nas_vm` is the host). Verified
with `--list-hosts`: 15 hosts, with `nas_vm` and `family_finances_lxc` both absent.

The exclusion carries a comment explaining that it is load-bearing — the previous
one-line comment mentioned only TrueNAS, so a reader had no way to know the second
exclusion existed for a different reason. Remove it once F36's key is refreshed.

This is a second break in the same rebuild path W7 repaired, which is worth noting
as a pattern: `make site` breaks quietly, because nobody runs it until they need it.

## The immich secret file is gone (deleted here, with approval)

`roles/immich_lxc/files/immich_api_key.secret` — untracked, left in place by session
3 because deleting the last on-disk copy of a credential is the user's call.
Deleted on approval, after confirming all three of:

- its `sha256` still began `0f894a77`, matching session 3's recorded value;
- `vault_immich_key` is present in `group_vars/all/vault.yml`;
- **nothing references it.** The role deploys from
  `roles/immich_lxc/templates/immich_api_key.secret.j2`, whose entire content is
  `{{ vault_immich_key }}`. The loose file under `files/` was never an input.

## Carried forward, not actioned

- **F36** — see above. Needs the user's Tailscale admin access. Also added to the
  improvement plan's open items so sessions 5-9 cannot lose it.
- **F32** — two credentials leaked into session 3's transcript
  (`vault_immich_media_vm_api_key`, `vault_pushover_media_vm_app_api_token`) still
  need rotating.

## Method note worth keeping

`pipe | tail` and `pipe | grep` **mask the exit code**, because a pipeline returns
its last command's status. Session 3 read "Passed: 0 failure(s)" out of
`make lint | tail -20` while `make lint` was in fact exiting 2. Gates were run bare
this session. Note also that `PIPESTATUS` is bash-only — this shell is zsh, where it
is `pipestatus` and 1-indexed — so the safe habit is simply not to pipe a gate.
