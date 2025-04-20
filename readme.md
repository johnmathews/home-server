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

   ```cfg
   dir: local
           path /var/lib/vz
           content iso,vztmpl,backup,images

   zfspool: local-zfs
           pool rpool/data
           sparse
           content images,rootdir

   ```

5. ~~Manually download and place the TrueNAS ISO in `iso-images/`~~

6. Run
   [proxmox post install](https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install):

   Advanced Options: 

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

   Containers reserved IP: `192.168.2.100`

   Advanced Settings:

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
       - here. Can update later at `/etc/resolv.conf`
       - MAC address: `02:00:00:00:01:00`
       - VLAN: `blank`
       - Tags: `community-script`, `network`, `cloudflare`
       - Verbose mode: `Yes`
       - DNS-over-HTTPS (DoH) Proxy: `No`

8. Run
   [Pi-hole LXC](https://community-scripts.github.io/ProxmoxVE/scripts?id=pihole):

   Reserved IP: `192.168.2.101`

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
     - MAC Address: `02:00:00:00:01:01`
     - VLAN: `blank`
     - Tags: `community-script`, `adblock`
     - Verbose Mode: `Yes`
     - Add unbound: `Yes`
     - Should Unbound be in Forwarding Mode or Recursive Mode: `Recursive`

9. Run
   [Home Assistant VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=haos-vm):

   Reserved IP: `192.168.2.102`

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
     - MAC Address: `02:00:00:00:01:02`
     - VLAN: `blank`
     - MTU Size: `blank`
     - Storage pool: `local-zfs` 

10. Setup
    [Project VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=ubuntu2204-vm).
    This will be the VM to run data engineering projects:

    Reserved IP: `192.168.2.103`

    - Advanced Settings:
      - VMID: `103`
      - Machine Type: `q35`
      - Disk Size: `120GB`
      - Disk Cache: `0 None`
      - Host Name: `project`
      - CPU Model: `Host`
      - CPU Cores: `6`
      - RAM: `8192MB`
      - Bridge: `vmbr0`
      - MAC Address: `02:00:00:00:01:03`
      - VLAN: `blank`
      - MTU Size: `blank`
      - Storage pool: `local-zfs` 

    - Setup Cloud-Init and then reboot. Set:
      - User (as root)
      - Password
      - SSH Public Key

    More info at https://github.com/community-scripts/ProxmoxVE/discussions/272
    about resizing disks, getting SSH to work, installing Docker, etc.

11. Provision TrueNAS SCALE VM:

    Reserved IP: `192.168.2.104`

    - Run `make TrueNAS`. This runs an Ansible play
    - Then in Proxmox start the new TrueNAS VM and install the OS.
    - Then cleanup:
      - ssh into proxmox and edit `/etc/pve/qemu-server/104.conf`
      - remove the line starting `ide2` (the size parameter breaks the UI)
      - exit ssh
      - reboot the machine

12. Provision the Media VM
    [Ubuntu 22.04 VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=ubuntu2204-vm).
    This VM will host the media apps running in docker containers.

    Reserved IP: `192.168.2.105`

    - Advanced Settings:
      - VMID: `105`
      - Machine Type: `q35`
      - Disk Size: `32GB`
      - Disk Cache: `0 None`
      - Host Name: `media`
      - CPU Model: `Host`
      - CPU Cores: `4`
      - RAM: `8192MB`
      - Bridge: `vmbr0`
      - MAC Address: `02:00:00:00:01:05`
      - VLAN: `blank`
      - MTU Size: `blank`
      - Storage Pool: `local-zfs` 

    - Make sure that in cloud-init the `IP config` isnt blank:
      - IPv4: `DHCP`
    - In proxmox > 105 (media) > Cloud-Init and set User, Password, SSH public key etc.
    - Update reserved IP on router if necessary and use correct IP address in next Ansible configuration step.

13. Media VM - Setup
   - Run `make media` 

## NEXT STEPS

1. setup pi-hole
1. USB passthrough for zigbee dongle
2. migrate home-assistant
1. setup NAS data...

## Ansible Steps

```sh
# Clone the repo and enter it
git clone git@github.com:yourname/home-server.git
cd home-server

# Create and activate the virtual environment (using uv)
uv venv
source .venv/bin/activate

# Install Python + Ansible dependencies
make requirements

# Run lint and dry-run to validate everything
make ci

# Provision everything (safe to rerun)
make site
```

## 🛠 Tooling

- Provisioning is driven by `ansible-playbook`s and structured with a Makefile.
- Project structure is modular and separated by playbooks per service.
- Linting and CI-style checks are included for reliability.

### Makefile Targets

```sh
make requirements       # Install Ansible requirements
make check              # Dry-run of full site.yml
make site               # Run full home server provisioning
make media              # Provision and configure Media VM
make truenas            # Create TrueNAS VM
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
```

---
