# Fix infra-vm compose deploy: zombie containers + wrong converge state

## Problem

`make infra tags=docker` failed with:

```
Error response from daemon: Cannot restart container ...:
Bind for 0.0.0.0:3001 failed: port is already allocated
```

Root cause: a previous `recreate: always` run had been interrupted partway
through, leaving Docker in a half-converged state. Compose had renamed each old
container with a 12-char hex prefix (e.g. `956930400e05_uptime-kuma`) intending
to remove them after the new ones came up, but never finished the cleanup. The
result was duplicate container pairs for ~13 services — one running, one stuck
in `Created` — both claiming the same host port.

The deploy task was running `docker compose restart`, which just tries to start
every container the project knows about. With duplicates present, both copies
fight for the port and the new one fails.

## Why `state: restarted` was wrong

The "Launch containers" task (`roles/infra_vm/tasks/main.yml:206`) used
`state: restarted` + `recreate: always`. That maps to `docker compose restart`,
which only stops/starts existing containers in place. It does **not**:

- Remove orphan containers
- Recreate containers when image, env vars, ports, mounts, or labels changed
- Clean up zombies left by an interrupted prior run
- Pick up newly pulled images

Container config is immutable after creation, so a restart silently keeps the
old config even after the compose file has been edited — silent drift between
what the template says and what's running. The right pattern for a "converge
the stack to desired state" task is `state: present` + `recreate: auto`, which
diffs each container's `com.docker.compose.config-hash` label against the
rendered file and recreates only the services that actually changed.

## Changes

1. `roles/infra_vm/tasks/main.yml:206` — "Launch containers" task switched to
   `state: present` + `recreate: auto`. Top-level converge task should let
   compose decide what to recreate based on the config-hash diff.
2. `roles/infra_vm/handlers/main.yml` — "Update docker compose stack" handler
   softened from `recreate: always` to `recreate: auto`. Per-service handlers
   (`Restart grafana`, `Restart loki`, etc.) kept at `recreate: always` because
   they're scoped to a service whose config is known to have just changed.
3. `documentation/infra_vm.md` — added Troubleshooting entry for the
   `port is already allocated` zombie-container error with the cleanup
   one-liner, plus a new "Deploy Model" section explaining the converge
   semantics.
4. `documentation/adding-a-new-service.md` — fixed the handler template that
   was teaching new services the same `state: restarted` bug; added a callout
   explicitly warning against it.

## Cleanup one-liner

To remove the zombie containers on infra-vm before the next deploy:

```sh
ssh infra-vm "docker ps -a --filter label=com.docker.compose.project=infra \
  --format '{{.Names}}' | grep -E '^[0-9a-f]{12}_' | xargs -r docker rm -f"
```

## Audit of other roles

Checked every `docker_compose_v2` invocation across all roles. Only `infra_vm`
had a top-level "converge the whole stack" task that used `state: restarted`.
Other docker stacks (media_vm, immich_lxc, paperless_lxc, jellyfin_lxc, pve)
rely on the **notify→handler** pattern: config-rendering tasks notify a
handler, the handler runs `state: present` + `recreate: always` for the
affected service. That's already correct — handlers fire because something
specific changed, so forcing recreate is right. No further fixes needed.
