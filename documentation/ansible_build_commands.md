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
     tags: [nfs]
   - role: share_drive_probe
     tags: [shares]
   - role: jellyfin_lxc
     tags: [jelly]
```
