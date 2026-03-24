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

- `jelly.itsa-pizza.com` -> Traefik -> Jellyfin (192.168.2.110:8096)
- `immich.itsa-pizza.com` -> Traefik -> Immich (192.168.2.113:2283)
- `share.itsa-pizza.com` -> Traefik -> Immich shared albums
- `navidrome.itsa-pizza.com` -> Traefik -> Navidrome (192.168.2.109:4533)
- `music.itsa-pizza.com` -> Traefik -> Feishin (192.168.2.109:9180)

**Direct (with Zero Access):**

- `itsa-pizza.com` / `dash.itsa-pizza.com` -> Homepage (192.168.2.106:3002)
- `claw.itsa-pizza.com` -> OpenClaw (192.168.2.107:18789)
- `agent-journal.itsa-pizza.com` -> MkDocs Journal (192.168.2.107:8000)
- `agent-docs.itsa-pizza.com` -> MkDocs Docs (192.168.2.107:8001)
- `charts.itsa-pizza.com` / `grafana.itsa-pizza.com` -> Grafana (192.168.2.106:3000)
- `sonarr.itsa-pizza.com`, `radarr.itsa-pizza.com`, etc. -> Media VM services
- `paperless.itsa-pizza.com` / `documents.itsa-pizza.com` -> Paperless-ngx
- `proxmox.itsa-pizza.com` / `pve.itsa-pizza.com` -> Proxmox UI
- ... (see full list in config.yml)

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

Migration from `itsa.pizza` to `itsa-pizza.com` is complete. See `documentation/domain-migration.md` for history.
