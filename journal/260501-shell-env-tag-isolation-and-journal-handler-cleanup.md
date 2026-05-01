# Shell-env tag isolation, journal context glob, and handler cleanup

## Context

`make media tags=journal` failed with `Failed to update apt cache after 5 retries`. The failure pointed at the
`shell_environment` role rather than anything in the journal pipeline.

## Findings

1. **Three tasks at the top of `roles/shell_environment/tasks/main.yml` were tagged `[always]`** (user discovery,
   target-user fact, `apt update` + `git`/`acl` install). Per Ansible semantics, `tags: [always]` runs regardless of
   `--tags` selection. So *every* play that included this role pulled in those three tasks, including
   `tags=journal` runs that have nothing to do with shell environments.
2. **The failing `apt update` was caused by the `tomtomtom/yt-dlp` PPA**, not anything internal. The PPA host
   (`ppa.launchpadcontent.net`, `185.125.190.80`) was unreachable from media-vm — TCP/443 timing out at
   Canonical's edge. Routing reached the host (traceroute completed) but TLS handshakes hung, and ICMP showed 50%
   packet loss. The main `launchpad.net` was healthy. Classic transient PPA-fileserver overload — expected to
   resolve on its own. PPA was added manually (not Ansible-managed); nothing in the repo references it.

## Changes

### Drop `[always]` tags in shell_environment

Removed `tags: [always]` from the three prerequisite tasks. Trade-off: running scoped sub-tags
(`tags=zsh`, `tags=neovim`, etc.) standalone now requires that the role has been deployed at least once with
`tags=shell` so user discovery and apt prereqs are present. Acceptable — fresh hosts get the full role; per-tool
tweaks happen on already-bootstrapped hosts. Documented in `documentation/shell_environment.md`.

### Refactor journal context file upload

The original `Upload journal-server context files` task hand-listed each `.md` file in a loop. Split into:

1. `Upload journal-server mood dimensions` — explicit single-file copy of `mood-dimensions.toml`.
2. `Upload journal-server context files` — `with_fileglob` over `{{ role_path }}/templates/journal/context/*.md`,
   with `dest:` using `{{ item | basename }}` to preserve filename. New `.md` files dropped into the templates
   directory now ship without a playbook edit.

### Wire up `Restart journal-insights` handler

The handler already existed but wasn't notified by anything. Added `notify: Restart journal-insights` to both new
upload tasks. The journal-server reads context files and `mood-dimensions.toml` at startup, so a recreate is
required to pick up changes. Verified idempotent: when local files match remote, the handler doesn't fire.

### Clean up `roles/media_vm/handlers/main.yml`

1. Removed `remove_orphans: true` from subset handlers (`Restart journal-insights`, `Restart alloy`,
   `Restart gluetun`). On a `services:`-filtered call this only removes containers no longer in the compose file —
   redundant with the full-stack `Restart media stack` and just adds noise. Kept on `Restart media stack` only.
2. Dropped `dependencies: true` everywhere — it's the `community.docker.docker_compose_v2` default. The earlier
   inconsistency (set on subset handlers, omitted on the full-stack one) was removed by dropping it across the
   board.
3. Deleted `Restart qbittorrent` — no task notified it.
4. Reordered: `Restart gluetun` now declared before `Restart alloy`, so VPN-routed services come up before any
   later handlers that might depend on them. Handlers fire in declaration order, not notify order.
5. Added per-handler comments describing what triggers each one and why `remove_orphans` lives only on the
   full-stack handler.

## Verification

- `make media tags=journal` — ran clean, all 5 context files (`glossary.md`, `people.md`, `places.md`, `things.md`,
  `topics.md`) picked up by the glob; mood-dimensions copied; subsequent run was fully idempotent (0 changed).
- `--syntax-check` clean. `--list-tasks --tags journal` showed expected task list.
- `ansible-lint` on the touched files surfaced only pre-existing warnings (deno `curl` task, file browser/booklore
  command tasks, atuin pipefail). None introduced by this session.

## Follow-ups

1. **`tomtomtom/yt-dlp` PPA on media-vm** — if it stays unreachable for >24h, disable it or downgrade yt-dlp to
   the `noble-backports` version. Likely self-resolving.
2. **`documentation/journal_agent.md`** is broadly stale — still names the service `journal-agent`/`journal`
   instead of `journal-server`/`journal-webapp`/`journal-chromadb`, and lists outdated environment variables
   (`OPENAI_API_KEY` instead of the Gemini-based config now in use). Targeted update made for context-files +
   restart handler this session; full refresh of this doc is a separate task.
