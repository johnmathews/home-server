# Route navidrome, music, timer, and docs through Traefik

## Problem

Navidrome audio streams were cutting out after 10-15 minutes. Investigation revealed
that `navidrome.itsa-pizza.com` and `music.itsa-pizza.com` were routed directly from
cloudflared to the backend (192.168.2.109), bypassing Traefik entirely. This meant
Traefik's 600s read/write/idle timeouts were not applied, leaving the stream subject
to Cloudflare's shorter default connection lifecycle timeouts.

The Traefik config already had routers and services defined for navidrome and music,
but the cloudflared ingress rules pointed directly to the backend IPs instead of
through Traefik.

## Changes

### cloudflared ingress (`roles/cloudflared_lxc/defaults/main.yml`)

Rerouted four services through Traefik (192.168.2.108) with `set_host_header: true`:
- `navidrome` (was: 192.168.2.109:4533)
- `music` / Feishin (was: 192.168.2.109:9180)
- `timer` (was: 192.168.2.106:8082)
- `docs` (was: 192.168.2.106:3003)

### Traefik dynamic config (`roles/traefik_lxc/templates/routers.yml.j2`)

- Added `timer` and `docs` routers, each with `force-https-proto`, `security-headers`,
  and `public-rl` middleware
- Added `timer-svc` (192.168.2.106:8082) and `docs-svc` (192.168.2.106:3003)
- Added `public-rl` rate limiter (200 req/s, 300 burst, keyed on CF-Connecting-IP)
- Applied `public-rl` to the existing `music` (Feishin) router

### Documentation

Updated `traefik.md`, `cloudflared.md`, and `navidrome.md` to reflect the new routing,
correct inaccurate rate limit values, and document the streaming timeout fix.

## Deploy

```bash
make traefik && make cloudflared
```

Also need to update Cloudflare Access policies to remove Zero Access for timer, docs,
and music subdomains (if they had it).
