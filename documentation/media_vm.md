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

`PUID` and `GUID` are set as variables in `roles/media_vm/defaults/main.yml` and must match the user id in TrueNAS of a
user that has access to the relevant datasets.

## Music Acquisition Stack (Lidarr + slskd + Soularr)

### Overview

Lidarr manages wanted albums, slskd is a self-hosted Soulseek P2P client, and
Soularr bridges the two by polling Lidarr's wanted list and downloading via slskd. Downloaded music lands on NFS at
`/mnt/nfs/music` where Navidrome (on the music LXC) already reads from.

### Architecture

```
Lidarr (:8686)          Soularr (daemon)         slskd (:5030, :50300)
   │                       │                        │
   │  wanted albums        │  polls every 5min      │  Soulseek P2P (:50300)
   │◄──────────────────────│───────────────────────►│────────────────────────► peers
   │                       │                        │
   │  imports completed    │                        │  downloads to
   │  downloads to /music  │                        │  /downloads/slskd
   │                       │                        │
   ▼                       ▼                        ▼
/mnt/nfs/music         /mnt/nfs/downloads/slskd
(NFS from TrueNAS)     (NFS from TrueNAS)
       │
       ▼
   Navidrome (music_lxc, 192.168.2.109:4533)
```

### Ports

```
+-------+-----------+-------------------------------------------+
| Port  | Service   | Notes                                     |
+-------+-----------+-------------------------------------------+
| 8686  | Lidarr    | Web UI (direct, not behind VPN)            |
| 5030  | slskd     | Web UI (direct, own network)               |
| 50300 | slskd     | Soulseek P2P (direct, own network)         |
+-------+-----------+-------------------------------------------+
```

Soularr has no ports — it is a headless daemon that polls on a 300-second interval.

### Volume mapping

```
+-----------------------------+----------------+---------+--------+
| Host path                   | Container path | Service | Access |
+-----------------------------+----------------+---------+--------+
| /srv/media/config/lidarr    | /config        | lidarr  | rw     |
| /srv/media/config/slskd     | /app           | slskd   | rw     |
| /srv/media/config/soularr   | /data          | soularr | rw     |
| /mnt/nfs/music              | /music         | lidarr  | rw     |
| /mnt/nfs/music              | /music         | slskd   | ro     |
| /mnt/nfs/downloads          | /downloads     | lidarr  | rw     |
| /mnt/nfs/downloads/slskd    | /downloads     | slskd   | rw     |
| /mnt/nfs/downloads/slskd    | /downloads     | soularr | rw     |
+-----------------------------+----------------+---------+--------+
```

### Usage

#### Adding music via Lidarr (automated)

1. Open Lidarr at http://192.168.2.105:8686
2. Go to Artists > Add New, search for an artist, and add them with root folder `/music`
3. Lidarr fetches the artist's discography from MusicBrainz and marks albums as "wanted"
4. Soularr picks up wanted albums on its next poll cycle (every 5 minutes)
5. Soularr searches Soulseek via slskd for matching releases
6. If found, slskd downloads the files to `/mnt/nfs/downloads/slskd`
7. Soularr notifies Lidarr when the download completes
8. Lidarr imports, renames, and moves the files to `/mnt/nfs/music/Artist/Album/`
9. Navidrome picks up the new files on its next hourly scan

#### Monitoring downloads

- **Soularr logs**: `ssh media "docker logs soularr --tail 30 -f"` — shows polling, search results, and failures
- **slskd WebUI**: http://192.168.2.105:5030 — Transfers tab shows active/completed downloads
- **Lidarr WebUI**: http://192.168.2.105:8686 — Activity tab shows import queue

#### slskd WebUI

- **Search**: manually search Soulseek for files (separate from Soularr's automated searches)
- **Transfers**: monitor uploads and downloads
- **Users**: shows peers you've interacted with (empty until first download)
- **Settings**: edit YAML config live (remote configuration is enabled)

Default WebUI credentials are in the vault (`vault_slskd_web_username` / `vault_slskd_web_password`).

#### Why searches fail

Soularr search failures are common and usually not a problem — it retries on the next cycle. Common reasons:
- **New account**: Soulseek peers may ignore users sharing 0 files. As your library grows, results improve.
- **Niche music**: not everything is on Soulseek. Soularr keeps retrying wanted albums indefinitely.
- **409 Conflict**: slskd is not connected to the Soulseek network — check if VPN integration is stuck (see troubleshooting below).

### Network routing

- slskd runs on the default Docker compose network (not behind VPN) — this allows Soulseek peers to connect directly on port 50300 for uploads
- Soularr reaches slskd at `http://slskd:5030` (both on the default compose network)
- Soularr reaches Lidarr at `http://lidarr:8686` (also on the default compose network)
- slskd exposes its own WebUI (:5030) and Soulseek P2P (:50300) ports directly
- Previously slskd was behind gluetun/Mullvad VPN, but Mullvad removed port forwarding support (July 2023), making uploads impossible — peers could not connect to port 50300 through the VPN

### Configuration files

- **slskd**: `roles/media_vm/templates/slskd/slskd.yml.j2` — Ansible-managed, deployed on every run
  - Soulseek credentials: `vault_slskd_soulseek_username`, `vault_slskd_soulseek_password`
  - WebUI credentials: `vault_slskd_web_username`, `vault_slskd_web_password`
  - API key (for Soularr): `vault_slskd_api_key`
  - VPN integration: **disabled** — slskd is not behind a VPN
- **Soularr**: `roles/media_vm/templates/soularr/config.ini.j2` — Ansible-managed, deployed on every run
  - Lidarr API key: `vault_lidarr_api_key`
  - slskd API key: `vault_slskd_api_key`

### Vault variables

```
vault_slskd_soulseek_username   # Soulseek network username
vault_slskd_soulseek_password   # Soulseek network password
vault_slskd_web_username        # slskd WebUI login
vault_slskd_web_password        # slskd WebUI password
vault_slskd_api_key             # slskd API key (used by Soularr)
vault_lidarr_api_key            # Lidarr API key (used by Soularr)
```

### Deployment

```bash
make media              # Full media VM deployment
make media t=docker     # Docker stack only
make media t=slskd      # slskd config only
make media t=soularr    # Soularr config only
```

### Sleep hours

All three containers (`lidarr`, `slskd`, `soularr`) are in `sleep_hours_stop_containers` and will be stopped
during quiet hours to allow HDD spindown.

### Troubleshooting

#### slskd shows "disconnected"
- Check Soulseek credentials in vault — the username may already be taken on the network
- Check logs: `ssh media "docker logs slskd --tail 20"`
- Look for `INVALIDPASS` — means username exists but password doesn't match

#### slskd not uploading / peers can't download
- slskd must expose port 50300 directly (not behind VPN) so Soulseek peers can connect
- Verify port is reachable: check `docker port slskd` shows 50300
- If slskd was moved back behind gluetun, uploads will break — Mullvad has no port forwarding

#### Soularr can't resolve hostnames
- Startup race condition — usually resolves on next poll cycle (5 minutes)
- Check: `ssh media "docker logs soularr --tail 30"`

#### Soularr "Unauthorized" errors
- Lidarr API key mismatch — grab key from Lidarr Settings > General, update vault
- Redeploy: `make media t=soularr && ssh media "docker restart soularr"`

#### Verify VPN is working
```bash
ssh media "docker exec gluetun wget -qO- https://ifconfig.me"
```
Should show a Mullvad IP, not your home IP.

#### Lidarr can't write to /music
- Check NFS mount: `ssh media "mount | grep music"`
- If not mounted, run: `make media t=nfs`
- Verify write access: `ssh media "docker exec lidarr sh -c 'touch /music/.test && rm /music/.test && echo ok'"`
