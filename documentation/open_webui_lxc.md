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
+-----------------+---------------------------------------------------------------+-------+------------------------------+
| Container       | Image                                                         | Port  | Purpose                      |
+-----------------+---------------------------------------------------------------+-------+------------------------------+
| open-webui      | ghcr.io/open-webui/open-webui:main                            | 3000  | LLM chat interface           |
| node_exporter   | quay.io/prometheus/node-exporter:{{ node_exporter_version }}  | 9100  | Host metrics for Prometheus  |
| cadvisor        | gcr.io/cadvisor/cadvisor:{{ cadvisor_version }}               | 18080 | Container metrics            |
| alloy           | grafana/alloy:{{ alloy_version }}                             | 12345 | Log shipping to Loki         |
+-----------------+---------------------------------------------------------------+-------+------------------------------+
```

Sidecar version pins live in `roles/open_webui_lxc/defaults/main.yml` (currently:
cadvisor `v0.49.1`, alloy `v1.5.1`, node_exporter `v1.8.2`).

## Configuration

### LLM Backend

Open WebUI connects to the OpenAI API using the `OPENAI_API_KEY` environment variable.
The key is stored in the Ansible-deployed `.env` file as `OPENAI_KEY` (from `vault_openai_key`),
which the compose template maps to `OPENAI_API_KEY` in the container environment.

Settings:
- `OPENAI_API_KEY` — set from `${OPENAI_KEY}` in `docker-compose.yml.j2` (`.env` deployed from
  `roles/open_webui_lxc/templates/.env.j2`)
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

## Vault Variables Used

- `vault_openai_key` — OpenAI API key in `.env` template

Note: the role defaults still carry vestigial `smb_username` / `smb_server` variables from a
removed Paperless SMB share config (Paperless was decommissioned 2026-07-04; the `smb_shares`
entry was deleted from the defaults at that time).

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
