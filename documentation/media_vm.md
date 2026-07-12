## Mullvad VPN

The account number is in 1Password.

## qBittorrent

### Logging in

Auth will work as long as you dont change the password or user. User should be `admin`. The template config file contains
the correct hash for the current password. The template config file is a copy of a working config file.

If auth breaks, you can `ssh` into the media vm and `docker compose logs qbittorrent`. The logs will contain the
temporary password.

### SMB shares

The media files are stored on disks attached to the NAS not on the media VM. They are mounted to the media VM using smb
shares. For this to work the permissions on the media VM have to match the permissions on TrueNAS for the relevant
datasets.

`puid` and `guid` are set as variables in `group_vars/all/main.yml` (both `1001`) and must match the user id in TrueNAS
of a user that has access to the relevant datasets.

## Music Acquisition — slskd (Standalone)

### Overview

slskd is a self-hosted Soulseek P2P client used standalone for manual music discovery and downloading.
Downloads are reviewed in the slskd WebUI, then manually moved to `/mnt/nfs/music/slskd/Artist/Album/`
where Navidrome picks them up as a dedicated library.

**History**: Previously used an automated Lidarr + Soularr + slskd pipeline. Lidarr and Soularr were
disabled (2026-03-27) because Lidarr's metadata matching was rejecting valid downloads, causing repeated
downloads and wasted bandwidth. Both services have since been removed from `docker-compose.yml.j2`
entirely (their version vars and the Soularr config template remain — see "Disabled services" below).

### Architecture

```
slskd (:5030 WebUI, :50300 P2P)
   │
   │  manual search & download
   │
   ▼
/mnt/nfs/downloads/slskd          (staging — temporary)
   │
   │  review & move approved albums
   │
   ▼
/mnt/nfs/music/slskd/Artist/Album/  (final — Navidrome library)
   │
   ▼
Navidrome (music_lxc, 192.168.2.109:4533, scans hourly)
```

### Ports

```
+-------+-----------+-------------------------------------------+
| Port  | Service   | Notes                                     |
+-------+-----------+-------------------------------------------+
| 5030  | slskd     | Web UI (direct, own network)               |
| 50300 | slskd     | Soulseek P2P (direct, own network)         |
+-------+-----------+-------------------------------------------+
```

### Volume mapping

```
+-----------------------------+----------------+---------+--------+
| Host path                   | Container path | Service | Access |
+-----------------------------+----------------+---------+--------+
| /srv/media/config/slskd     | /app           | slskd   | rw     |
| /mnt/nfs/downloads/slskd    | /downloads     | slskd   | rw     |
| /mnt/nfs/music/slskd        | /music         | slskd   | ro     |
+-----------------------------+----------------+---------+--------+
```

- `/downloads` — where slskd saves downloaded files (staging area)
- `/music` — shared with other Soulseek peers for uploads (read-only)

### Usage

#### Downloading music

1. Open slskd WebUI at http://192.168.2.105:5030
2. Search for an artist or album
3. Browse results, select a release, and download it
4. Monitor progress in the Transfers tab
5. Once complete, review the files in `/mnt/nfs/downloads/slskd/`
6. Move approved albums to `/mnt/nfs/music/slskd/Artist/Album/`
7. Navidrome picks up the new files on its next hourly scan

#### Uploading music

slskd shares everything in `/music` (maps to `/mnt/nfs/music/slskd`) with other Soulseek peers.
After moving albums to the music directory, rescan shares in the WebUI (Options > Rescan Shares)
so they become visible to other users.

#### slskd WebUI

- **Search**: search Soulseek for files
- **Transfers**: monitor uploads and downloads
- **Browse**: browse shared files (yours and peers')
- **Users**: shows peers you've interacted with
- **Options > Shares**: manage shared directories, rescan files

Default WebUI credentials are in the vault (`vault_slskd_web_username` / `vault_slskd_web_password`).

### Network routing

- slskd runs on the default Docker compose network (not behind VPN) — this allows Soulseek peers to connect directly on port 50300 for uploads
- slskd exposes its own WebUI (:5030) and Soulseek P2P (:50300) ports directly
- Previously slskd was behind gluetun/Mullvad VPN, but Mullvad removed port forwarding support (July 2023), making uploads impossible — peers could not connect to port 50300 through the VPN

### Configuration files

- **slskd**: `roles/media_vm/templates/slskd/slskd.yml.j2` — Ansible-managed, deployed on every run
  - Soulseek credentials: `vault_slskd_soulseek_username`, `vault_slskd_soulseek_password`
  - WebUI credentials: `vault_slskd_web_username`, `vault_slskd_web_password`
  - API key: `vault_slskd_api_key`
  - VPN integration: **disabled** — slskd is not behind a VPN
  - Shares: only `/music` is shared (not `/downloads`)

### Vault variables

```
vault_slskd_soulseek_username   # Soulseek network username
vault_slskd_soulseek_password   # Soulseek network password
vault_slskd_web_username        # slskd WebUI login
vault_slskd_web_password        # slskd WebUI password
vault_slskd_api_key             # slskd API key
```

### Deployment

```bash
make media              # Full media VM deployment
make media t=docker     # Docker stack only
make media t=slskd      # slskd config only
```

### Nuking and recreating slskd

To start fresh (clears database, search history, transfer history):

```bash
ssh media-vm
cd /srv/media
docker compose stop slskd
docker compose rm slskd
rm -rf /srv/media/config/slskd/*
make media t=slskd      # re-templates config from Ansible
docker compose up -d slskd
```

Optionally clear old downloads: `rm -rf /mnt/nfs/downloads/slskd/*`

### Sleep hours

`slskd` is in `sleep_hours_stop_containers` and will be stopped during quiet hours to allow HDD spindown.

### Disabled services (Lidarr + Soularr)

Lidarr and Soularr were removed from `roles/media_vm/templates/docker-compose.yml.j2` — there are
no commented-out blocks left to uncomment. What remains for re-enablement: `lidarr_version` /
`soularr_version` in `roles/media_vm/defaults/main.yml`, the Soularr config template
(`roles/media_vm/templates/soularr/config.ini.j2`), and their vault variables. To re-enable:

1. Re-add `lidarr` and `soularr` service blocks to `roles/media_vm/templates/docker-compose.yml.j2`
   (recover the old blocks from git history)
2. Add `lidarr` and `soularr` back to `sleep_hours_stop_containers` in `host_vars/media-vm.yml`
3. Run `make media`

### Troubleshooting

#### slskd shows "disconnected"
- Check Soulseek credentials in vault — the username may already be taken on the network
- Check logs: `ssh media "docker logs slskd --tail 20"`
- Look for `INVALIDPASS` — means username exists but password doesn't match

#### slskd not uploading / peers can't download
- slskd must expose port 50300 directly (not behind VPN) so Soulseek peers can connect
- Verify port is reachable: check `docker port slskd` shows 50300
- If slskd was moved back behind gluetun, uploads will break — Mullvad has no port forwarding
- Check shares are scanned: WebUI > Options > Shares should show file count > 0
- Rescan shares after adding new files to `/mnt/nfs/music/slskd/`

#### Downloads timing out
- Some peers are offline, firewalled, or have you queued — this is normal on Soulseek
- Try a different source (search again, pick another user with the same album)
- Check slskd logs: `ssh media "docker logs slskd --tail 30"`

#### Verify VPN is working (for other services)
```bash
ssh media "docker exec gluetun wget -qO- https://ifconfig.me"
```
Should show a Mullvad IP, not your home IP.

## BookLore

Book library server (`ghcr.io/booklore-app/booklore` — the project left Docker Hub in
2026, so the old `booklore/booklore` path is dead) with a `booklore-mariadb` sidecar
(`lscr.io/linuxserver/mariadb`, pinned). Both are in the media-vm compose template;
port 6060, data under `/srv/media/config/booklore/` plus the `/mnt/nfs/books` share.
Part of `sleep_hours_stop_containers`.
