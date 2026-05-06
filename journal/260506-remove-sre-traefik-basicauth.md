# Remove Traefik BasicAuth from sre.itsa-pizza.com

## Context

Commit `4fe8d71` (May 5) introduced a `sre-auth` BasicAuth middleware on the `sre`
Traefik router as part of moving the SRE Streamlit app from direct (Zero Access)
routing to public Traefik routing. The BasicAuth gate proved annoying in daily use.

## Decision

Partial revert: keep `sre.itsa-pizza.com` routed through Traefik (so it still
benefits from rate limiting and security headers), but drop the BasicAuth layer.
Auth is now handled at the Cloudflare edge by a Zero Access policy applied to
the hostname.

## Changes

- `roles/traefik_lxc/templates/routers.yml.j2`: removed `- sre-auth` from the
  `sre` router middlewares list, and deleted the `sre-auth` middleware
  definition.
- `documentation/traefik.md`: removed the `sre-auth` row from the middlewares
  table.
- `documentation/cloudflared.md`: updated the Traefik-routed SRE entry to note
  Zero Access (instead of BasicAuth), and added SRE to the public-portfolio
  list of services that use the edge for auth rather than Traefik.

## Notes

- The vault var `vault_sre_basicauth_users` is no longer referenced by any
  template but was left in `group_vars/all/vault.yml` untouched. It can be
  removed in a future vault rotation.
- The Cloudflare Zero Access policy for `sre.itsa-pizza.com` is configured
  manually in the Cloudflare dashboard — not in Ansible. Verify the policy is
  in place before rolling out this change.

## Validation

- `ansible-lint roles/traefik_lxc/` — no new violations (pre-existing
  `var-naming` warnings unrelated).
- Rendered the Jinja template with a representative `primary_domain_name` and
  parsed the result as YAML. The `sre` router's middleware list contains only
  `force-https-proto`, `security-headers`, `public-rl`; the `sre-auth`
  middleware no longer exists.
