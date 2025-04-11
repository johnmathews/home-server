# Home Server Provisioning with Ansible

This project contains the Ansible playbooks and roles used to provision a home
server based on Proxmox.

It automates the setup of virtual machines and containers for services like
storage (TrueNAS), media streaming (Jellyfin, Sonarr, Radarr, qBittorrent), home
automation (Home Assistant), network security (Pi-hole), and remote access
(Cloudflare Tunnel).

## Manual steps

1. Install Proxmox using a USB drive.
1. Id this is a do over, remove the old host key from `~/.ssh/known_hosts` to
   avoid warnings and make ssh in Ansible work.
1. Copy a public key onto the server, otherwise SSH authentication wont work.

   ```sh
   ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.2.214
   ```

1. You need to manually download a TrueNas image and have the ISO locally.
1. You need to update `/etc/pve/storage.cfg` and add `images` to the `local`
   block.

   ```sh
   dir: local
           path /var/lib/vz
           content iso,vztmpl,backup,images

   lvmthin: local-lvm
           thinpool data
           vgname pve
           content rootdir,images
   ```

 Store the credentials etc in 1Password.

### TrueNAS VM

- After Ansible has created the VM and attached the TrueNAS ISO to its CD Drive,
  install TrueNAS yourself.
- Turn it on and click through the install process.
- Remove the CD Drive and reboot
- It gets a new different MAC address each time, update the reserved IP
  address.

## MediaVM

- Add the user and password at the `cloud-init` tab in Proxmox UI.
- Add the public key `~/.ssh/id_ed25519.pub` also.
- Then reboot

## 🛠 Overview of Setup Steps

Provisioning the server is done in distinct, idempotent steps. Each step is
backed by an Ansible role:

1. Initial Proxmox Setup

- Proxmox is installed manually on the NVMe drive. Format the entire NVMe drive
  as ext4.
- SSH enabled, enterprise repo disabled, packages installed
- ZRAM configured, email notifications via Postfix

  Image Preparation

- `upload_cloud_image` downloads and uploads Ubuntu Server cloud image for VM
  creation

3. VM Provisioning

- `media_vm`: creates Ubuntu Server VM (cloud-init), 4 vCPUs, 8GB RAM, 32GB disk
- `truenas_vm`: TrueNAS SCALE VM with raw disk passthrough

4. LXC Container Setup

- Unprivileged LXC for Pi-hole with static IP
- Lightweight LXC for Cloudflare Tunnel

5. Service Configuration

- Media VM: Docker + Docker Compose stack for Jellyfin, Sonarr, Radarr,
  qBittorrent, etc.
- Home Assistant VM: HAOS image, USB pass through for Zigbee

6. Storage Configuration

- TrueNAS manages ZFS pools with mirror vdevs
- Snapshots and replication to 3TB/1TB HDDs

7. Backup & Recovery

- Optional Proxmox Backup Server VM
- PBS deduplication and retention
- Proxmox backup jobs + TrueNAS snapshots

## 🎯 Priorities, Objectives & Tradeoffs

### Main goals:

- A reliable and extensible home server
- Minimal power draw at idle (below 20% load)
- Capable of running VMs, containers, and media services
- Maintainable and repeatable provisioning (via Ansible)

### Priorities:

- Flexibility: Modular VM/container layout, easy to expand
- Simplicity: Clear separation of concerns, avoid over-engineering
- Power efficiency: Idle power draw is more important than peak performance
- Storage resilience: ZFS mirror pools, snapshot-based backups

### Trade-offs:

- No GPU initially: Media server may rely on CPU transcoding
- NAS (TrueNAS) runs in a VM, not bare metal
- Network speed limits off-server editing (e.g., video editing still happens
  locally)
- Services exposed via Cloudflare Tunnel (less control than direct reverse
  proxy)

## ✅ Current Progress

| Task                                | Status         |
| ----------------------------------- | -------------- |
| Proxmox base setup                  | ✅ Done        |
| Upload cloud image role             | ✅ Done        |
| Media VM provisioning via Ansible   | ✅ Done        |
| TrueNAS VM created                  | ✅ Done        |
| Services installed via Docker stack | 🔄 In progress |
| Pi-hole container setup             | 🔲 Pending     |
| Cloudflare Tunnel container         | 🔲 Pending     |
| Backup strategy implemented         | 🔲 Pending     |

---

## 🌐 Networking Overview

| Device             | Interface | Speed            |
| ------------------ | --------- | ---------------- |
| Home Server        | Ethernet  | 1 Gbps           |
| MacBook Pro M2 Max | Wi-Fi     | ~120–140 Mbps    |
| ISP Connection     | Fiber     | 100 Mbps up/down |

## Notes:

- Server is connected via Gigabit Ethernet to home router
- Clients (e.g., MacBook) access server over Wi-Fi, so local transfer speeds are
  capped around 130 Mbps
- Cloudflare Tunnel provides secure remote access without port forwarding
