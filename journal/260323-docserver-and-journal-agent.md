# Add docserver and journal-agent services

**Date**: 2026-03-23

## Changes

### Documentation MCP Server (infra VM)

Added the `docserver` service to the infra VM docker-compose stack. This runs the
`documentation-mcp-server` container, which indexes git-hosted documentation and local MkDocs
sources for MCP-compatible search and retrieval.

- New tasks file: `roles/infra_vm/tasks/docserver.yml`
- New template: `roles/infra_vm/templates/docserver-sources.yml.j2`
- Added `docserver` tag to shared infra tasks (directory creation, docker-compose template, compose up)
- Container exposed on port 8085, memory capped at 1.5 GB

### Journal Agent (media VM)

Added the `journal` and `journal-chromadb` services to the media VM docker-compose stack. The journal
agent provides an MCP journaling and retrieval service backed by ChromaDB for vector search.

- Replaced old `hometube` directory tasks with `journal-agent` directory tasks
- Added `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` to `.env.j2` (sourced from vault)
- Journal agent on port 8400, ChromaDB on port 8401
- ChromaDB healthcheck gates journal agent startup
