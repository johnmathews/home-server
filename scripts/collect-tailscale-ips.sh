#!/bin/bash
# Collect Tailscale IPs from all hosts and display them in a table
# Usage: ./scripts/collect-tailscale-ips.sh

set -euo pipefail

SSH_KEY="$HOME/.ssh/john_macbook"

echo "Collecting Tailscale IPs from all hosts..."
echo ""
echo "┌──────────────────────┬─────────────────┬───────────────────┐"
echo "│ Host                 │ Local IP        │ Tailscale IP      │"
echo "├──────────────────────┼─────────────────┼───────────────────┤"

# Function to get Tailscale IP from a host
get_tailscale_ip() {
  local user=$1
  local host=$2
  local name=$3

  # Try to get Tailscale IP
  tailscale_ip=$(ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "${user}@${host}" "tailscale ip -4 2>/dev/null" 2>/dev/null || echo "Not available")

  printf "│ %-20s │ %-15s │ %-17s │\n" "$name" "$host" "$tailscale_ip"
}

# Proxmox
get_tailscale_ip "root" "192.168.2.214" "proxmox_host"

# VMs
get_tailscale_ip "root" "192.168.2.104" "truenas"
get_tailscale_ip "john" "192.168.2.105" "media_vm"
get_tailscale_ip "john" "192.168.2.106" "infra_vm"

# LXCs
get_tailscale_ip "root" "192.168.2.100" "cloudflared_lxc"
get_tailscale_ip "root" "192.168.2.101" "pihole_lxc"
get_tailscale_ip "root" "192.168.2.103" "n8n_lxc"
get_tailscale_ip "root" "192.168.2.108" "traefik_lxc"
get_tailscale_ip "root" "192.168.2.110" "jellyfin_lxc"
get_tailscale_ip "root" "192.168.2.113" "immich_lxc"
get_tailscale_ip "root" "192.168.2.115" "prometheus_lxc"
get_tailscale_ip "root" "192.168.2.116" "tubearchivist_lxc"
get_tailscale_ip "root" "192.168.2.117" "paperless_lxc"
get_tailscale_ip "root" "192.168.2.119" "open_webui_lxc"
get_tailscale_ip "root" "192.168.2.201" "key_server"

echo "└──────────────────────┴─────────────────┴───────────────────┘"
echo ""
echo "Next steps:"
echo "1. Copy the Tailscale IPs above"
echo "2. Update inventory-tailscale.ini with these IPs"
echo "3. Test remote access: ansible all -i inventory-tailscale.ini -m ping"
