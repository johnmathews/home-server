# Portainer agents Ansible-managed fleet-wide; full endpoint coverage

**Date:** 2026-07-12 (evening, after the image-freshness dashboard shipped)

## The surprise that shrank the task

The freshness dashboard covered only 8 hosts and the plan assumed 5 hosts needed
agents installed. Survey said otherwise: **every docker host already ran a
portainer agent** — hand-launched (`docker run`, untagged `latest`, ~a year old,
in no compose file). The 5 "missing" hosts (music, open-webui, prometheus,
traefik, agent) had running agents that were simply **never registered as
endpoints** in Portainer.

## What was done

1. `portainer_agent_version: "2.39.1"` pinned globally in `group_vars/all/main.yml`
   (matched to the Portainer server, 2.39.1 LTS); removed the stale per-role
   `2.24.1` defaults from media_vm and pve.
2. The same `portainer-agent` compose service added to 8 templated roles
   (immich, tubearchivist, document_library, music, open_webui, prometheus,
   traefik, agent) + a literal block in jellyfin's static compose.
3. Per host: pre-pulled `portainer/agent:2.39.1` (`pull: never` handlers),
   `docker rm -f` the hand-run agent, then `make <host>` — 10 hosts deployed.
4. Registered the 5 missing endpoints via the Portainer API (the
   container-status-exporter's API key turned out to have admin rights) —
   13 endpoints total, all online except the long-dead Dev LXC.
   Rollout wrinkle: the open_webui role starts containers only via
   change-triggered handlers, so on a rerun (compose already rendered) the new
   agent service was never created — started it with a one-off
   `docker compose up -d portainer-agent` from the rendered file.
5. pve deferred: its docker block has no tag and a full `make pve` (host tuning)
   wasn't worth one agent bump — image pre-pulled, next `make pve` upgrades it.

## Notes

- New doc: `documentation/portainer.md` (registration recipe, upgrade procedure,
  the `-f2-` token-extraction gotcha).
- The container-status-exporter picks up new endpoints automatically each cycle;
  the freshness thread was force-cycled by recreating the exporter container so
  the dashboard showed the full fleet immediately.
- Agent registration survives agent container recreation (fresh TLS certs are
  accepted because endpoints use skip-verify) — the standard portainer upgrade
  path relies on this.
