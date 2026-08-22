**Status:** current — verified 2026-08-22 · covers: makefile
Every target listed here was checked against `makefile` on that date.

A list of make commands with tags to remember how to do all the things:

### Docs and Observability

- `make infra tags=docs`
- `make infra tags=grafana`
- `make infra tags=homepage`

### Setup NFS Shares

- `make site tags=nfs`

### Network Drive Monitoring

Monitor NFS and SMB shares from clients:

- `make site tags=shares`
- `make share_drive_probe`

Each playbook imports several roles. The roles are setup tasks unique the client, a shared role to setup NFS shares, and
a shared role to setup the share drive monitoring probe. In the playbooks, these roles are tagged. See below.

### Key Server

- `make key`
- `make nas tags=key`

### Logs

- `make site tags=alloy`

## Quality checks

`make help` is the source of truth for the full target list — it is generated from
the makefile and cannot drift from it. The five that matter before a commit:

```sh
make lint         # ansible-lint over the WHOLE repo. Exits 2 on any failure.
make check-ports  # render every compose template, fail on a duplicate host port
make check-docs   # parse every doc's **Status:** stamp, fail on a stale or missing one
make test         # pytest + bats (needs docker, bats, jq, curl)
make ci-offline   # all four. No network, no SSH, no vault password.
```

`make check-docs` is the docs half. It parses the stamp rather than grepping for
a label: docs whose `covers:` names repo paths are dated against `git log` of
those paths (change-driven, 14-day grace), and only docs whose `covers:` is
`live` — out-of-repo state git cannot see — get a calendar backstop. The
convention, and the opt-out list at `documentation/.freshness-exempt`, are
described in readme.md under "Documentation freshness stamps".

`.github/workflows/lint.yml` runs on every push and every PR with no `paths:`
filter. It and `make ci-offline` overlap but are not identical, and the
difference matters when a local run is green and CI is not:

```
+------------------------+--------------+---------------+
| Stage                  | ci-offline   | lint.yml      |
+------------------------+--------------+---------------+
| make lint              | yes          | yes           |
| playbook syntax-check  | no           | yes           |
| make check-ports       | yes          | yes           |
| make check-docs        | yes          | yes           |
| pytest tests/          | yes          | yes           |
| bats integration suite | yes          | no (test.yml) |
| sleep_hours gate check | no           | yes           |
+------------------------+--------------+---------------+
```

So a green local `ci-offline` does not by itself promise a green lint job — the
syntax-check and the sleep-hours gate only run on the runner. The bats suite runs
locally and in `test.yml`, which needs a docker daemon.

`make ci` adds `make check` — a `--check` dry run of `site.yml` against the live
fleet — which needs SSH to every production host and the gitignored
`.vault_pass.txt`, so it is operator-only and cannot run on a runner.

`make lint` is **blocking**, not advisory. Because make stops at the first failed
prerequisite, a lint failure aborts `ci`/`ci-offline` before their later stages.

## Useful Commands

Copy the config.alloy file in `tubearchivist_lxc` to replace all other instances of `config.alloy`:

`find . -type f -name "config.alloy" ! -path "./roles/tubearchivist_lxc/templates/config.alloy" -exec cp ./roles/tubearchivist_lxc/templates/config.alloy {} \;`

## Example playbook

```yaml
# playbooks/jellyfin_lxc.yml
---
- name: Jellyfin LXC
  hosts: jellyfin_lxc
  gather_facts: true
  become: true

  roles:
    - role: nfs_client
      tags: nfs
    - role: share_drive_probe
      tags: shares
    - role: jellyfin_lxc
      tags: jelly
    - role: shell_environment
      tags: shell
    - role: tailscale
      tags: tailscale
```

## App upgrade shortcuts

```sh
make jelly-upgrade    # pull newest jellyfin base, rebuild local image, recreate, health-check
make immich-upgrade   # pull newest immich release images, make immich, health-check
```

Needed because compose handlers use `pull: never` — see `upgrade-procedures.md`.

## Check-mode rule for new roles

`make check` passes fleet-wide (fixed 2026-07-13). Keep it that way: a `command`/
`shell` probe is **skipped in check mode**, so any task consuming its register will
see empty/undefined output. When writing a probe→register→consume chain, mark
read-only probes with `check_mode: false` (they then run in dry runs and the facts
stay accurate), and gate consumers of write-command results with
`not ansible_check_mode`. Fixed instances to copy from: tailscale status parse,
nfs_client getent/mountpoint probes, shell_environment nodejs/lazygit.
