# Home Server Provisioning with Ansible

This project contains the Ansible playbooks and roles used to provision a home
server based on Proxmox.

It automates the setup of virtual machines and containers for services like
storage (TrueNAS), media streaming (Jellyfin, Sonarr, Radarr, qBittorrent), home
automation (Home Assistant), network security (Pi-hole), and remote access
(Cloudflare Tunnel).

## 🚀 Quickstart

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


## ⚙️ Manual steps

1. Install Proxmox from USB
2. (If reinstalling) Remove old host key from `~/.ssh/known_hosts`
3. Copy your public SSH key to the host:

```sh
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.2.214
```

4. Manually download and place the TrueNAS ISO in `iso-images/`
5. Edit `/etc/pve/storage.cfg` on the Proxmox host:

```conf
dir: local
    path /var/lib/vz
    content iso,vztmpl,backup,images

lvmthin: local-lvm
    thinpool data
    vgname pve
    content rootdir,images
```

6. Store credentials and secrets in 1Password (referenced via `vault.yml`)

---

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
- ⚙️ Flexibility: Modular VMs & services
- ✨ Simplicity: Separation of concerns
- 🔋 Efficiency: Low idle power draw
- 💾 Storage resilience: ZFS + snapshots

### Tradeoffs
- No GPU (initially) → CPU transcoding
- TrueNAS runs in VM, not bare metal
- Editing via Wi-Fi limits throughput
- External access via Cloudflare Tunnel (not NGINX)

---

## ✅ Current Status

| Task                                | Status         |
| ----------------------------------- | -------------- |
| Proxmox base setup                  | ✅ Done        |
| Upload cloud image role             | ✅ Done        |
| Media VM provisioning via Ansible   | ✅ Done        |
| TrueNAS VM created                  | ✅ Done        |
| Services installed via Docker stack | 🔄 In progress |
| Pi-hole container setup             | 🔲 Pending     |
| Cloudflare Tunnel container         | 🔄 In progress |
| Backup strategy implemented         | 🔲 Pending     |

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
