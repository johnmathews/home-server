# Navidrome — Self-Hosted Music Streaming

## Overview

Navidrome is a self-hosted music server and streamer, compatible with the Subsonic API. Runs as a Docker container inside a dedicated Proxmox LXC, with music files served from TrueNAS via NFS.

## Architecture

```
┌─────────────────────────────────────────────┐
│  music_lxc (192.168.2.109)                  │
│                                             │
│  ┌─────────────┐   ┌──────────────────────┐ │
│  │  Navidrome   │   │  /mnt/nfs/music (RO) │ │
│  │  :4533       │──▶│  NFS from TrueNAS    │ │
│  │  SQLite: /data   │  /mnt/tank/music     │ │
│  └─────────────┘   └──────────────────────┘ │
│                                             │
│  ┌─────────┐  ┌──────────────┐  ┌────────┐ │
│  │  Alloy   │  │ Node Exporter│  │cAdvisor│ │
│  │  :12345  │  │  :9100       │  │ :18080 │ │
│  └─────────┘  └──────────────┘  └────────┘ │
└─────────────────────────────────────────────┘
         │                │             │
         ▼                ▼             ▼
    Loki (infra)    Prometheus     Prometheus
    :3100           :9090          :9090
```

## Network

- **LXC IP**: 192.168.2.109
- **Navidrome web UI**: http://192.168.2.109:4533
- **Access**: LAN + Tailscale only (no Traefik/Cloudflare routing)

## Ports

| Port  | Service       | Purpose                |
|-------|---------------|------------------------|
| 4533  | Navidrome     | Web UI + Subsonic API  |
| 9100  | Node Exporter | Host metrics           |
| 12345 | Alloy         | Log shipping dashboard |
| 18080 | cAdvisor      | Container metrics      |

## NFS Mount

- **Source**: TrueNAS `/mnt/tank/music`
- **Mountpoint**: `/mnt/nfs/music` (via autofs, managed by `nfs_client` role)
- **Docker bind**: `/mnt/nfs/music:/music:ro` (read-only)
- **UID/GID**: 1001:1001 (matches Docker `user:` directive)

The NFS share must be configured on TrueNAS with authorization for `192.168.2.0/24`.

## SQLite Database

Navidrome stores its database (users, playlists, play counts, etc.) in `/srv/apps/navidrome/data` on the **local LXC disk** — NOT on NFS. This is critical: SQLite on NFS causes corruption due to broken file locking.

## Deployment

```bash
# Full deployment
make music

# Specific tags
make music t=music         # Only Navidrome docker stack
make music t=nfs          # Only NFS client setup
make music t=shell        # Only shell environment
```

## First Run

1. Deploy with `make music`
2. Open http://192.168.2.109:4533 in a browser
3. Navidrome presents an admin account creation form on first visit
4. Create the admin user
5. Music library scan starts automatically (hourly schedule via `ND_SCANSCHEDULE=1h`)
6. Trigger a manual scan from Settings > Scan if needed

## Subsonic API Clients

Navidrome is compatible with the Subsonic API. Recommended clients:

### iPhone / iPad
- **play:Sub** — intuitive, automatic caching, CarPlay support
- **flo** — modern SwiftUI client, offline listening, Last.fm scrobbling

### macOS / Desktop
- **Feishin** — modern player with MPV backend, smart playlists, lyrics (macOS/Linux/Windows)
- **Supersonic** — lightweight, gapless playback, equalizer, DLNA casting

Full list of compatible apps: https://www.navidrome.org/apps/

### Client configuration
- **Server URL**: `http://192.168.2.109:4533` (LAN) or Tailscale IP when off-network
- **Username/password**: create accounts in the Navidrome web UI

## Ansible

- **Role**: `roles/music_lxc`
- **Playbook**: `playbooks/music_lxc.yml`
- **Host vars**: `host_vars/music_lxc.yml`
- **Inventory group**: `[music]`
- **Make target**: `make music`

Role chain: `nfs_client` → `share_drive_probe` → `music_lxc` → `shell_environment` → `tailscale`

## Troubleshooting

### Navidrome shows empty library
- Check NFS mount: `ssh music "ls /mnt/nfs/music/"`
- If empty, verify TrueNAS NFS share is configured and the LXC IP is authorized
- Trigger manual scan from Navidrome web UI: Settings > Scan

### Container won't start
- Check Docker status: `ssh music "docker ps -a"`
- Check logs: `ssh music "docker logs navidrome"`

### Health check
```bash
ssh music "docker exec navidrome wget -qO- http://localhost:4533/ping"
```
The `/ping` endpoint returns a simple response and does NOT touch NFS — safe even if the mount is stale. The Docker healthcheck uses `wget` (not `curl`) since the Navidrome image doesn't ship `curl`.

### NFS issues
- Navidrome starts fine even if NFS is unavailable (autofs ghost mount)
- When NFS recovers, the next hourly scan picks up the music files
- SQLite database is on local disk, never affected by NFS issues

### Logs
- Docker logs: `ssh music "docker logs navidrome --tail 50"`
- Alloy ships all container logs to Loki at 192.168.2.106:3100
- Query in Grafana: `{hostname="navidrome", container="navidrome"}`
