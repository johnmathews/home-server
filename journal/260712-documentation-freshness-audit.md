# Documentation freshness audit — 39 docs verified against the repo

**Date:** 2026-07-12

## What was done

Four parallel audit agents checked every doc in `/documentation/` line-by-line
against the repo (roles, playbooks, makefile, inventory, group_vars/host_vars).
Result: 9 fresh, 18 minor drift, 12 materially stale. All findings were then
applied.

## Archived (per the superseded-docs convention)

- `domain-migration.md` — migration complete; Stage-4 leftovers marked moot
  (itsa.pizza expiring)
- `cloudflare-api.md` — migration research; its "Tunnel config API not
  applicable" claim had become actively wrong (the cloudflared role PUTs config
  to that API on every deploy) — superseded by `cloudflared.md`
- `traefik-log-resilience-plan.md` — Option B (json-file log rotation) was
  implemented in the traefik role; A never created, C deferred
- `documentation-improvement-plan.md` — Tiers 1–3 done in March, dormant since

## Themes in the drift

- **Version pins vs `:latest`** — several docs claimed images use `:latest`
  when roles pin versions (tubearchivist v0.5.10, atuin v18.13.3, sidecars
  alloy v1.5.1 / node-exporter v1.8.2 / cadvisor v0.49.1 per-role). The
  tubearchivist upgrade procedure as documented would have upgraded nothing.
- **Paperless afterlife** — five docs still described paperless-ngx as running
  (decommissioned 2026-07-04; the LXC now runs the library app).
- **Var locations** — multiple docs pointed at `group_vars/all/main.yml` for
  vars that live in role defaults (and vice versa).
- **quiet_hours reality gap** — the doc implied the sleep feature was enabled
  on three hosts; actually `sleep_hours_enabled: false` fleet-wide and CI
  skips the whole test suite as a result. Now stated explicitly.

## Repo-side fixes (docs were right, repo was stale)

- `roles/cloudflared_lxc/defaults`: claw ingress 18789 → **18790** (verified
  live: NanoClaw's config.json says 18790). NOT yet deployed — needs
  `make cloudflared`. NOTE: at audit time nothing was listening on either port
  on the agent LXC even though the main NanoClaw process was up — the public
  claw endpoint is broken until the gateway is running again.
- `host_vars/openclaw_lxc.yml` → `host_vars/agent_lxc.yml` (dead since the
  rename; its overrides applied to no host)
- makefile: deleted dead targets `atuin`, `media-dl`, `lint-paths` (playbooks
  never existed)
- `roles/infra_vm/tasks/main.yml`: mkdocs tag typo `documentaton` →
  `documentation`, added `mkdocs` tag
- `roles/infra_vm/templates/mkdocs.yml.j2`: removed nav entries for the two
  archived docs (docs site nav would have 404'd)
- `host_vars/media-vm.yml`: removed lidarr/soularr from
  `sleep_hours_stop_containers` (services no longer exist in compose)

## Left alone (needs owner decision)

- Sidecar version pins duplicated across 5+ roles — refactor candidate.

## Same-day follow-up: the two holds resolved

- `refresh_shares_nfs_path` → `tank/document-store` (owner-confirmed), deployed
  via `make nas t=refresh-shares` and test-run to completion — script finds the
  share (ID 19) and toggles it cleanly. Note: interrupting this script mid-run
  (e.g. piping through `head`) leaves shares DISABLED; its trap re-enables on
  SIGINT but not SIGPIPE. Always let it finish.
- `vm_id` in `playbooks/media_vm.yml`: investigated — **no role consumes
  `vm_id`** (or `vm_name`/`vm_cloud_init_*`); they're leftovers from a
  VM-provisioning role no longer in the playbook. The live media VM is
  VMID 114 (recreated ~2025-04 via the community-scripts helper, keeping MAC
  `02:00:00:00:01:05` and hence IP .105). Updated the value to 114 with an
  "unused" comment. `infra_vm.yml`'s 106 happens to still match live.
- Claw ingress fix deployed via `make cloudflared`: edge now routes
  `claw.itsa-pizza.com` → 18790 (verified in /etc/cloudflared/config.yml).
  Endpoint stays down until the NanoClaw gateway itself is listening again.
