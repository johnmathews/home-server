#!/usr/bin/env python3
"""Slowly re-fetch YouTube metadata for episodes whose first lookup failed.

The YouTube Metadata plugin shells out to yt-dlp per item; a bulk scan of a
few hundred items gets the Jellyfin host rate-limited by YouTube (HTTP 429 /
"sign in to confirm you're not a bot") and those items are left with a
filename-derived title.  This script refreshes only the episodes in a library
that still lack a YoutubeMetadata provider id, one at a time with a pause,
and repeats in passes with a longer back-off until none are left or the pass
limit is hit.

Env: JELLYFIN_URL, JELLYFIN_API_KEY.   Usage: retry_metadata.py <library-item-id> [--passes N] [--gap S] [--backoff S]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from typing import Any

URL = os.environ.get("JELLYFIN_URL", "http://192.168.2.110:8096")
KEY = os.environ["JELLYFIN_API_KEY"]


def req(method: str, path: str, params: dict[str, Any] | None = None) -> Any:
    q = ("?" + urllib.parse.urlencode(params)) if params else ""
    r = urllib.request.Request(URL + path + q, method=method)
    r.add_header("Authorization", f'MediaBrowser Token="{KEY}", Client="fitness-migration", Device="cli", DeviceId="fitness-migration", Version="1"')
    with urllib.request.urlopen(r, timeout=120) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def missing(lib: str, uid: str) -> list[dict[str, Any]]:
    eps = req("GET", "/Items", {"userId": uid, "parentId": lib, "recursive": "true", "includeItemTypes": "Episode",
                                "fields": "Path,ProviderIds", "limit": "1000"})["Items"]
    return [e for e in eps if not (e.get("ProviderIds") or {}).get("YoutubeMetadata")]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("library_id")
    ap.add_argument("--passes", type=int, default=6)
    ap.add_argument("--gap", type=float, default=20.0, help="seconds between items")
    ap.add_argument("--backoff", type=float, default=600.0, help="seconds between passes")
    a = ap.parse_args()
    uid = next(u["Id"] for u in req("GET", "/Users") if u["Name"] == "john")
    for p in range(1, a.passes + 1):
        todo = missing(a.library_id, uid)
        print(f"pass {p}: {len(todo)} episodes without YouTube metadata", flush=True)
        if not todo:
            break
        fixed = 0
        for e in todo:
            req("POST", f"/Items/{e['Id']}/Refresh", {"MetadataRefreshMode": "FullRefresh", "ImageRefreshMode": "FullRefresh",
                                                       "ReplaceAllMetadata": "false", "ReplaceAllImages": "false"})
            time.sleep(a.gap)
            it = req("GET", "/Items", {"userId": uid, "ids": e["Id"], "fields": "ProviderIds"})["Items"]
            ok = bool(it and (it[0].get("ProviderIds") or {}).get("YoutubeMetadata"))
            fixed += ok
            print(f"  {'ok ' if ok else '---'} {e['Path'].rsplit('/', 1)[1][:90]}", flush=True)
        print(f"pass {p}: fixed {fixed}/{len(todo)}", flush=True)
        if fixed < len(todo) and p < a.passes:
            print(f"  backing off {a.backoff:.0f}s", flush=True)
            time.sleep(a.backoff)
    left = missing(a.library_id, uid)
    print(f"DONE: {len(left)} still without metadata", flush=True)
    for e in left:
        print("   ", e["Path"].rsplit("/", 1)[1])
    sys.exit(0 if not left else 1)


if __name__ == "__main__":
    main()
