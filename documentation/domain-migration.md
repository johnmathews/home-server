# Domain Migration: itsa.pizza -> itsa-pizza.com

## Context

The home server is accessible externally via the domain `itsa.pizza`, managed through Cloudflare. The domain price has
increased, so all services are being migrated to `itsa-pizza.com`.

## Current Architecture

External access flows through two paths:

1. **Cloudflare Tunnel (cloudflared)** — The primary ingress. A cloudflared daemon runs on an LXC (192.168.2.101) and
   proxies ~40 subdomains to internal services. Most services sit behind Cloudflare Zero Access policies for
   authentication.

2. **Traefik (reverse proxy)** — Handles Jellyfin, Immich, Navidrome, and Music. These services bypass Cloudflare Zero
   Access (which breaks their native app/API flows) but are still proxied through Cloudflare via the tunnel. Traefik
   adds rate limiting on auth endpoints. Traefik runs on 192.168.2.108 and listens on HTTP only (no TLS — Cloudflare
   handles TLS termination).

The cloudflared LXC is managed by `roles/cloudflared_lxc` and `playbooks/cloudflared_lxc.yml` (`make cloudflared`).
The tunnel config template is at `roles/cloudflared_lxc/templates/config.yml.j2`.

## Motivation

- `itsa.pizza` domain renewal price has increased significantly
- `itsa-pizza.com` is the replacement domain (already registered on Cloudflare)

## Retired Services

The following services are no longer in use and can be ignored during migration:

- **Mailcow** (`mail.itsa.pizza`) — not used
- **Mealie** — not used

## Templatization (Completed)

All Ansible-managed files now use `{{ primary_domain_name }}` instead of hardcoded `itsa.pizza`. To change the domain,
update `primary_domain_name` in `group_vars/all/main.yml` and redeploy.

**Templatized files:**

- `roles/traefik_lxc/templates/routers.yml.j2` — Host() rules
- `roles/infra_vm/templates/homepage/services.yaml.j2` — all dashboard links
- `roles/infra_vm/templates/homepage/bookmarks.yaml.j2` — bookmark links (converted from static file)
- `roles/infra_vm/templates/docker-compose.yml.j2` — HOMEPAGE_ALLOWED_HOSTS
- `roles/infra_vm/files/grafana/grafana.ini` — Grafana domain/root_url (deployed via template module)
- `roles/infra_vm/templates/mkdocs.yml.j2` — site_url
- `roles/immich_lxc/templates/docker-compose.yml.j2` — PUBLIC_BASE_URL (converted from static file)
- `roles/immich_lxc/templates/.env.j2` — IMMICH_INSTANCE_URL
- `roles/music_lxc/templates/docker-compose.yml.j2` — SERVER_URL
- `roles/paperless_lxc/templates/.env.j2` — ALLOWED_HOSTS, CORS, CSRF
- `roles/open_webui_lxc/templates/docker-compose.yml.j2` — WEBUI_NAME, WEBUI_URL
- `roles/media_vm/templates/docker-compose.yml.j2` — sabnzbd HOST_WHITELIST
- `roles/tubearchivist_lxc/defaults/main.yml` — host config
- `roles/n8n_lxc/defaults/main.yml` — host and webhook URL
- `host_vars/n8n_lxc.yml` — webhook URL
- `playbooks/mail_vm.yml` — mail_domain, mail_hostname
- `roles/cloudflared_lxc/templates/config.yml.j2` — all tunnel ingress hostnames

**Not templatized (need manual update at Stage 3):**

- `scripts/immich-empty-album.sh` line 4 — `IMMICH_URL="https://immich.itsa.pizza"`
- `scripts/immich-unfavourite-all.sh` line 5 — `IMMICH_URL="https://immich.itsa.pizza"`
- `documentation/cloudflared.md` — subdomain examples and service list
- `documentation/traefik.md` — dashboard URLs and service list
- `documentation/navidrome.md` — service access URLs
- `documentation/openclaw.md` — `claw.itsa.pizza` references
- `documentation/mailcow.md` — mail domain and DNS records (mailcow is retired, consider deleting)
- `documentation/index.md` — `charts.itsa.pizza` reference
- `CLAUDE.md` — network reference table (`mail.itsa.pizza`)
- `readme.md` — `docs.itsa.pizza` link

## Tunnel and Multi-Domain Support

A single Cloudflare tunnel can serve multiple domains. The tunnel is a pipe between cloudflared and Cloudflare's edge —
hostname routing happens at the edge based on DNS CNAME records. Both `itsa.pizza` and `itsa-pizza.com` subdomains can
point to the same tunnel (`<tunnel-id>.cfargotunnel.com`), and the cloudflared config can list hostnames from both
domains simultaneously. No second tunnel is needed.

## What Needs to Change

### Cloudflare Side

- [x] Register `itsa-pizza.com` on Cloudflare (nameservers already pointing to Cloudflare)
- [x] Create CNAME records on `itsa-pizza.com` (51 records created via API script)
- [x] Clean up bad CNAME records on `itsa.pizza` zone (removed via dashboard)
- [x] Recreate Cloudflare Zero Access policies for `itsa-pizza.com` subdomains (duplicated via dashboard)

### Cloudflared LXC (192.168.2.101)

- [x] Add `itsa-pizza.com` hostnames to `/etc/cloudflared/config.yml` (alongside existing entries)
- [x] Restart cloudflared service
- [x] DNS records created via API (not CLI route commands — cert.pem is zone-locked)

### Ansible Codebase

- [ ] Change `primary_domain_name` from `itsa.pizza` to `itsa-pizza.com` in `group_vars/all/main.yml`
- [ ] Deploy with `make site` or per-service targets
- [ ] Update standalone scripts and documentation

### Services That Need Reconfiguration After Deploy

These services store the domain in their own config/database and may need manual updates:

- **Grafana** — domain is set via grafana.ini (handled by Ansible)
- **Paperless-ngx** — CSRF/CORS origins (handled by Ansible)
- **Open WebUI** — URL config (handled by Ansible)
- **Home Assistant** — may have external URL configured in its own settings
- **Uptime Kuma** — all monitored URLs will need updating

## Stages

### Stage 0: Preparation (Completed, Deployed)

- [x] Document current state and create migration plan
- [x] Templatize all Ansible-managed domain references to use `{{ primary_domain_name }}`
- [x] Create Ansible role + playbook for cloudflared LXC (`make cloudflared`)
- [x] Investigate Cloudflare API for programmatic DNS/tunnel management (see `documentation/cloudflare-api.md`)
- [x] Deploy cloudflared role (`make cloudflared` — config templated, service restarted, shell environment configured)

### Stage 1: Cloudflare Setup (Completed)

- [x] `itsa-pizza.com` registered on Cloudflare (nameservers already set, DNS setup "full")
- [x] Create CNAME records for `itsa-pizza.com` subdomains (51 records via `scripts/cf-create-dns-records.sh --apply`)
- [x] Clean up bad CNAME records on `itsa.pizza` zone (removed via dashboard)
- [x] Recreate Zero Access policies for `itsa-pizza.com` subdomains (duplicated via dashboard)

**DNS records created via API:** Used `scripts/cf-create-dns-records.sh` with a Cloudflare API token scoped to
`itsa-pizza.com` (DNS:Edit). The script creates proxied CNAME records pointing to the tunnel. It supports dry-run
(default), `--apply` (create), and `--cleanup` (remove bad records from old zone). The CLI `cloudflared tunnel route
dns` cannot be used for cross-zone record creation due to zone-locked cert.pem (see `cloudflare-api.md`).

### Stage 2: Parallel Running (Completed)

Both domains work simultaneously using the same tunnel. `migration_additional_domains` in `group_vars/all/main.yml`
drives the multi-domain support. The cloudflared config template loops over all domains to generate ingress rules.
Traefik routers use a Jinja2 macro to match `Host()` on both domains.

- [x] Add `itsa-pizza.com` hostnames to cloudflared config (`make cloudflared`)
- [x] Add Traefik router rules for new domain (`make traefik`)
- [x] Zero Access policies duplicated for new domain (done in Stage 1)
- [x] Update services with allowed-hosts settings for both domains:
  - Homepage `HOMEPAGE_ALLOWED_HOSTS` (infra VM docker-compose)
  - Paperless `PAPERLESS_ALLOWED_HOSTS`, `CORS`, `CSRF` (.env template)
- [x] Test all services on `itsa-pizza.com`
- [x] Verify Cloudflare Zero Access works on new domain

### Stage 3: Ansible Codebase Update

- [ ] Update `primary_domain_name` to `itsa-pizza.com` in `group_vars/all/main.yml`
- [ ] Run `make check` (dry-run) to validate
- [ ] Deploy with `make site` or per-service targets
- [ ] Update standalone scripts:
  - `scripts/immich-empty-album.sh` line 4 — IMMICH_URL
  - `scripts/immich-unfavourite-all.sh` line 5 — IMMICH_URL
- [ ] Update documentation files:
  - `documentation/cloudflared.md` — subdomain examples and service list
  - `documentation/traefik.md` — dashboard URLs and service list
  - `documentation/navidrome.md` — service access URLs
  - `documentation/openclaw.md` — `claw.itsa.pizza` references
  - `documentation/index.md` — `charts.itsa.pizza` reference
  - `CLAUDE.md` — network reference table
  - `readme.md` — `docs.itsa.pizza` link
- [ ] Delete or archive `documentation/mailcow.md` (mailcow is retired)

### Stage 4: Cutover and Cleanup

**Do NOT execute any Stage 4 steps without explicit permission.** Ideally both domains remain active for a significant
crossover period.

- [ ] Confirm all services work on `itsa-pizza.com`
- [ ] Optional: set up redirects from `itsa.pizza` -> `itsa-pizza.com` (see `cloudflare-api.md`)
- [ ] Remove old `itsa.pizza` hostnames from cloudflared config
- [ ] Remove old Traefik router rules for `itsa.pizza`
- [ ] Update services with internal domain references (Uptime Kuma, Home Assistant, etc.)
- [ ] Update any external references (app configs on phones/devices, bookmarks, etc.)
- [ ] Decide whether to keep or release `itsa.pizza` domain

## Open Questions

1. **Crossover duration**: How long to keep both domains active? Recommendation: at least 2-4 weeks.

2. **Redirects**: Optional. Without redirects, old URLs fail after cutover. Only matters if shared Immich album links
   or similar external-facing URLs exist. See `cloudflare-api.md` for implementation details if needed.

3. **Access policies**: Duplicated via dashboard. Only 3 apps existed (2 relevant + Warp). Policies include wildcard
   `*.itsa-pizza.com` with email allowlist + service token bypass, and a bypass app for Immich/Jelly/Navidrome/Timer.

## SSH Access

```sh
ssh cloudflared    # cloudflared LXC (192.168.2.101)
```

## Cloudflared Config Location

```
/etc/cloudflared/config.yml
```
