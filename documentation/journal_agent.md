# Journal Insights

## Overview

A self-hosted journaling, transcription, and retrieval stack running on the **media VM** (192.168.2.105) as three
Docker containers. Provides a web UI, an MCP-compatible API, image OCR / handwriting transcription, mood scoring,
and vector search over journal entries.

## Architecture

| Container          | Image                                                          | Host port | Memory  |
|--------------------|----------------------------------------------------------------|-----------|---------|
| `journal-webapp`   | `ghcr.io/johnmathews/journal-webapp:latest`                    | 8402 → 80 | (default) |
| `journal-server`   | `ghcr.io/johnmathews/journal-server:{{ journal_agent_version }}` | 8400 → 8400 | (default) |
| `journal-chromadb` | `ghcr.io/johnmathews/journal-chromadb:{{ journal_chromadb_version }}` | 8401 → 8000 | (default) |

`journal-webapp` depends on `journal-server`; `journal-server` depends on `journal-chromadb` being healthy
(`condition: service_healthy`). The chromadb image is a custom johnmathews fork; its healthcheck uses `curl` against
`http://localhost:8000/api/v2/heartbeat` (interval 30s, retries 3, start_period 10s with start_interval 2s).

Image versions for journal-server and journal-chromadb come from `journal_agent_version` and
`journal_chromadb_version` in `group_vars/all/main.yml`. The webapp pins `:latest`.

## Data Storage

| Path on host                                          | Container | Container path                       | Purpose                |
|-------------------------------------------------------|-----------|--------------------------------------|------------------------|
| `/srv/media/config/journal/data`                      | server    | `/data`                              | SQLite journal DB      |
| `/srv/media/config/journal/context`                   | server    | `/app/context` (dir bind)            | Markdown context files |
| `/srv/media/config/journal/mood-dimensions.toml`      | server    | `/app/config/mood-dimensions.toml` (ro) | Mood scoring dimensions |
| `/srv/media/config/journal/chromadb`                  | chromadb  | `/data`                              | Vector store           |

## Environment Variables

Set in `roles/media_vm/templates/.env.j2` and consumed by `journal-server` (the webapp + chromadb don't need any
secrets beyond `TZ`):

| Variable                                  | Source / value                                       |
|-------------------------------------------|------------------------------------------------------|
| `ANTHROPIC_API_KEY`                       | from vault                                           |
| `OPENAI_API_KEY`                          | from vault                                           |
| `GOOGLE_GEMINI_JOURNAL_INSIGHTS_API_KEY`  | from vault — used by `GOOGLE_API_KEY` in container   |
| `JOURNAL_INSIGHTS_APP_OCR_PROVIDER`       | primary OCR/transcription provider                   |
| `OCR_MODEL`                               | model name for the primary provider                  |
| `TRANSCRIPTION_SHADOW_PROVIDER=gemini`    | hardcoded — runs gemini in shadow alongside primary  |
| `OCR_DUAL_PASS=true`, `PREPROCESS_IMAGES=true` | hardcoded toggles                               |
| `JOURNAL_SECRET_KEY`                      | from vault — Flask/session signing                   |
| `MCP_ALLOWED_HOSTS`                       | comma-separated host allowlist for the MCP API       |
| `SLACK_BOT_TOKEN`                         | from vault — Slack notifications                     |
| `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM_EMAIL` | from vault — outgoing email                |
| `PUSHOVER_USER_KEY`, `PUSHOVER_APP_API_TOKEN` | from vault — push notifications                  |
| `APP_BASE_URL`                            | public URL the webapp is served at                   |
| `REGISTRATION_ENABLED`                    | `true` / `false`                                     |
| `JOURNAL_ENABLE_MOOD_SCORING=true`        | hardcoded                                            |

The shadow gemini transcription is a measured-rollout pattern: primary OCR remains whatever
`JOURNAL_INSIGHTS_APP_OCR_PROVIDER` selects, and gemini runs in parallel for comparison data without affecting
user-facing output.

## Ansible

- **Deploy**: `make media t=journal`
- **Role**: `roles/media_vm`
- **Task file**: `roles/media_vm/tasks/main.yml` (directory creation + config upload tasks tagged `journal`)
- **Templates**: `.env.j2`, `docker-compose.yml.j2`
- **Handler**: `Restart journal-insights` recreates all three containers when notified

### Context files and mood dimensions

The journal-server reads two kinds of host-side configuration that are bind-mounted into the container:

| Local source                                                  | Mounted at (container)                  | Upload behavior                  |
|---------------------------------------------------------------|-----------------------------------------|----------------------------------|
| `roles/media_vm/templates/journal/moods/mood-dimensions.toml` | `/app/config/mood-dimensions.toml` (ro) | Single explicit copy task        |
| `roles/media_vm/templates/journal/context/*.md`               | `/app/context` (directory bind)         | `with_fileglob` — drop in `.md`s |

Adding a new `.md` file to `roles/media_vm/templates/journal/context/` and running `make media t=journal` is
sufficient — no playbook edit required. Both upload tasks notify `Restart journal-insights`, which recreates
`journal-server`, `journal-webapp`, and `journal-chromadb` so the new content is loaded at startup.

## Troubleshooting

- **journal-chromadb unhealthy**: `ssh media docker logs journal-chromadb`. The healthcheck calls
  `/api/v2/heartbeat` — if the chroma version was bumped and the API path changed, update the healthcheck.
- **journal-server crash-looping**: `ssh media docker logs journal-server`. Most failures here are a missing env
  var or a chromadb that's not yet healthy. Verify `.env` rendered correctly and that `journal-chromadb` reports
  healthy first.
- **OCR / transcription failures**: check the provider key matches `JOURNAL_INSIGHTS_APP_OCR_PROVIDER`. Shadow
  gemini failures don't break the user-facing path but log noisily — `GOOGLE_GEMINI_JOURNAL_INSIGHTS_API_KEY` must
  be set.
- **webapp blank / 502**: usually means `journal-server` is down. Check `docker logs journal-server` first; the
  webapp itself rarely fails on its own.
