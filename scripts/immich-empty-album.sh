#!/usr/bin/env bash
set -euo pipefail

IMMICH_URL="https://immich.itsa.pizza"
API_KEY=$IMMICH_API_KEY
ALBUM_NAME="Favorites"
BATCH=200 # drop to 100 if you hit 413/timeout

album_id="$(
  curl -sS "$IMMICH_URL/api/albums" -H "x-api-key: $API_KEY" |
    jq -r --arg n "$ALBUM_NAME" '.[] | select((.albumName|ascii_downcase)==($n|ascii_downcase)) | .id' |
    head -n 1
)"

[[ -n "$album_id" ]] || {
  echo "Album not found: $ALBUM_NAME"
  exit 1
}

tmp_ids="$(mktemp)"
curl -sS "$IMMICH_URL/api/albums/$album_id" -H "x-api-key: $API_KEY" |
  jq -r '.assets[].id' >"$tmp_ids"

total="$(wc -l <"$tmp_ids" | tr -d ' ')"
echo "Album $album_id has $total items."

split -l "$BATCH" -d -a 4 "$tmp_ids" "${tmp_ids}.chunk."

for f in "${tmp_ids}.chunk."*; do
  ids_json="$(jq -R -s -c 'split("\n") | map(select(length>0))' <"$f")"

  curl -sS --fail-with-body -o /dev/null -w "Removed batch ${f##*.chunk.} (HTTP %{http_code})\n" \
    -X DELETE "$IMMICH_URL/api/albums/$album_id/assets" \
    -H "x-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"ids\":$ids_json}"
done

rm -f "$tmp_ids" "${tmp_ids}.chunk."*

# verify
curl -sS "$IMMICH_URL/api/albums/$album_id" -H "x-api-key: $API_KEY" | jq '.assets | length'
echo "Done."
