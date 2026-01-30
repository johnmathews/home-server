#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["requests"]
# ///
"""Find all photos in a subdirectory of the external library and add them to a named Immich album.

Usage:
    IMMICH_API_KEY=xxx uv run immich-add-photos-to-album-using-subdirectory.py --dir spain --album "Spain 2024"
"""

import argparse
import os
import sys

import requests

IMMICH_URL = "http://192.168.2.113:2283"
LIBRARY_BASE = "/mnt/nfs/photos/reference"


def get_album_id(session: requests.Session, album_name: str) -> str:
    # Check owned albums, then shared albums
    for shared_param in [None, "true"]:
        params = {}
        if shared_param is not None:
            params["shared"] = shared_param
        label = "shared" if shared_param else "owned"
        resp = session.get(f"{IMMICH_URL}/api/albums", params=params)
        resp.raise_for_status()
        albums = resp.json()
        print(f"  Found {len(albums)} {label} albums")
        for album in albums:
            if album.get("albumName") == album_name:
                return album["id"]

    answer = input(f"Album '{album_name}' not found. Create it? [y/N] ").strip().lower()
    if answer != "y":
        print("Aborted", file=sys.stderr)
        sys.exit(1)

    resp = session.post(
        f"{IMMICH_URL}/api/albums",
        json={"albumName": album_name},
        timeout=30,
    )
    resp.raise_for_status()
    album_id = resp.json()["id"]
    print(f"Created album '{album_name}' ({album_id})")
    return album_id


def search_assets(
    session: requests.Session, target_path: str, *, debug: bool = False
) -> list[str]:
    asset_ids: list[str] = []
    page = 1
    while True:
        body = {"originalPath": target_path, "page": page, "size": 1000}
        if debug:
            print(f"[debug] POST /api/search/metadata body={body}")
        resp = session.post(
            f"{IMMICH_URL}/api/search/metadata",
            json=body,
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()

        if debug and page == 1:
            # Show raw top-level keys and item count
            asset_section = data.get("assets", {})
            print(f"[debug] Response keys: {list(data.keys())}")
            print(f"[debug] assets.items count: {len(asset_section.get('items', []))}")
            print(f"[debug] assets.nextPage: {asset_section.get('nextPage')}")
            for item in asset_section.get("items", [])[:3]:
                print(f"[debug]   originalPath: {item.get('originalPath', '(none)')}")

        assets = data.get("assets", {}).get("items", [])
        for asset in assets:
            original = asset.get("originalPath", "")
            # Only include direct children — strip the target prefix and reject paths with /
            suffix = original.removeprefix(target_path)
            if "/" not in suffix:
                asset_ids.append(asset["id"])

        next_page = data.get("assets", {}).get("nextPage")
        if next_page is None:
            break
        page = next_page

    return list(dict.fromkeys(asset_ids))  # deduplicate, preserve order


def add_assets_to_album(
    session: requests.Session, album_id: str, asset_ids: list[str], dry_run: bool
) -> None:
    batch_size = 500
    total_added = 0
    total_duplicate = 0
    total_errors = 0

    for i in range(0, len(asset_ids), batch_size):
        batch = asset_ids[i : i + batch_size]
        if dry_run:
            print(f"[dry-run] Would add batch of {len(batch)} assets to album")
            total_added += len(batch)
            continue

        resp = session.put(
            f"{IMMICH_URL}/api/albums/{album_id}/assets",
            json={"ids": batch},
            timeout=60,
        )
        resp.raise_for_status()

        for result in resp.json():
            if result.get("success"):
                total_added += 1
            elif result.get("error") == "duplicate":
                total_duplicate += 1
            else:
                total_errors += 1

    print(f"Total assets found:     {len(asset_ids)}")
    print(f"Newly added:            {total_added}")
    print(f"Already in album:       {total_duplicate}")
    if total_errors:
        print(f"Errors:                 {total_errors}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Add photos from a subdirectory to an Immich album"
    )
    parser.add_argument(
        "--dir", required=True, help="Subdirectory name relative to the library base"
    )
    parser.add_argument(
        "--album", required=True, help="Exact album name to add assets to"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would happen without making changes",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Print sample asset paths and raw API responses for troubleshooting",
    )
    args = parser.parse_args()

    api_key = os.environ.get("IMMICH_API_KEY")
    if not api_key:
        print("Error: IMMICH_API_KEY environment variable is not set", file=sys.stderr)
        sys.exit(1)

    target_path = f"{LIBRARY_BASE}/{args.dir}/"

    session = requests.Session()
    session.headers.update({"x-api-key": api_key})

    print(f"Looking for album: {args.album}")
    album_id = get_album_id(session, args.album)
    print(f"Found album: {album_id}")

    if args.debug:
        print(
            f"\n[debug] Fetching assets from album '{args.album}' to show stored paths..."
        )
        resp = session.get(f"{IMMICH_URL}/api/albums/{album_id}", timeout=30)
        resp.raise_for_status()
        album_data = resp.json()
        album_assets = album_data.get("assets", [])
        print(f"[debug] Album contains {len(album_assets)} assets")
        if album_assets:
            print("[debug] Sample originalPath values from album:")
            for item in album_assets[:5]:
                print(f"  {item.get('originalPath', '(none)')}")
        print()

    print(f"Searching for assets in: {target_path}")
    asset_ids = search_assets(session, target_path, debug=args.debug)

    if not asset_ids:
        print("No assets found in the specified directory")
        sys.exit(0)

    add_assets_to_album(session, album_id, asset_ids, args.dry_run)


if __name__ == "__main__":
    main()
