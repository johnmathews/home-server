# Prometheus Metrics Collection

## Purpose

Central metrics collection for the entire home server infrastructure. Scrapes metrics from
node exporters, cAdvisor, and service-specific exporters across all hosts. Grafana on the
infra VM queries Prometheus for dashboards.

## Quick Reference

```
+-----------------------+--------------------------------------------------+
| Host                  | prometheus_lxc (192.168.2.115)                   |
| SSH                   | ssh prometheus (user: root)                      |
| Web UI                | prometheus.itsa-pizza.com                        |
| Port                  | 9090                                             |
| Docker compose dir    | /srv/apps                                        |
| Ansible               | make prometheus                                  |
| Role                  | roles/prometheus_lxc                             |
+-----------------------+--------------------------------------------------+
```

## Docker Containers

```
+----------------+------------------------------------+-------+----------------------------+
| Container      | Image                              | Port  | Purpose                    |
+----------------+------------------------------------+-------+----------------------------+
| prometheus     | prom/prometheus:latest              | 9090  | Metrics collection + query |
| node_exporter  | node-exporter:v1.12.1              | 9100  | Host metrics               |
| cadvisor       | cadvisor:v0.55.1                   | 18080 | Container metrics          |
| alloy          | grafana/alloy:v1.18.0              | 12345 | Log shipping to Loki       |
+----------------+------------------------------------+-------+----------------------------+
```

## Storage and Retention

- **Data path**: `/srv/apps/prometheus/data`
- **Config path**: `/srv/apps/prometheus/prometheus.yml` (read-only mount)
- **Retention by size**: 22GB (`--storage.tsdb.retention.size=22GB`)
- **Retention by time**: 100 days (`--storage.tsdb.retention.time=100d`)
- **Runs as**: UID 65534 (nobody) for security

Whichever retention limit is hit first triggers data deletion.

## Scrape Configuration

Global defaults: 30s scrape interval, 15s timeout, 15s evaluation interval.

### Scrape Jobs

```
+-------------------------------+-------------------------------------------+-----------+------------------------------+
| Job Name                      | Targets                                   | Interval  | Notes                        |
+-------------------------------+-------------------------------------------+-----------+------------------------------+
| prometheus                    | localhost:9090                             | 30s       | Self-monitoring              |
| node_exporter                 | 12 hosts on :9100                         | 30s       | Host metrics (all VMs/LXCs)  |
| cadvisor                      | 11 hosts on :18080 (infra on :8080)       | 30s       | Container metrics            |
| adguard                       | 192.168.2.111:9618                        | 30s       | DNS query metrics            |
| container-status              | 192.168.2.106:8081                        | 30s       | Container health via Portainer|
| home_assistant                | 192.168.2.102:8123/api/prometheus          | 30s       | Smart home metrics (Bearer)  |
| unbound                       | 192.168.2.111:9167                        | 30s       | DNS resolver metrics         |
| fastapi                       | 192.168.2.201:8001                        | 60s       | Key server metrics           |
| ipmi                          | 192.168.2.214:9290                        | 60s       | Server hardware metrics      |
| smartctl                      | 192.168.2.214:9633                        | 30s       | Disk SMART data (PVE only)   |
| pve_exporter                  | 192.168.2.214:9221                        | 30s       | Proxmox VM/LXC metrics      |
| disk_power_status_exporter    | TrueNAS :9635, PVE :9635                 | 30s       | Disk spin state              |
| nut                           | 192.168.2.214:9199                        | 30s       | UPS metrics                  |
| traefik                       | 192.168.2.108:8080                        | 30s       | Reverse proxy metrics        |
| mikrotik_exporter             | 192.168.2.106:49090                       | 30s       | Router metrics (MKTXP)       |
| sre-agent                     | 192.168.2.106:8001                        | 30s       | SRE assistant metrics        |
+-------------------------------+-------------------------------------------+-----------+------------------------------+
```

### Node Exporter Hosts

All hosts scraped on port 9100:

```
agent (192.168.2.107), proxmox (192.168.2.214), truenas (192.168.2.104),
media (192.168.2.105), infra (192.168.2.106), jellyfin (192.168.2.110),
immich (192.168.2.113), prometheus (192.168.2.115), tube-archivist (192.168.2.116),
paperless (192.168.2.117), open-webui (192.168.2.119), music (192.168.2.109)
```

### cAdvisor Hosts

Same hosts minus TrueNAS (no Docker). Note: infra uses port 8080 while all others use 18080.

### AdGuard Client Name Mapping

The AdGuard scrape job includes extensive `metric_relabel_configs` that map IP addresses
(both local and Tailscale) to human-readable client names. This makes DNS query dashboards
show device names instead of raw IPs.

## Relabeling

All jobs use a common relabel pattern that extracts the host IP (without port) into a `host` label:

```yaml
relabel_configs:
  - source_labels: [__address__]
    regex: '([^:]+)(?::\d+)?'
    target_label: host
    replacement: '$1'
```

The `disk_power_status_exporter` job additionally drops the `device` label to prevent
reboots from creating new time series when `/dev/sdX` letters change.

## Vault Variables

- `vault_home_assistant_token` — Bearer token for Home Assistant Prometheus endpoint

## How to Add a New Monitored Host

1. Add `node_exporter` target to the `node_exporter` job in
   `roles/prometheus_lxc/templates/prometheus/prometheus.yml.j2`:

```yaml
      - targets: ['192.168.2.XXX:9100']
        labels: {hostname: '<name>'}
```

2. Add `cadvisor` target to the `cadvisor` job (if the host runs Docker):

```yaml
      - targets: ['192.168.2.XXX:18080']
        labels: {hostname: '<name>'}
```

3. Run `make prometheus` to deploy the updated config.

4. Verify the targets appear in Prometheus UI: `prometheus.itsa-pizza.com/targets`

**Note**: All IPs are currently hardcoded. A future improvement would generate scrape
configs from inventory variables using Jinja2 loops.

## How to Add a New Service Exporter

1. Add a new `job_name` block to the prometheus config template:

```yaml
  - job_name: '<exporter-name>'
    scrape_interval: 30s
    static_configs:
      - targets: ['192.168.2.XXX:<port>']
        labels: {hostname: '<host>'}
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+)(?::\d+)?'
        target_label: host
        replacement: '$1'
```

2. Run `make prometheus`

## External Access

Accessible via Cloudflare Tunnel with Zero Access:

- `prometheus.itsa-pizza.com` → `192.168.2.115:9090`

## Relationship to Grafana

Grafana (on infra VM at 192.168.2.106:3000) has Prometheus configured as a datasource.
All Grafana dashboards query Prometheus for time-series metrics. Loki handles logs separately.

```
Exporters (all hosts) --> Prometheus (192.168.2.115:9090) --> Grafana (192.168.2.106:3000)
Alloy (all hosts) --> Loki (192.168.2.106:3100) --> Grafana (192.168.2.106:3000)
```

## Troubleshooting

- **Target DOWN in Prometheus**: Check that the exporter is running on the target host.
  SSH to the host and verify with `docker ps` or `curl http://localhost:<port>/metrics`.
- **High cardinality warnings**: Check for labels with many unique values. The AdGuard job
  has many relabel rules but cardinality is bounded.
- **Storage full**: Prometheus enforces 22GB limit. If the disk is full, check with
  `df -h /srv/apps/prometheus/data`. Reduce retention or add disk space.
- **TrueNAS smartctl disabled**: TrueNAS smartctl scraping is commented out because it
  prevents HDD spindown. Do not re-enable without understanding the spindown implications.
