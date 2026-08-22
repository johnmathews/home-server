**Status:** current — verified 2026-08-22 · covers: roles/cloudflared_lxc/**
The ingress list and the source-of-truth note were checked against
`roles/cloudflared_lxc/` on that date.

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

**The source of truth is `cloudflared_ingress` in
`roles/cloudflared_lxc/defaults/main.yml`.** Read the route list there:

```bash
grep -A2 'prefix:' roles/cloudflared_lxc/defaults/main.yml
```

`/etc/cloudflared/config.yml` on the host is *rendered output*, not input — Ansible
overwrites it on every `make cloudflared`, so edits made there are lost and reading it
tells you only what the last deploy produced. The same variable also renders
`tunnel_config_api.json.j2`, which is pushed to the Cloudflare API; the edge pushes its
remote config back down and overrides the local file, so the API copy is what actually
routes traffic — see the **Important** note under [Updating Configuration](#updating-configuration).

## Updating Configuration

To add, remove, or change a tunnel route:

```sh
# 1. Edit the ingress rules (single source of truth)
vim roles/cloudflared_lxc/defaults/main.yml    # cloudflared_ingress list

# 2. Deploy (templates config, syncs to Cloudflare API, creates DNS records, restarts if changed)
make cloudflared
```

The `cloudflared_ingress` variable in `defaults/main.yml` is the single source of truth for all tunnel routes.
Both templates (`config.yml.j2` and `tunnel_config_api.json.j2`) render from this variable, so there is no
duplication to keep in sync.

Each entry has a `prefix` (subdomain, or `""` for the bare domain), a `service` (origin URL), and optional flags:
- `no_tls_verify: true` — for HTTPS backends with self-signed certs
- `set_host_header: true` — sets `originRequest.httpHostHeader` to the full hostname

DNS CNAME records are created automatically during deploy. The role fetches all existing CNAME records for the
zone in a single API call, compares against the hostnames derived from the ingress variable, and creates any
missing records pointing to the tunnel. No need to SSH into the LXC or run `cloudflared tunnel route dns` manually.

**Important:** The Cloudflare edge always pushes a remote tunnel config that overrides the local `config.yml` at
runtime. The Ansible role works around this by PUTting the config to the Cloudflare Tunnel API on every deploy,
keeping both in sync.

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

2. **Via Traefik** — Services routed through Traefik (192.168.2.108) bypass Cloudflare Zero Access. This
   includes native apps that break with auth redirects (Jellyfin, Immich, Navidrome, Music), public portfolio
   services (Homepage, Uptime, Speed, Docs, Timer, SRE), and services with alternative auth (Stats uses
   path-restricted Grafana public dashboards). Traefik applies rate limiting on all routes. Auth for the
   SRE app is handled by a Cloudflare Zero Access policy applied to `sre.itsa-pizza.com` at the edge.

```
Internet -> Cloudflare Edge (TLS) -> Tunnel -> cloudflared LXC
                                                   |
                                +------------------+------------------+
                                |                                     |
                          Direct to service                     Via Traefik
                          (+ Zero Access)                    (bypass Zero Access,
                                                              + rate limiting)
                          e.g. grafana, sonarr,              e.g. jellyfin, immich,
                          radarr, library, etc.              homepage, uptime, sre
```

## Proxied Services

Derived from `cloudflared_ingress` in `roles/cloudflared_lxc/defaults/main.yml` — that
list is authoritative and this one is a readable summary. Key subdomains:

**Via Traefik (bypass Zero Access):**

- `itsa-pizza.com` -> Traefik -> Homepage (192.168.2.106:3002)
- `jelly.itsa-pizza.com` -> Traefik -> Jellyfin (192.168.2.110:8096)
- `immich.itsa-pizza.com` -> Traefik -> Immich (192.168.2.113:2283)
- `share.itsa-pizza.com` -> Traefik -> Immich shared albums
- `navidrome.itsa-pizza.com` -> Traefik -> Navidrome (192.168.2.109:4533)
- `music.itsa-pizza.com` -> Traefik -> Feishin (192.168.2.109:9180)
- `timer.itsa-pizza.com` -> Traefik -> Gym Timer (192.168.2.106:8082)
- `docs.itsa-pizza.com` -> Traefik -> Documentation Server (192.168.2.106:3003)
- `uptime.itsa-pizza.com` -> Traefik -> Uptime Kuma (192.168.2.106:3001)
- `speed.itsa-pizza.com` -> Traefik -> Speedtest (192.168.2.100:8080)
- `finances.itsa-pizza.com` -> Traefik -> Family finances app (192.168.2.120:8080)
- `sre.itsa-pizza.com` -> Traefik -> SRE Streamlit (192.168.2.106:8501) [Zero Access]
- `stats.itsa-pizza.com` -> Traefik -> Grafana public dashboards (192.168.2.106:3000) [path-restricted]

**Direct (with Zero Access):**

- `agent-journal.itsa-pizza.com` -> MkDocs Journal (192.168.2.107:8000)
- `agent-docs.itsa-pizza.com` -> MkDocs Docs (192.168.2.107:8001)
- `charts.itsa-pizza.com` / `grafana.itsa-pizza.com` -> Grafana (192.168.2.106:3000)
- `sonarr.itsa-pizza.com`, `radarr.itsa-pizza.com`, etc. -> Media VM services
- `paperless.itsa-pizza.com` / `documents.itsa-pizza.com` / `library.itsa-pizza.com` -> Library app (192.168.2.117:8010; Paperless-ngx decommissioned 2026-07-04)
- `proxmox.itsa-pizza.com` / `pve.itsa-pizza.com` -> Proxmox UI
- ... (full list: `cloudflared_ingress` in `roles/cloudflared_lxc/defaults/main.yml`)

## Ansible

- Role: `roles/cloudflared_lxc`
- Playbook: `playbooks/cloudflared_lxc.yml`
- Deploy: `make cloudflared`
- Ingress rules: `roles/cloudflared_lxc/defaults/main.yml` (`cloudflared_ingress` variable)
- Config template: `roles/cloudflared_lxc/templates/config.yml.j2` (renders from `cloudflared_ingress`)
- API sync template: `roles/cloudflared_lxc/templates/tunnel_config_api.json.j2` (renders from `cloudflared_ingress`)
- Vault secrets: `vault_cloudflared_account_id`, `vault_cloudflared_api_token`

The LXC was originally created manually via a Proxmox community script. The Ansible role manages the tunnel
config file, DNS records, shell environment, and Tailscale.

## Domain Migration

Migration from `itsa.pizza` to `itsa-pizza.com` is complete. See `documentation/archive/domain-migration.md` for history.
