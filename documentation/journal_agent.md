# Journal Agent

## Overview

The journal agent runs on the **media VM** (192.168.2.105) as two Docker containers: the agent itself and a ChromaDB
instance for vector storage. It provides an MCP-compatible journaling and retrieval service.

## Architecture

- **journal** container: `ghcr.io/johnmathews/journal-agent:latest` — port 8400
- **journal-chromadb** container: `ghcr.io/johnmathews/journal-chromadb:latest` — port 8401 (host) -> 8000 (container)
- The journal container depends on ChromaDB being healthy before starting.

## Data Storage

| Path on host                             | Container path | Purpose               |
|------------------------------------------|---------------|-----------------------|
| `/srv/media/config/journal/data`         | `/data`       | SQLite journal DB     |
| `/srv/media/config/journal/chromadb`     | `/data`       | ChromaDB vector store |

## Environment Variables

The journal agent requires two API keys, added to `roles/media_vm/templates/.env.j2`:

- `ANTHROPIC_API_KEY` — from vault (`vault_anthropic_api_key`)
- `OPENAI_API_KEY` — from vault (`vault_openai_api_key`)

## Ansible

- **Deploy**: `make media t=journal`
- **Role**: `roles/media_vm`
- **Task file**: `roles/media_vm/tasks/main.yml` (directory creation tasks tagged `journal`)
- **Templates**: `.env.j2`, `docker-compose.yml.j2`

## Healthcheck

The ChromaDB container uses a `curl`-based healthcheck hitting `http://localhost:8000/api/v2/heartbeat`. If the
ChromaDB image does not include `curl`, this healthcheck will need to be replaced with a Python-based alternative.

## Troubleshooting

- **ChromaDB not starting**: Check `docker compose logs journal-chromadb` on the media VM.
- **Journal agent failing**: Verify API keys are in vault and `.env` is templated correctly. Check with
  `docker compose logs journal`.
