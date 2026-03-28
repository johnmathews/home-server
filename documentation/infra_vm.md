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
| Docker compose dir    | /srv/apps                                        |
| Ansible               | make infra                                       |
| Role                  | roles/infra_vm                                   |
+-----------------------+--------------------------------------------------+
```

## Service Inventory

```
+----------------------------+-----------------------------------------------------+-------+-----------------------------+
| Container                  | Image                                               | Port  | URL                         |
+----------------------------+-----------------------------------------------------+-------+-----------------------------+
| documentation-ui           | ghcr.io/johnmathews/documentation-ui:latest         | 3003  | docs.itsa-pizza.com         |
| documentation-mcp-server   | ghcr.io/johnmathews/documentation-mcp-server:latest | 8085  | -                           |
| grafana                    | grafana/grafana-oss:latest                          | 3000  | grafana.itsa-pizza.com      |
| loki                       | grafana/loki:latest                                 | 3100  | loki.itsa-pizza.com         |
| alloy                      | grafana/alloy:latest                                | 12345 | -                           |
| homepage                   | ghcr.io/gethomepage/homepage:latest                 | 3002  | dash.itsa-pizza.com         |
| uptime-kuma                | louislam/uptime-kuma:latest                         | 3001  | uptime.itsa-pizza.com       |
| portainer                  | portainer/portainer-ce:latest                       | 9000  | portainer.itsa-pizza.com    |
| dozzle                     | amir20/dozzle:latest                                | 9999  | dozzle.itsa-pizza.com       |
| mkdocs                     | squidfunk/mkdocs-material:latest                    | 8000  | server-docs.itsa-pizza.com  |
| timer                      | ghcr.io/johnmathews/gym-timer:latest                | 8082  | timer.itsa-pizza.com        |
| sre-ui                     | ghcr.io/johnmathews/sre-assistant:latest            | 8501  | sre.itsa-pizza.com          |
| sre-api                    | ghcr.io/johnmathews/sre-assistant:latest            | 8001  | -                           |
| mikrotik_exporter          | ghcr.io/akpw/mktxp:latest                          | 49090 | -                           |
| container-status-exporter  | ghcr.io/johnmathews/container-status-exporter:latest| 8081  | -                           |
| atuin                      | ghcr.io/atuinsh/atuin:latest                        | 8888  | atuin.itsa-pizza.com        |
| atuin_database             | postgres:14                                         | -     | -                           |
| node-exporter              | prom/node-exporter:latest                           | 9100  | -                           |
| cadvisor                   | gcr.io/cadvisor/cadvisor:latest                     | 8080  | -                           |
| iperf3                     | networkstatic/iperf3                                | 5201  | -                           |
+----------------------------+-----------------------------------------------------+-------+-----------------------------+
```

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

- **Documentation UI** — Custom documentation browser served at docs.itsa-pizza.com (port 3003).
  Connects to the docserver API.
- **Documentation MCP Server** — Indexes documentation from git repos and local mkdocs. Stores
  embeddings in ChromaDB. Memory limit: 1.5GB. See `documentation/docserver.md` for details.
- **MkDocs** — Renders home server documentation as a static site. Source at
  `/srv/infra/mkdocs/docs`, served at port 8000.

### SRE Assistant

- **SRE UI** — Streamlit-based SRE assistant interface. Memory limit: 96MB.
- **SRE API** — Backend API with ChromaDB for runbook search. Uses Claude Agent SDK for LLM
  interactions. Memory limit: 384MB. Health check via Python httpx.
- **SRE Ingest** — One-time ingestion job for runbooks (runs with Docker profile `setup`).

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
| documentation-mcp-server | 1536MB | ~500MB    |
| grafana                  | 256MB  | ~183MB    |
| loki                     | 200MB  | ~125MB    |
| uptime-kuma              | 192MB  | ~142MB    |
| homepage                 | 192MB  | ~122MB    |
| alloy                    | 128MB  | ~82MB     |
| sre-api                  | 384MB  | ~134MB    |
| sre-ui                   | 96MB   | ~63MB     |
| cadvisor                 | 96MB   | ~45MB     |
+--------------------------+--------+-----------+
```

## Ansible Tasks

The role splits tasks across multiple files:

- `tasks/main.yml` — Docker compose deployment, .env file, directory creation
- `tasks/homepage.yml` — Homepage dashboard configuration files
- `tasks/docserver.yml` — Documentation server source config
- `tasks/file-browser.yml` — File browser setup
- `tasks/mikrotik_exporter.yml` — MKTXP configuration
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

All services accessible via Cloudflare Tunnel with Zero Access:

```
+-----------+--------------------+
| Prefix    | Service            |
+-----------+--------------------+
| (root)    | Homepage (3002)    |
| dash      | Homepage (3002)    |
| docs      | Docs UI (3003)     |
| charts    | Grafana (3000)     |
| grafana   | Grafana (3000)     |
| loki      | Loki (3100)        |
| portainer | Portainer (9000)   |
| dozzle    | Dozzle (9999)      |
| atuin     | Atuin (8888)       |
| timer     | Timer (8082)       |
| sre       | SRE UI (8501)      |
| uptime    | Uptime Kuma (3001) |
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
/srv/apps/loki/              — Loki data and config
/srv/apps/alloy/             — Alloy config
/srv/apps/docserver/         — Docserver config
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
- **Docserver high memory**: ChromaDB embeddings use ~500MB. If hitting the 1.5GB limit,
  check number of indexed repos in `sources.yaml`
- **Atuin sync failing**: Check PostgreSQL health: `docker logs atuin_database`
