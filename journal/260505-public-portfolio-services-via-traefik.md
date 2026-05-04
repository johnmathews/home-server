# Public Portfolio Services via Traefik

Moved several read-only services from Cloudflare Zero Access to Traefik-proxied routing,
making them publicly accessible for portfolio demos while maintaining rate limiting.

## Changes

- **Homepage** (`itsa-pizza.com`), **Uptime Kuma** (`uptime.*`), **Speedtest** (`speed.*`)
  now route through Traefik with `public-rl` rate limiting. No authentication required.
- **SRE Streamlit app** (`sre.*`) routes through Traefik with BasicAuth gate (credentials
  in vault) plus rate limiting. Allows sharing demo access with a simple username/password.
- **Grafana public dashboards** (`stats.*`) routes through Traefik with path restriction:
  only `/public-dashboards/`, `/public/`, and `/api/public/` paths are accessible. All
  other Grafana endpoints (explore, admin, data sources) return 404. Full Grafana UI remains
  behind Zero Access on `charts.*` / `grafana.*`.

## Cleanup

Removed unused duplicate subdomains from cloudflared ingress:
- `dash` (was Grafana alias, redundant with `charts`/`grafana`)
- `subs` (was Bazarr alias, redundant with `bazarr`)
- `kids-tube` (was TubeArchivist alias, redundant with `tube`)
- `truenas` (was NAS alias, redundant with `nas`)

## Security Model

All migrated services retain four security layers:
1. Cloudflare edge (DDoS, WAF, TLS)
2. Cloudflare Tunnel (no open ports)
3. Traefik rate limiting (`public-rl`: 200/s avg, 300 burst per IP)
4. BasicAuth (SRE only) or path restriction (stats only)

## Decision: Why Not Grafana Full UI?

Grafana exposes infrastructure topology, IPs, and service names even in read-only mode.
Instead of making the full UI public, we use Grafana's built-in "Public Dashboards" feature
which renders individual curated dashboards via unique URLs with no access to explore, admin,
or other dashboards. The `stats.*` router enforces this at the proxy level.
