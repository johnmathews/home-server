#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
LIST="/etc/quiet-hours/containers.list"

if [[ "${ACTION}" != "pause" && "${ACTION}" != "unpause" ]]; then
  echo "Usage: $0 {pause|unpause}" >&2
  exit 2
fi

if [[ ! -r "$LIST" ]]; then
  echo "Container list not found: $LIST" >&2
  exit 1
fi

# Resolve docker path (usually /usr/bin/docker)
DOCKER_BIN="$(command -v docker)"

while IFS= read -r name; do
  [[ -z "$name" || "$name" =~ ^# ]] && continue
  # Best-effort: ignore failures if a container doesn't exist or is already paused/running
  if [[ "$ACTION" == "pause" ]]; then
    "$DOCKER_BIN" pause "$name" || true
  else
    "$DOCKER_BIN" unpause "$name" || true
  fi
done < "$LIST"
