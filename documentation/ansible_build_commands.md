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
