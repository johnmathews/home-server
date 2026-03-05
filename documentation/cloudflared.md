This LXC container runs the `cloudflared` service, enabling secure remote access to services hosted on your Proxmox
server via Cloudflare Tunnel.

The container was created using the Proxmox Community Scripts project:
https://community-scripts.github.io/ProxmoxVE/scripts?id=cloudflared

## Access

SSH into the container with:

```sh
ssh cloudflared
```

## Configuration

Main configuration file:

```sh
/etc/cloudflared/config.yml
```

## Updating Configuration

To apply changes to the Cloudflare Tunnel configuration:

```sh
cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
sudo systemctl restart cloudflared
cloudflared tunnel route dns home-server <subdomain>.itsa.pizza
```

## Bulk DNS Update Example

Automatically update DNS routes for all configured hostnames:

```sh
for domain in $(grep hostname: /etc/cloudflared/config.yml | awk '{print $3}'); do
  cloudflared tunnel route dns home-server "$domain"
done
```

## Logging

```sh
journalctl -u cloudflared -f
```

## Useful Commands

Check configured tunnels:

```sh
cloudflared tunnel list
cloudflared tunnel info <tunnel-name>
```

Manage the systemd service:

```sh
sudo systemctl restart cloudflared
sudo systemctl status cloudflared
```

## Architecture

All external traffic flows through the Cloudflare Tunnel. The tunnel terminates at the cloudflared LXC (192.168.2.101),
which proxies requests to internal services based on hostname.

There are two routing paths:

1. **Direct to service** — Most services are routed directly from the tunnel to their internal IP/port. These are
   protected by Cloudflare Zero Access policies which require authentication before allowing access.

2. **Via Traefik** — Jellyfin, Immich, Navidrome, and Music are routed through Traefik (192.168.2.108) instead of
   directly to the service. These services bypass Cloudflare Zero Access because their native apps and APIs don't
   work with Zero Access authentication redirects. Traefik applies rate limiting on auth endpoints as a compensating
   control.

```
Internet -> Cloudflare Edge (TLS) -> Tunnel -> cloudflared LXC
                                                   |
                                +------------------+------------------+
                                |                                     |
                          Direct to service                     Via Traefik
                          (+ Zero Access)                    (bypass Zero Access,
                                                              + rate limiting)
                          e.g. grafana, sonarr,              e.g. jellyfin, immich,
                          radarr, paperless, etc.            navidrome, music
```

## Proxied Services

All services listed in `/etc/cloudflared/config.yml`. Key subdomains:

**Via Traefik (bypass Zero Access):**

- `jelly.itsa.pizza` -> Traefik -> Jellyfin (192.168.2.110:8096)
- `immich.itsa.pizza` -> Traefik -> Immich (192.168.2.113:2283)
- `share.itsa.pizza` -> Traefik -> Immich shared albums
- `navidrome.itsa.pizza` -> Traefik -> Navidrome (192.168.2.109:4533)
- `music.itsa.pizza` -> Traefik -> Feishin (192.168.2.109:9180)

**Direct (with Zero Access):**

- `itsa.pizza` / `dash.itsa.pizza` -> Homepage (192.168.2.106:3002)
- `claw.itsa.pizza` -> OpenClaw (192.168.2.107:18789)
- `charts.itsa.pizza` / `grafana.itsa.pizza` -> Grafana (192.168.2.106:3000)
- `mail.itsa.pizza` -> Mailcow (192.168.2.103:443)
- `sonarr.itsa.pizza`, `radarr.itsa.pizza`, etc. -> Media VM services
- `paperless.itsa.pizza` / `documents.itsa.pizza` -> Paperless-ngx
- `proxmox.itsa.pizza` / `pve.itsa.pizza` -> Proxmox UI
- ... (see full list in config.yml)

## Ansible

- Role: `roles/cloudflared_lxc`
- Playbook: `playbooks/cloudflared_lxc.yml`
- Deploy: `make cloudflared`
- Config template: `roles/cloudflared_lxc/templates/config.yml.j2` (uses `{{ primary_domain_name }}`)

The LXC was originally created manually via a Proxmox community script. The Ansible role manages the tunnel
config file, shell environment, and Tailscale.

## Domain Migration

A migration from `itsa.pizza` to `itsa-pizza.com` is planned. See `documentation/domain-migration.md` for the full
plan, stages, and open questions.
