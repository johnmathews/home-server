#!/usr/bin/env bash
# Create CNAME DNS records on itsa-pizza.com for all tunnel subdomains.
# Uses the Cloudflare API v4.
#
# Prerequisites:
#   1. Create an API token at https://dash.cloudflare.com/profile/api-tokens
#      with DNS:Edit permission scoped to itsa-pizza.com
#   2. Export CF_API_TOKEN=<your-token>
#
# Usage:
#   ./scripts/cf-create-dns-records.sh              # dry-run (default)
#   ./scripts/cf-create-dns-records.sh --apply       # create records
#   ./scripts/cf-create-dns-records.sh --cleanup     # delete bad records from itsa.pizza zone

set -euo pipefail

TUNNEL_CNAME="e1e3b9c4-789a-4ad3-adff-a0c71bff1122.cfargotunnel.com"
NEW_DOMAIN="itsa-pizza.com"
OLD_DOMAIN="itsa.pizza"
API_BASE="https://api.cloudflare.com/client/v4"

# All subdomains from cloudflared config.yml
SUBDOMAINS=(
  "@"
  dash
  timer
  sre
  claw
  traefik
  immich
  share
  jelly
  navidrome
  music
  lidarr
  slskd
  chat
  charts
  grafana
  loki
  prometheus
  portainer
  dozzle
  speed
  atuin
  files
  home
  vault
  passwords
  proxmox
  pve
  pbs
  bmc
  uptime
  ads
  adguard
  seerr
  kids-seerr
  radarr
  sonarr
  sabnzbd
  qbittorrent
  tube
  kids-tube
  bazarr
  subs
  prowlarr
  paperless
  documents
  docs
  booklore
  books
  nas
  truenas
)

# --- Helpers ---

cf_api() {
  curl -sf "$@" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json"
}

get_zone_id() {
  local domain="$1"
  local response
  response=$(cf_api "${API_BASE}/zones?name=${domain}&per_page=1")
  echo "$response" | jq -r '.result[0].id // empty'
}

# --- Commands ---

create_records() {
  local dry_run="${1:-true}"
  local zone_id
  zone_id=$(get_zone_id "$NEW_DOMAIN")

  if [[ -z "$zone_id" ]]; then
    echo "ERROR: Could not find zone ID for $NEW_DOMAIN. Check your API token permissions."
    exit 1
  fi
  echo "Zone ID for $NEW_DOMAIN: $zone_id"
  echo ""

  # Get existing records to avoid duplicates
  local existing
  existing=$(cf_api "${API_BASE}/zones/${zone_id}/dns_records?type=CNAME&per_page=500" | jq -r '.result[].name')

  local created=0 skipped=0 failed=0

  for sub in "${SUBDOMAINS[@]}"; do
    local name
    if [[ "$sub" == "@" ]]; then
      name="$NEW_DOMAIN"
    else
      name="${sub}.${NEW_DOMAIN}"
    fi

    # Skip if record already exists
    if echo "$existing" | grep -qx "$name"; then
      echo "SKIP  $name (already exists)"
      ((skipped++))
      continue
    fi

    if [[ "$dry_run" == "true" ]]; then
      echo "DRY   $name -> $TUNNEL_CNAME"
      ((created++))
    else
      local payload
      payload=$(jq -n \
        --arg type "CNAME" \
        --arg name "$name" \
        --arg content "$TUNNEL_CNAME" \
        '{type: $type, name: $name, content: $content, proxied: true, ttl: 1}')

      local result
      if result=$(cf_api "${API_BASE}/zones/${zone_id}/dns_records" -X POST -d "$payload"); then
        local success
        success=$(echo "$result" | jq -r '.success')
        if [[ "$success" == "true" ]]; then
          echo "OK    $name"
          ((created++))
        else
          local errors
          errors=$(echo "$result" | jq -r '.errors[]?.message // "unknown error"')
          echo "FAIL  $name — $errors"
          ((failed++))
        fi
      else
        echo "FAIL  $name — API request failed"
        ((failed++))
      fi
    fi
  done

  echo ""
  echo "--- Summary ---"
  [[ "$dry_run" == "true" ]] && echo "MODE: dry-run (use --apply to create records)"
  echo "Created: $created  Skipped: $skipped  Failed: $failed"
}

cleanup_bad_records() {
  local zone_id
  zone_id=$(get_zone_id "$OLD_DOMAIN")

  if [[ -z "$zone_id" ]]; then
    echo "ERROR: Could not find zone ID for $OLD_DOMAIN."
    exit 1
  fi
  echo "Zone ID for $OLD_DOMAIN: $zone_id"
  echo ""

  # Find records containing "itsa-pizza.com" in the itsa.pizza zone (the bad ones)
  local records
  records=$(cf_api "${API_BASE}/zones/${zone_id}/dns_records?per_page=500" \
    | jq -r '.result[] | select(.name | contains("itsa-pizza")) | "\(.id) \(.name)"')

  if [[ -z "$records" ]]; then
    echo "No bad records found on $OLD_DOMAIN zone. Nothing to clean up."
    return
  fi

  echo "Bad records found on $OLD_DOMAIN zone:"
  echo "$records"
  echo ""
  read -rp "Delete these records? (y/N) " confirm
  if [[ "$confirm" != "y" ]]; then
    echo "Aborted."
    return
  fi

  while IFS=' ' read -r id name; do
    if cf_api "${API_BASE}/zones/${zone_id}/dns_records/${id}" -X DELETE > /dev/null; then
      echo "DELETED  $name"
    else
      echo "FAIL     $name ($id)"
    fi
  done <<< "$records"
}

# --- Main ---

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "ERROR: CF_API_TOKEN environment variable is not set."
  echo "Create a token at https://dash.cloudflare.com/profile/api-tokens"
  echo "Required permission: DNS:Edit on $NEW_DOMAIN"
  exit 1
fi

case "${1:-}" in
  --apply)
    echo "Creating DNS records on $NEW_DOMAIN..."
    echo ""
    create_records false
    ;;
  --cleanup)
    echo "Cleaning up bad records on $OLD_DOMAIN zone..."
    echo ""
    cleanup_bad_records
    ;;
  *)
    echo "Dry-run: showing records that would be created on $NEW_DOMAIN..."
    echo ""
    create_records true
    ;;
esac
