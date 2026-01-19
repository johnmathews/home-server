[TOC]

Monitors the MikroTik hAP ax3 router using [MKTXP](https://github.com/akpw/mktxp), a Prometheus exporter that pulls
metrics via the RouterOS API.

## Architecture

```
MikroTik Router (192.168.2.1:8728) → MKTXP Container (infra:49090) → Prometheus
```

## Router Setup

Enable the API and create a read-only user on the router:

```routeros
/ip service enable api
/user add name=mktxp_exporter group=read password=YOUR_PASSWORD
/user set mktxp_exporter group=read,api
```

## Deployment

Add credentials to vault:

```yaml
vault_mikrotik_exporter_username: mktxp_exporter
vault_mikrotik_exporter_password: YOUR_PASSWORD
```

Deploy:

```sh
make infra t=mikrotik_exporter
make prometheus
```

## Verification

Test API connectivity from infra VM:

```sh
nc -zv 192.168.2.1 8728
```

Check container logs:

```sh
docker logs mikrotik_exporter
```

Verify metrics endpoint:

```sh
curl -s http://192.168.2.106:49090/metrics | head -20
```

## Metrics

Key metrics exposed (all prefixed with `mktxp_`):

- `interface_tx_byte`, `interface_rx_byte` - Network throughput
- `wireless_clients_count` - Connected WiFi clients
- `dhcp_lease_count` - Active DHCP leases
- `system_cpu_load` - Router CPU usage
- `health_temperature` - Router temperature

## Configuration

Router IP is set in `group_vars/all/main.yml`:

```yaml
mikrotik_router_ip: 192.168.2.1
```

MKTXP config templates are in `roles/infra_vm/templates/mikrotik_exporter/`.
