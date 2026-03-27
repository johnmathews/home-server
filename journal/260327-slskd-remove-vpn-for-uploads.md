# slskd: Remove VPN routing to fix Soulseek uploads

## Problem

slskd was not uploading any files to the Soulseek network. Other peers saw us as sharing
0 files / not connectable because incoming connections on port 50300 could not reach the
container.

## Root cause

slskd was running behind Mullvad VPN via gluetun (`network_mode: service:gluetun`).
Mullvad removed port forwarding support in July 2023, so port 50300 was unreachable from
the internet through the VPN tunnel. The gluetun firewall allowed the port locally
(`FIREWALL_VPN_INPUT_PORTS`), but without Mullvad actually forwarding the port to the VPN
IP, peers could never connect.

## Fix

Moved slskd off gluetun's network onto the default Docker compose network:

- **docker-compose.yml.j2**: removed `network_mode: service:gluetun` and
  `depends_on: gluetun` from slskd; added `ports: 5030, 50300` directly to slskd
- **docker-compose.yml.j2**: removed slskd ports (5030, 50300) from gluetun's port list
  and removed 50300 from `FIREWALL_VPN_INPUT_PORTS`
- **soularr/config.ini.j2**: changed `host_url` from `http://gluetun:5030` to
  `http://slskd:5030` (both now on default Docker network)
- **documentation/media_vm.md**: updated network routing section, architecture diagram,
  port table, and troubleshooting guide

## Trade-off

slskd traffic is no longer VPN-protected. This is acceptable because Soulseek is a public
P2P network where your username and IP are visible to peers regardless. The alternative
would be switching to a VPN provider that still supports port forwarding (ProtonVPN,
AirVPN, PIA).

## Additional fixes discovered during deploy

### `pull: never` added to all docker_compose_v2 handlers (39 blocks, 14 files)

First deploy attempt failed because the `community.docker.docker_compose_v2` module defaults
to pulling images before recreating containers. This caused two problems:

1. **Slow deploys**: every config-only change triggered a pull of all images in the stack
2. **Broken tags**: `soularr_version: "0.5.0"` didn't exist on Docker Hub (available tags:
   `latest`, `dev`, `v1.0.0`, `v1.1.0`), causing the entire deploy to fail

Fixed by adding `pull: never` to every `docker_compose_v2` handler across all 14 roles
(39 total blocks). Image pulls are now manual — run `docker compose pull` on the host
before deploying version bumps.

### Soularr version fixed

Changed `soularr_version` from `"0.5.0"` (nonexistent) to `"v1.1.0"` in
`roles/media_vm/defaults/main.yml`.

### Gluetun restart handler updated

Removed `slskd` from the "Restart gluetun" handler service list since slskd no longer
depends on gluetun's network.

## Deploy

```bash
ssh media 'cd /srv/media && docker compose pull soularr'  # pull new version first
make media t=docker
```
