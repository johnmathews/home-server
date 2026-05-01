# Traefik Migration Plan: Portfolio Services

Move 5 services from Cloudflare Zero Access to Traefik-proxied routing, making them publicly accessible for portfolio demos while maintaining rate limiting. Also add path-restricted public Grafana dashboards, and clean up unused duplicate subdomains.

## Motivation

Several read-only services are currently locked behind Cloudflare Zero Access email authentication. Moving them to Traefik (with rate limiting) makes them easy to demo and share without requiring visitors to authenticate. The SRE Streamlit app gets BasicAuth as an additional gate since it exposes infrastructure details.

## Security Model

Four layers remain in place for all migrated services:

1. **Cloudflare edge** -- DDoS protection, WAF, TLS termination
2. **Cloudflare Tunnel** -- no open ports on the home network
3. **Traefik rate limiting** -- `public-rl` middleware (200/s avg, 300 burst per IP)
4. **BasicAuth** (SRE only) -- browser-native username/password prompt

## Services

| Service          | Subdomain        | Current Path  | New Path            | Auth              |
| ---------------- | ---------------- | ------------- | ------------------- | ----------------- |
| Homepage         | `itsa-pizza.com` | CF -> backend | CF -> Traefik -> BE | None (public)     |
| Uptime           | `uptime.*`       | CF -> backend | CF -> Traefik -> BE | None (public)     |
| Speed            | `speed.*`        | CF -> backend | CF -> Traefik -> BE | None (public)     |
| SRE              | `sre.*`          | CF -> backend | CF -> Traefik -> BE | BasicAuth + RL    |
| Grafana (public) | `stats.*`        | **New**       | CF -> Traefik -> BE | Path-restricted   |

`stats.*` only exposes Grafana's public dashboard paths (`/public-dashboards/`, `/public/`, `/api/public/`). All other Grafana endpoints (explore, admin, data sources, private dashboards) return 404 on this subdomain. The full Grafana UI remains on `charts.*` / `grafana.*` behind Zero Access.

**Removed subdomains** (unused duplicates, deleted from cloudflared ingress):

- `dash` -- Grafana alias, redundant with `charts`/`grafana`
- `subs` -- Bazarr alias, redundant with `bazarr`
- `kids-tube` -- TubeArchivist alias, redundant with `tube`
- `truenas` -- NAS alias, redundant with `nas`

Services NOT moving (remain behind Zero Access): Grafana (full UI), Prometheus, Loki, Portainer, Dozzle, Paperless, Proxmox, PBS, Vaultwarden, NAS, all media management apps, AdGuard, Home Assistant, and all other admin interfaces.

## File Changes

### 1. `roles/cloudflared_lxc/defaults/main.yml`

Redirect 5 ingress rules to Traefik (`192.168.2.108`), add 1 new rule, and delete 4 unused duplicates:

| Prefix     | Action                      | New service            | Add `set_host_header` |
| ---------- | --------------------------- | ---------------------- | --------------------- |
| `""`       | Redirect to Traefik         | `http://192.168.2.108` | yes                   |
| `uptime`   | Redirect to Traefik         | `http://192.168.2.108` | yes                   |
| `speed`    | Redirect to Traefik         | `http://192.168.2.108` | yes                   |
| `sre`      | Redirect to Traefik         | `http://192.168.2.108` | yes                   |
| `stats`    | **Add new**                 | `http://192.168.2.108` | yes                   |
| `dash`     | **Delete** (unused alias)   | --                     | --                    |
| `subs`     | **Delete** (unused alias)   | --                     | --                    |
| `kids-tube`| **Delete** (unused alias)   | --                     | --                    |
| `truenas`  | **Delete** (unused alias)   | --                     | --                    |

Group the Traefik-routed entries (docs, timer, homepage, uptime, speed, sre, stats) together for clarity.

### 2. `roles/traefik_lxc/templates/routers.yml.j2`

**New routers:**

- `homepage` -- matches bare domain only. Needs a direct `Host()` rule (the existing `host()` macro only handles subdomains). Middlewares: `force-https-proto`, `security-headers`, `public-rl`.
- `uptime` -- standard subdomain rule via `host()` macro. Same middlewares.
- `speed` -- same pattern and middlewares.
- `sre` -- same pattern, plus `sre-auth` middleware for BasicAuth.
- `stats` -- subdomain rule combined with `PathPrefix` to restrict accessible paths. Only `/public-dashboards/`, `/public/`, and `/api/public/` are routable. All other Grafana paths (explore, admin, private dashboards, data sources) get no route match and return 404. Middlewares: `force-https-proto`, `security-headers`, `public-rl`.

**New services:**

| Traefik Service | Backend URL                 |
| --------------- | --------------------------- |
| `homepage-svc`  | `http://192.168.2.106:3002` |
| `uptime-svc`    | `http://192.168.2.106:3001` |
| `speed-svc`     | `http://192.168.2.100:8080` |
| `sre-svc`       | `http://192.168.2.106:8501` |
| `grafana-svc`   | `http://192.168.2.106:3000` |

**New middlewares:**

```yaml
sre-auth:
 basicAuth:
  users:
   - "{{ vault_sre_basicauth_user }}"
```

The `stats` router uses a path-restricted rule in Traefik — no new middleware needed, the path restriction is in the router rule itself:

```yaml
stats:
  rule: Host(`stats.itsa-pizza.com`) &&
        ( PathPrefix(`/public-dashboards`) ||
          PathPrefix(`/public/`) ||
          PathPrefix(`/api/public/`) )
```

### 3. `group_vars/all/vault.yml`

Add `vault_sre_basicauth_user` containing an htpasswd-format credential string.

Generate with:

```sh
htpasswd -nb demo <password>
```

## Manual Step: Cloudflare Zero Access

After deploying, update Zero Access policies in the Cloudflare dashboard to bypass authentication for these subdomains:

- `itsa-pizza.com` (bare domain)
- `uptime.itsa-pizza.com`
- `speed.itsa-pizza.com`
- `sre.itsa-pizza.com`
- `stats.itsa-pizza.com`

Also delete DNS routes for removed subdomains: `dash`, `subs`, `kids-tube`, `truenas`.

## Deployment Sequence

1. Enable Grafana public dashboards feature and create portfolio dashboards
2. `make traefik` -- deploy new Traefik routers, services, and middlewares
3. `make cloudflared` -- deploy updated ingress rules
4. Update Cloudflare Zero Access policies in the dashboard
5. Delete DNS routes for removed subdomains (`dash`, `subs`, `kids-tube`, `truenas`)
6. Test each service:
   - `itsa-pizza.com` -- loads without auth
   - `uptime.itsa-pizza.com` -- loads without auth
   - `speed.itsa-pizza.com` -- loads without auth
   - `sre.itsa-pizza.com` -- prompts for BasicAuth credentials
   - `stats.itsa-pizza.com/public-dashboards/<uid>` -- loads public dashboard without auth
   - `stats.itsa-pizza.com/explore` -- returns 404 (path not allowed)
   - `charts.itsa-pizza.com` -- still requires Zero Access (full Grafana UI unchanged)
   - Confirm removed subdomains no longer resolve

## What's NOT Changing

- All other Zero Access-protected services remain unchanged
- Existing Traefik services (docs, timer, music, navidrome, immich, jelly) stay as-is
- Grafana full UI stays behind Zero Access on `charts.*` / `grafana.*`
- The `public-rl` middleware is reused -- no new rate limit definitions needed
- Remaining duplicate subdomains (`bazarr`/`subs` etc.) cleaned up as part of this work
