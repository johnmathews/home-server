This LXC container runs the `cloudflared` service, enabling secure remote access
to services hosted on your Proxmox server via Cloudflare Tunnel.

The container was created using the Proxmox Community Scripts project:
https://community-scripts.github.io/ProxmoxVE/scripts?id=cloudflared

## Access

SSH into the container with:

```sh
ssh cloudflared
```

## Configuration

Main configuration file:

```sh
/etc/cloudflared/config.yml
```

## Updating Configuration

To apply changes to the Cloudflare Tunnel configuration:

```sh
cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
sudo systemctl restart cloudflared
cloudflared tunnel route dns home-server <subdomain>.itsa.pizza
```

## Bulk DNS Update Example

Automatically update DNS routes for all configured hostnames:

```sh
for domain in $(grep hostname: /etc/cloudflared/config.yml | awk '{print $3}'); do
  cloudflared tunnel route dns home-server "$domain"
done
```

## Logging

```sh
journalctl -u cloudflared -f
```

## Useful Commands

Check configured tunnels:

```sh
cloudflared tunnel list
cloudflared tunnel info <tunnel-name>
```

Manage the systemd service:

```sh
sudo systemctl restart cloudflared
sudo systemctl status cloudflared
```
