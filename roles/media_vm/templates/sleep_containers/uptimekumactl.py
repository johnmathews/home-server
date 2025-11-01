#!/opt/uptimekumactl/venv/bin/python3
# -*- coding: utf-8 -*-
"""
kumactl.py — Pause/resume Uptime Kuma monitors with retries and debug logs.

Env:
  KUMA_URL                 (http(s)://host:port)
  KUMA_USERNAME
  KUMA_PASSWORD
  KUMA_INSECURE=1          (optional: skip TLS verify — not used by client currently)
  KUMA_MAP_FILE            (e.g. /etc/sleep-hours/kuma.map)
  KUMA_TIMEOUT_S=10        (overall op timeout hint; best-effort)
  KUMA_RETRIES=3
  KUMA_RETRY_DELAY_S=2
  QUIET_LOG_LEVEL=debug|info|warn|error (default: info)
Stdout:
  Single logfmt line per event.
"""

import os, sys, time
from typing import Optional, Dict, Any

# ----- logging with levels (no quotes, spaces -> underscores) -----
LEVELS = {"debug": 10, "info": 20, "warn": 30, "error": 40}
LOG_THRESH = LEVELS.get(os.environ.get("QUIET_LOG_LEVEL", "info"), 20)


def _should(level: str) -> bool:
    return LEVELS.get(level, 20) >= LOG_THRESH


def _clean(v: Any) -> str:
    return str(v).replace(" ", "_")


def logfmt(level="info", **kvs):
    if not _should(level):
        return
    parts = [f"{k}={_clean(v)}" for k, v in kvs.items()]
    print(" ".join(parts))


def load_map(path: str) -> Dict[str, int]:
    m: Dict[str, int] = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    m[parts[0]] = int(parts[1])
        logfmt("debug", system="kumactl", event="map_loaded", path=path, entries=len(m))
    except Exception as e:
        logfmt("warn", system="kumactl", event="map_load_failed", path=path, err=e)
    return m


def find_monitor_id(api, container: str, mapping: Dict[str, int]) -> Optional[int]:
    if container in mapping:
        return mapping[container]
    # Fallbacks: direct name match, then tag value/name match
    for mon in api.get_monitors():
        if mon.get("name") == container:
            return int(mon["id"])
    for mon in api.get_monitors():
        tags = mon.get("tags") or []
        for t in tags:
            if (t.get("name") == container) or (str(t.get("value") or "") == container):
                return int(mon["id"])
    return None


def with_retries(desc: str, func, *args, retries: int, delay_s: int):
    attempt = 1
    start_all = time.time()
    while True:
        t0 = time.time()
        try:
            out = func(*args)
            logfmt(
                "debug",
                system="kumactl",
                event=f"{desc}_ok",
                attempt=attempt,
                duration_s=int(time.time() - t0),
            )
            return out
        except Exception as e:
            logfmt(
                "warn",
                system="kumactl",
                event=f"{desc}_failed",
                attempt=attempt,
                duration_s=int(time.time() - t0),
                err=e,
            )
            if attempt >= retries:
                logfmt(
                    "error",
                    system="kumactl",
                    event=f"{desc}_giving_up",
                    attempts=attempt,
                    total_duration_s=int(time.time() - start_all),
                )
                raise
            attempt += 1
            time.sleep(delay_s)


def main():
    import argparse

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("action", choices=["pause", "resume"])
    parser.add_argument("--container", required=True)
    args = parser.parse_args()

    url = os.environ.get("KUMA_URL")
    user = os.environ.get("KUMA_USERNAME")
    pwd = os.environ.get("KUMA_PASSWORD")
    map_path = os.environ.get("KUMA_MAP_FILE", "/etc/sleep-hours/kuma.map")

    retries = int(os.environ.get("KUMA_RETRIES", "3"))
    delay_s = int(os.environ.get("KUMA_RETRY_DELAY_S", "2"))

    if not url or not user or not pwd:
        logfmt(
            "error",
            system="kumactl",
            event="missing_env",
            url=bool(url),
            username=bool(user),
            password=bool(pwd),
        )
        sys.exit(2)

    mapping = load_map(map_path) if os.path.exists(map_path) else {}
    try:
        from uptime_kuma_api import UptimeKumaApi

        api = with_retries(
            "login", UptimeKumaApi, url, retries=retries, delay_s=delay_s
        )
        with_retries(
            "authenticate", api.login, user, pwd, retries=retries, delay_s=delay_s
        )

        mid = find_monitor_id(api, args.container, mapping)
        if mid is None:
            logfmt(
                "warn",
                system="kumactl",
                container=args.container,
                event="monitor_not_found",
            )
            try:
                api.disconnect()
            except Exception:
                pass
            sys.exit(3)

        t0 = time.time()
        if args.action == "pause":
            res = with_retries(
                "pause_monitor",
                api.pause_monitor,
                mid,
                retries=retries,
                delay_s=delay_s,
            )
            logfmt(
                "info",
                system="kumactl",
                container=args.container,
                event="paused",
                monitor_id=mid,
                msg=res.get("msg", "ok"),
                duration_s=int(time.time() - t0),
            )
        else:
            res = with_retries(
                "resume_monitor",
                api.resume_monitor,
                mid,
                retries=retries,
                delay_s=delay_s,
            )
            logfmt(
                "info",
                system="kumactl",
                container=args.container,
                event="resumed",
                monitor_id=mid,
                msg=res.get("msg", "ok"),
                duration_s=int(time.time() - t0),
            )

        try:
            api.disconnect()
        except Exception:
            pass
        sys.exit(0)

    except Exception as e:
        logfmt(
            "error",
            system="kumactl",
            container=args.container,
            event="exception",
            err=e,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
