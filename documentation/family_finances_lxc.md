# Family Finances

**Status:** current — verified 2026-08-22 · covers: live, roles/family_finances_lxc/**, playbooks/family_finances_lxc.yml
The container list, data-directory ownership and the absence of Tailscale were read from
the host on that date; everything else traces to `roles/family_finances_lxc/` and
`playbooks/family_finances_lxc.yml`.

## Purpose

The family finances app
([github.com/johnmathews/family-finances](https://github.com/johnmathews/family-finances)) —
a private household budgeting and bank-sync application. A FastAPI backend holds **one
encrypted SQLite database per household**; an nginx container serves the built Vue app and
proxies `/api` to the backend. Bank transactions sync over PSD2 via Enable Banking.

The Proxmox guest is CT 120, named `finance-app`.

## 1. Quick Reference

```
+-----------------------+--------------------------------------------------+
| Host                  | family_finances_lxc (192.168.2.120)              |
| Proxmox guest         | CT 120, hostname `finance-app`                   |
| OS                    | Debian 12 (bookworm)                             |
| SSH                   | ssh finances (user: root)                        |
| Web UI                | finances.itsa-pizza.com                          |
| Port                  | 8080 on the host -> 80 in the nginx container    |
| Docker compose dir    | /srv/apps                                        |
| Ansible               | make finances                                    |
| Role                  | roles/family_finances_lxc                        |
| Playbook              | playbooks/family_finances_lxc.yml                |
+-----------------------+--------------------------------------------------+
```

## 2. Containers

From `roles/family_finances_lxc/templates/docker-compose.yml.j2`:

```
+-----------------+---------------------------------------------------+--------------------------+
| Container       | Image                                             | Role                     |
+-----------------+---------------------------------------------------+--------------------------+
| ff-backend      | ghcr.io/johnmathews/family-finances-backend:SHA   | FastAPI. Not published   |
| ff-frontend     | ghcr.io/johnmathews/family-finances-frontend:SHA  | nginx + Vue app, :8080   |
| portainer_agent | portainer/agent:{{portainer_agent_version}}       | Fleet management         |
| node_exporter   | node-exporter:{{node_exporter_version}}           | Host metrics :9100       |
| alloy           | grafana/alloy:{{alloy_version}}                   | Logs -> Loki :12345      |
| cadvisor        | cadvisor:{{cadvisor_version}}                     | Container metrics :18080 |
+-----------------+---------------------------------------------------+--------------------------+
```

**The backend is deliberately not published** — it has `expose:` but no `ports:`. Only nginx
reaches it, over the compose network. Publishing it would put a path to the API on the host
that never passes through the proxy or its rate limiting. That single-origin arrangement is
also why the backend carries no CORS layer anywhere: there is no second origin for a browser
to be told about.

`ff-frontend` waits on `ff-backend` being `service_healthy`, so the app never serves against
a backend that is not up.

## 3. Images are pinned to a commit SHA

`family_finances_version` in `defaults/main.yml` is **the git commit SHA the images were
built from**, not a semver tag and not `latest`:

```yaml
family_finances_version: "6b315ad444241f5925c62ec41dd8dd4c930e8268"
```

The app builds images only from a green `main`, and pinning the SHA is what makes a rollback
one line rather than an investigation. This is also why this role's handlers use
`pull: missing` where the rest of the estate uses `pull: never` — the tag changes on every
deploy, so `never` would fail the first time a new SHA is pinned unless somebody remembered
to pull it on the host by hand. The sidecars keep `pull: never`, because their versions are
bumped on purpose.

The repository is **private**, so its ghcr packages are private too — unlike `library` or
`sre-agent`, whose public repositories mean a pullable image discloses nothing. The image
carries the backend's Python source, so the role does a `docker_login` with
`vault_family_finances_ghcr_token` before converging.

## 4. Storage

```
+---------------------------------+------------------------------------------------+
| Path                            | What                                           |
+---------------------------------+------------------------------------------------+
| /srv/family-finances            | THE family's financial record. uid 10001, 0700 |
| /srv/family-finances/households | One encrypted SQLite file per household        |
| /srv/family-finances-secrets    | Enable Banking app key only. uid 10001, 0700   |
+---------------------------------+------------------------------------------------+
```

`10001` is the `finances` uid inside the backend image, which runs non-root. `0700` because
these directories hold the encrypted household databases and archived statements: no other
account on the host has any business reading them, encrypted or not.

**`/srv/family-finances` is what the PBS guest backup has to contain.** There is no NFS
mount and no `share_drive_probe` here, deliberately: the databases live on the guest's own
disk because they are small (~1 MB each), are rewritten in full on every write, and putting
them on an NFS mount would add a network filesystem to the path of an atomic rename that the
encryption depends on.

The bank-sync secrets directory is **deliberately separate** and not under the data
directory. An application credential has no business inside the thing the backups and the
encryption exist to protect. The key file is mode `0400` — nothing needs to write it; it is
generated once in the browser when the application is registered, and Enable Banking never
held a copy.

## 5. Configuration

Vault variables (see [vault.md](vault.md)):

```
+-------------------------------------+------------------------------------------------+
| Variable                            | Purpose                                        |
+-------------------------------------+------------------------------------------------+
| vault_family_finances_signup_code   | Invite code required to create a household     |
| vault_family_finances_ghcr_token    | Pull the private backend/frontend images       |
| vault_enable_banking_app_id         | Enable Banking application id                  |
| vault_enable_banking_private_key    | Enable Banking application key -> 0400 pem     |
| vault_portainer_agent_secret        | Portainer agent shared secret                  |
+-------------------------------------+------------------------------------------------+
```

Two settings fail **closed**, which is intentional and is what the app's tests assert:

- **Registration.** An unset `family_finances_signup_code` closes registration rather than
  opening it.
- **Bank sync.** All three Enable Banking values unset means sync is simply off — a
  deployment that forgets them offers no bank connections, rather than erroring when a
  household tries to use one.

`enable_banking_redirect_url` must match a Redirect URL registered on the Enable Banking
application **exactly**, and production requires HTTPS. It is currently the SPA route
`https://finances.itsa-pizza.com/oauth/callback`.

The Enable Banking key is the *application's*, not a household's. It grants nothing without
a consent handle established by a member's own bank authorisation, and that handle lives
inside the encrypted household database — which is why it is deployment configuration rather
than household material.

## 6. Deploying restarts every session

The `Restart family finances` handler recreates `backend` and `frontend`. **Every restart
ends every logged-in session**: sessions hold the household encryption key in memory and are
never persisted, by design. Nothing is readable again until a member logs in. Deploy when
nobody is mid-upload.

Handlers use `state: present` with `recreate: always`, never `state: restarted` — the latter
is `docker compose restart`, which will not pick up a changed image tag, env var or mount,
and a handler fires precisely because one of those changed.

## 7. Tailscale is deliberately omitted

**This host runs no Tailscale, on purpose, and `make finances` would go red if it did.**
Confirmed on 2026-08-22: `tailscale status` on the host reports no running `tailscaled`.
The reasoning is recorded at `playbooks/family_finances_lxc.yml:21-36` and lifted here
because that is not a file anyone reads:

1. **The guest was cloned**, so it arrived holding the document-library host's Tailscale
   node key — same node ID, same `100.100.7.47`, same `paperless.*.ts.net` name. Tailnet
   traffic for `paperless` landed on whichever machine had connected last. That state has
   been wiped on this host.
2. **Re-registering it as its own node needs a working auth key, and
   `vault_tailscale_auth_key` is expired** — it returns "API key does not exist". The
   `tailscale` role calls `fail()` when authentication does not work, so including the role
   would make `make finances` red on every run.

Existing hosts are unaffected: they are already authenticated, so the role's registration
block is skipped for them — **which is why a dead auth key has gone unnoticed.**

To restore: refresh `vault_tailscale_auth_key`, add the role back to the playbook, run. The
app itself does not need the tailnet — it is reached over the Cloudflare tunnel.

> **Open operational item:** `vault_tailscale_auth_key` being expired is a live defect that
> affects any *new* host needing Tailscale, not just this one. It is tracked as F36 and
> needs a decision; it is not a documentation bug and is not fixed here.

## 8. External Access

`finances.itsa-pizza.com` -> Cloudflare Tunnel -> **Traefik** (192.168.2.108) ->
`192.168.2.120:8080`. Unlike most services, this one goes through Traefik rather than direct
routing, which is what gives it rate limiting — `routers.yml.j2` defines a separate
`finances-auth` router with its own `finances-auth-rl` rate limit on the login, signup and
recover paths.

Route definitions: `cloudflared_ingress` in `roles/cloudflared_lxc/defaults/main.yml:31` and
`roles/traefik_lxc/templates/routers.yml.j2:101-126,234`. See
[cloudflared.md](cloudflared.md) and [traefik.md](traefik.md).

## 9. Monitoring

Prometheus scrapes `node_exporter` (:9100) and `cadvisor` (:18080); both targets are
`192.168.2.120` in `roles/prometheus_lxc/templates/prometheus/prometheus.yml.j2`. Logs ship
to Loki via Alloy. The app itself exposes no Prometheus metrics.

The three sidecars are pinned **literally** in this role's own `defaults/main.yml` (alloy
`v1.18.0`, node-exporter `v1.12.1`, cadvisor `v0.55.1`), not via the shared `sidecar_*`
variables — see [upgrade-procedures.md](upgrade-procedures.md).

## 10. Upgrading

```bash
# 1. bump family_finances_version to the new commit SHA
vim roles/family_finances_lxc/defaults/main.yml
# 2. converge — handlers use pull: missing, so the new image is fetched
make finances
```

To roll back, set the SHA to the previous value and re-run. Remember that either direction
ends every logged-in session (section 6).
