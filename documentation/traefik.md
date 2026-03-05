## Traefik

View the dashboard at [https://traefik.itsa-pizza.com/dashboard](https://traefik.itsa-pizza.com/dashboard/)

API overview: [https://traefik.itsa-pizza.com/api/overview](https://traefik.itsa-pizza.com/api/overview)

## Role

Traefik acts as a reverse proxy for services that bypass Cloudflare Zero Access policies. These services have native
apps or APIs that break when Zero Access injects an authentication redirect (302).

Traefik does **not** handle TLS — Cloudflare terminates TLS at the edge, and the tunnel connects to Traefik over HTTP.
Traefik listens on port 80 only.

## Services Behind Traefik

- **Jellyfin** (`jelly.itsa-pizza.com`) — media streaming apps need direct API access
- **Immich** (`immich.itsa-pizza.com`, `share.itsa-pizza.com`) — mobile app needs direct API access
- **Navidrome** (`navidrome.itsa-pizza.com`) — Subsonic API clients need direct access
- **Music/Feishin** (`music.itsa-pizza.com`) — Feishin web client

These domains have a Cloudflare Zero Access bypass policy, so Traefik applies rate limiting on their authentication
and API routes as a compensating security control.

## Traffic Flow

```
Cloudflare Edge -> Tunnel -> cloudflared LXC -> Traefik (192.168.2.108:80) -> Service
```

## Configuration

- Static config: `traefik.yml` (entrypoints, providers)
- Dynamic config: `routers.yml` (routing rules, rate limiting, services)
- Both managed by Ansible role `traefik_lxc`

## Deployment

```sh
make traefik
```
