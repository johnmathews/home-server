# claw.itsa-pizza.com retired (NanoClaw v2 has no gateway); sidecar pins centralized

**Date:** 2026-07-12

## claw route: root cause and removal

Yesterday's finding — "nothing listening on 18789/18790 despite NanoClaw running" —
is not an outage. NanoClaw migrated v1 → v2 in May 2026 and **v2 has no TCP
gateway**: verified by grep (no `18790`, no gateway listener in
`/srv/apps/nanoclaw/src|dist`; only a localhost health server and the Slack webhook
server) and by the v2 migration notes in the nanoclaw repo docs. v2's surfaces are
the `ncl` CLI over a Unix socket (`data/ncl.sock`), the localhost health endpoint,
and Slack inbound via Tailscale Funnel (`agent.flicker-enigmatic.ts.net`).

So the claw ingress (fixed to 18790 earlier today) fronts a port that will never be
bound again. Removed the `claw` entry from `roles/cloudflared_lxc/defaults` and
deployed (`make cloudflared`, verified gone from `/etc/cloudflared/config.yml`).
Leftovers at the Cloudflare edge (the `claw` CNAME and its Access application) are
harmless orphans — delete via dashboard if tidiness demands.

Also discovered: the systemd user unit is now **`nanoclaw-583cc1c4.service`**
(suffixed with `data/install-id`), not `nanoclaw.service`. As root, logs are
reachable via `journalctl _UID=1000`; user-unit control via
`systemctl --user -M john@ …`. `documentation/agent.md` got a v2 status callout and
targeted corrections (gateway/Control UI sections marked v1-historical).

## Sidecar version pins: single-sourced

7 roles pinned identical sidecar versions (alloy v1.5.1, node-exporter v1.8.2,
cadvisor v0.49.1) in their own defaults; 5 roles track `latest`. Refactor:

- `group_vars/all/main.yml` now defines `sidecar_alloy_version`,
  `sidecar_node_exporter_version`, `sidecar_cadvisor_version`.
- Pinning roles (immich, infra_vm, pve, media_vm, open_webui, tubearchivist)
  reference them via their defaults: `alloy_version: "{{ sidecar_alloy_version }}"`.
  The indirection (rather than defining `alloy_version` globally) means the
  `latest` roles (agent, music, prometheus, traefik, document_library) are NOT
  shadowed by group_vars — no behavior change anywhere.
- `jellyfin_lxc` uses a static compose file; its dead version vars were removed and
  the file/comment now says to sync its literal pins with `sidecar_*` by hand.
- Verified: `--check --diff` on immich renders identically (changed=0); music's
  check-mode changes are pre-existing template drift (blank line + feishin quoting
  + picard dir ownership, never deployed since the Picard edit), not from this
  refactor.

## Note found in passing

`playbooks/music_lxc.yml` has undeployed drift — `make music` will recreate the
stack with a whitespace-only compose change and fix the picard dir ownership.
