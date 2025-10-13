#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
uptimekumactl.py — minimal CLI for Uptime Kuma pause/resume from shell scripts.

Env:
  KUMA_URL          (e.g. http://192.168.2.106:3001 or https://kuma.example.com)
  KUMA_USERNAME     (dashboard username)
  KUMA_PASSWORD     (dashboard password)
  KUMA_INSECURE=1   (optional: skip TLS verify)
  KUMA_MAP_FILE     (optional: "container monitor_id" per line)
Behavior:
  - If KUMA_MAP_FILE maps the container -> id, use it.
  - Else try to find a monitor whose name == container.
  - Else try a tag match where tag value or name == container.
Exit codes:
  0 on success, non-zero on error.
Stdout:
  Single logfmt line (no quotes).
"""

import os, sys
from typing import Optional, Dict

def logfmt(**kvs):
    # No quotes, escape spaces to underscores
    def clean(v):
        return str(v).replace(" ", "_")
    print(" ".join(f"{k}={clean(v)}" for k, v in kvs.items()))

def load_map(path: str) -> Dict[str, int]:
    m = {}
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                m[parts[0]] = int(parts[1])
    return m

def find_monitor_id(api, container: str, mapping: Dict[str,int]) -> Optional[int]:
    if container in mapping:
        return mapping[container]
    # Fallback: name match or tag match
    for mon in api.get_monitors():
        if mon.get("name") == container:
            return int(mon["id"])
    for mon in api.get_monitors():
        tags = mon.get("tags") or []
        for t in tags:
            # tag dict: {"tag_id": ..., "monitor_id": ..., "value": None, "name": "production", "color": "#059669"}
            if (t.get("name") == container) or (str(t.get("value") or "") == container):
                return int(mon["id"])
    return None

def main():
    import argparse
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("action", choices=["pause","resume"])
    parser.add_argument("--container", required=True)
    args = parser.parse_args()

    url = os.environ.get("KUMA_URL")
    user = os.environ.get("KUMA_USERNAME")
    pwd  = os.environ.get("KUMA_PASSWORD")
    map_file = os.environ.get("KUMA_MAP_FILE","")
    # insecure = os.environ.get("KUMA_INSECURE","0") == "1"

    if not url or not user or not pwd:
        logfmt(level="error", system="kumactl", event="missing_env", url=bool(url), username=bool(user), password=bool(pwd))
        sys.exit(2)

    mapping = {}
    if map_file and os.path.exists(map_file):
        try:
            mapping = load_map(map_file)
        except Exception as e:
            logfmt(level="warn", system="kumactl", event="map_load_failed", path=map_file, err=str(e))
            mapping = {}

    try:
        # Lazy import so normal runs of your script don't fail if python deps missing
        from uptime_kuma_api import UptimeKumaApi
        # api = UptimeKumaApi(url, ssl_verify=not insecure)
        api = UptimeKumaApi(url)
        api.login(user, pwd)

        mid = find_monitor_id(api, args.container, mapping)
        if mid is None:
            logfmt(level="warn", system="kumactl", event="monitor_not_found", container=args.container)
            api.disconnect()
            sys.exit(3)

        if args.action == "pause":
            res = api.pause_monitor(mid)  # {'msg': 'Paused Successfully.'}
            logfmt(level="info", system="kumactl", container=args.container, event="paused", monitor_id=mid, msg=res.get("msg","ok"))
        else:
            res = api.resume_monitor(mid)
            logfmt(level="info", system="kumactl", container=args.container, event="resumed", monitor_id=mid, msg=res.get("msg","ok"))

        api.disconnect()
        sys.exit(0)

    except Exception as e:
        # Avoid quotes; compress spaces
        logfmt(level="error", system="kumactl", container=args.container, event="exception", err=str(e))
        sys.exit(1)

if __name__ == "__main__":
    main()
