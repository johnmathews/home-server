# Infrastructure VM (infra-vm)

## Purpose

Central infrastructure VM hosting monitoring, dashboards, logging, documentation, and utility
services. This is the operational backbone of the home server — most observability and management
tools run here.

## Quick Reference

```
+-----------------------+--------------------------------------------------+
| Host                  | infra-vm (192.168.2.106)                         |
| SSH                   | ssh infra (user: john)                           |
| Docker compose dir    | /srv/infra                                       |
| Ansible               | make infra                                       |
| Role                  | roles/infra_vm                                   |
+-----------------------+--------------------------------------------------+
```

## Service Inventory

Image tags use Jinja variables (e.g. `{{ grafana_version }}`) defined in `roles/infra_vm/defaults/main.yml`
(exception: `atuin_version` lives in `group_vars/all/main.yml`); only a few
services pin `:latest` directly. Container names are stable.

```
+----------------------------+-----------------------------------------------------+-------+-----------------------------+
| Container                  | Image                                               | Port  | URL                         |
+----------------------------+-----------------------------------------------------+-------+-----------------------------+
| documentation-webapp       | ghcr.io/johnmathews/unified-documentation-webapp    | 3003  | docs.itsa-pizza.com         |
| documentation-server       | ghcr.io/johnmathews/unified-documentation-server    | 8085  | -                           |
| documentation-chroma       | chromadb/chroma:1.5.8                               | 8000* | -                           |
| grafana                    | grafana/grafana-oss                                 | 3000  | grafana.itsa-pizza.com      |
| loki                       | grafana/loki                                        | 3100  | loki.itsa-pizza.com         |
| alloy                      | grafana/alloy                                       | 12345 | -                           |
| homepage                   | ghcr.io/gethomepage/homepage                        | 3002  | itsa-pizza.com (root)       |
| uptime-kuma                | louislam/uptime-kuma                                | 3001  | uptime.itsa-pizza.com       |
| portainer                  | portainer/portainer-ce                              | 9000  | portainer.itsa-pizza.com    |
| dozzle                     | amir20/dozzle                                       | 9999  | dozzle.itsa-pizza.com       |
| mkdocs                     | squidfunk/mkdocs-material                           | 8000  | server-docs.itsa-pizza.com  |
| timer                      | ghcr.io/johnmathews/gym-timer                       | 8082  | timer.itsa-pizza.com        |
| sre-webapp                 | ghcr.io/johnmathews/sre-webapp:latest               | 8501  | sre.itsa-pizza.com          |
| sre-agent                  | ghcr.io/johnmathews/sre-agent                       | 8001  | -                           |
| sre-ingest                 | ghcr.io/johnmathews/sre-agent                       | -     | -                           |
| mikrotik_exporter          | ghcr.io/akpw/mktxp                                  | 49090 | -                           |
| diun                       | crazymax/diun                                       | -     | Image-update notifier       |
| container-status-exporter  | ghcr.io/johnmathews/container-status-exporter       | 8081  | -                           |
| atuin                      | ghcr.io/atuinsh/atuin                               | 8888  | atuin.itsa-pizza.com        |
| atuin_database             | postgres:14                                         | -     | -                           |
| node-exporter              | prom/node-exporter                                  | 9100  | -                           |
| cadvisor                   | gcr.io/cadvisor/cadvisor                            | 8080  | -                           |
| iperf3                     | networkstatic/iperf3                                | 5201  | -                           |
+----------------------------+-----------------------------------------------------+-------+-----------------------------+
```

`*` documentation-chroma's port 8000 is internal-only on the docker network; not published on the host.

## Service Groups

### Monitoring and Logging

- **Grafana** — Dashboards and visualization. Data at `/srv/infra/grafana/data`, config at
  `/srv/infra/grafana/grafana.ini`. Memory limit: 256MB.
- **Loki** — Log aggregation. Receives logs from Alloy instances across all hosts. Config at
  `./loki/config.yml`, data at `./loki/data`. Memory limit: 200MB. Runs as root (UID 0).
- **Alloy** — Local log shipper for the infra VM itself. Ships Docker container logs and
  journald to Loki. Memory limit: 128MB. See `documentation/river.md` for Alloy config details.
- **Uptime Kuma** — Uptime monitoring for all services. Data at `/srv/infra/uptime_kuma/data`.
  Memory limit: 192MB.

### Dashboards and Management

- **Homepage** — Main dashboard at the root domain. Config at `/srv/infra/homepage/config`.
  Memory limit: 192MB. Allowed hosts include the primary domain and any migration domains.
- **Portainer** — Docker container management UI. Data at `/srv/infra/portainer/data`.
- **Dozzle** — Real-time Docker log viewer. Read-only access to Docker socket.

### Documentation

- **documentation-webapp** — Custom documentation browser served at docs.itsa-pizza.com (port 3003).
  Connects to the docserver API.
- **documentation-server** — Indexes documentation from git repos and local mkdocs, exposes an MCP
  API on port 8085. Memory limit: 1GB (512MB reservation). Talks to `documentation-chroma` for vector
  storage. See `documentation/docserver.md` for details.
- **documentation-chroma** — Dedicated ChromaDB sidecar (chromadb/chroma:1.5.8). Internal-only on
  port 8000. Memory limit: 256MB. The server depends on this being healthy before starting.
- **MkDocs** — Renders home server documentation as a static site. Source at
  `/srv/infra/mkdocs/docs`, served at port 8000.

### SRE Assistant

- **sre-webapp** — Streamlit-based SRE assistant interface. Memory limit: 64MB.
- **sre-agent** — Backend agent service. Uses Claude Agent SDK for LLM interactions. Memory
  limit: 768MB. Health check via Python httpx.
- **sre-ingest** — One-time ingestion job for runbooks (runs with Docker profile `setup`).

### Exporters and Metrics

- **MikroTik Exporter (MKTXP)** — Scrapes MikroTik router metrics for Prometheus. Config at
  `/srv/infra/mikrotik_exporter`. See `documentation/mikrotik-exporter.md`.
- **Container Health Exporter** — Custom exporter that queries Portainer API for container
  status. Exposes metrics on port 8081.
- **Node Exporter** — Standard host metrics (CPU, memory, disk, network).
- **cAdvisor** — Container-level metrics. Read-only, no-new-privileges, limited to Docker
  containers only.

### Utilities

- **Timer** — Gym timer web app.
- **Atuin** — Shell history sync server. Uses PostgreSQL backend with health check.
  Data at `/srv/infra/atuin`. Open registration enabled.
- **iperf3** — Network speed testing server (TCP and UDP on port 5201).
  See `documentation/iperf3-speedtest.md`.

## Memory Limits

Several containers have explicit memory limits to prevent the VM from being overwhelmed:

```
+--------------------------+--------+-----------+
| Container                | Limit  | Typical   |
+--------------------------+--------+-----------+
| documentation-server     | 1GB    | ~500MB    |
| documentation-chroma     | 256MB  | varies    |
| documentation-webapp     | 192MB  | ~50MB     |
| grafana                  | 256MB  | ~183MB    |
| loki                     | 200MB  | ~125MB    |
| uptime-kuma              | 192MB  | ~142MB    |
| homepage                 | 192MB  | ~122MB    |
| alloy                    | 128MB  | ~82MB     |
| sre-agent                | 768MB  | ~134MB    |
| sre-webapp               | 64MB   | ~40MB     |
| cadvisor                 | 96MB   | ~45MB     |
+--------------------------+--------+-----------+
```

## Ansible Tasks

The role splits tasks across multiple files:

- `tasks/main.yml` — Docker compose deployment, .env file, directory creation
- `tasks/homepage.yml` — Homepage dashboard configuration files
- `tasks/docserver.yml` — Documentation server source config
- `tasks/file-browser.yml` — File browser setup (orphaned: not imported by `main.yml` and no
  filebrowser service in the compose file)
- `tasks/mikrotik_exporter.yml` — MKTXP configuration
- `tasks/diun.yml` — Diun watched-images list (`templates/diun-images.yml.j2` → `/srv/infra/diun/images.yml`)
- `tasks/mkdocs.yml` — MkDocs documentation site

### Ansible Tags

```sh
make infra                    # Full deployment
make infra t=homepage         # Homepage config only
make infra t=docserver        # Docserver config only
make infra t=mkdocs           # MkDocs config only
make infra t=alloy            # Alloy log shipper config only
```

## External Access

All services are reachable via Cloudflare Tunnel, but with two different routing models
(see `roles/cloudflared_lxc/defaults/main.yml`):

Via Traefik (192.168.2.108) — public, rate-limited, **no Zero Access**:

```
+-----------+--------------------+
| Prefix    | Backend            |
+-----------+--------------------+
| (root)    | Homepage (3002)    |
| docs      | Docs UI (3003)     |
| timer     | Timer (8082)       |
| sre       | SRE UI (8501)      |
| uptime    | Uptime Kuma (3001) |
+-----------+--------------------+
```

Direct to the infra VM — protected by Zero Access:

```
+-----------+--------------------+
| Prefix    | Service            |
+-----------+--------------------+
| charts    | Grafana (3000)     |
| grafana   | Grafana (3000)     |
| loki      | Loki (3100)        |
| portainer | Portainer (9000)   |
| dozzle    | Dozzle (9999)      |
| atuin     | Atuin (8888)       |
+-----------+--------------------+
```

## Data Directories

```
/srv/infra/grafana/          — Grafana data and config
/srv/infra/uptime_kuma/      — Uptime Kuma data
/srv/infra/portainer/        — Portainer data
/srv/infra/atuin/            — Atuin config and database
/srv/infra/homepage/config/  — Homepage dashboard config
/srv/infra/mikrotik_exporter/— MKTXP config
/srv/infra/mkdocs/           — MkDocs source files
/srv/infra/loki/             — Loki data and config
/srv/infra/alloy/            — Alloy config
/srv/infra/docserver/        — Docserver config
```

## Related Documentation

- `documentation/river.md` — Alloy/Loki log pipeline configuration (River language)
- `documentation/docserver.md` — Documentation MCP server details
- `documentation/mikrotik-exporter.md` — MikroTik router metrics exporter
- `documentation/iperf3-speedtest.md` — Network speed testing

## Troubleshooting

- **Grafana not loading**: Check container status and port binding:
  `ssh infra && docker logs grafana`
- **Logs not appearing in Loki**: Check Alloy is running on the source host and Loki is
  accepting writes: `curl http://192.168.2.106:3100/ready`
- **Homepage blank**: Verify config files in `/srv/infra/homepage/config/` and check
  `HOMEPAGE_ALLOWED_HOSTS` includes the domain being accessed
- **Docserver high memory**: documentation-server has a 1GB limit (do not raise it without raising
  the VM's RAM — see the comment in `roles/infra_vm/templates/docker-compose.yml.j2`). If approaching it, check the
  number of indexed repos in `sources.yaml` and inspect `documentation-chroma` separately — vector
  store growth shows up in that container, not the server.
- **Atuin sync failing**: Check PostgreSQL health: `docker logs atuin_database`
- **`make infra tags=docker` fails with `port is already allocated`**: Zombie compose
  containers (names prefixed with a 12-char hex hash, e.g. `956930400e05_uptime-kuma`)
  are holding ports. These are leftovers from an interrupted `recreate: always` run.
  Clean them up:

  ```sh
  ssh infra-vm "docker ps -a --filter label=com.docker.compose.project=infra \
    --format '{{.Names}}' | grep -E '^[0-9a-f]{12}_' | xargs -r docker rm -f"
  ```

  Then re-run the deploy. If many services are affected, a full
  `cd /srv/infra && docker compose down --remove-orphans && docker compose up -d`
  is faster.

## Deploy Model (How `make infra` Converges the Stack)

The "Launch containers" task in `roles/infra_vm/tasks/main.yml` runs
`docker_compose_v2` with `state: present` and `recreate: auto`. This means:

- Compose diffs the rendered `docker-compose.yml` against the running stack
  using each container's `com.docker.compose.config-hash` label.
- Only services whose config actually changed are recreated.
- `remove_orphans: true` deletes containers for services that were removed
  from the compose file.

**Why not `state: restarted`?** That maps to `docker compose restart`, which only
stops/starts existing containers in place. Container config is immutable after
creation, so a restart will silently keep the old port mappings, env vars, mounts,
and image tag — even after you've edited the template. Always use `state: present`
for converge tasks.

**Handlers** (e.g. `Restart grafana`, `Restart loki`) use `recreate: always`
because they fire only when a specific config file changed — forcing recreate of
the affected service is exactly what's wanted there.
