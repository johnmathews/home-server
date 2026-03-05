# Cloudflare API Reference for Domain Migration

Research notes for programmatically managing the migration from `itsa.pizza` to `itsa-pizza.com`.

## DNS Records: CLI vs API

The `cloudflared` CLI can create DNS CNAME records directly:

```sh
cloudflared tunnel route dns home-server lidarr.itsa-pizza.com
```

**However**, the CLI's `cert.pem` (`/root/.cloudflared/cert.pem`) is zone-locked. It contains an API token scoped to
a single zone (currently `itsa.pizza`). It cannot create records on `itsa-pizza.com`. The `cert.pem` is an
"ARGO TUNNEL TOKEN" with an embedded `zoneID`.

**Workarounds:**

1. **Cloudflare dashboard** — manually create CNAME records in `itsa-pizza.com` DNS settings
2. **Cloudflare API** — use a separate API token with `DNS:Edit` on both zones (see below)
3. **Re-login** — `cloudflared tunnel login` and select `itsa-pizza.com` to get a new cert.pem (but this replaces
   the old cert, so the CLI would then lose access to `itsa.pizza`)

The CLI approach works fine for managing records within a single zone (e.g., the bulk update loop for `itsa.pizza`
hostnames). For cross-zone work, use the dashboard or API.

## Redirect Rules: Not Required

Redirects from `*.itsa.pizza` to `*.itsa-pizza.com` are optional. Without them:

- During the crossover period: both domains work simultaneously, no issue
- After `itsa.pizza` tunnel entries are removed: requests get a Cloudflare error page (if domain stays in CF) or DNS
  failure (if domain is released)

Since this is a personal homelab, the only consumers are household devices and apps. All clients can be updated
directly. The main risk without redirects is shared Immich album links (`share.itsa.pizza/...`) breaking for external
recipients.

**Recommendation:** Skip redirects unless shared links are a concern. The crossover period with both domains active
is sufficient for transitioning all clients.

If redirects are wanted later, see the Dynamic Redirect Rules section below.

## Authentication

Use an **API Token** (not the legacy Global API Key). Create at https://dash.cloudflare.com/profile/api-tokens.

```
Header: Authorization: Bearer $CF_API_TOKEN
```

Recommended token permissions (only needed if using the API for Access policies):

```
+-----------------------------------------+--------+--------+
| Permission                              | Level  | Access |
+-----------------------------------------+--------+--------+
| Access: Apps and Policies               | Account| Edit   |
| Access: Orgs, Identity Providers, Tokens| Account| Read   |
+-----------------------------------------+--------+--------+
```

Scope the zone resources to just `itsa.pizza` and `itsa-pizza.com`.

## Zero Trust / Access API

This is the main reason to use the API — the `cloudflared` CLI cannot manage Access policies.

Account-scoped. Access Applications define which domains are protected; Access Policies define who can access them.

**List Access applications:**

```sh
curl "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

**Create a new Access application:**

```sh
curl "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps" \
  -X POST \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  --json '{
    "name": "Grafana",
    "domain": "charts.itsa-pizza.com",
    "type": "self_hosted",
    "session_duration": "24h"
  }'
```

**List policies for an app:**

```sh
curl "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps/$APP_ID/policies" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

**Create a policy on an app:**

```sh
curl "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps/$NEW_APP_ID/policies" \
  -X POST \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  --json '{
    "name": "Allow email login",
    "decision": "allow",
    "include": [{"email": {"email": "john@example.com"}}]
  }'
```

**Migration workflow:** There is no "clone" endpoint. To migrate:

1. GET all apps from old domain
2. For each app: GET its policies, change the `domain` field, strip server fields (`id`, `created_at`, `updated_at`)
3. POST as new app on the new domain
4. POST each policy on the new app

Account-level reusable policies do NOT need to be recreated. Access policies can also be created manually via the
Cloudflare Zero Trust dashboard if the number of apps is manageable.

## DNS Records API (Reference)

Not needed for this migration (use `cloudflared tunnel route dns` instead), but documented for completeness.

Zone-scoped. Need `zone_id` for each domain (find via dashboard or `GET /zones?name=itsa-pizza.com`).

**List all records:**

```sh
curl "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=5000" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

**Create a CNAME record:**

```sh
curl "https://api.cloudflare.com/client/v4/zones/$NEW_ZONE_ID/dns_records" \
  -X POST \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  --json '{
    "type": "CNAME",
    "name": "app",
    "content": "e1e3b9c4-789a-4ad3-adff-a0c71bff1122.cfargotunnel.com",
    "proxied": true,
    "ttl": 1
  }'
```

## Tunnel API (Reference)

Not applicable to our setup. Our tunnel uses a **local config file** (`/etc/cloudflared/config.yml`) managed by Ansible.
The Tunnel configurations API only works for remotely-managed tunnels (where `config_src` is `cloudflare`).

## Dynamic Redirect Rules (Optional)

If redirects are wanted, use Dynamic Redirect Rules on the old zone.

**Create a redirect rule preserving subdomain and path:**

```sh
curl "https://api.cloudflare.com/client/v4/zones/$OLD_ZONE_ID/rulesets" \
  -X POST \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  --json '{
    "name": "Domain migration redirect",
    "kind": "zone",
    "phase": "http_request_dynamic_redirect",
    "rules": [{
      "expression": "true",
      "description": "Redirect all traffic to new domain",
      "action": "redirect",
      "action_parameters": {
        "from_value": {
          "target_url": {
            "expression": "concat(\"https://\", regex_replace(http.host, \"itsa\\\\.pizza\", \"itsa-pizza.com\"), http.request.uri.path)"
          },
          "status_code": 301,
          "preserve_query_string": true
        }
      }
    }]
  }'
```

This maps `app.itsa.pizza/path?q=1` -> `app.itsa-pizza.com/path?q=1`.

**Prerequisites:**
- Old domain must stay in Cloudflare with active DNS
- DNS records on old zone must be proxied (orange cloud)
- Create proxied A records pointing to `192.0.2.1` as placeholders

**Gotcha:** `regex_replace()` may require a Business or Enterprise plan. If on Free/Pro, use `concat()` with a
hardcoded target domain instead.

## References

- Tunnel Route DNS: `cloudflared tunnel route dns --help`
- Access API: https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/
- DNS Records API: https://developers.cloudflare.com/api/resources/dns/subresources/records/
- Redirect Rules: https://developers.cloudflare.com/rules/url-forwarding/single-redirects/create-api/
- API Tokens: https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
