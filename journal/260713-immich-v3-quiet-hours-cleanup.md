# Immich v3, quiet hours, open_webui launch fix, dead-host cleanup

**Date:** 2026-07-13

## 1. Immich v2.6.3 → v3.0.2

Release-notes check first: v3's breaking changes are API-surface (removed
endpoints incl. shared-link DTO changes), the pgvecto.rs→vectorchord prereq was
already satisfied, and DB migrations are forward-only (rollback = PBS restore).
Upgrade found a bug in `make immich-upgrade`: `$(MAKE) immich` does NOT recreate
containers on an image-only change (compose definition unchanged →
`recreate: auto` sees nothing to do). Fixed the target to run
`docker compose up -d` on the host after pulling — compose recreates on image-ID
change. Verified: v3.0.2, migrations "Finished", all containers healthy,
immich.itsa-pizza.com 200, share proxy recreated onto its newest build.

## 2. Quiet hours for update notifications

Grafana mute timing `quiet-hours` (22:00–09:00 Europe/Amsterdam, two ranges to
cross midnight) attached to the two image-update rules only ("Container image
stale", "App update available"). UPS/disk/watchdog alerts deliberately stay
24/7 — those are wake-me-up alerts. Suppressed notifications deliver after the
window ends.

## 3. open_webui role: unconditional launch

The role only started containers via change-triggered handlers, so a re-run
never created newly-added services (bit us during the portainer rollout).
Added the standard unconditional "Launch containers" task (recreate: auto,
pull: never, remove_orphans) like infra_vm has. The two transient rollout
failures remain undiagnosed (evidence lost to output truncation); if it recurs,
capture the full play output.

## 4. Dead-host debris

Discovery: neither mailcow-vm (103) nor the dev LXC exists on Proxmox anymore —
both were deleted at the hypervisor some time ago; only references survived.
- Portainer: deleted the "Dev LXC" endpoint → 12/12 endpoints online.
- Repo: removed [mailcow] from inventory, the `mail` make target (+ .PHONY),
  playbooks/mail_vm.yml (git preserves it), the tailscale playbook's
  `!mailcow` pattern, and the CLAUDE.md network-table row + VM-list mention.
- Left for the owner (needs Tailscale admin console; vault only has a join
  key): remove the dead `dev` and `mailcow` nodes from the tailnet.
