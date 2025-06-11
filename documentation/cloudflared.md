# Cloudflared

The cloudflared service runs in an LXC. The LXC was created using proxmox-community-scripts:

https://community-scripts.github.io/ProxmoxVE/scripts?id=cloudflared


This allows services running on the server to be accessed from the internet.

## Access

`ssh cloudflared`


## Configuration

config file:

`/etc/cloudflared/config.yaml`


## Updated and changes

If you make changes to existing routes, you will need to delete the existing DNS records from the cloudflare UI.

Then you can run this command to make the routes again.


```
for domain in $(grep hostname: /etc/cloudflared/config.yml | awk '{print $3}'); do
  cloudflared tunnel route dns home-server "$domain"
done
```


## Other Commands

`cloudflared tunnel list`

`cloudflared tunnel info <tunnel-name>`

`cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate`


```
sudo systemctl restart cloudflared
sudo systemctl status cloudflared
```
