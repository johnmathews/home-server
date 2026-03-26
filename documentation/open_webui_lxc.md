# Open WebUI

## Purpose

Self-hosted web interface for interacting with LLM models. Provides a ChatGPT-like UI backed
by the OpenAI API (or compatible endpoints).

## Quick Reference

```
+-----------------------+--------------------------------------------------+
| Host                  | open_webui_lxc (192.168.2.119)                   |
| SSH                   | ssh open-webui (user: root)                      |
| Web UI                | chat.itsa-pizza.com                              |
| Port                  | 3000 (maps to container 8080)                    |
| Docker compose dir    | /srv/apps                                        |
| Ansible               | make open-webui                                  |
| Role                  | roles/open_webui_lxc                             |
+-----------------------+--------------------------------------------------+
```

## Docker Containers

```
+-----------------+-------------------------------------------+-------+------------------------------+
| Container       | Image                                     | Port  | Purpose                      |
+-----------------+-------------------------------------------+-------+------------------------------+
| open-webui      | ghcr.io/open-webui/open-webui:main        | 3000  | LLM chat interface           |
| node_exporter   | node-exporter:latest                      | 9100  | Host metrics for Prometheus  |
| cadvisor        | cadvisor:latest                           | 18080 | Container metrics            |
| alloy           | grafana/alloy:latest                      | 12345 | Log shipping to Loki         |
+-----------------+-------------------------------------------+-------+------------------------------+
```

## Configuration

### LLM Backend

Open WebUI connects to the OpenAI API using the `OPENAI_API_KEY` environment variable.
The API key is stored in the `.env` file deployed by Ansible (sourced from vault).

Settings:
- `OPENAI_API_KEY` — From vault via `.env` file
- No custom `OPENAI_API_BASE` configured — uses default `https://api.openai.com/v1`
- Supports switching to Azure OpenAI or local LLM proxies by setting `OPENAI_API_BASE`

### Web UI Settings

- `WEBUI_NAME` — Set to the primary domain name
- `WEBUI_URL` — `https://chat.{{ primary_domain_name }}`
- `ENABLE_SIGNUP: true` — Cloudflare Access acts as the authentication gate
- `MAX_FILE_SIZE_MB: 50` — File upload limit

### Storage

- `/srv/apps/open-webui/data` — Application data (conversations, settings, user data)

No NFS mounts — all data is local to the LXC.

## External Access

Accessible via Cloudflare Tunnel with Zero Access protection:

- `chat.itsa-pizza.com` → `192.168.2.119:3000`

Signup is enabled in Open WebUI itself, but Cloudflare Access provides the authentication
layer. Users must pass Zero Access before reaching the signup/login page.

## SMB Configuration

The role defaults include an SMB share configuration for Paperless (`smb_shares: paperless`
mounted at `/mnt/paperless`). This appears to allow the Open WebUI LXC to access the Paperless
document store, potentially for document-based chat or RAG workflows.

## Vault Variables Used

- `vault_openai_api_key` (or equivalent) — OpenAI API key in `.env` template

## Troubleshooting

- **Can't reach chat UI**: Check Cloudflare tunnel status and container health:
  `ssh open-webui && docker logs open-webui`
- **API errors**: Verify the OpenAI API key is valid. Check `.env` file at `/srv/apps/.env`
- **Slow responses**: Open WebUI proxies requests to OpenAI. Latency depends on the OpenAI API.

## Upgrading

Open WebUI uses the `:main` tag which tracks the latest release:

1. Pull latest image: `ssh open-webui && docker compose pull`
2. Or run `make open-webui` to redeploy
3. Data persists in `/srv/apps/open-webui/data` across upgrades
