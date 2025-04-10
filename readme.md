# Home Server Provisioning with Ansible

This project contains the Ansible playbooks and roles used to provision a home
server based on Proxmox.

It automates the setup of virtual machines and containers for services like
storage (TrueNAS), media streaming (Jellyfin, Sonarr, Radarr, qBittorrent), home
automation (Home Assistant), network security (Pi-hole), and remote access
(Cloudflare Tunnel).

## 🛠 Overview of Setup Steps

Provisioning the server is done in distinct, idempotent steps. Each step is backed by an Ansible role:

1.	Initial Proxmox Setup
   - OS installed manually on NVMe
   - SSH enabled, enterprise repo disabled, packages installed
   - ZRAM configured, email notifications via Postfix

2.	Image Preparation
    - upload_cloud_image downloads and uploads Ubuntu Server cloud image for VM creation

3.	VM Provisioning
•	media_vm: creates Ubuntu Server VM (cloud-init), 4 vCPUs, 8GB RAM, 32GB disk
•	truenas_vm: TrueNAS SCALE VM with raw disk passthrough
4.	LXC Container Setup
•	Unprivileged LXC for Pi-hole with static IP
•	Lightweight LXC for Cloudflare Tunnel
5.	Service Configuration
•	Media VM: Docker + Docker Compose stack for Jellyfin, Sonarr, Radarr, qBittorrent, etc.
•	Home Assistant VM: HAOS image, USB passthrough for Zigbee
6.	Storage Configuration
•	TrueNAS manages ZFS pools with mirror vdevs
•	Snapshots and replication to 3TB/1TB HDDs
7.	Backup & Recovery
•	Optional Proxmox Backup Server VM
•	PBS deduplication and retention
•	Proxmox backup jobs + TrueNAS snapshots

