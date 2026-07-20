# `make refresh-sidecars`: bulk pull+recreate for the observability sidecars

**Date:** 2026-07-20

## Why

The Image Freshness dashboard flagged `grafana/alloy:latest` as outdated on five
hosts at once (agent, music, prometheus, traefik, document_library/paperless) —
exactly the roles that deliberately track `:latest` for their sidecars. Because
compose handlers use `pull: never`, `make <host>` recreates but never pulls, so
clearing the drift meant `ssh <host> 'docker pull …'` + `make <host>` five times
over. The exporter gives us bulk *visibility* of image drift; there was no bulk
*apply* to match. This adds it, without reintroducing an auto-updater (Diun was
retired 2026-07-13 precisely to keep deploys manual and controlled — see
[[260713-retire-diun]]). `refresh-sidecars` is manual-trigger, same as
`jelly-upgrade` / `immich-upgrade`.

## Changes

1. **`playbooks/refresh_sidecars.yml`** — targets the `observability_sidecars`
   group, pulls the newest images for `alloy` / `node-exporter` / `cadvisor` and
   recreates them. It runs `docker compose config --services` per host and
   intersects with the desired list, so it (a) touches only sidecars that
   actually exist on that host, never app containers, and (b) handles the
   `node_exporter` (underscore, every role) vs `node-exporter` (hyphen,
   infra_vm only) service-name split automatically. The `sidecars` var is
   overridable (`-e '{"sidecars":["alloy"]}'`) so other observability
   containers can be refreshed the same way.
2. **`inventory.ini`** — replaced the dead `alloy_clients` group (defined but
   referenced nowhere, and stale — missing traefik and pve) with an accurate
   `observability_sidecars` group of all 12 sidecar hosts, derived from the
   roles whose compose template carries the sidecar block.
3. **`makefile`** — `make refresh-sidecars` (+ `.PHONY`, help line). Honours the
   standard `LIMIT=` / `EXTRA=` knobs.
4. **`documentation/upgrade-procedures.md`** — documented the target under
   "Monitoring sidecar upgrades".

## Idempotence / safety

Idempotent, and verified so. `docker compose up -d` recreates a sidecar only when
its image digest changed, so a re-run with no new upstream image is a no-op —
observed directly: a second run on agent_lxc left the container untouched
(`Container alloy Running`, `changed=0`). Pinned hosts are therefore unaffected:
`docker compose pull` fetches the pinned tag they already run and nothing is
recreated. On `latest` hosts with a genuinely newer build, the sidecar is
recreated onto it — a few seconds' gap in that host's log shipping / scrape.

Reporting is idempotent too: the pull step is `changed_when: false` (it is a cache
fill, and `docker compose pull` prints "Pulled" even on a no-op so its output can't
signal a real download), and the recreate step reports `changed` accurately. Net:
the play reports `changed` iff a container was actually recreated.

Validated read-only against agent_lxc and infra-vm (both service-name spellings)
before the first run; `--syntax-check` and `ansible-lint` (production profile) both
clean.

## Follow-up (not done here)

The `:latest` sidecar tracking on those five roles is the root cause of the drift
(filed as WU-13 in the improvement plan). Pinning them to `sidecar_*` versions
would make the dashboard's version numbers meaningful and turn updates into a
deliberate one-line bump. `refresh-sidecars` is the pragmatic interim: it makes
the drift a one-command fix instead of removing it.
