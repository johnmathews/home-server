# MkDocs new file detection fix

`mkdocs serve` inside Docker doesn't detect new files added to bind-mounted volumes. inotify only
fires for modifications to files that existed at startup -- new files created on the host never
trigger a rebuild.

## Fix

Added a polling entrypoint script (`mkdocs-entrypoint.sh.j2`) that wraps `mkdocs serve`:

- Hashes the list of `.md` files every 5 seconds using `find | sort | md5sum`
- Restarts `mkdocs serve` when the hash changes (file added or deleted)
- Traps SIGTERM/SIGINT for clean Docker shutdown (forwards signal to mkdocs child)
- Detects if mkdocs crashes and auto-restarts it

Existing file modifications are still handled by mkdocs' built-in inotify (works fine for
already-known files even on bind mounts).

## Files changed

- `roles/agent_lxc/templates/mkdocs-entrypoint.sh.j2` -- new polling entrypoint
- `roles/agent_lxc/templates/mkdocs.Dockerfile.j2` -- uses entrypoint instead of default CMD
- `roles/agent_lxc/tasks/main.yml` -- deploys entrypoint script to host
- `documentation/agent.md` -- updated docs to reflect new behavior
