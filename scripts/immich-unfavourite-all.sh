#!/usr/bin/env bash

set -euo pipefail

IMMICH_URL="https://immich.itsa-pizza.com" # no trailing /api
API_KEY=$IMMICH_API_KEY

PAGE=1
SIZE=1000
BATCH=200 # how many IDs per update request

tmp_ids="$(mktemp)"
: >"$tmp_ids"

echo "Collecting favorite asset IDs..."
while :; do
  resp="$(
    curl -sS -X POST "$IMMICH_URL/api/search/metadata" \
      -H "x-api-key: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"isFavorite\":true,\"page\":$PAGE,\"size\":$SIZE}"
  )"

  # IDs live at .assets.items[].id in the API docs schema
  echo "$resp" | jq -r '.assets.items[]?.id' >>"$tmp_ids"

  next_page="$(echo "$resp" | jq -r '.nextPage // empty')"
  if [[ -z "$next_page" ]]; then
    break
  fi
  PAGE="$next_page"
done

total="$(wc -l <"$tmp_ids" | tr -d ' ')"
echo "Found $total favorite assets."

if [[ "$total" -eq 0 ]]; then
  rm -f "$tmp_ids"
  exit 0
fi

echo "Un-favoriting in batches of $BATCH..."
# chunk and update
split -l "$BATCH" -d -a 4 "$tmp_ids" "${tmp_ids}.chunk."
for f in "${tmp_ids}.chunk."*; do
  ids_json="$(jq -R -s -c 'split("\n") | map(select(length>0))' <"$f")"

  curl -sS -o /dev/null -w "Updated batch: ${f##*.chunk.} (HTTP %{http_code})\n" \
    -X PUT "$IMMICH_URL/api/assets" \
    -H "x-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"ids\":$ids_json,\"isFavorite\":false}"
done

rm -f "$tmp_ids" "${tmp_ids}.chunk."*
echo "Done."
