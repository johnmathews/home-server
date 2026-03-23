# Documentation MCP Server (docserver)

## Overview

The docserver runs on the **infra VM** (192.168.2.106) as a Docker container. It provides an MCP-compatible
documentation search and retrieval service, indexing git-hosted documentation sources and making them queryable.

## Architecture

- **Image**: `ghcr.io/johnmathews/documentation-mcp-server:latest`
- **Container name**: `documentation-mcp-server`
- **Port**: 8085 (host) -> 8080 (container)
- **Memory limit**: 1536 MB (embeddings + ChromaDB + SQLite)

## Volumes

| Mount                                       | Container path                  | Purpose                      |
|---------------------------------------------|--------------------------------|------------------------------|
| `docserver-data` (named volume)             | `/data`                        | SQLite, ChromaDB, git clones |
| `./docserver/config/sources.yaml`           | `/config/sources.yaml` (ro)    | Source configuration         |
| `/srv/infra/mkdocs/docs`                    | `/repos/home-server-docs` (ro) | Local MkDocs documentation   |

## Configuration

Sources are defined in `roles/infra_vm/templates/docserver-sources.yml.j2`, which is templated to
`/srv/infra/docserver/config/sources.yaml` on the infra VM.

The poll interval is set to 300 seconds (5 minutes) via both the `DOCSERVER_POLL_INTERVAL` environment variable and the
`poll_interval` field in `sources.yaml`.

## Ansible

- **Deploy**: `make infra t=docserver`
- **Role**: `roles/infra_vm`
- **Task file**: `roles/infra_vm/tasks/docserver.yml`
- **Templates**: `docserver-sources.yml.j2`, included in `docker-compose.yml.j2`

## Adding Documentation Sources

Edit `roles/infra_vm/templates/docserver-sources.yml.j2` and add a new entry under `sources:`:

```yaml
sources:
  - name: "My docs"
    path: "https://github.com/user/repo.git"
    branch: "main"
    is_remote: true
```

Then run `make infra t=docserver` to deploy.
