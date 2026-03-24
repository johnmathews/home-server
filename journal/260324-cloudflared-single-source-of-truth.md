# Cloudflared: Single Source of Truth for Tunnel Routes

**Date:** 2026-03-24

## Problem

Adding a new cloudflared tunnel route required editing two separate Jinja2 templates (`config.yml.j2` and
`tunnel_config_api.json.j2`) with the same hostname and service URL. This duplication invited drift — for example,
`picard` was present in the API template but missing from the local config template. Additionally, DNS CNAME record
creation was a manual step requiring SSH into the LXC and running `cloudflared tunnel route dns`, which was easy to
forget and depended on a CLI certificate that could expire.

## Solution

### Centralized ingress variable

Defined `cloudflared_ingress` in `roles/cloudflared_lxc/defaults/main.yml` as a list of ingress rules. Each entry
has a `prefix` (subdomain), `service` (origin URL), and optional flags (`no_tls_verify`, `set_host_header`). Both
templates now render from this single variable.

### Automated DNS record creation

Added tasks to the role that:
1. Extract all hostnames from the rendered config template
2. Fetch all existing CNAME records for the zone in one Cloudflare API call
3. Diff against expected hostnames
4. Create missing CNAME records pointing to the tunnel

Steady-state cost is one GET request (~1-2 seconds). New records are created automatically on deploy.

### Check mode compatibility

Read-only API calls (zone lookup, CNAME fetch) use `check_mode: false` so they execute during `make check`
dry runs, avoiding undefined variable errors in downstream tasks.

## New workflow

```sh
# 1. Edit the ingress list (one place)
vim roles/cloudflared_lxc/defaults/main.yml

# 2. Deploy
make cloudflared
```

## Files changed

- `roles/cloudflared_lxc/defaults/main.yml` — added `cloudflared_ingress` variable
- `roles/cloudflared_lxc/templates/config.yml.j2` — renders from variable instead of hardcoded entries
- `roles/cloudflared_lxc/templates/tunnel_config_api.json.j2` — renders from variable instead of hardcoded entries
- `roles/cloudflared_lxc/tasks/main.yml` — added DNS sync tasks
- `documentation/cloudflared.md` — updated to reflect new workflow
