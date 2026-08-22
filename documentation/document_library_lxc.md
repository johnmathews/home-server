# Document Library

**Status:** current — verified 2026-08-22 · covers: live, roles/document_library_lxc/**
Container list, NFS mount and the `/metrics` response were read from the host on that
date; everything else traces to `roles/document_library_lxc/` in this repo.

## Purpose

The **library** app ([github.com/johnmathews/library](https://github.com/johnmathews/library)) —
a personal document store. It ingests documents (dropped on an NFS share, or mailed to a
watched Gmail account), OCRs and indexes them, extracts metadata with Claude, and answers
questions over the corpus semantically ("Ask") using local bge-m3 embeddings.

**The guest is still called `paperless`.** Paperless-ngx used to run here and was
decommissioned on 2026-07-04; the LXC, its hostname, its Loki `hostname` label and its
Prometheus target label were all left alone rather than churn the monitoring. So
`paperless` in a dashboard, a log query or `pct list` means *this* host. The retired
Paperless notes are in [archive/paperless.md](archive/paperless.md).

**This role is the reference implementation for the repo's Docker pattern** — `CLAUDE.md`
points here for it. [Section 4](#4-the-template-then-restart-pattern) is that explanation.

## 1. Quick Reference

```
+-----------------------+---------------------------------------------------+
| Host                  | document_library_lxc (192.168.2.117)              |
| Proxmox guest         | CT 117, hostname `paperless`                      |
| SSH                   | ssh paperless (user: root)                        |
| Web UI                | library.itsa-pizza.com, documents..., paperless.. |
| Port                  | 8010 on the host -> 8000 in the container         |
| Docker compose dir    | /srv/apps                                         |
| Ansible               | make document-library                             |
| Role                  | roles/document_library_lxc                        |
| Playbook              | playbooks/document_library_lxc.yml                |
+-----------------------+---------------------------------------------------+
```

Note the hyphen: the make target is `make document-library`, not `make document_library`.

## 2. Containers

Nine, all from `roles/document_library_lxc/templates/docker-compose.yml.j2`:

```
+-------------------+-----------------------------------------------+--------------------------+
| Container         | Image                                         | Role                     |
+-------------------+-----------------------------------------------+--------------------------+
| library-webserver | ghcr.io/johnmathews/library:{{version}}       | Web app + API, :8010     |
| library-worker    | ghcr.io/johnmathews/library:{{version}}       | Ingestion, OCR, email    |
| library-migrate   | ghcr.io/johnmathews/library:{{version}}       | One-shot alembic upgrade |
| library-db        | pgvector/pgvector:pg17                        | Postgres + vector index  |
| library-embedder  | huggingface/text-embeddings-inference:cpu-1.7 | Local bge-m3 embeddings  |
| portainer_agent   | portainer/agent:{{portainer_agent_version}}   | Fleet management         |
| node_exporter     | node-exporter:{{document_library_lxc_node_exporter_version}}       | Host metrics :9100       |
| alloy             | grafana/alloy:{{document_library_lxc_alloy_version}}               | Logs -> Loki :12345      |
| cadvisor          | cadvisor:{{document_library_lxc_cadvisor_version}}                 | Container metrics :18080 |
+-------------------+-----------------------------------------------+--------------------------+
```

`library-migrate` runs `alembic upgrade head` and exits 0. The webserver and worker wait on
it via `service_completed_successfully`, so a failed migration blocks the app rather than
letting it start against an unmigrated schema. Seeing it `Exited (0)` is correct.

`library-embedder` downloads ~2 GB of model on first start and is capped at `mem_limit: 6g`
with `--max-batch-tokens 2048`. The small batch budget is deliberate: the default 16384
allocates enough at warm-up to OOM this 8 GB guest.

## 3. Storage

```
+----------------------------------+--------------------------------------------------+
| Path                             | What                                             |
+----------------------------------+--------------------------------------------------+
| /mnt/nfs/document-store/data     | NFS. Indexed documents, /data in the containers  |
| /mnt/nfs/document-store/consume  | NFS. Drop zone — anything here gets ingested     |
| /srv/apps/library/pgdata         | Local disk. Postgres data, uid 999, 0700         |
| /srv/apps/library/embedder-cache | Local disk. The bge-m3 model                     |
| /srv/apps/library/claude         | Local disk. Claude CLI OAuth creds, uid 999, 0700|
+----------------------------------+--------------------------------------------------+
```

The NFS export is `192.168.2.104:/mnt/tank/document-store` — its **own** dataset, not the
paperless dataset and not the media `library` dataset.

Two traps live here, both recorded in the role:

- The document-store dataset uses **NFSv4 ACLs** (TrueNAS "Multiprotocol" preset), which
  reject `chmod` and `chgrp` over NFS with EPERM. Only `chown` works. So the role sets
  `owner: 999` and no `mode:` on those directories — the `# noqa: risky-file-permissions`
  on that task is there for that reason. SMB and iPhone access are granted through the
  dataset's NFSv4 ACL in the TrueNAS UI, not through a unix group.
- The consume directory is an NFS mount and **inotify does not cross NFS**, so the worker
  runs with `LIBRARY_CONSUME_FORCE_POLLING=true`. Without it nothing is ever ingested and
  nothing errors.

## 4. The template-then-restart pattern

`CLAUDE.md` names this role as the canonical example of how every Dockerised host in this
repo works. The shape is:

```
roles/document_library_lxc/
  defaults/main.yml               image tags and tunables
  templates/docker-compose.yml.j2 the stack
  templates/.env.j2               secrets and app settings
  templates/config.alloy          log shipping
  tasks/main.yml                  render the templates, notify handlers
  handlers/main.yml               docker compose up, on change only
```

On `make document-library`, `tasks/main.yml` renders `.env.j2` and `docker-compose.yml.j2`
into `/srv/apps/`. **Each render task carries `notify:`, so the handler fires only when the
rendered file actually changed** — an unchanged converge touches nothing. The handler then
runs `community.docker.docker_compose_v2` to apply it.

So: **to change a container — image tag, env var, port, volume — edit the role's template
and run `make document-library`. Never `ssh` in and edit `/srv/apps/docker-compose.yml`;
Ansible overwrites it on the next run.**

Three details worth copying, and one worth avoiding:

- Handlers use `state: present` with `recreate: always`, **never `state: restarted`**.
  `restarted` is `docker compose restart`, which reuses the existing container and so will
  not pick up a changed image tag, environment variable or mount — and a handler fires
  precisely because one of those changed.
- `remove_orphans: true` deletes containers that have left the compose file. That is what
  cleared the decommissioned `paperless-*` containers, which otherwise linger.
- `pull: never` means the tag must already be on the host. Bump a sidecar version and the
  converge fails until you pull it there, or run `make refresh-sidecars`.
- **The landmine:** `.env` and `docker-compose.yml` both notify **`Restart all containers`**,
  which recreates *every* service including `library-db`. There is a narrower
  `Restart library` handler, but nothing triggers it. So a one-word `.env` edit bounces
  Postgres and the embedder too. Deploy when nobody is mid-upload, and expect the embedder
  to spend a minute warming up afterwards.

## 5. Configuration

Secrets come from Ansible Vault via `templates/.env.j2` (see
[vault.md](vault.md)): `vault_library_db_password`, `vault_library_anthropic_api_key`,
`vault_library_gmail_email_address`, `vault_library_gmail_app_password`,
`vault_library_public_base_url`.

`.env.j2` is the **only** place `LIBRARY_ANTHROPIC_API_KEY` is set. It used to be duplicated
into the `environment:` blocks of the webserver and worker, which silently won over the env
file — so changing the vault value did not reach the containers.

The image tag is `document_library_lxc_library_version` in `defaults/main.yml`, currently **`latest`**. Combined
with `pull: never`, that means the running image is whatever `latest` resolved to the last
time it was pulled on the host — `docker images ghcr.io/johnmathews/library` to see what is
actually there. Unlike `family_finances_lxc`, which pins a commit SHA, a rollback here is
not a one-line change.

### Ask needs credentials on the host

Library's "Ask" reaches Claude through one of two backends. The default is
`subscription`, which uses Claude CLI OAuth credentials mounted from
`/srv/apps/library/claude`. **Those credentials are deliberately not managed by Ansible** —
they are short-lived and rotate themselves. Provision once, on the host:

```bash
CLAUDE_CONFIG_DIR=/srv/apps/library/claude claude auth login --claudeai
chown 999:999 /srv/apps/library/claude/.credentials.json
```

`claude setup-token` does **not** work for this — it prints a token and writes no
credentials file. The mount is read-write on purpose: the access token expires roughly
8-hourly and library rewrites it in place, so `:ro` would break it. On a host where this has
not been done, set `LIBRARY_ASK_LLM_BACKEND=api` in `.env.j2` to use the metered API
instead; otherwise every question fails.

## 6. External Access

Routed through the Cloudflare Tunnel **directly to `192.168.2.117:8010`, not via Traefik**
(`roles/cloudflared_lxc/defaults/main.yml:156-162`), so it gets Cloudflare Zero Access
protection rather than Traefik's rate limiting. Three hostnames all reach this app —
`library.itsa-pizza.com`, `documents.itsa-pizza.com` and `paperless.itsa-pizza.com` — the
last two kept from the Paperless era. `cloudflared_ingress` in that file is the source of
truth for the route list; see [cloudflared.md](cloudflared.md).

## 7. Monitoring

Prometheus scrapes three things here: `node_exporter` (:9100), `cadvisor` (:18080), and the
app's own `library` job on **:8010** at a 60s interval. Logs ship to Loki through Alloy under
the hostname label **`paperless`**.

**A 404 on `http://192.168.2.117:8010/metrics` is almost always an app setting, not a scrape
misconfiguration.** The metrics endpoint is off by default in the image;
`LIBRARY_OTEL_METRICS_ENABLED=true` in `.env.j2` is what turns it on, and while disabled the
endpoint 404s rather than returning an empty 200 (an empty exposition is indistinguishable
from a healthy scrape collecting nothing). The same warning sits beside the job at
`roles/prometheus_lxc/templates/prometheus/prometheus.yml.j2:69-73`. Verified returning 200
on 2026-08-22.

Claude Code's own CLI telemetry is deliberately **not** enabled: it needs an OTLP collector
and this network has none (Prometheus scrapes, it does not receive pushes). Note also that
the app refuses to start if any `OTEL_LOG_*` content variable is set, because those export
prompt and response content — which for Ask is the text of the documents themselves.

## 8. Upgrading

```bash
# 1. bump document_library_lxc_library_version in roles/document_library_lxc/defaults/main.yml
#    (or, while it is "latest", pull on the host)
ssh paperless docker compose -f /srv/apps/docker-compose.yml pull library-webserver
# 2. converge
make document-library
```

Migrations run themselves — `library-migrate` applies `alembic upgrade head` before the app
starts. See [upgrade-procedures.md](upgrade-procedures.md) for the sidecar pins, and note
that this role pins alloy, node-exporter and cadvisor **literally** in its own
`defaults/main.yml` rather than via the shared `sidecar_*` variables.
