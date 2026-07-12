# Documentation MCP Server (docserver)

## Overview

The docserver runs on the **infra VM** (192.168.2.106) as three Docker containers: a webapp UI, the MCP server
itself, and a dedicated ChromaDB instance for vector storage. It provides an MCP-compatible documentation search
and retrieval service, indexing git-hosted documentation sources and making them queryable from Claude Code and
other MCP clients.

## Architecture

| Container               | Image                                                       | Host port | Memory             |
|-------------------------|-------------------------------------------------------------|-----------|--------------------|
| `documentation-webapp`  | `ghcr.io/johnmathews/unified-documentation-webapp:<ver>`    | 3003      | 192 MB (64 MB res.)|
| `documentation-server`  | `ghcr.io/johnmathews/unified-documentation-server:latest`   | 8085      | 1 GB (512 MB res.) |
| `documentation-chroma`  | `chromadb/chroma:1.5.8`                                     | (internal)| 256 MB (100 MB res.)|

Do not raise the server's memory limit without raising the VM's RAM — the cap is deliberately set
below the VM's available memory so the cgroup OOM killer fires cleanly (see the comment in
`roles/infra_vm/templates/docker-compose.yml.j2`).

The server depends on `documentation-chroma` being healthy before starting (compose `condition: service_healthy`).
The chroma container's healthcheck uses a TCP probe (`</dev/tcp/127.0.0.1/8000`) on a 10s interval.

## Volumes

| Mount                                       | Container path                  | Purpose                      |
|---------------------------------------------|---------------------------------|------------------------------|
| `docserver-data` (named volume)             | `/data`                         | SQLite, git clones           |
| `documentation-chroma-data` (named volume)  | `/chroma-data`                  | ChromaDB vector store        |
| `./docserver/config/sources.yaml`           | `/config/sources.yaml` (ro)     | Source configuration         |

There is no local MkDocs bind mount: the home server documentation is indexed as a remote git
source (`home-server` in `sources.yaml`, cloned from GitHub using `GITHUB_TOKEN`) like every other source.

## Environment Variables

Set in `roles/infra_vm/templates/docker-compose.yml.j2`:

| Variable                       | Value                                       |
|--------------------------------|---------------------------------------------|
| `ANTHROPIC_API_KEY`             | from vault (`vault_anthropic_api_key_unified_documentation_server`) |
| `GITHUB_TOKEN`                  | from vault                                  |
| `DOCSERVER_CHAT_MODEL`          | `claude-opus-4-7`                           |
| `DOCSERVER_CHROMA_HOST`         | `documentation-chroma` (compose service name) |
| `DOCSERVER_CHROMA_PORT`         | `8000`                                      |

## Configuration

Sources are defined in `roles/infra_vm/templates/docserver-sources.yml.j2`, which is templated to
`/srv/infra/docserver/config/sources.yaml` on the infra VM. The effective poll interval is **1800 seconds
(30 minutes)**, set via the `DOCSERVER_POLL_INTERVAL=1800` environment variable in the compose file — chosen
to limit how often the memory-hungry embedding worker runs (see the compose comment). The `poll_interval: 120`
field still present in `sources.yaml` is overridden by the environment variable.

Document types are defined in `roles/infra_vm/templates/docserver-doctypes.yml.j2`, templated to
`/srv/infra/docserver/config/document-types.yaml` by the same task file.

## Ansible

- **Deploy**: `make infra t=docserver`
- **Role**: `roles/infra_vm`
- **Task file**: `roles/infra_vm/tasks/docserver.yml`
- **Templates**: `docserver-sources.yml.j2`, `docserver-doctypes.yml.j2`, included in `docker-compose.yml.j2`

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
