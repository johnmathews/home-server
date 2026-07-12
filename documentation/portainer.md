# Portainer

Portainer CE runs on the infra VM (`portainer` container, `:9000`, public at
`portainer.itsa-pizza.com` behind Zero Access). It is the fleet-wide Docker API:
every docker host runs a **Portainer agent** (`:9001`) registered as an endpoint,
and two things consume that view:

1. The Portainer UI itself (container management across all hosts).
2. The **container-status-exporter** (infra VM, `:8081`), which polls
   `/api/endpoints/{id}/docker/...` for container state/health and image
   freshness metrics — feeding the Grafana "Image Freshness" dashboard and the
   container alert rules. A host without a registered endpoint is invisible to
   all of that.

## Agents are Ansible-managed (since 2026-07-12)

Every docker role's compose file carries the same `portainer-agent` service
(image `portainer/agent:{{ portainer_agent_version }}`, pinned in
`group_vars/all/main.yml` — keep it matched to the server version; server was
2.39.1 LTS when pinned). `roles/jellyfin_lxc` uses a static compose file with a
literal pin — sync it by hand when bumping.

Before 2026-07-12 the agents were hand-run containers (~a year stale); they were
removed and replaced by the compose-managed ones on: jellyfin, immich,
tubearchivist, paperless, music, open-webui, prometheus, traefik, agent.
`media-vm` and `pve` already managed theirs (pve still deploys 2.24.1 until the
next full `make pve`; the 2.39.1 image is pre-pulled there).

## Registering a new endpoint

Deploying the agent does NOT register it — Portainer must be told about it once:

```sh
# from the infra VM (the exporter's API key has admin rights)
TOKEN=$(grep "^PORTAINER_TOKEN=" /srv/infra/.env | cut -d= -f2-)   # note: -f2-, token contains '='
curl -s -H "X-API-Key: $TOKEN" -X POST http://localhost:9000/api/endpoints \
  -F "Name=<hostname>" -F "EndpointCreationType=2" \
  -F "URL=tcp://<ip>:9001" -F "TLS=true" \
  -F "TLSSkipVerify=true" -F "TLSSkipClientVerify=true"
```

(or Portainer UI → Environments → Add environment → Docker Standalone → Agent).
The container-status-exporter discovers new endpoints automatically on its next
collection cycle.

## Upgrading agents

Bump `portainer_agent_version` in `group_vars/all/main.yml` (match the server),
pre-pull `portainer/agent:<version>` on each host (compose handlers use
`pull: never`), update the jellyfin static compose pin, then `make <host>` per
host. Upgrade the server first: it's `portainer/portainer-ce` (rolling tag) in
`roles/infra_vm` — pull + recreate on infra.
