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
`media-vm` and `pve` already managed theirs; pve converged the same evening via
`make pve t=portainer` (its docker tasks carry the `portainer` tag).

## Security: AGENT_SECRET (added 2026-07-12)

A Portainer agent is full Docker control (it mounts `docker.sock`) listening on
`0.0.0.0:9001`. Without a shared secret, anything on the LAN that speaks the agent
protocol gets root-equivalent on the host. All agents and the server therefore
carry `AGENT_SECRET` from `vault_portainer_agent_secret`:

- server: `AGENT_SECRET=${PORTAINER_AGENT_SECRET}` via the infra `.env`
- templated roles: rendered inline in each compose's `portainer-agent` service
- jellyfin (static compose): interpolated from `/srv/apps/.env` (mode 0600,
  deployed by the role)

An agent without the matching secret is rejected by the server — so when rotating
the secret, redeploy the server first, then every host. The
`/var/lib/docker/volumes` bind-mount was also dropped from all agents (only the
UI's volume-browse feature used it). Port 9001 remains LAN-bound: there is no
management VLAN, and the secret is the effective control.

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
