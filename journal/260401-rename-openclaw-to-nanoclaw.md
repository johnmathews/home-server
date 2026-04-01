# Rename OpenClaw to NanoClaw across project

The AI assistant platform on the Agent LXC was renamed from OpenClaw to NanoClaw upstream.
Updated all references across documentation, Ansible roles, and project config.

## Key changes

- **documentation/agent.md**: Full rewrite reflecting NanoClaw architecture (Docker sandbox
  model, gateway port 18790, config at `~/.nanobot/config.json`, systemd service `nanoclaw`,
  no Canvas server, no Bridge). Removed stale OpenClaw-specific sections (CLI uninstall,
  summarize skill, old architecture diagrams).
- **Ansible handler**: `Restart openclaw gateway` (service `openclaw-gateway`) renamed to
  `Restart nanoclaw` (service `nanoclaw`) in `roles/agent_lxc/handlers/main.yml`.
- **Ansible tasks**: Updated notify reference in `roles/agent_lxc/tasks/main.yml`.
- **Docker compose template**: Updated comment header in
  `roles/agent_lxc/templates/docker-compose.yml.j2`.
- **Infra VM mkdocs nav**: Changed `OpenClaw: openclaw.md` to `NanoClaw: agent.md` in
  `roles/infra_vm/templates/mkdocs.yml.j2`.
- **documentation/cloudflared.md**: Updated route reference to NanoClaw on port 18790.
- **documentation/tailscale.md**: Updated LXC name references from OpenClaw to NanoClaw.
- **CLAUDE.md**: Updated network table (gateway port) and documentation index entry.

## Notes

- The Tailscale MagicDNS hostname (`openclaw.flicker-enigmatic.ts.net`) still uses the old
  name because it was registered before the rename. Can be changed in Tailscale admin console.
- NanoClaw does not use Docker Compose for its own runtime (unlike most services in this
  project). It runs as a user-level systemd service (`nanoclaw.service`) that spawns Docker
  sandbox containers directly for agent sessions.
