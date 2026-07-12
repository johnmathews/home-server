# Traefik Reverse Proxy

## Purpose

Traefik acts as a reverse proxy for services that bypass Cloudflare Zero Access policies. These services have native
apps or APIs that break when Zero Access injects an authentication redirect (302). Traefik applies rate limiting on
authentication and API routes as a compensating security control.

## Quick Reference

```
+---------------------+------------------------------------------+
| Host                | traefik_lxc (192.168.2.108)              |
| SSH                 | ssh traefik                              |
| Docker compose dir  | /srv/apps                                |
| Ansible             | make traefik                             |
| Dashboard           | traefik.itsa-pizza.com/dashboard/        |
| API overview        | traefik.itsa-pizza.com/api/overview      |
+---------------------+------------------------------------------+
```

## Architecture

Traefik does **not** handle TLS. Cloudflare terminates TLS at the edge, and the tunnel connects to Traefik over HTTP.
Traefik listens on port 80 only.

```
Internet -> Cloudflare Edge (TLS) -> Tunnel -> cloudflared LXC -> Traefik (192.168.2.108:80) -> Backend Service
```

## Services Behind Traefik

```
+-----------------+-------------------------------+-----------------------+-------------------+
| Router          | Domain                        | Backend               | Auth              |
+-----------------+-------------------------------+-----------------------+-------------------+
| immich          | immich.itsa-pizza.com          | 192.168.2.113:2283    | None (app auth)   |
| immich-share    | share.itsa-pizza.com           | 192.168.2.113:3000    | None (app auth)   |
| jelly           | jelly.itsa-pizza.com           | 192.168.2.110:8096    | None (app auth)   |
| navidrome       | navidrome.itsa-pizza.com       | 192.168.2.109:4533    | None (app auth)   |
| music           | music.itsa-pizza.com           | 192.168.2.109:9180    | None (app auth)   |
| timer           | timer.itsa-pizza.com           | 192.168.2.106:8082    | None (public)     |
| docs            | docs.itsa-pizza.com            | 192.168.2.106:3003    | None (public)     |
| homepage        | itsa-pizza.com                 | 192.168.2.106:3002    | None (public)     |
| uptime          | uptime.itsa-pizza.com          | 192.168.2.106:3001    | None (public)     |
| speed           | speed.itsa-pizza.com           | 192.168.2.100:8080    | None (public)     |
| sre             | sre.itsa-pizza.com             | 192.168.2.106:8501    | Zero Access (edge)|
| stats           | stats.itsa-pizza.com           | 192.168.2.106:3000    | Path-restricted   |
+-----------------+-------------------------------+-----------------------+-------------------+
```

These domains bypass Cloudflare Zero Access — either because native apps/APIs can't handle auth redirects (jellyfin,
immich, navidrome, music), because they are intentionally public for portfolio demos (homepage, timer, docs, uptime,
speed), or because they use alternative authentication (sre has a Cloudflare Zero Access policy applied at the edge,
stats uses path restriction to only expose Grafana public dashboards). Traefik applies rate limiting as a compensating security control on all routes.

## Configuration Files

All managed by Ansible in `roles/traefik_lxc/templates/`:

### Static config: `traefik.yml.j2`

Deployed to `/srv/apps/traefik/traefik.yml`. Defines:

- **Entrypoint `web`** on port 80 with forwarded headers trusted only from cloudflared (192.168.2.101/32)
- **API dashboard** enabled (insecure mode for LAN access)
- **Prometheus metrics** with router labels
- **File provider** watching `/etc/traefik/dynamic/` for dynamic config changes
- **Transport timeouts**: `readTimeout` and `writeTimeout` set to 0 (unlimited) for multi-hour media streams; `idleTimeout` at 600s for idle keep-alive cleanup. Safe because only cloudflared (LAN) connects to this entrypoint.

### Dynamic config: `routers.yml.j2`

Deployed to `/srv/apps/traefik/dynamic/routers.yml`. Defines routers, services, and middlewares.

**Routers** route traffic based on `Host()` rules. Each router uses Jinja2 macros to support
multiple domains (for domain migration compatibility). Priority values ensure specific routes
(like auth endpoints) are matched before generic routes.

**Services** define load balancer backends pointing to the actual service IPs.

**Middlewares:**

```
+---------------------+-----------------------------------------------------+
| Middleware          | Purpose                                             |
+---------------------+-----------------------------------------------------+
| local-only          | IP allowlist for LAN access (192.168.0.0/16, etc.) |
| force-https-proto   | Sets X-Forwarded-Proto: https for backends          |
| security-headers    | Referrer policy, XSS filter, frame deny, nosniff   |
| immich-login-rl     | Rate limit: 200/s avg, 300 burst on auth routes    |
| jelly-login-rl      | Rate limit: 240/s avg, 120 burst on general routes |
| jelly-auth-rl       | Rate limit: 5/min, 3 burst on login endpoint       |
| music-rl            | Rate limit: 200/s avg, 300 burst (navidrome)       |
| navidrome-auth-rl   | Rate limit: 5/min, 3 burst on auth endpoint        |
| public-rl           | Rate limit: 200/s avg, 300 burst (public services) |
+---------------------+-----------------------------------------------------+
```

Rate limits use `CF-Connecting-IP` header for source identification (real client IP from Cloudflare).

## Docker Containers

```
+-------------+---------------------+-------+--------------------------------------------+
| Container   | Image               | Port  | Purpose                                    |
+-------------+---------------------+-------+--------------------------------------------+
| traefik     | traefik:v3.1        | 80    | Reverse proxy                              |
| cadvisor    | cadvisor:latest     | 18080 | Container metrics for Prometheus           |
| alloy       | grafana/alloy:latest| 12345 | Log shipping to Loki                       |
+-------------+---------------------+-------+--------------------------------------------+
```

No node-exporter on this host (not present in docker-compose).

## How to Add a New Proxied Service

1. Add a router in `roles/traefik_lxc/templates/routers.yml.j2`:

```yaml
    new-service:
      rule: {{ host('new-service') }}
      entryPoints: [web]
      service: new-service-svc
      middlewares:
        - force-https-proto
        - security-headers
```

2. Add a service backend:

```yaml
    new-service-svc:
      loadBalancer:
        servers:
          - url: "http://192.168.2.XXX:<port>"
        passHostHeader: true
```

3. Add rate limiting middleware if the service has auth endpoints (copy an existing pattern).

4. Add the cloudflared tunnel route in `roles/cloudflared_lxc/defaults/main.yml`:

```yaml
  - prefix: new-service
    service: "http://192.168.2.108"    # Route through Traefik
    set_host_header: true              # If the backend needs the original Host header
```

5. Add a Cloudflare Zero Access bypass policy for the domain.

6. Deploy: `make traefik && make cloudflared`

## Dashboard Security

The dashboard runs in insecure mode (`api.insecure: true`). It's accessible:
- Locally via `192.168.2.108:8080/dashboard/`
- Externally via `traefik.itsa-pizza.com/dashboard/` (restricted to LAN IPs via `local-only` middleware)

The `traefik-ip` router (priority 600) handles direct IP access, and `traefik-dash` handles domain access.
Both apply the `local-only` middleware to restrict access to local network ranges.

## Troubleshooting

- **502 Bad Gateway**: Backend service is down. Check the backend container: `ssh <host> docker ps`
- **Rate limited (429)**: Check middleware config. Rate limits use `CF-Connecting-IP`, so all requests
  from the same client share a bucket.
- **Dashboard inaccessible externally**: The `local-only` middleware blocks non-LAN IPs. Access via
  Tailscale or directly on the LAN.
- **Config not updating**: Traefik watches the dynamic config directory. Changes should apply within
  seconds. Check Traefik logs: `ssh traefik` then `docker logs traefik`
