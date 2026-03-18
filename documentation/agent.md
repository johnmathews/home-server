# OpenClaw

OpenClaw is a free and open-source autonomous AI agent that acts as a personal assistant running on your own
infrastructure. It connects messaging platforms (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, and many others)
to LLM backends (Claude, GPT, DeepSeek, etc.) via your own API keys. Your data does not pass through third-party
infrastructure beyond the LLM API calls themselves.

The project was created by Peter Steinberger, originally published in November 2025 as "Clawdbot", briefly renamed to
"Moltbot" in January 2026 following a trademark complaint from Anthropic, and then renamed to "OpenClaw" three days
later. In February 2026, Steinberger announced he would join OpenAI, with the project moving to an open-source
foundation.

- GitHub: https://github.com/openclaw/openclaw
- Official docs: https://docs.openclaw.ai
- Skill registry (ClawHub): https://clawhub.com

## Architecture

OpenClaw uses a hub-and-spoke architecture centered on the **Gateway**.

```
                        +---------------------+
                        |      Gateway        |
                        |  (ws://0.0.0.0      |
                        |       :18789)       |
                        |                     |
                        |  - Agent runtime    |
                        |  - Session mgmt     |
                        |  - Channel adapters |
                        |  - Control UI       |
                        |  - A2UI endpoints   |
                        +----+-----+-----+----+
                             |     |     |
              +--------------+     |     +---------------+
              |                    |                      |
     +--------v------+    +-------v-------+    +---------v------+
     | Canvas Server |    | Node (macOS)  |    | Node (iOS /    |
     |  (:18793)     |    | Menu-bar app  |    |  Android)      |
     | HTML/CSS/JS   |    | WebView panel |    | WebView        |
     +---------------+    +---------------+    +----------------+
```

### Gateway (port 18789)

The central control plane -- a long-running Node.js daemon that:

- Owns all messaging channel connections (adapters for WhatsApp, Telegram, Discord, etc.)
- Manages sessions, routing, and access control
- Runs a WebSocket server (JSON payloads) on `127.0.0.1:18789` by default
- Serves the Control UI (web dashboard) and A2UI endpoints
- Coordinates the agent runtime: resolving sessions, assembling context, invoking models, executing tool calls,
  persisting state
- Emits events: `agent`, `chat`, `presence`, `health`, `heartbeat`, `cron`

The Gateway refuses to start if `bind != "loopback"` and `auth.mode = "none"`, preventing accidental exposure without
authentication.

### Canvas (port 18793)

An agent-driven visual workspace running as a separate server process on port 18793. Instead of only communicating
through text, the agent can render interactive HTML, charts, diagrams, dashboards, and structured outputs that update in
real time.

- The agent interacts via skill commands: `canvas present`, `canvas navigate`, `canvas eval`, `canvas snapshot`
- A2UI (Agent-to-UI) endpoints are hosted by the Gateway at `http://<host>:18789/__openclaw__/a2ui/`
- Canvas content is served at `http://<host>:18793/__openclaw__/canvas/`
- Runs as a separate process -- if Canvas crashes, the Gateway continues
- Auto-reloads when local files change

On macOS, Canvas renders in a native `WKWebView` panel -- borderless, resizable, anchored near the menu bar. Files are
served via custom URL scheme `openclaw-canvas://` rather than loopback HTTP.

### Bridge (port 18790) -- deprecated

The TCP/JSONL bridge protocol on port 18790 (gateway port + 1) was used for mobile node connections. According to
official docs, current OpenClaw builds no longer ship the TCP bridge listener. Modern node connections use the unified
Gateway WebSocket protocol instead.

> **Note**: This homelab setup previously had port 18790 configured as the bridge port. If your OpenClaw version still
> uses it, it may be a legacy holdover. Check your version.

### Nodes

Nodes are device endpoints (macOS, iOS, Android, headless) that connect to the Gateway WebSocket with `role: "node"`.
They expose device-specific capabilities: canvas rendering, camera access, screen recording, location services, system
notifications, voice interaction. Pairing is device-based with approval stored in a pairing store.

### Skills

Skills are modular task guides that teach the agent how to use tools:

- Each skill is a folder containing a `SKILL.md` file with YAML frontmatter and Markdown instructions
- Loaded from three locations (highest precedence first): workspace skills, local skills (`~/.openclaw/skills/`),
  bundled skills
- Selectively injected into prompts based on relevance
- Can be gated on: platform, required binaries, environment variables, config conditions
- ClawHub (https://clawhub.com) is the public registry for discovering and installing skills

> **Security**: Treat third-party skills as untrusted code. Read them before enabling.

## Client apps

```
+-----------+----------------------------------------------------------------+
| Platform  | Details                                                        |
+-----------+----------------------------------------------------------------+
| macOS     | Native menu-bar app (Universal Binary, macOS 14+).            |
|           | Manages Gateway locally via launchd. Native WKWebView for     |
|           | Canvas. Supports "Remote over SSH" mode.                       |
+-----------+----------------------------------------------------------------+
| iOS       | Device node via WebSocket. Canvas, camera, voice, screen       |
|           | recording, location, notifications.                            |
+-----------+----------------------------------------------------------------+
| Android   | Device node via WebSocket. Canvas (WebView), camera, voice,    |
|           | screen recording. No Voice Wake or location currently.         |
+-----------+----------------------------------------------------------------+
| CLI       | Works on macOS, Linux, Windows (WSL2). Onboarding wizard:      |
|           | `openclaw onboard`.                                            |
+-----------+----------------------------------------------------------------+
| Web       | Browser-based chat (WebChat) served by the Gateway.            |
|           | Control UI at http://127.0.0.1:18789.                          |
+-----------+----------------------------------------------------------------+
```

## LXC setup

OpenClaw runs on a dedicated Proxmox LXC container. The application is installed **natively** (not via Docker) using
the official getting-started script. Docker on this LXC is only used for the monitoring stack.

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

The `agent_lxc` role handles infrastructure around OpenClaw, **not** OpenClaw itself:

- Creates the `john` user
- Sets up directory structure (`/srv/apps/`)
- Deploys the Docker Compose stack (monitoring + MkDocs documentation sites)
- Configures Alloy for log aggregation to Loki
- Deploys MkDocs Material sites for browsing markdown documentation
- Applies the `shell_environment` role (CLI tools, shell config)

OpenClaw itself was installed manually via the getting-started script and is managed outside of Ansible.

### What runs in Docker

```
+-----------------+--------+--------------------------------------------------+
| Container       | Port   | Purpose                                          |
+-----------------+--------+--------------------------------------------------+
| mkdocs-journal  | 8000   | NanoClaw dev journal (MkDocs Material)            |
| syncthing       | 8384   | File sync (nanoclaw data)                        |
| cadvisor        | 18080  | Container resource metrics                       |
| alloy           | 12345  | Log aggregation → Loki (192.168.2.106:3100)      |
| node_exporter   | 9100   | Host-level Prometheus metrics                    |
+-----------------+--------+--------------------------------------------------+
```

### What runs natively

```
+-----------------+--------+--------------------------------------------------+
| Service         | Port   | Notes                                            |
+-----------------+--------+--------------------------------------------------+
| OpenClaw Gateway| 18789  | Bound to 0.0.0.0 (bind: "lan")                   |
| Canvas server   | 18793  | Agent-driven visual workspace                    |
+-----------------+--------+--------------------------------------------------+
```

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
needed. New or renamed markdown files appear automatically via MkDocs' polling file watcher.

The optional `order` field controls page sort order via the `mkdocs-awesome-pages-plugin`. Set to `desc` for
reverse-alphabetical (newest-first for date-prefixed filenames like `YYMMDD-description.md`). Omit for default
ascending order.

The optional `date_titles` field enables a MkDocs hook that prepends the date from the `YYMMDD-` filename prefix to
each page title in the nav (e.g., `260318-fix-bug.md` → **26-03-18 — Fix Bug**). Any trailing date already in the
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

The Gateway binds to `0.0.0.0:18789` (bind mode: `lan`), so it is reachable on the LAN. You can also use an SSH tunnel:

```sh
ssh -N -L 18789:127.0.0.1:18789 agent
```

Then open http://localhost:18789 in your browser.

To also forward the Canvas port:

```sh
ssh -N \
  -L 18789:127.0.0.1:18789 \
  -L 18793:127.0.0.1:18793 \
  agent
```

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

To switch: change the **SSH target** in OpenClaw app settings (or edit `gateway.remote.sshTarget` in
`~/.openclaw/openclaw.json`) from `agent` to `agentt`. The config is hot-reloaded. Tailscale must be running on
both the MacBook and the Agent LXC.

To verify Tailscale is healthy on the LXC:

```sh
ssh agent
tailscale status    # Shows node state and connected peers
```

### Public access (Cloudflare Tunnel)

OpenClaw is proxied behind cloudflared (NOT Traefik) at `claw.itsa-pizza.com` → `192.168.2.107:18789`. The tunnel is
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

**Tailscale Serve** was tested for TLS termination (`tailscale serve --bg http://localhost:18789`) which exposes the
gateway at `https://openclaw.flicker-enigmatic.ts.net`. However, Tailscale Serve does **not** properly forward
WebSocket upgrade headers -- it returns HTTP 200 (the HTML UI page) instead of 101 Switching Protocols. This makes it
unsuitable for the macOS app's `wss://` connection.

### macOS app (remote over SSH)

The macOS OpenClaw.app connects to the homelab Gateway using the built-in "Remote over SSH" transport. The app manages
its own SSH tunnel to the LXC and connects to the gateway via `ws://127.0.0.1:18789` through that tunnel.

#### Why SSH tunnel (not direct WebSocket)

Several approaches were tested and failed:

```
+----------------------------------+---------------------------------------------+
| Approach                         | Result                                      |
+----------------------------------+---------------------------------------------+
| wss://claw.itsa-pizza.com            | Blocked by Cloudflare Access (302 redirect) |
| wss://100.125.185.47:18789       | Connection timeout (no TLS on gateway)      |
| wss://openclaw.flicker-          | Tailscale Serve strips WebSocket upgrade    |
|   enigmatic.ts.net               |   headers (returns 200 instead of 101)      |
| ws://100.125.185.47:18789        | App enforces wss:// for non-localhost URLs  |
+----------------------------------+---------------------------------------------+
```

The macOS app enforces `wss://` (TLS) for any non-localhost gateway URL. Since the gateway only speaks plain HTTP, and
neither Cloudflare Tunnel nor Tailscale Serve properly proxy WebSocket upgrades, the SSH tunnel is the only reliable
transport. The app allows `ws://` for localhost because the tunnel makes it appear local.

#### Setup steps

1. Install OpenClaw.app from the official release
2. Launch it and go through the Getting Started flow
3. Choose "Remote over SSH" mode
4. Fill in only the SSH target field:
   - **SSH target**: `agent` (uses your `~/.ssh/config` alias)
   - **Identity file**: leave blank (SSH config handles it)
   - **Project root**: leave blank
   - **CLI path**: leave blank (auto-detected from gateway)
5. Complete the setup flow
6. The app will establish an SSH tunnel and connect to the gateway
7. The gateway will prompt for **pairing approval** -- approve the macOS node from the OpenClaw web UI
   (http://localhost:18789 → Instances)

#### Authentication token

The gateway requires an auth token. The macOS app's setup flow does **not** provide a UI field for this. The token must
be added manually to the macOS-side config file at `~/.openclaw/openclaw.json`:

```json
{
  "gateway": {
    "mode": "remote",
    "remote": {
      "sshTarget": "agent",
      "url": "ws://agent:18789",
      "token": "<gateway-auth-token>"
    }
  }
}
```

The token value must match `gateway.auth.token` in `~/.openclaw/openclaw.json` on the LXC. The config key is
`gateway.remote.token` (found by inspecting the app binary -- the key `gateway.remote.token` is not documented in
the official docs as of 2026.2.25).

The macOS config file is hot-reloaded -- no app restart needed after editing it.

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
pkill -f "OpenClaw.app"
defaults delete ai.openclaw.mac
defaults delete ai.openclaw.shared
rm -rf ~/.openclaw
open /Applications/OpenClaw.app
```

The app stores settings in two places:
- `~/Library/Preferences/ai.openclaw.mac.plist` -- app preferences (connection mode, onboarding state, icon settings)
- `~/.openclaw/openclaw.json` -- gateway connection config (mode, URL, token, SSH target)

#### Uninstalling the CLI (if installed separately)

The OpenClaw CLI may be installed globally via npm at `/opt/homebrew/lib/node_modules/openclaw/`. If `npm uninstall -g
openclaw` fails (e.g., because it was installed under a different Node version prefix via `fnm`), remove it manually:

```sh
rm /opt/homebrew/bin/openclaw
rm -rf /opt/homebrew/lib/node_modules/openclaw
```

Note: the CLI requires Node.js v20.11.0+ (the `--disable-warning=ExperimentalWarning` flag is not supported in v18).

#### Known issues (as of version 2026.2.25, build 14883)

- **Menu bar icon not appearing on macOS 26 Tahoe**: The app uses the `MenuBarExtraAccess` library to introspect
  SwiftUI's `MenuBarExtra` and set a custom icon. This library relies on private SwiftUI internals that changed in
  macOS 26 Tahoe, breaking icon rendering. The app runs and connects fine but the menu bar icon is invisible
  (`lsappinfo` shows `StatusLabel = NULL`). This is an upstream bug -- the library needs to be updated for Tahoe.

  **Workaround**: Enable the Dock icon so the app is visible and interactive:

  ```sh
  defaults write ai.openclaw.mac "openclaw.showDockIcon" -bool true
  # Restart the app for the change to take effect
  pkill -f "OpenClaw.app" && open /Applications/OpenClaw.app
  ```

  The web UI at http://localhost:18789 also works as an alternative interface.

  Things that were tried and **did not** fix the menu bar icon:
  - macOS System Settings > Menu Bar > "Allow in Menu Bar" toggle (new Tahoe feature)
  - Changing the `openclaw.iconOverride` preference (system, idle, workingMain)
  - Resetting SystemUIServer, ControlCenter, and Dock processes/preferences
  - Enabling `NSStatusItem Visible Item-N` flags in `com.apple.controlcenter`
  - Full app reset (delete prefs + config + relaunch onboarding)
  - Updating to 2026.2.26 (the GitHub release zip contains a debug build -- see below)

- **GitHub release 2026.2.26 is a debug build**: The zip at
  `github.com/openclaw/openclaw/releases/download/v2026.2.26/OpenClaw-2026.2.26.zip` has bundle ID
  `ai.openclaw.mac.debug` instead of `ai.openclaw.mac`. It uses a separate preferences domain, triggers Gatekeeper
  warnings, and should not be used. Stick with the 2026.2.25 release build (`ai.openclaw.mac`, build 14883).

- **No token field in setup UI**: The Getting Started flow does not include a field for the gateway auth token. It must
  be added manually to `~/.openclaw/openclaw.json` after completing the flow.
- **Port conflicts with manual SSH tunnels**: If a manual SSH tunnel is already bound to port 18789, the app's built-in
  tunnel will fail with "Local port 18789 is unavailable". Kill any manual tunnels before launching the app:
  `pkill -f "ssh -f -N -L 18789"`

## Configuration

OpenClaw's primary config file is `~/.openclaw/openclaw.json` (JSON5 format -- supports comments and trailing commas).

The Gateway watches this file and applies changes automatically (hot reload) -- no manual restart needed for most
settings.

Key settings:

```
+-------------------------------+-------------------------------------------+
| Setting                       | Description                               |
+-------------------------------+-------------------------------------------+
| gateway.port                  | WebSocket port (default 18789)            |
| gateway.bind                  | Bind address (default "loopback")         |
| gateway.auth.token            | Authentication token                      |
| gateway.auth.allowTailscale   | Allow Tailscale identity headers          |
| gateway.mode                  | "local" or "remote"                       |
| gateway.remote.url            | Remote gateway URL                        |
| gateway.remote.token          | Remote gateway token                      |
| skills.entries                | Per-skill config, env vars, API keys      |
| skills.load.extraDirs         | Additional skill directories              |
+-------------------------------+-------------------------------------------+
```

Other important paths on the LXC:

- `~/.openclaw/openclaw.json` -- Main config
- `~/.openclaw/skills/` -- Local/shared skills
- `<workspace>/skills/` -- Workspace-specific skills

Credential precedence: explicit flags (`--token`) > environment variables (`OPENCLAW_GATEWAY_TOKEN`) > config file.

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
make agent t=shell     # Shell environment only
```

## Useful commands

On the LXC (`ssh agent`):

```sh
# Gateway service (user-level systemd, NOT system-level)
systemctl --user status openclaw-gateway
systemctl --user restart openclaw-gateway
journalctl --user -u openclaw-gateway -f

# Gateway logs (JSON, daily-rotated files in /tmp)
tail -f /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log
# Search logs for errors:
grep -i 'error\|fail' /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log | tail -20

# Skills: check requirements, inspect a skill
openclaw skills check
openclaw skills info <skill-name>
openclaw skills list

# Check monitoring stack
cd /srv/apps && docker compose ps
cd /srv/apps && docker compose logs -f alloy

# View config
cat ~/.openclaw/openclaw.json
```

> **Important**: The gateway service is `openclaw-gateway` under **user-level** systemd (not system-level). Always use
> the `--user` flag. `systemctl status openclaw` (without `--user`) will report "not found".

> **Important**: After restarting the gateway, the macOS app must also be restarted (`pkill -f "OpenClaw.app" && open
> /Applications/OpenClaw.app`). The app's SSH tunnel breaks when the gateway restarts and does not automatically
> reconnect.

## Skills troubleshooting

Skills declare requirements (binaries, env vars, config keys, OS) in their `SKILL.md` frontmatter. If a skill fails to
install with "unsatisfied requirement":

1. Check what's missing: `openclaw skills info <skill-name>`
2. Run a full requirements audit: `openclaw skills check`
3. The gateway logs (`/tmp/openclaw/openclaw-*.log`) show install failures but the error message is generic — use the
   CLI commands above for specifics

After installing a missing dependency (binary, env var, etc.), **restart the gateway** for it to pick up the change:

```sh
systemctl --user restart openclaw-gateway
```

Then restart the macOS app (see note above).

### Example: summarize skill

The `summarize` skill requires the `summarize` CLI (`https://summarize.sh`). The skill's built-in install option is
Homebrew-only, which doesn't work on the Debian LXC. Install via npm instead:

```sh
npm install -g @steipete/summarize
```

The `summarize` CLI also requires at least one LLM API key: `GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or
`XAI_API_KEY`.

## References

- Official docs: https://docs.openclaw.ai
- GitHub: https://github.com/openclaw/openclaw
- Architecture: https://docs.openclaw.ai/concepts/architecture
- Configuration: https://docs.openclaw.ai/gateway/configuration
- Remote access: https://docs.openclaw.ai/gateway/remote
- Skills: https://docs.openclaw.ai/tools/skills
- Canvas (macOS): https://docs.openclaw.ai/platforms/mac/canvas
- ClawHub (skill registry): https://clawhub.com
