# NanoClaw

NanoClaw is an AI assistant that runs agents securely in their own Docker containers. Lightweight, built to be easily
understood and completely customized. It connects messaging platforms (WhatsApp, Telegram, Slack, Discord, and others)
to LLM backends (Claude, GPT, DeepSeek, etc.) via your own API keys. Your data does not pass through third-party
infrastructure beyond the LLM API calls themselves.

NanoClaw was originally published as "Clawdbot" (November 2025), briefly renamed to "Moltbot", then "OpenClaw", and
finally renamed to "NanoClaw" in early 2026.

- GitHub (fork): https://github.com/johnmathews/nanoclaw
- Official site: https://nanoclaw.dev

## Architecture

NanoClaw uses a gateway-centric architecture where the gateway process manages all messaging channels and spawns
isolated Docker containers for each agent session.

```
                    +-------------------------+
                    |        Gateway          |
                    |  (ws://0.0.0.0:18790)   |
                    |                         |
                    |  - Channel adapters     |
                    |  - Session mgmt         |
                    |  - Container orchestration|
                    |  - Control UI           |
                    +----+--------+-----+-----+
                         |        |     |
              +----------+   +----+---+ +----------+
              |              |        |            |
     +--------v------+  +---v----+ +-v----------+ |
     | Docker sandbox|  | Slack  | | WhatsApp   | |
     | (agent container) | bot  | | bridge     | |
     +---------------+  +-------+ +------------+ ...
```

### Gateway (port 18790)

The central process -- a long-running Node.js daemon that:

- Owns all messaging channel connections (adapters for WhatsApp, Telegram, Slack, Discord, etc.)
- Manages sessions, routing, and access control
- Runs a WebSocket server on `0.0.0.0:18790`
- Serves the Control UI (web dashboard)
- Orchestrates Docker sandbox containers for agent execution
- Emits events: `agent`, `chat`, `presence`, `health`, `heartbeat`, `cron`

Additional internal ports:

```
+--------------------+--------+---------------------------------------------+
| Service            | Port   | Notes                                       |
+--------------------+--------+---------------------------------------------+
| Gateway (WS)       | 18790  | Bound to 0.0.0.0                            |
| Credential proxy   | 3001   | On Docker bridge (172.17.0.1), for containers|
| Health endpoint    | 3002   | On localhost only                            |
+--------------------+--------+---------------------------------------------+
```

### Docker Sandboxes

Every agent session gets its own isolated Docker container. This provides hypervisor-level isolation with millisecond
startup. The gateway manages container lifecycle (creation, timeout, cleanup).

Key container settings (from `.env`):

```
CONTAINER_IMAGE=nanoclaw-agent:latest
CONTAINER_TIMEOUT=1800000
CONTAINER_MEMORY_LIMIT=2g
CONTAINER_CPU_LIMIT=2
MAX_CONCURRENT_CONTAINERS=5
```

### Skills

Skills are modular task guides that teach the agent how to use tools:

- Each skill is a folder containing a `SKILL.md` file with YAML frontmatter and Markdown instructions
- Loaded from three locations (highest precedence first): workspace skills, local skills, bundled skills
- Selectively injected into prompts based on relevance
- Can be gated on: platform, required binaries, environment variables, config conditions

> **Security**: Treat third-party skills as untrusted code. Read them before enabling.

## Client apps

```
+-----------+----------------------------------------------------------------+
| Platform  | Details                                                        |
+-----------+----------------------------------------------------------------+
| macOS     | Native menu-bar app (Universal Binary, macOS 14+).            |
|           | Supports "Remote over SSH" mode.                               |
+-----------+----------------------------------------------------------------+
| iOS       | Device node via WebSocket. Camera, voice, screen recording,    |
|           | location, notifications.                                       |
+-----------+----------------------------------------------------------------+
| Android   | Device node via WebSocket. Camera, voice, screen recording.    |
|           | No Voice Wake or location currently.                           |
+-----------+----------------------------------------------------------------+
| CLI       | Works on macOS, Linux, Windows (WSL2).                         |
+-----------+----------------------------------------------------------------+
| Web       | Browser-based chat (WebChat) served by the Gateway.            |
|           | Control UI at http://127.0.0.1:18790.                          |
+-----------+----------------------------------------------------------------+
```

## LXC setup

NanoClaw runs on a dedicated Proxmox LXC container. The application is installed **natively** (not via Docker) and
managed as a user-level systemd service. Docker on this LXC is used for the monitoring stack and the agent sandbox
containers.

```
+-------------------+--------------------------+
| Property          | Value                    |
+-------------------+--------------------------+
| Hostname          | agent_lxc                |
| IP address        | 192.168.2.107            |
| SSH user          | root                     |
| OS                | Debian 13                |
| Timezone          | Europe/Amsterdam         |
| Ansible role      | roles/agent_lxc          |
| Playbook          | playbooks/agent_lxc.yml  |
| Make target       | make agent               |
+-------------------+--------------------------+
```

### What the Ansible role manages

The `agent_lxc` role handles infrastructure around NanoClaw, **not** NanoClaw itself:

- Creates the `john` user
- Sets up directory structure (`/srv/apps/`)
- Deploys the Docker Compose stack (monitoring + MkDocs documentation sites)
- Deploys the NanoClaw `.env` file (secrets from vault)
- Configures Alloy for log aggregation to Loki
- Deploys MkDocs Material sites for browsing markdown documentation
- Applies the `shell_environment` role (CLI tools, shell config)

NanoClaw itself was installed manually and is managed as a systemd user service outside of Ansible.

### What runs in Docker (Compose stack)

```
+-----------------+--------+--------------------------------------------------+
| Container       | Port   | Purpose                                          |
+-----------------+--------+--------------------------------------------------+
| relay           | 7800   | Relay orchestrator (public: relay.itsa-pizza.com) |
| mkdocs-journal  | 8000   | NanoClaw dev journal (MkDocs Material)            |
| mkdocs-docs     | 8001   | NanoClaw documentation (MkDocs Material)          |
| syncthing       | 8384   | File sync with MacBook (dev folders)             |
| cadvisor        | 18080  | Container resource metrics                       |
| alloy           | 12345  | Log aggregation -> Loki (192.168.2.106:3100)      |
| node_exporter   | 9100   | Host-level Prometheus metrics                    |
+-----------------+--------+--------------------------------------------------+
```

### What runs in Docker (NanoClaw-managed)

```
+-----------------+--------+--------------------------------------------------+
| Container       | Port   | Purpose                                          |
+-----------------+--------+--------------------------------------------------+
| nanoclaw-agent  |        | Slack bot container (spawned by gateway)          |
+-----------------+--------+--------------------------------------------------+
```

### What runs natively

```
+-----------------+--------+--------------------------------------------------+
| Service         | Port   | Notes                                            |
+-----------------+--------+--------------------------------------------------+
| NanoClaw Gateway| 18790  | Bound to 0.0.0.0, systemd user service           |
+-----------------+--------+--------------------------------------------------+
```

### Relay

The `relay` container (image `ghcr.io/johnmathews/relay`, version pinned by `relay_version` in
`roles/agent_lxc/defaults/main.yml`) runs the relay orchestrator on port 7800. It is exposed publicly at
`relay.itsa-pizza.com` via the Cloudflare Tunnel (`roles/cloudflared_lxc/defaults/main.yml`, prefix `relay` ->
`192.168.2.107:7800`) — an SSH-free ingress into the agent LXC. It bind-mounts its SQLite event store
(`/srv/apps/relay/data`), a Pi OAuth credential (`/srv/apps/relay/.pi`), and the Syncthing project tree
(`/srv/apps/syncthing`, identity-mounted so in-container paths match host paths). See the comments in
`roles/agent_lxc/templates/docker-compose.yml.j2` for setup details.

### Syncthing

Syncthing (host network mode, GUI on `:8384`) syncs dev folders between the LXC and the MacBook
(device "MacBook Pro"). Folder roots live under `/srv/apps/syncthing/` (`horizons`, `relay`,
`meeting-assistant`, `screenshots`), mounted into the container at `/var/syncthing`. The folder
list is the `syncthing_folders` variable in `roles/agent_lxc/defaults/main.yml`.

**Ignore patterns:** every synced folder gets the same `.stignore`
(`roles/agent_lxc/templates/syncthing-stignore.j2`): `.DS_Store`, `node_modules`, `.venv`,
`__pycache__`, all with the `(?d)` prefix so Syncthing may delete them when removing a parent
directory. The MacBook side must carry the **same** patterns
(`~/projects/syncthing/agent-lxc/<folder>/.stignore`) — mismatched ignores cause persistent
`Failed to sync ... directory has been deleted on a remote device but is not empty` warnings
(this happened with Claude worktrees containing `node_modules`/`.venv`; thousands of warnings
per week until ignores were aligned on 2026-06-10).

**Known log noise (benign):**

- `Failed to acquire open port ... NAT-PMP@192.168.2.1 ... connection refused` — the MikroTik
  does not run NAT-PMP/UPnP. Harmless; both devices connect directly over the LAN. Silence it by
  disabling NAT traversal (GUI: Actions → Settings → Connections → uncheck "Enable NAT
  traversal", or `syncthing cli ... config options nat-enabled set false` inside the container).
- `Failed to exchange Hello messages (device=VI7EDPA... error=EOF)` — the MacBook went to sleep
  mid-handshake. Resolves itself when the laptop wakes; not actionable.

### MkDocs documentation sites

MkDocs Material is used to serve markdown documentation from the LXC as browsable websites. Sites are defined in the
`mkdocs_sites` variable in `roles/agent_lxc/defaults/main.yml`. Each entry generates a Docker container, an MkDocs
config file, and a unique port mapping.

Current sites:

```
+-----------------+--------+-------+-----------------------------------+
| Site            | Port   | Order | Source path on LXC                |
+-----------------+--------+-------+-----------------------------------+
| journal         | 8000   | desc  | /srv/apps/nanoclaw/journal        |
| docs            | 8001   |       | /srv/apps/nanoclaw/docs           |
+-----------------+--------+-------+-----------------------------------+
```

To add a new documentation site, add an entry to the `mkdocs_sites` list:

```yaml
mkdocs_sites:
  - name: journal
    site_name: NanoClaw Journal
    docs_path: /srv/apps/nanoclaw/journal
    port: 8000
    order: desc
  - name: docs
    site_name: NanoClaw Docs
    docs_path: /srv/apps/nanoclaw/docs
    port: 8001
```

Then deploy with `make agent t=docs`. Pages are auto-discovered from the docs directory -- no `nav:` configuration is
needed. New or renamed markdown files are detected within ~5 seconds by a polling entrypoint script (`mkdocs-entrypoint.sh`)
that hashes the file listing every 5 seconds and restarts `mkdocs serve` when files are added or removed. This works
around a known limitation where Docker bind mounts don't propagate inotify events for new files to the container.

The optional `order` field controls page sort order via the `mkdocs-awesome-pages-plugin`. Set to `desc` for
reverse-alphabetical (newest-first for date-prefixed filenames like `YYMMDD-description.md`). Omit for default
ascending order.

The optional `date_titles` field enables a MkDocs hook that prepends the date from the `YYMMDD-` filename prefix to
each page title in the nav (e.g., `260318-fix-bug.md` -> **26-03-18 -- Fix Bug**). Any trailing date already in the
heading is stripped automatically to avoid duplication.

Both the awesome-pages plugin and the date-titles hook are baked into a custom Docker image built from
`mkdocs/Dockerfile` (extends `squidfunk/mkdocs-material`). The image is rebuilt automatically when the Dockerfile
changes.

Each docs directory needs an `index.md` to serve a landing page. Without one, MkDocs returns a 404 on the site root.

MkDocs configs are templated to `/srv/apps/mkdocs/<site-name>/mkdocs.yml` on the LXC. The source markdown directories
are mounted into the containers (rw to allow Docker overlay mounts for `.pages` files).

## Access

### SSH

```sh
ssh agent
```

### Web UI (Control UI / WebChat)

The Gateway binds to `0.0.0.0:18790`, so it is reachable on the LAN. You can also use an SSH tunnel:

```sh
ssh -N -L 18790:127.0.0.1:18790 agent
```

Then open http://localhost:18790 in your browser.

### Remote access (off-network via Tailscale)

When off the home network, the macOS app can connect through Tailscale by changing the SSH target. The `~/.ssh/config`
on the MacBook has two host aliases:

```
+-------------------+-------------------+------------------------------------------+
| SSH alias         | HostName          | Use when                                 |
+-------------------+-------------------+------------------------------------------+
| agent             | 192.168.2.107     | On the home LAN                          |
| agentt            | 100.125.185.47    | Off-network (via Tailscale)              |
+-------------------+-------------------+------------------------------------------+
```

To switch: change the **SSH target** in the NanoClaw app settings from `agent` to `agentt`. Tailscale must be running
on both the MacBook and the Agent LXC.

To verify Tailscale is healthy on the LXC:

```sh
ssh agent
tailscale status    # Shows node state and connected peers
```

### Public access (Cloudflare Tunnel)

NanoClaw is proxied behind cloudflared (NOT Traefik) at `claw.itsa-pizza.com` -> `192.168.2.107:18790`. The tunnel is
configured on the cloudflared LXC (192.168.2.101) in `/etc/cloudflared/config.yml`.

**Important**: `claw.itsa-pizza.com` is behind **Cloudflare Access** (zero-trust), which redirects unauthenticated requests
to `itsapizza.cloudflareaccess.com` for login. This means the Cloudflare Tunnel URL **cannot be used** for WebSocket
connections from the macOS app or programmatic clients -- Cloudflare Access intercepts the WebSocket upgrade and returns
a 302 redirect instead of passing it through to the gateway.

The Cloudflare Tunnel route works for browser-based access (WebChat) because the browser can complete the Access login
flow, but native apps cannot.

### Tailscale

Tailscale is installed on the Agent LXC.

```
+---------------------------+---------------------------------------------+
| Property                  | Value                                       |
+---------------------------+---------------------------------------------+
| Tailscale IP              | 100.125.185.47                              |
| MagicDNS hostname         | openclaw.flicker-enigmatic.ts.net            |
| Tailnet                   | flicker-enigmatic.ts.net                    |
| Installed via             | pkgs.tailscale.com/stable/debian/trixie      |
+---------------------------+---------------------------------------------+
```

Note: The MagicDNS hostname still reads `openclaw` because that was the device name when Tailscale was first registered.
The hostname can be renamed in the Tailscale admin console if desired.

Tailscale was previously skipped because `apt-key` is not available on Debian 13. The workaround is to install using
the modern keyring method (no `apt-key` needed):

```sh
# As root on the LXC:
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  | tee /etc/apt/sources.list.d/tailscale.list > /dev/null
apt-get update && apt-get install -y tailscale
tailscale up
```

**Tailscale Serve** was tested for TLS termination (`tailscale serve --bg http://localhost:18790`) which exposes the
gateway at `https://openclaw.flicker-enigmatic.ts.net`. However, Tailscale Serve does **not** properly forward
WebSocket upgrade headers -- it returns HTTP 200 (the HTML UI page) instead of 101 Switching Protocols. This makes it
unsuitable for the macOS app's `wss://` connection.

### macOS app (remote over SSH)

The macOS NanoClaw app connects to the homelab Gateway using the built-in "Remote over SSH" transport. The app manages
its own SSH tunnel to the LXC and connects to the gateway via `ws://127.0.0.1:18790` through that tunnel.

#### Why SSH tunnel (not direct WebSocket)

Several approaches were tested and failed:

```
+----------------------------------+---------------------------------------------+
| Approach                         | Result                                      |
+----------------------------------+---------------------------------------------+
| wss://claw.itsa-pizza.com        | Blocked by Cloudflare Access (302 redirect) |
| wss://100.125.185.47:18790       | Connection timeout (no TLS on gateway)      |
| wss://openclaw.flicker-          | Tailscale Serve strips WebSocket upgrade    |
|   enigmatic.ts.net               |   headers (returns 200 instead of 101)      |
| ws://100.125.185.47:18790        | App enforces wss:// for non-localhost URLs  |
+----------------------------------+---------------------------------------------+
```

The macOS app enforces `wss://` (TLS) for any non-localhost gateway URL. Since the gateway only speaks plain HTTP, and
neither Cloudflare Tunnel nor Tailscale Serve properly proxy WebSocket upgrades, the SSH tunnel is the only reliable
transport. The app allows `ws://` for localhost because the tunnel makes it appear local.

#### Setup steps

1. Install the NanoClaw app from the official release
2. Launch it and go through the Getting Started flow
3. Choose "Remote over SSH" mode
4. Fill in only the SSH target field:
   - **SSH target**: `agent` (uses your `~/.ssh/config` alias)
   - **Identity file**: leave blank (SSH config handles it)
   - **Project root**: leave blank
   - **CLI path**: leave blank (auto-detected from gateway)
5. Complete the setup flow
6. The app will establish an SSH tunnel and connect to the gateway
7. The gateway will prompt for **pairing approval** -- approve the macOS node from the web UI
   (http://localhost:18790 -> Instances)

#### Authentication token

The gateway requires an auth token. The macOS app's setup flow does **not** provide a UI field for this. The token must
be added manually to the macOS-side config file at `~/.nanobot/config.json`. Abbreviated example — note the token field
itself is **not shown** below (copy the auth key name/value from the gateway config on the LXC into the `gateway`
block):

```json
{
  "gateway": {
    "host": "0.0.0.0",
    "port": 18790,
    "heartbeat": {
      "enabled": true,
      "intervalS": 1800
    }
  }
}
```

The token value must match the gateway auth config in `~/.nanobot/config.json` on the LXC.

#### Gateway origin allowlist

The gateway's `controlUi.allowedOrigins` on the LXC must include the origin of any client connecting via WebSocket.
For the Tailscale hostname (if used in future):

```json
"controlUi": {
  "allowedOrigins": [
    "https://claw.itsa-pizza.com",
    "https://openclaw.flicker-enigmatic.ts.net"
  ]
}
```

Without a matching origin, the gateway returns 405 Method Not Allowed on WebSocket upgrade attempts. However, requests
from `localhost` (via SSH tunnel) are allowed by default without needing an explicit origin entry.

#### Resetting the macOS app

To fully reset the app and redo the Getting Started flow:

```sh
pkill -f "NanoClaw"
rm -rf ~/.nanobot
# Relaunch the app
```

#### Known issues

- **Menu bar icon not appearing on macOS 26 Tahoe**: The app uses a library that relies on private SwiftUI internals
  that changed in macOS 26 Tahoe, breaking icon rendering. The app runs and connects fine but the menu bar icon is
  invisible. This is an upstream bug.

- **Port conflicts with manual SSH tunnels**: If a manual SSH tunnel is already bound to port 18790, the app's built-in
  tunnel will fail with "Local port 18790 is unavailable". Kill any manual tunnels before launching the app:
  `pkill -f "ssh -f -N -L 18790"`

## Configuration

NanoClaw's primary config file is `~/.nanobot/config.json` (JSON format).

The Gateway watches this file and applies changes automatically (hot reload) -- no manual restart needed for most
settings.

Key settings:

```
+-------------------------------+-------------------------------------------+
| Setting                       | Description                               |
+-------------------------------+-------------------------------------------+
| gateway.port                  | WebSocket port (default 18790)            |
| gateway.host                  | Bind address (default "0.0.0.0")          |
| gateway.heartbeat.enabled     | Heartbeat on/off                          |
| agents.defaults.model         | Default LLM model                         |
| agents.defaults.provider      | Provider selection ("auto", etc.)         |
| channels.*                    | Per-channel config (slack, telegram, etc.)|
| providers.*                   | Per-provider API keys and config          |
| tools.mcpServers              | MCP server configuration                  |
+-------------------------------+-------------------------------------------+
```

Other important paths on the LXC:

- `~/.nanobot/config.json` -- Main config
- `~/.nanobot/workspace/` -- Agent workspace
- `~/.nanobot/cron/` -- Cron job definitions
- `/srv/apps/nanoclaw/.env` -- Environment variables (API keys, managed by Ansible)
- `/srv/apps/nanoclaw/groups/` -- Group-specific configs (e.g., Slack bot CLAUDE.md)

## Deployment

Deploy the monitoring stack and infrastructure:

```sh
make agent
```

To run only specific tags:

```sh
make agent t=docker    # Docker compose stack only
make agent t=docs      # MkDocs sites + docker compose
make agent t=alloy     # Alloy config only
make agent t=nanoclaw  # NanoClaw .env file only
make agent t=shell     # Shell environment only
```

## Useful commands

On the LXC (`ssh agent`):

```sh
# Gateway service (user-level systemd, NOT system-level)
systemctl --user status nanoclaw
systemctl --user restart nanoclaw
journalctl --user -u nanoclaw -f

# Check monitoring stack
cd /srv/apps && docker compose ps
cd /srv/apps && docker compose logs -f alloy

# View config
cat ~/.nanobot/config.json

# Check running agent containers
docker ps --filter "ancestor=nanoclaw-agent:latest"
```

> **Important**: The gateway service is `nanoclaw` under **user-level** systemd (not system-level). Always use
> the `--user` flag. `systemctl status nanoclaw` (without `--user`) will report "not found".

> **Important**: After restarting the gateway, the macOS app must also be restarted. The app's SSH tunnel breaks
> when the gateway restarts and does not automatically reconnect.

## References

- Official site: https://nanoclaw.dev
- GitHub (fork): https://github.com/johnmathews/nanoclaw
