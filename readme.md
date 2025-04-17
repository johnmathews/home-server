# Home Server Provisioning with Ansible

This project is about setting up my home server. It contains the commands and
Ansible playbooks used to provision a home server based on Proxmox.

[Proxmox helper scripts](https://community-scripts.github.io/ProxmoxVE/) are
used.

It automates the setup of virtual machines and containers for services like
storage (TrueNAS), media streaming (Jellyfin, Sonarr, Radarr, qBittorrent), home
automation (Home Assistant), network security (Pi-hole), and remote access
(Cloudflare Tunnel).

Proxmox helper scripts are run manually, the configuration options are listed
here.

## Setup

1. Install Proxmox from USB
   1. Remove and reinsert the drive when the installer is searching and not
      finding.
   1. Use the M.2 Drive
   1. Use ZFS (Raid0)
   1. Server name is Proxmox
   1. Management Interface is which Ethernet port its going to use. Different
      ports will give different MAC addresses.
   1. Gateway is the URL of the router.
2. (If reinstalling) Remove old host key from `~/.ssh/known_hosts`

3. Copy public SSH keys to the host:

   ```sh
   ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.2.214
   ```

4. [This might not be necessary] Add `images` to first block in
   `/etc/pve/storage.cfg`, on the Proxmox host:

   ```conf
   dir: local
       path /var/lib/vz
       content iso,vztmpl,backup,images

   lvmthin: local-lvm
       thinpool data
       vgname pve
       content rootdir,images
   ```

5. ~~Manually download and place the TrueNAS ISO in `iso-images/`~~

6. Run
   [proxmox post install](https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install):

   - Correct VE Sources: `Y`
   - Disable PVE enterprise Repo: `Y`
   - Enable PVE no subscription Repo: `Y`
   - Correct Ceph package sources: `Y`
   - Add (disabled) `pvetest` repo: `Y`
   - Disable subscription nag: `Y`
   - Disable high availability: `Y`
   - Update Proxmox VE: `Y`
   - Reboot Proxmox now? : `Y`

7. Run
   [cloudflared LXC script](https://community-scripts.github.io/ProxmoxVE/scripts?id=cloudflared):

   - Advanced Settings:
     - Unprivileged Container
     - Root password: `blank`
     - Container id: `100`
     - Hostname: `cloudflared`
     - Set disksize: `2GB`
     - CPU Cores: `1`
     - Allocate RAM: `512MB`
     - Bridge: `vmbr0`
     - Static IPv4 CIDR Address (/24): `dhcp`
     - APT-cacher IP: `blank`
     - Disable IPv6: `Yes`
     - Interface MTU Size: `blank`
     - DNS search domain: `blank`
     - DNS server IP: `blank` but if you know the Pi-hole IP you could add it
       here. Can update later at `/etc/resolv.conf`
     - MAC address: `02:00:00:00:00:01`
     - VLAN: `blank`
     - Tags: `community-script`, `network`, `cloudflare`
     - Verbose mode: `Yes`
     - DNS-over-HTTPS (DoH) Proxy: `No`

8. Run
   [Pi-hole LXC](https://community-scripts.github.io/ProxmoxVE/scripts?id=pihole):

   - Advanced Settings:
     - Unprivileged Container
     - Root password: `blank`
     - Container ID: `101`
     - Hostname: `pihole`
     - Disk size: `2GB`
     - CPU cores: `1`
     - RAM: `512MB`
     - Bridge: `vmbr0`
     - Static IPv4 CIDR Address: `dhcp`
     - APT-cacher IP: `blank`
     - Disable IPv6: `Yes`
     - Interface MTU Size: `blank`
     - DNS Search Domain: `blank`
     - DNS Server IP: `1.1.1.1`
     - MAC Address: `02:00:00:00:00:02`
     - VLAN: `blank`
     - Tags: `community-script`, `adblock`
     - Verbose Mode: `Yes`
     - Add unbound: `Yes`
     - Should Unbound be in Forwarding Mode or Recursive Mode: `Recursive`

9. Run
   [Home Assistant VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=haos-vm):

   - Advanced Settings:
     - Version: `stable`
     - Virtual Machine ID: `102`
     - Machine Type: `q35`
     - Disk Cache: `Write Through`
     - Host Name: `home-assistant`
     - CPU Model: `host`
     - CPU Cores: `2`
     - RAM: `4096MB`
     - Bridge: `vmbr0`
     - MAC Address: `02:00:00:00:00:03`
     - VLAN: `blank`
     - MTU Size: `blank`

10. Run
    [Ubuntu 22.04 VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=ubuntu2204-vm).
    This will be the VM to run data engineering projects on:

    - Advanced Settings:
      - VMID: `103`
      - Machine Type: `q35`
      - Disk Size: `120GB`
      - Disk Cache: `0 None`
      - Host Name: `Ubuntu`
      - CPU Model: `Host`
      - CPU Cores: `6`
      - RAM: `8192MB`
      - Bridge: `vmbr0`
      - MAC Address: `02:00:00:00:00:04`
      - VLAN: `blank`
      - MTU Size: `blank`

    Setup Cloud-Init before starting. Set:

    - User (as root)
    - Password
    - SSH Public Key

    More info at https://github.com/community-scripts/ProxmoxVE/discussions/272
    about resizing disks, getting SSH to work, installing Docker, etc.

1. Then, Do TrueNAS scale and then do Media VM

1. TrueNAS SCALE:
    - Provision VM
    -
2. Media VM

## Ansible Steps

```sh
# Clone the repo and enter it
git clone git@github.com:yourname/home-server.git
cd home-server

# Create and activate the virtual environment (using uv)
uv venv
source .venv/bin/activate

# Install Python + Ansible dependencies
uv pip install -r requirements.txt
ansible-galaxy install -r requirements.yml

# Run lint and dry-run to validate everything
make ci

# Provision everything (safe to rerun)
make site
```

## 🛠 Tooling

- Provisioning is driven by `ansible-playbook` and structured with a Makefile
- Project structure is modular and separated by playbooks per service
- Linting and CI-style checks are included for reliability

### Makefile Targets

```sh
make site               # Run full home server provisioning
make media              # Provision and configure Media VM
make media_provision    # Only provision Media VM (no Docker)
make media_configure    # Configure services inside Media VM
make cloudflared        # Setup Cloudflare Tunnel LXC
make proxmox            # Configure base Proxmox OS setup
make truenas            # Create TrueNAS VM
make cloud_image        # Upload Ubuntu cloud-init image
make check              # Dry-run of full site.yml
make lint               # Lint all playbooks and roles
make ci                 # Run lint + check for validation
make clean              # Remove retry/log files
```

---

## Manual steps instead of running `make site`

-

## 🧭 VM & Container Provisioning Workflow

1. **Base Proxmox Setup**  
   Configure SSH, ZRAM, Postfix, disable enterprise repo

2. **Image Preparation**  
   Upload Ubuntu cloud image using `upload_cloud_image` role

3. **VMs**

   - `media_vm`: Ubuntu server w/ cloud-init, Docker + media stack
   - `truenas_vm`: TrueNAS VM with raw disk passthrough

4. **LXC Containers**

   - `cloudflared_lxc`: Cloudflare Tunnel container (LXC)
   - Pi-hole: Unprivileged LXC (not yet implemented)

5. **Service Configuration**

   - Docker stack in `media_vm`: Jellyfin, Sonarr, Radarr, qBittorrent
   - Home Assistant (planned): HAOS image with USB passthrough

6. **Storage**

   - TrueNAS manages ZFS pools (mirrored vdevs)
   - Snapshots & replication to backup drives

7. **Backups**
   - Optional PBS VM
   - Proxmox + TrueNAS-based snapshot + dedup backups

---

## 🎯 Objectives, Priorities & Tradeoffs

### Main Goals

- Reliable and extensible home server
- Power-efficient (20% draw at idle)
- VM + container support
- Repeatable provisioning with Ansible

### Priorities

- Flexibility: Modular VMs & services
- Simplicity: Separation of concerns
- Efficiency: Low idle power draw
- Storage resilience: ZFS + snapshots

### Tradeoffs

- No GPU (initially) → CPU transcoding
- TrueNAS runs in VM, not bare metal
- Editing via Wi-Fi limits throughput
- External access via Cloudflare Tunnel (not NGINX)

---

## Current Status

| Task                                | Status      |
| ----------------------------------- | ----------- |
| Proxmox base setup                  | Done        |
| Upload cloud image role             | Done        |
| Media VM provisioning via Ansible   | Done        |
| TrueNAS VM created                  | Done        |
| Services installed via Docker stack | In progress |
| Pi-hole container setup             | Pending     |
| Cloudflare Tunnel container         | In progress |
| Backup strategy implemented         | Pending     |

---

## 🌐 Networking Overview

| Device             | Interface | Speed            |
| ------------------ | --------- | ---------------- |
| Home Server        | Ethernet  | 1 Gbps           |
| MacBook Pro M2 Max | Wi-Fi     | ~120–140 Mbps    |
| ISP Connection     | Fiber     | 100 Mbps up/down |

- Server is wired to home router
- Clients (MacBook, phones) access via Wi-Fi
- Cloudflare Tunnel for remote access without port forwarding

---

## 🗂 Project Structure

```
.
├── ansible.cfg
├── makefile
├── inventory.ini
├── requirements.txt
├── requirements.yml
├── group_vars/
│   └── all/
│       ├── main.yml
│       └── vault.yml
├── host_vars/
│   ├── pve.yml
│   ├── media-vm.yml
│   └── cloudflared.yml
├── playbooks/
│   ├── site.yml            # Master playbook
│   ├── proxmox.yml
│   ├── media_vm.yml
│   ├── cloudflared.yml
│   ├── truenas.yml
│   └── cloud_image.yml
└── roles/
    ├── common/
    ├── media_vm/
    │   ├── tasks/{main,provision,configure}.yml
    │   ├── templates/env.j2
    │   └── files/docker-compose.yml
    ├── cloudflared_lxc/
    │   ├── tasks/{main,provision,configure}.yml
    │   └── templates/config.yml.j2
    ├── truenas_vm/
    ├── upload_cloud_image/
    ├── upload_iso/
    ├── postfix/
    ├── pve-repos/
    └── zram/
```

---
