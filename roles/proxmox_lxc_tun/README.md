# Proxmox LXC TUN Device Role

Configures Proxmox LXC containers to support TUN/TAP devices, which are required for VPN software (Tailscale, WireGuard,
OpenVPN, etc.).

## What This Role Does

Proxmox LXC containers are sandboxed by default and cannot create `/dev/net/tun` devices. This role:

1. Discovers all LXC containers on the Proxmox host
2. Checks which containers need TUN device support
3. Adds device permissions to LXC config files (`/etc/pve/lxc/XXX.conf`)
4. Reboots containers to apply changes (optional)

## Requirements

- Must run on a Proxmox VE host (checks for `/usr/bin/pct`)
- Root privileges (uses `become: true`)

## Role Variables

Available in `defaults/main.yml`:

```yaml
# Enable TUN device support for LXCs
proxmox_lxc_tun_enabled: true

# Automatically reboot LXCs after config changes
proxmox_lxc_tun_auto_reboot: true

# Wait time after rebooting LXCs (seconds)
proxmox_lxc_tun_reboot_wait: 20
```

## What Gets Added to LXC Configs

The role adds these lines to each LXC configuration file:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

- `c 10:200` = Character device, major 10, minor 200 (TUN device)
- `rwm` = Read, Write, Mknod permissions
- The mount entry creates `/dev/net/tun` inside the container

## Usage

### Automatic (Recommended)

The role is included in the `pve.yml` playbook:

```bash
make pve
```

### Manual

```bash
ansible-playbook -i inventory.ini playbooks/pve.yml --tags lxc,vpn
```

### In Other Playbooks

```yaml
- name: Configure Proxmox
  hosts: proxmox
  become: true
  roles:
   - role: proxmox_lxc_tun
```

## Example Output

```
TASK [proxmox_lxc_tun : Display found LXCs]
ok: [pve] => {
    "msg": "Found 12 LXC containers: 100, 101, 103, 108, 110, 113, 115, 116, 117, 119, 120, 200"
}

TASK [proxmox_lxc_tun : Add TUN/TAP device access to LXC containers]
changed: [pve] => (item=100)
changed: [pve] => (item=101)
skipping: [pve] => (item=108)  # Already configured

TASK [proxmox_lxc_tun : Summary]
ok: [pve] => {
    "msg": "LXC TUN device configuration complete!\nTotal LXCs: 12\nUpdated: 10\n"
}
```

## Idempotency

The role is idempotent - safe to run multiple times:

- Only updates LXCs that don't already have TUN device config
- Skips LXCs that are already configured
- Only reboots containers that were modified

## Dependencies

None

## License

MIT

## Author

Created for home-server Proxmox setup
