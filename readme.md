# Home Server Provisioning with Ansible

1. [iGPU setup](#igpu-setup)
   - [The solution:](#the-solution:)
2. [Setup](#setup)
3. [Proxmox Backup Server (PBS)](<#proxmox-backup-server-(pbs)>)
4. [Ansible Steps](#ansible-steps)
5. [Colors and themes](#colors-and-themes)
6. [Tuning and maintenance:](#tuning-and-maintenance:)
   - [Makefile Targets](#makefile-targets)

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

The motherboard uses the Redfish API. You can use it to change fan profiles, but
not to set fan RPM directly. Probably best to attach the fans to an ESP32 board
that has temperature probes, and make it log metrics via Home Assistant.

## iGPU setup

In BIOS, go Advanced > NBIO Common Options >

- IOMMU: enabled
- PCIe ARI Support: enabled
- PCIe ARI Enumeration: enabled
- GFX Configuration: UMA specified
- UMA frame buffer size: 2Gj
- GPU Host translation cache: Auto Advanced > PCI subsystem settings >
- Above 4G decoding: enabled
- Re-size BAR support: disabled

This doesn't work because I cant extract the ROM file from the iGPU in Proxmox
and then load it in the VM. A different OS image might have it already. This is
the only blocker - I can set passthrough and assign it to the VM. but the VM
cannot bind the iGPU to a driver, i think. Therefore, for now, run jellyfin in
docker in Proxmox itself.

You can run `lspci -k -nn -d 1002:` in proxmox to see that the iGPU is
recognised and a driver is attached to it.

## Setup

1.  Install Proxmox from USB

    1. Remove and reinsert the drive after the installer starts. It will say its
       looking for something.
    1. Install operating systems on the M.2 Drive.
    1. Use ZFS (Raid0).
    1. Server name is Proxmox.
    1. Management Interface is which Ethernet port its going to use. Different
       ports will give different MAC addresses.
    1. Gateway is the URL of the router.
    1. Go to [login page](https://192.168.2.214:8006)

2.  (If reinstalling) Remove old host key from `~/.ssh/known_hosts`

3.  Copy public SSH keys to the host:

    ```sh
    ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.2.214
    ```

4.  Run
    [proxmox post install](https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install)
    script:

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

5.  Run
    [cloudflared LXC](https://community-scripts.github.io/ProxmoxVE/scripts?id=cloudflared)
    script:

    Containers reserved IP: `192.168.2.100`

        Advanced Settings:
         Unprivileged Container
         Root password: `blank`
         Container id: `100`
         Hostname: `cloudflared`
         Disksize: `2GB`
         CPU Cores: `1`
         RAM: `512MB`
         Bridge: `vmbr0`
         Static IPv4 CIDR Address (/24): `dhcp`
         APT-cacher IP: `blank`
         Disable IPv6: `Yes`
         Interface MTU Size: `blank`
         DNS search domain: `blank`
         DNS server IP: `blank` but if you know the Pi-hole IP you could add it
         here. Can update later at `/etc/resolv.conf`
         MAC address: `02:00:00:00:01:00`
         VLAN: `blank`
         Tags: `community-script`, `network`, `cloudflare`
         Verbose mode: `Yes`
         DNS-over-HTTPS (DoH) Proxy: `No`

    - Set ZFS reserved space and volsize (maximum possible size):
      - `zfs set refreservation=XXG rpool/data/vm-XXX-disk-1`
      - `zfs set volsize=XXG rpool/data/vm-XXX-disk-1`

6.  Run
    [Pi-hole LXC](https://community-scripts.github.io/ProxmoxVE/scripts?id=pihole)
    script:

    Reserved IP: `192.168.2.101`

    [Local Login](http://192.168.2.101/admin/)

        Advanced Settings:
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

    - Set ZFS reserved space and volsize (maximum possible size): -
      `zfs set refreservation=XXG rpool/data/vm-XXX-disk-1` -
      `zfs set volsize=XXG rpool/data/vm-XXX-disk-1` Set the Pi-holes DNS
      Settings to use Unbound only:
      - Settings > DNS > Upstream DNS Servers
      - Uncheck all options except
      - Custom DNS servers: `127.0.0.1#5335` After setup, set your router to
        resolve DNS using the Pi-hole IP.

7.  Run
    [adguard][https://community-scripts.github.io/ProxmoxVE/scripts?id=adguard]
    maybe.

    Settings are generally the same as for pihole..

8.  Run
    [Home Assistant VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=haos-vm)
    script:

    Reserved IP: `192.168.2.102`

    [Local Login](http://192.168.2.102:8123/onboarding.html)

        Advanced Settings:
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

    - Set ZFS reserved space and volsize (maximum possible size):
      - `zfs set refreservation=XXG rpool/data/vm-XXX-disk-1`
      - `zfs set volsize=XXG rpool/data/vm-XXX-disk-1`

9.  Setup `Project VM` using
    [Ubuntu VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=ubuntu2204-vm)
    script. This will be the VM to run data engineering projects:

    Reserved IP: `192.168.2.103`

        Advanced Settings:
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
    - Set ZFS reserved space and volsize (maximum possible size):
      - `zfs set refreservation=120G rpool/data/vm-XXX-disk-1`
      - `zfs set volsize=120G rpool/data/vm-XXX-disk-1`

    More info at https://github.com/community-scripts/ProxmoxVE/discussions/272
    about resizing disks, getting SSH to work, installing Docker, etc.

10. Provision TrueNAS SCALE VM:

    Reserved IP: `192.168.2.104`

    [Local Login](http://192.168.2.104/ui/sessions/signin)

    - You need to manually download the ISO file and place it in the correct
      directory. TrueNAS require an email address.
    - Run `make TrueNAS`. This runs an Ansible play
    - In Proxmox, start the new TrueNAS VM and install the OS.

    - Set zfs reserved space and volsize (maximum possible size):
      - `zfs set refreservation=128G rpool/data/vm-XXX-disk-1`
      - `zfs set volsize=128G rpool/data/vm-XXX-disk-1`

11. Provision the Media VM using
    [Ubuntu 22.04 VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=ubuntu2204-vm)
    script. This VM will host the media apps running in docker containers.

    Reserved IP: `192.168.2.105`

    For `qBittorrent` the username and password doesnt work. Before you login,
    ssh into the VM and run `docker logs qbittorrent`. Here you will see a
    temporary username and password you can use to login to the web UI and
    create a username and password.

    For `homarr` to use the Proxmox integration, you need to create an API user
    and then enter the secret in the format `api@pve!<group>=<secret>`. You cant
    just enter the secret. Follow homarr documentation about how to create the
    Proxmox user, group and api token.

    Local logins:

    - [Sonarr](http://192.168.2.105:8989/)
    - [Radarr](http://192.168.2.105:7878/)
    - [File Browser](http://192.168.2.105:8081/login?redirect=/files/)
    - [JellyFin](http://192.168.2.105:8096/web/#/wizardstart.html)
    - [qBitTorrent](http://192.168.2.105:8080/)
    - [Bazarr](http://192.168.2.105:8080/)
    - [Jackett](http://192.168.2.105:9117/)

      Advanced Settings:

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

    - Make sure that in cloud-init the `IP config` isn't blank:
      - IPv4: `DHCP`
    - In Proxmox > 105 (media) > Cloud-Init and set User, Password, SSH public
      key etc.
    - Set ZFS reserved space and volsize (maximum possible size):
      - `zfs set refreservation=32G rpool/data/vm-105-disk-1`
      - `zfs set volsize=32G rpool/data/vm-105-disk-1`
    - Update reserved IP on router if necessary and use correct IP address in
      next Ansible configuration step.

12. Media VM setup - run `make media`.

**You will need to set up TrueNAS before running this playbook.** This is
because media_vm needs to mount some datasets as SMB shares, and the SMB shares
must exist in order to be able to connect to them

Infra VM - Setup using
[Ubuntu 22.04 VM](https://community-scripts.github.io/ProxmoxVE/scripts?id=ubuntu2204-vm)
script. This VM will host the monitoring and dashboard applications.

    Reserved IP: `192.168.2.105`

        Advanced Settings:
         VMID: `106`
         Machine Type: `q35`
         Disk Size: `16GB`
         Disk Cache: `0 None`
         Host Name: `infra`
         CPU Model: `Host`
         CPU Cores: `2`
         RAM: `2048MB`
         Bridge: `vmbr0`
         MAC Address: `02:00:00:00:01:06`
         VLAN: `blank`
         MTU Size: `blank`
         Storage Pool: `local-zfs`

    - Make sure that in cloud-init the `IP config` isn't blank:
      - IPv4: `DHCP`
    - In Proxmox > 106 (infra) > Cloud-Init and set User, Password, SSH public
      key etc.
    - Set ZFS reserved space and volsize (maximum possible size):
      - `zfs set refreservation=16G rpool/data/vm-106-disk-1`
      - `zfs set volsize=16G rpool/data/vm-106-disk-1`
    - Update reserved IP on router if necessary and use the correct IP address
      in Ansible configuration step.

14. Infra VM configuration - run `make infra`.

15. Add
    [File Browser](https://community-scripts.github.io/ProxmoxVE/scripts?id=filebrowser)
    to PVE host.

## Proxmox Backup Server (PBS)

1.  Run the
    [helper script](https://community-scripts.github.io/ProxmoxVE/scripts?id=proxmox-backup-server)
    to set it up.

         Advanced Settings:
          Priviliged Container: Y
          VMID: `200`
          Hostname: `proxmox-backup-server`
          Disk Size: `10GB`
          CPU Cores: `2`
          RAM: `2048MB`
          Bridge: `vmbr0`
          Static IPv4 CIDR Address: `dhcp`
          APT-cacher IP: `blank`
          Disable IPv6: `Yes`
          Interface MTU Size: `blank`
          DNS search domain: `blank`
          DNS server IP: `blank`
          MAC Address: `02:00:00:00:02:00`
          VLAN: `blank`
          Custom Tags: `community-script;backup`
          Enable Root SSH Access: `Yes`
          SSH Authorized Key for Root: ...
          Enable verbose mode: `Yes` (this only refers to the verbosity of the install script)

2.  Then run the post install
    [helper script](https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pbs-install)
    to set up an LXC.

    - Run it from a shell on the PBS LXC.
    - Answer `yes` to just about everything, like when you installed Proxmox.
    - Then assign it a static IP address and connect on port 8007.
    - Then reboot.

3.  Notes on the setup of the backup jobs:

    The server is backed up to a `pbs` data store. `proxmox ui` > `datacenter` >
    `storage` > `pbs`

    In `proxmox UI > datacenter > backup` you see the scheduled job that backs
    up all VMs and LXCs to the pbs data store.

    In `proxmox backup server UI > datastore > backups > content` you see what
    has been backed up.

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

## Colors and themes

From [PVEThemes](https://github.com/Happyrobot33/PVEThemes) repo: -
`git clone https://github.com/Happyrobot33/PVEThemes && cd PVEThemes && chmod +x install.sh && ./install.sh`

## Tuning and maintenance:

Reduce power consumption. Save money...

1. Run `powertop --calibrate`. This will take up to 20 minutes and after you can
   run `powertop --auto-tune`. Then look in the `tunables` section and change
   anything that is `bad` to `good`.

2. Run `cat /sys/module/pcie_aspm/parameters/policy` and you should see:
   `[default] performance powersave powersupersave`. Run
   `echo powersave > /sys/module/pcie_aspm/parameters/policy` and then PCIe
   devices will use less power when they're not in use.

3. To upgrade the OS, run `do-release-upgrade` from the console, not over SSH.

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
