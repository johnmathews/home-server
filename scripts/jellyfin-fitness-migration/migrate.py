#!/usr/bin/env python3
"""Migrate the flat per-playlist Jellyfin "movie" libraries into one Shows library.

Sub-commands (run in this order; each is idempotent / re-runnable):

  export-history   Read every user's played/position/favourite state for items
                   under the source folders via the Jellyfin API, keyed by
                   YouTube ID.  Read-only.
  plan             Build the rename plan (old path -> new path) from a NAS
                   directory listing + mapping.toml.  Writes plan.json and a
                   human-readable plan.md.  Touches nothing.
  apply-moves      Execute the plan on the NAS over ssh (mv within one ZFS
                   dataset), create tvshow.nfo / season.nfo.  Refuses to run if
                   a destination already exists.
  apply-history    After the new library has been scanned: map YouTube ID ->
                   new episode item and POST the saved user data back.
  fix-library-options
                   Disable the YouTube Metadata plugin for Episodes/Series in the
                   new library (its episode provider hard-codes IndexNumber = 1,
                   which destroys SxxExx ordering) and make Nfo the only local
                   metadata reader.
  write-nfo        Generate <episode>.nfo sidecars (title/plot/aired/season/
                   episode/uniqueid) for every planned episode from the metadata
                   Jellyfin already holds (API) with a fallback file for the rest,
                   export each episode's stored primary image as <stem>-thumb.*,
                   and ship them to the NAS.  --dry-run writes them under --workdir.
  fix-overviews    Replace every episode Overview with a cleaned YouTube description
                   ("<channel> · <date>" + first real paragraph, boilerplate removed).
  fix-names        After refresh: clear the plugin's forced sort names, retitle
                   filename-named episodes from the metadata snapshot, apply the
                   season names from mapping.toml, re-extract missing thumbnails.
  refresh          Plain FullRefresh (never ReplaceAllMetadata — see cmd_refresh)
                   so Jellyfin fills missing SxxExx from filenames and reads the
                   nfo files; then verifies every episode's numbers match its
                   filename and reports season names.

Environment:
  JELLYFIN_URL      default http://192.168.2.110:8096
  JELLYFIN_API_KEY  admin API key (vault_jellyfin_key)
  NAS_SSH_HOST      default "nas"   (ssh alias; runs mv as that user)

All state files live in the working directory passed with --workdir.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tomllib
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

JELLYFIN_PATH_ROOT = "/movies/youtube"  # library path inside the jellyfin container
NAS_PATH_ROOT = "/mnt/tank/movies/youtube"  # same directory seen from the NAS shell
MEDIA_EXTS = {".mkv", ".mp4", ".webm", ".m4v", ".mov", ".avi"}
YT_ID_RE = re.compile(r"\[([A-Za-z0-9_-]{11})\]")  # yt-dlp may append _1 etc after the bracket on collisions
PLAYLIST_PREFIX_RE = re.compile(r"^(\d{3})-")
SXXEXX_RE = re.compile(r"S\d{2}E\d{2,3}")


# --------------------------------------------------------------------------- #
# data model
# --------------------------------------------------------------------------- #
@dataclass
class SeasonSpec:
    series: str
    number: int
    name: str
    folder: str
    ids: list[str] | None  # None => whole folder, episode = NNN- prefix


@dataclass
class Move:
    src: str  # relative to the youtube root, e.g. "training/Foo-[id].mp4"
    dst: str  # relative to the youtube root, e.g. "fitness/Bodyweight/Season 01/Bodyweight S01E03 - Foo-[id].mp4"
    kind: str  # "media" | "sidecar" | "dir"
    youtube_id: str | None
    series: str | None = None
    season: int | None = None
    episode: int | None = None


@dataclass
class Plan:
    target_subdir: str
    library_name: str
    moves: list[Move]
    nfo_files: dict[str, str]  # relative path -> file contents
    unmapped: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def load_mapping(path: Path) -> tuple[dict[str, Any], list[SeasonSpec]]:
    cfg = tomllib.loads(path.read_text())
    seasons: list[SeasonSpec] = []
    for series in cfg["series"]:
        for s in series["seasons"]:
            seasons.append(
                SeasonSpec(
                    series=series["name"],
                    number=int(s["number"]),
                    name=str(s.get("name") or ""),
                    folder=s["folder"],
                    ids=list(s["ids"]) if "ids" in s else None,
                )
            )
    # validate: (series, number) unique, ids unique across all seasons
    keys = [(s.series, s.number) for s in seasons]
    if len(keys) != len(set(keys)):
        raise SystemExit("mapping.toml: duplicate (series, season number)")
    all_ids = [i for s in seasons if s.ids for i in s.ids]
    dupes = {i for i in all_ids if all_ids.count(i) > 1}
    if dupes:
        raise SystemExit(f"mapping.toml: ids listed more than once: {sorted(dupes)}")
    return cfg, seasons


def youtube_id(name: str) -> str | None:
    m = YT_ID_RE.search(name)
    return m.group(1) if m else None


def media_stem(filename: str) -> str | None:
    """'Foo-[id].mkv' -> 'Foo-[id]'; returns None for non-media files."""
    p = PurePosixPath(filename)
    if p.suffix.lower() in MEDIA_EXTS:
        return p.stem
    return None


def strip_playlist_prefix(stem: str) -> tuple[int | None, str]:
    m = PLAYLIST_PREFIX_RE.match(stem)
    if m:
        return int(m.group(1)), stem[m.end() :]
    return None, stem


def safe_series_dirname(name: str) -> str:
    # Jellyfin reads the series name from tvshow.nfo; the folder just needs to be filesystem-safe.
    return re.sub(r"[/\\:*?\"<>|]", "-", name).strip()


def episode_filename(series: str, season: int, episode: int, rest_stem: str, ext: str, width: int) -> str:
    return f"{series} S{season:02d}E{episode:0{width}d} - {rest_stem}{ext}"


def tvshow_nfo(title: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8" standalone="yes"?>\n'
        f"<tvshow>\n  <title>{_xml(title)}</title>\n  <lockdata>false</lockdata>\n</tvshow>\n"
    )


def season_nfo(title: str, number: int) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8" standalone="yes"?>\n'
        f"<season>\n  <title>{_xml(title)}</title>\n  <seasonnumber>{number}</seasonnumber>\n"
        "  <lockdata>false</lockdata>\n</season>\n"
    )


def _xml(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# --------------------------------------------------------------------------- #
# plan
# --------------------------------------------------------------------------- #
def build_plan(
    listing: dict[str, list[str]],
    seasons: list[SeasonSpec],
    target_subdir: str,
    library_name: str,
    premiere_dates: dict[str, str],
) -> Plan:
    """listing: folder -> list of entry names (files and dirs) directly inside it.
    premiere_dates: youtube id -> ISO date (used to order id-based seasons)."""
    moves: list[Move] = []
    nfo: dict[str, str] = {}
    unmapped: list[str] = []
    assigned: dict[tuple[str, str], SeasonSpec] = {}  # (folder, media filename) -> season

    for season in seasons:
        entries = listing.get(season.folder)
        if entries is None:
            raise SystemExit(f"folder {season.folder!r} referenced by {season.series} S{season.number:02d} is not in the listing")
        media = [e for e in entries if media_stem(e)]
        if season.ids is None:
            chosen = media
        else:
            by_id = {youtube_id(e): e for e in media}
            missing = [i for i in season.ids if i not in by_id]
            if missing:
                raise SystemExit(f"{season.series} S{season.number:02d}: ids not found in {season.folder}/: {missing}")
            chosen = [by_id[i] for i in season.ids]
        for e in chosen:
            key = (season.folder, e)
            if key in assigned:
                raise SystemExit(f"{e} in {season.folder}/ assigned to two seasons")
            assigned[key] = season

    # strays: media files in referenced folders that no season claimed
    for folder in {s.folder for s in seasons}:
        for e in listing[folder]:
            if media_stem(e) and (folder, e) not in assigned:
                unmapped.append(f"{folder}/{e}")

    # group per season, number episodes, emit moves
    per_season: dict[tuple[str, int], list[tuple[str, str]]] = {}
    for (folder, fname), season in assigned.items():
        per_season.setdefault((season.series, season.number), []).append((folder, fname))
    spec_by_key = {(s.series, s.number): s for s in seasons}

    for (series, number), files in sorted(per_season.items()):
        spec = spec_by_key[(series, number)]
        season_dir = f"{target_subdir}/{safe_series_dirname(series)}/Season {number:02d}"
        nfo.setdefault(f"{target_subdir}/{safe_series_dirname(series)}/tvshow.nfo", tvshow_nfo(series))
        nfo[f"{season_dir}/season.nfo"] = season_nfo(spec.name or f"Season {number}", number)

        numbered: list[tuple[int, str, str, str]] = []  # (ep, folder, fname, rest_stem)
        if spec.ids is None:
            for folder, fname in files:
                stem = media_stem(fname) or ""
                n, rest = strip_playlist_prefix(stem)
                if n is None:
                    raise SystemExit(f"{folder}/{fname}: whole-folder season but no NNN- prefix")
                numbered.append((n, folder, fname, rest))
            nums = [n for n, *_ in numbered]
            if len(nums) != len(set(nums)):
                raise SystemExit(f"{series} S{number:02d}: duplicate NNN- prefixes")
        else:
            def sort_key(item: tuple[str, str]) -> tuple[str, str]:
                vid = youtube_id(item[1]) or ""
                return (premiere_dates.get(vid, "9999"), item[1].lower())

            for i, (folder, fname) in enumerate(sorted(files, key=sort_key), start=1):
                numbered.append((i, folder, fname, media_stem(fname) or ""))

        width = 3 if max(n for n, *_ in numbered) >= 100 else 2
        for ep, folder, fname, rest in sorted(numbered):
            vid = youtube_id(fname)
            old_stem = media_stem(fname) or ""
            new_stem = f"{series} S{number:02d}E{ep:0{width}d} - {rest}"
            ext = PurePosixPath(fname).suffix
            moves.append(Move(f"{folder}/{fname}", f"{season_dir}/{new_stem}{ext}", "media", vid, series, number, ep))
            # sidecars: anything in the folder that starts with the media stem (trickplay dir, .en.vtt, .jpg, ...)
            for other in listing[folder]:
                if other != fname and other.startswith(old_stem):
                    tail = other[len(old_stem) :]
                    kind = "dir" if tail == ".trickplay" else "sidecar"
                    moves.append(Move(f"{folder}/{other}", f"{season_dir}/{new_stem}{tail}", kind, vid, series, number, ep))

    # sanity: every destination unique, every media dst parses as SxxExx exactly once
    dsts = [m.dst for m in moves]
    if len(dsts) != len(set(dsts)):
        raise SystemExit("plan produced duplicate destinations")
    for m in moves:
        if m.kind == "media" and len(SXXEXX_RE.findall(PurePosixPath(m.dst).name)) != 1:
            raise SystemExit(f"destination does not contain exactly one SxxExx token: {m.dst}")
    return Plan(target_subdir, library_name, moves, nfo, unmapped)


def plan_markdown(plan: Plan) -> str:
    out = [f"# Plan: {plan.library_name}  ({len([m for m in plan.moves if m.kind == 'media'])} videos)\n"]
    if plan.unmapped:
        out.append("## UNMAPPED media (plan is INVALID until these are assigned or removed)\n")
        out += [f"- {u}" for u in plan.unmapped]
        out.append("")
    cur = None
    for m in plan.moves:
        if m.kind != "media":
            continue
        head = (m.series, m.season)
        if head != cur:
            cur = head
            out.append(f"\n## {m.series} — Season {m.season:02d}\n")
        out.append(f"- `{m.src}`\n  → `{m.dst}`")
    side = [m for m in plan.moves if m.kind != "media"]
    out.append(f"\n\n_{len(side)} sidecar/trickplay entries move alongside their videos; "
               f"{len(plan.nfo_files)} nfo files will be written._\n")
    return "\n".join(out)


def nas_listing(ssh_host: str, folders: list[str]) -> dict[str, list[str]]:
    script = "cd " + shlex.quote(NAS_PATH_ROOT) + " && for d in " + " ".join(shlex.quote(f) for f in folders) + \
        "; do echo \"## $d\"; /bin/ls -1A \"$d\"; done"
    res = subprocess.run(["ssh", "-o", "BatchMode=yes", ssh_host, script], check=True, capture_output=True, text=True)
    listing: dict[str, list[str]] = {}
    cur = None
    for line in res.stdout.splitlines():
        if line.startswith("## "):
            cur = line[3:]
            listing[cur] = []
        elif cur is not None and line:
            listing[cur].append(line)
    return listing


# --------------------------------------------------------------------------- #
# jellyfin api
# --------------------------------------------------------------------------- #
class Jellyfin:
    def __init__(self, url: str, key: str) -> None:
        self.url = url.rstrip("/")
        self.key = key

    def _req(self, method: str, path: str, params: dict[str, Any] | None = None, body: Any = None) -> Any:
        q = ("?" + urllib.parse.urlencode(params)) if params else ""
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path + q, data=data, method=method)
        req.add_header("Authorization", f'MediaBrowser Token="{self.key}", Client="fitness-migration", Device="cli", DeviceId="fitness-migration", Version="1"')
        if data is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return json.loads(raw) if raw else None

    def users(self) -> list[dict[str, Any]]:
        return self._req("GET", "/Users")

    def items(self, user_id: str, **params: Any) -> list[dict[str, Any]]:
        base = {"userId": user_id, "recursive": "true", "enableImages": "false"}
        base.update(params)
        return self._req("GET", "/Items", base)["Items"]

    def virtual_folders(self) -> list[dict[str, Any]]:
        return self._req("GET", "/Library/VirtualFolders")

    def update_user_data(self, user_id: str, item_id: str, data: dict[str, Any]) -> dict[str, Any]:
        return self._req("POST", f"/UserItems/{item_id}/UserData", {"userId": user_id}, data)

    def get_user_data(self, user_id: str, item_id: str) -> dict[str, Any]:
        return self._req("GET", f"/UserItems/{item_id}/UserData", {"userId": user_id})


def jf_from_env() -> Jellyfin:
    key = os.environ.get("JELLYFIN_API_KEY")
    if not key:
        raise SystemExit("JELLYFIN_API_KEY not set")
    return Jellyfin(os.environ.get("JELLYFIN_URL", "http://192.168.2.110:8096"), key)


def has_history(ud: dict[str, Any]) -> bool:
    return bool(ud.get("Played") or ud.get("PlaybackPositionTicks") or ud.get("IsFavorite") or ud.get("PlayCount"))


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_export_history(args: argparse.Namespace) -> None:
    _, seasons = load_mapping(args.mapping)
    folders = sorted({s.folder for s in seasons})
    prefixes = tuple(f"{JELLYFIN_PATH_ROOT}/{f}/" for f in folders)
    jf = jf_from_env()
    out: dict[str, Any] = {"folders": folders, "users": {}, "premiere_dates": {}, "items": {}}
    for u in jf.users():
        rows: list[dict[str, Any]] = []
        items = jf.items(u["Id"], includeItemTypes="Movie,Video", fields="Path,ProviderIds,PremiereDate")
        for it in items:
            p = it.get("Path") or ""
            if not p.startswith(prefixes):
                continue
            vid = (it.get("ProviderIds") or {}).get("YoutubeMetadata") or youtube_id(PurePosixPath(p).name)
            if not vid:
                print(f"  ! no youtube id for {p}", file=sys.stderr)
                continue
            out["items"][vid] = {"name": it.get("Name"), "path": p, "old_item_id": it["Id"]}
            if it.get("PremiereDate"):
                out["premiere_dates"][vid] = it["PremiereDate"][:10]
            ud = it.get("UserData") or {}
            if has_history(ud):
                rows.append({"youtube_id": vid, "name": it.get("Name"), "old_item_id": it["Id"],
                             "Played": bool(ud.get("Played")), "PlayCount": int(ud.get("PlayCount") or 0),
                             "PlaybackPositionTicks": int(ud.get("PlaybackPositionTicks") or 0),
                             "IsFavorite": bool(ud.get("IsFavorite")), "LastPlayedDate": ud.get("LastPlayedDate")})
        out["users"][u["Id"]] = {"name": u["Name"], "rows": rows}
        print(f"{u['Name']:>8}: {len(rows)} items with history (of {sum(1 for i in items if (i.get('Path') or '').startswith(prefixes))} in scope)")
    (args.workdir / "history.json").write_text(json.dumps(out, indent=2))
    print(f"wrote {args.workdir / 'history.json'}  ({len(out['items'])} items, {len(out['premiere_dates'])} premiere dates)")


def cmd_plan(args: argparse.Namespace) -> None:
    cfg, seasons = load_mapping(args.mapping)
    folders = sorted({s.folder for s in seasons})
    listing = nas_listing(args.nas, folders)
    (args.workdir / "listing.json").write_text(json.dumps(listing, indent=1))
    hist_path = args.workdir / "history.json"
    premiere = json.loads(hist_path.read_text())["premiere_dates"] if hist_path.exists() else {}
    if not premiere:
        print("warning: no history.json / premiere dates — id-based seasons will be ordered by filename", file=sys.stderr)
    plan = build_plan(listing, seasons, cfg["target_subdir"], cfg["library_name"], premiere)
    (args.workdir / "plan.json").write_text(json.dumps(asdict(plan), indent=1))
    (args.workdir / "plan.md").write_text(plan_markdown(plan))
    media = [m for m in plan.moves if m.kind == "media"]
    print(f"plan: {len(media)} videos, {len(plan.moves) - len(media)} sidecars, {len(plan.nfo_files)} nfo files -> {args.workdir / 'plan.md'}")
    if plan.unmapped:
        print(f"!! {len(plan.unmapped)} UNMAPPED media files — fix mapping.toml before apply-moves:", file=sys.stderr)
        for u in plan.unmapped:
            print(f"   {u}", file=sys.stderr)
        sys.exit(2)


def cmd_apply_moves(args: argparse.Namespace) -> None:
    plan_d = json.loads((args.workdir / "plan.json").read_text())
    if plan_d["unmapped"]:
        raise SystemExit("plan has unmapped files; refusing")
    moves = plan_d["moves"]
    # Build one bash script: mkdir -p dirs, then mv with -n (no clobber) and a
    # pre-flight that aborts if any destination exists or any source is missing.
    lines = ["set -euo pipefail", f"cd {shlex.quote(NAS_PATH_ROOT)}", "fail=0"]
    for m in moves:
        lines.append(f"[ -e {shlex.quote(m['src'])} ] || {{ echo MISSING-SRC {shlex.quote(m['src'])}; fail=1; }}")
        lines.append(f"[ ! -e {shlex.quote(m['dst'])} ] || {{ echo DST-EXISTS {shlex.quote(m['dst'])}; fail=1; }}")
    lines.append('[ "$fail" = 0 ] || { echo "pre-flight failed, nothing moved"; exit 3; }')
    dirs = sorted({str(PurePosixPath(m["dst"]).parent) for m in moves})
    for d in dirs:
        lines.append(f"mkdir -p {shlex.quote(d)}")
    for m in moves:
        lines.append(f"mv -n {shlex.quote(m['src'])} {shlex.quote(m['dst'])}")
    for rel, content in plan_d["nfo_files"].items():
        lines.append(f"cat > {shlex.quote(rel)} <<'NFO'\n{content}NFO")
    lines.append(f"echo moved {len(moves)} entries")
    script = "\n".join(lines) + "\n"
    (args.workdir / "apply-moves.sh").write_text(script)
    if args.dry_run:
        print(f"dry-run: script written to {args.workdir / 'apply-moves.sh'} ({len(moves)} moves); not executed")
        return
    res = subprocess.run(["ssh", "-o", "BatchMode=yes", args.nas, "bash -s"], input=script, text=True, capture_output=True)
    sys.stdout.write(res.stdout)
    sys.stderr.write(res.stderr)
    if res.returncode != 0:
        raise SystemExit(f"apply-moves failed with {res.returncode}")


def cmd_apply_history(args: argparse.Namespace) -> None:
    hist = json.loads((args.workdir / "history.json").read_text())
    plan_d = json.loads((args.workdir / "plan.json").read_text())
    jf = jf_from_env()
    lib = next((v for v in jf.virtual_folders() if v["Name"] == plan_d["library_name"]), None)
    if not lib:
        raise SystemExit(f"library {plan_d['library_name']!r} not found — create and scan it first")
    report: list[str] = []
    for uid, u in hist["users"].items():
        if not u["rows"]:
            continue
        eps = jf.items(uid, parentId=lib["ItemId"], includeItemTypes="Episode", fields="Path,ProviderIds")
        by_vid: dict[str, dict[str, Any]] = {}
        for e in eps:
            vid = (e.get("ProviderIds") or {}).get("YoutubeMetadata") or youtube_id(PurePosixPath(e.get("Path") or "").name)
            if vid:
                by_vid[vid] = e
        ok = missing = 0
        for row in u["rows"]:
            ep = by_vid.get(row["youtube_id"])
            if not ep:
                missing += 1
                report.append(f"{u['name']}: NO MATCH for {row['youtube_id']} ({row['name']})")
                continue
            body = {"Played": row["Played"], "PlayCount": row["PlayCount"],
                    "PlaybackPositionTicks": row["PlaybackPositionTicks"], "IsFavorite": row["IsFavorite"]}
            if row.get("LastPlayedDate"):
                body["LastPlayedDate"] = row["LastPlayedDate"]
            if args.dry_run:
                report.append(f"{u['name']}: would set {body} on {ep['Name']}")
                ok += 1
                continue
            jf.update_user_data(uid, ep["Id"], body)
            back = jf.get_user_data(uid, ep["Id"])
            if bool(back.get("Played")) != row["Played"] or int(back.get("PlaybackPositionTicks") or 0) != row["PlaybackPositionTicks"]:
                report.append(f"{u['name']}: VERIFY FAILED on {ep['Name']}: sent {body} got {back}")
            else:
                ok += 1
        print(f"{u['name']:>8}: {ok} applied, {missing} unmatched")
    (args.workdir / "apply-history.log").write_text("\n".join(report) + "\n")
    for r in report:
        print("  " + r)


# --------------------------------------------------------------------------- #
# nfo sidecars
# --------------------------------------------------------------------------- #
def episode_nfo(title: str, show: str, season: int, episode: int, plot: str | None, aired: str | None,
                year: int | None, youtube_id: str | None, uploader: str | None = None) -> str:
    lines = ['<?xml version="1.0" encoding="utf-8" standalone="yes"?>', "<episodedetails>",
             f"  <title>{_xml(title)}</title>", f"  <showtitle>{_xml(show)}</showtitle>",
             f"  <season>{season}</season>", f"  <episode>{episode}</episode>"]
    if plot:
        lines.append(f"  <plot>{_xml(plot)}</plot>")
    if aired:
        lines.append(f"  <aired>{_xml(aired[:10])}</aired>")
    if year:
        lines.append(f"  <year>{year}</year>")
    if uploader:
        lines.append(f"  <studio>{_xml(uploader)}</studio>")
    lines.append(f"  <sorttitle>{_xml(title)}</sorttitle>")
    if youtube_id:
        lines.append(f'  <uniqueid type="YoutubeMetadata" default="true">{_xml(youtube_id)}</uniqueid>')
    lines += ["  <lockdata>false</lockdata>", "</episodedetails>", ""]
    return "\n".join(lines)


def looks_like_filename_title(name: str) -> bool:
    """True when Jellyfin fell back to the filename (no real metadata was fetched)."""
    return bool(SXXEXX_RE.search(name)) and " - " in name


EPISODE_TYPE_OPTIONS = [
    {"Type": "Series", "MetadataFetchers": [], "MetadataFetcherOrder": [], "ImageFetchers": [], "ImageFetcherOrder": [], "ImageOptions": []},
    {"Type": "Season", "MetadataFetchers": [], "MetadataFetcherOrder": [], "ImageFetchers": [], "ImageFetcherOrder": [], "ImageOptions": []},
    {"Type": "Episode", "MetadataFetchers": [], "MetadataFetcherOrder": [],
     # provider *display* names, with spaces — "ScreenGrabber" silently matches nothing
     "ImageFetchers": ["Embedded Image Extractor", "Screen Grabber"], "ImageFetcherOrder": ["Embedded Image Extractor", "Screen Grabber"], "ImageOptions": []},
]


def cmd_fix_library_options(args: argparse.Namespace) -> None:
    plan_d = json.loads((args.workdir / "plan.json").read_text())
    jf = jf_from_env()
    lib = next((v for v in jf.virtual_folders() if v["Name"] == plan_d["library_name"]), None)
    if not lib:
        raise SystemExit("library not found")
    opts = lib["LibraryOptions"]
    opts["TypeOptions"] = EPISODE_TYPE_OPTIONS
    opts["LocalMetadataReaderOrder"] = ["Nfo"]
    opts["DisabledLocalMetadataReaders"] = ["YoutubeMetadata"]
    opts["EnableRealtimeMonitor"] = False
    jf._req("POST", "/Library/VirtualFolders/LibraryOptions", None, {"Id": lib["ItemId"], "LibraryOptions": opts})
    lib = next(v for v in jf.virtual_folders() if v["Name"] == plan_d["library_name"])
    lo = lib["LibraryOptions"]
    print("fetchers now:", [(t["Type"], t["MetadataFetchers"], t["ImageFetchers"]) for t in lo["TypeOptions"]])
    print("local readers:", lo["LocalMetadataReaderOrder"], "disabled:", lo["DisabledLocalMetadataReaders"], "realtime:", lo["EnableRealtimeMonitor"])


def cmd_write_nfo(args: argparse.Namespace) -> None:
    import io
    import tarfile

    plan_d = json.loads((args.workdir / "plan.json").read_text())
    fallback_path = args.workdir / "metadata-sources.json"
    sources = json.loads(fallback_path.read_text()) if fallback_path.exists() else {}
    snapshot = sources.get("api", {})  # API metadata captured before any destructive refresh
    fallback = sources.get("old", {})  # old-library DB rows keyed by YouTube ID
    jf = jf_from_env()
    lib = next(v for v in jf.virtual_folders() if v["Name"] == plan_d["library_name"])
    uid = next(u["Id"] for u in jf.users())
    eps = jf.items(uid, parentId=lib["ItemId"], includeItemTypes="Episode", enableImages="true",
                   fields="Path,ProviderIds,Overview,PremiereDate,ProductionYear,People", limit=2000)
    by_path = {e["Path"]: e for e in eps}
    buf = io.BytesIO()
    tar = tarfile.open(fileobj=buf, mode="w")
    n_nfo = n_img = n_fallback = n_nodata = 0
    for rel, content in plan_d["nfo_files"].items():  # tvshow.nfo / season.nfo (Jellyfin may have rewritten them)
        data = content.encode()
        ti = tarfile.TarInfo(rel); ti.size = len(data); ti.mode = 0o664
        tar.addfile(ti, io.BytesIO(data))
    for m in plan_d["moves"]:
        if m["kind"] != "media":
            continue
        dst = m["dst"]
        stem = str(PurePosixPath(dst).with_suffix(""))
        e = by_path.get(f"{JELLYFIN_PATH_ROOT}/{dst}")
        vid = m["youtube_id"]
        title = plot = aired = None
        year = None
        uploader = None
        if e and e.get("Overview") and not looks_like_filename_title(e["Name"]):
            title, plot, aired, year = e["Name"], e.get("Overview"), e.get("PremiereDate"), e.get("ProductionYear")
            ppl = e.get("People") or []
            uploader = ppl[0]["Name"] if ppl else None
        elif vid and vid in snapshot and snapshot[vid].get("overview"):
            f = snapshot[vid]
            title, plot, aired, year = f["name"], f.get("overview"), f.get("premiere"), f.get("year")
            uploader = (f.get("people") or [None])[0]
        elif vid and vid in fallback:
            f = fallback[vid]
            title, plot, aired, year = f["name"], f.get("overview"), f.get("premiere"), f.get("year")
            n_fallback += 1
        else:
            n_nodata += 1
            title = PurePosixPath(dst).stem.split(" - ", 1)[-1]
        plot = clean_overview(plot, uploader, aired) if plot else (clean_overview("", uploader, aired) or None)
        content = episode_nfo(title, m["series"], m["season"], m["episode"], plot, aired, year, vid, uploader).encode()
        ti = tarfile.TarInfo(stem + ".nfo"); ti.size = len(content); ti.mode = 0o664
        tar.addfile(ti, io.BytesIO(content)); n_nfo += 1
        if e and not args.no_images and "Primary" in (e.get("ImageTags") or {}):
            req = urllib.request.Request(f"{jf.url}/Items/{e['Id']}/Images/Primary?format=Jpg&quality=90")
            req.add_header("Authorization", f'MediaBrowser Token="{jf.key}", Client="fitness-migration", Device="cli", DeviceId="fitness-migration", Version="1"')
            with urllib.request.urlopen(req, timeout=60) as r:
                img = r.read(); ctype = r.headers.get("Content-Type", "")
            ext = ".webp" if "webp" in ctype else ".png" if "png" in ctype else ".jpg"
            ti = tarfile.TarInfo(stem + "-thumb" + ext); ti.size = len(img); ti.mode = 0o664
            tar.addfile(ti, io.BytesIO(img)); n_img += 1
    tar.close()
    print(f"nfo: {n_nfo} (fallback data: {n_fallback}, no data: {n_nodata})  thumbs: {n_img}  tar: {buf.tell()/1e6:.1f} MB")
    if args.dry_run:
        out = args.workdir / "nfo-preview"
        out.mkdir(exist_ok=True)
        buf.seek(0)
        with tarfile.open(fileobj=buf) as t:
            t.extractall(out, filter="data")
        print(f"dry-run: extracted under {out}")
        return
    res = subprocess.run(["ssh", "-o", "BatchMode=yes", args.nas, f"cd {shlex.quote(NAS_PATH_ROOT)} && tar -xf - && echo extracted"],
                         input=buf.getvalue(), capture_output=True)
    sys.stdout.write(res.stdout.decode()); sys.stderr.write(res.stderr.decode())
    if res.returncode != 0:
        raise SystemExit("upload failed")


def cmd_refresh(args: argparse.Namespace) -> None:
    import time

    plan_d = json.loads((args.workdir / "plan.json").read_text())
    jf = jf_from_env()
    lib = next(v for v in jf.virtual_folders() if v["Name"] == plan_d["library_name"])
    uid = next(u["Id"] for u in jf.users())
    # NOTE: ReplaceAllMetadata=true must NOT be used here. Observed on 10.11.11: it nulls every
    # episode's IndexNumber/Overview and the nfo reader does not repopulate them, whereas a plain
    # FullRefresh re-parses SxxExx from the filename (FillMissingEpisodeNumbersFromPath) and reads
    # the nfo sidecars.
    jf._req("POST", f"/Items/{lib['ItemId']}/Refresh", {"Recursive": "true", "MetadataRefreshMode": "FullRefresh",
            "ImageRefreshMode": "Default", "ReplaceAllMetadata": "false", "ReplaceAllImages": "false"})
    expected = {f"{JELLYFIN_PATH_ROOT}/{m['dst']}": (m["season"], m["episode"]) for m in plan_d["moves"] if m["kind"] == "media"}
    t0 = time.time(); last = None
    while time.time() - t0 < args.wait:
        eps = jf.items(uid, parentId=lib["ItemId"], includeItemTypes="Episode", fields="Path,ProviderIds,Overview", limit=2000)
        ok = sum(1 for e in eps if expected.get(e.get("Path")) == (e.get("ParentIndexNumber"), e.get("IndexNumber")))
        named = sum(1 for e in eps if not looks_like_filename_title(e["Name"]))
        ov = sum(1 for e in eps if e.get("Overview"))
        cur = (len(eps), ok, named, ov)
        if cur != last:
            print(f"t+{int(time.time()-t0):3}s episodes={len(eps)} numbers-ok={ok} real-titles={named} overview={ov}", flush=True); last = cur
        if len(eps) == len(expected) == ok == named and ov >= len(eps) - 5:
            break
        time.sleep(20)
    bad = [(e["Path"].rsplit("/", 1)[1], e.get("ParentIndexNumber"), e.get("IndexNumber")) for e in eps
           if expected.get(e.get("Path")) != (e.get("ParentIndexNumber"), e.get("IndexNumber"))]
    seasons = jf.items(uid, parentId=lib["ItemId"], includeItemTypes="Season", limit=100)
    print("seasons:", sorted((s.get("SeriesName"), s.get("IndexNumber"), s["Name"]) for s in seasons))
    print(f"mismatched numbers: {len(bad)}")
    for b in bad[:20]:
        print("  ", b)


# --------------------------------------------------------------------------- #
# overview cleaning — YouTube descriptions are mostly links/merch/"follow me"
# --------------------------------------------------------------------------- #
_URL_RE = re.compile(r"(https?://|www\.|\b[a-z0-9.-]+\.(com|net|org|io|ly|gg|tv|co|online|me|uk|app)\b(/|\b))", re.I)
_BOILER_RE = re.compile(
    r"^(follow( me| us| along)?\b|subscribe|join (us|our|the crew|here|now|my (discord|patreon|channel|community|newsletter))\b|shop\b|support (this|us|the|me|our)\b|patreon|merch|"
    r"music (i use|by|score)|faq|instagram|twitter|facebook|tiktok|discord|sponsor|use code|check out|sign ?up|tag us|"
    r"get the bonus|thanks?( you)? for (watching|reading|listening)|my favou?rite gear|gear i use|what (workout )?gear|"
    r"what'?s your camera|podcast credit|produced|directed|director of|edited by|filmed by|shot by|source:|"
    r"full .{0,30}protocol|home gym|timestamps?|chapters?|have any questions|questions\?|leave a comment|comment below|"
    r"let me know|like and|hit the|turn on notifications|#|\W*$)", re.I)
_PROMO_RE = re.compile(r"(discount|coupon|promo|\bcode\b|% ?off|offer|seminar|click|link below|sign ?up|training today|teacher training|"
                       r"for purchase|limited time|free trial|download the app|available now)", re.I)
_SENTENCE_RE = re.compile(r"[.!?…]")
_LABEL_RE = re.compile(r"^.{1,60}[:：]\s*$")  # "Kilian's equipment in the video:" / "FAQ & ANSWERS:" — a header for a list
_TIMESTAMP_RE = re.compile(r"^\(?\d{1,2}:\d{2}")
_BULLET_RE = re.compile(r"^[\s•►▶\-—–*·>]+")


def _prose_lines(paragraph: str) -> list[str]:
    keep: list[str] = []
    lines = [ln.strip() for ln in paragraph.splitlines() if ln.strip()]
    if lines and sum(1 for ln in lines if _BULLET_RE.match(ln) and _BULLET_RE.match(ln).end() > 0) > len(lines) / 2:  # type: ignore[union-attr]
        return []  # a gear / sponsor list
    for ln in lines:
        core = _BULLET_RE.sub("", ln)
        had_url = bool(_URL_RE.search(core))
        if had_url:  # keep a real sentence that merely ends with a link; drop "Label: URL" lines
            core = re.sub(r"(\(?(https?://|www\.)\S+\)?|\b\S+\.(com|net|org|io|gg|tv|ly|me|app|online|uk|us)\S*)", "", core, flags=re.I)
            core = re.sub(r"[\s➡️→>:\-–—|]+$", "", core).strip()
            if len(core) < 40 or not _SENTENCE_RE.search(core):
                continue
        if _TIMESTAMP_RE.match(core) or _BOILER_RE.match(core) or _LABEL_RE.match(core) or _PROMO_RE.search(core):
            continue
        core = re.sub(r"\s*#\w+", "", core)
        core = re.sub(r"[\u2066-\u2069\u200b-\u200f]", "", core).strip()  # bidi isolates / zero-width junk
        if len(core) >= 3:
            keep.append(core)
    text = " ".join(keep)
    if keep:
        words = text.split()
        caps = sum(1 for w in words if w.isupper() or w[:1].isupper()) / max(1, len(words))
        if not _SENTENCE_RE.search(text) and (len(text) < 80 or caps > 0.5):
            return []  # a link label, slogan or product catalogue, not a description
        if len(words) >= 3 and sum(1 for w in words if w.isupper()) / len(words) > 0.7:
            return []  # "BELLS OF STEEL, INC." / shouty sponsor lines
    return keep


def clean_overview(raw: str | None, uploader: str | None = None, aired: str | None = None, limit: int = 480) -> str:
    """Header line '<uploader> · <d Mon YYYY>' + the first real prose paragraph(s) of a YouTube
    description, with link/merch/social/gear boilerplate removed and the body capped at ~limit chars
    on a sentence boundary."""
    header = " · ".join(x for x in (uploader, _nice_date(aired)) if x)
    body_parts: list[str] = []
    for idx, para in enumerate(re.split(r"\n\s*\n", (raw or "").replace("\r", ""))):
        lines = _prose_lines(para)
        if not lines:
            continue
        text = " ".join(lines)
        # short fragments ("These are not 6 week programs.") are slogans unless they open the description
        if len(text) < 60 and not (idx == 0 and _SENTENCE_RE.search(text) and len(text) >= 25):
            continue
        body_parts.append(text)
        if sum(len(b) for b in body_parts) >= 120:
            break
    body = "\n\n".join(body_parts)
    if len(body) > limit:
        cut = body[:limit]
        end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
        body = (cut[: end + 1] if end > limit // 2 else cut.rstrip() + "…")
    return (header + ("\n\n" + body if body else "")).strip()


def _nice_date(iso: str | None) -> str | None:
    if not iso:
        return None
    try:
        from datetime import date
        d = date.fromisoformat(iso[:10])
        return f"{d.day} {d.strftime('%b %Y')}"
    except ValueError:
        return iso[:10]


def cmd_fix_overviews(args: argparse.Namespace) -> None:
    """Rewrite every episode's Overview in Jellyfin (API item update) from the raw description in
    the metadata snapshot; pair with `write-nfo` (which applies the same cleaning) to keep the
    on-disk nfo in step."""
    plan_d = json.loads((args.workdir / "plan.json").read_text())
    sources = json.loads((args.workdir / "metadata-sources.json").read_text())
    raw: dict[str, dict[str, Any]] = {}
    for part in ("old", "api"):
        for vid, d in sources.get(part, {}).items():
            if d.get("overview") or vid not in raw:
                raw[vid] = d
    jf = jf_from_env()
    lib = next(v for v in jf.virtual_folders() if v["Name"] == plan_d["library_name"])
    uid = next(u["Id"] for u in jf.users())
    eps = jf.items(uid, parentId=lib["ItemId"], includeItemTypes="Episode", fields="Path,ProviderIds,Overview,PremiereDate,People", limit=2000)
    n = 0
    for e in eps:
        vid = (e.get("ProviderIds") or {}).get("YoutubeMetadata") or youtube_id(e["Path"])
        src = raw.get(vid or "", {})
        ppl = e.get("People") or []
        uploader = (ppl[0]["Name"] if ppl else None) or (src.get("people") or [None])[0]
        new = clean_overview(src.get("overview") or e.get("Overview"), uploader, e.get("PremiereDate") or src.get("premiere"))
        if new == (e.get("Overview") or ""):
            continue
        dto = jf._req("GET", f"/Users/{uid}/Items/{e['Id']}", {"fields": UPDATE_FIELDS})
        dto["Overview"] = new
        jf._req("POST", f"/Items/{e['Id']}", None, dto)
        n += 1
    print(f"overviews rewritten: {n} of {len(eps)}")


UPDATE_FIELDS = ("Overview,Genres,Tags,Studios,People,ProviderIds,PremiereDate,ProductionYear,DateCreated,OriginalTitle,"
                 "Taglines,SortName,ForcedSortName,OfficialRating,CustomRating,CommunityRating,CriticRating,LockData,LockedFields,"
                 "Path,DisplayOrder,PreferredMetadataLanguage,PreferredMetadataCountryCode,AirsBeforeSeasonNumber,"
                 "AirsAfterSeasonNumber,AirsBeforeEpisodeNumber,EndDate,ParentId,SeriesId,SeasonId,Chapters,ExternalUrls,"
                 "Container,MediaSources,DateLastMediaAdded,Status,AirTime,AirDays,RunTimeTicks")


def cmd_fix_names(args: argparse.Namespace) -> None:
    """Post-refresh cosmetics a non-replace refresh cannot do: it never overwrites an existing
    Name or ForcedSortName, so episodes the plugin had already touched keep its date-based forced
    sort, filename-titled episodes keep the filename, and seasons keep "Season NN"."""
    plan_d = json.loads((args.workdir / "plan.json").read_text())
    _, seasons = load_mapping(args.mapping)
    season_names = {(s.series, s.number): s.name for s in seasons if s.name}
    src_path = args.workdir / "metadata-sources.json"
    sources = json.loads(src_path.read_text()) if src_path.exists() else {}
    titles: dict[str, str] = {}
    for part in ("api", "old"):  # prefer the plugin-fetched title, but never a filename-derived one
        for vid, d in sources.get(part, {}).items():
            if d.get("name") and not looks_like_filename_title(d["name"]) and vid not in titles:
                titles[vid] = d["name"]
    jf = jf_from_env()
    lib = next(v for v in jf.virtual_folders() if v["Name"] == plan_d["library_name"])
    uid = next(u["Id"] for u in jf.users())

    def update(item_id: str, **changes: Any) -> dict[str, Any]:
        before = jf._req("GET", f"/Users/{uid}/Items/{item_id}", {"fields": UPDATE_FIELDS})
        dto = dict(before); dto.update(changes)
        jf._req("POST", f"/Items/{item_id}", None, dto)
        after = jf._req("GET", f"/Users/{uid}/Items/{item_id}", {"fields": UPDATE_FIELDS})
        ignore = {"DateLastSaved", "Etag", "ImageBlurHashes", "ImageTags", "UserData", "SortName", "ForcedSortName", "Name"}
        unexpected = {k for k in set(before) | set(after) if k not in ignore and before.get(k) != after.get(k)}
        if unexpected:
            print(f"  ! unexpected field changes on {item_id}: {sorted(unexpected)}")
        return after

    eps = jf.items(uid, parentId=lib["ItemId"], includeItemTypes="Episode", fields="Path,ForcedSortName,ProviderIds", enableImages="true", limit=2000)
    n_sort = n_name = 0
    for e in eps:
        changes: dict[str, Any] = {}
        if e.get("ForcedSortName") or args.force_sort:
            changes["ForcedSortName"] = ""
        if looks_like_filename_title(e["Name"]):
            vid = (e.get("ProviderIds") or {}).get("YoutubeMetadata") or youtube_id(e["Path"])
            if vid in titles:
                changes["Name"] = titles[vid]
        if changes:
            update(e["Id"], **changes)
            n_sort += "ForcedSortName" in changes; n_name += "Name" in changes
    print(f"episodes: cleared forced sort on {n_sort}, renamed {n_name}")
    n_season = 0
    for s in jf.items(uid, parentId=lib["ItemId"], includeItemTypes="Season", fields="Path", limit=200):
        want = season_names.get((s.get("SeriesName"), s.get("IndexNumber")))
        if want and s["Name"] != want:
            update(s["Id"], Name=want); n_season += 1
    print(f"seasons renamed: {n_season}")
    noimg = [e for e in eps if "Primary" not in (e.get("ImageTags") or {})]
    for e in noimg:
        jf._req("POST", f"/Items/{e['Id']}/Refresh", {"MetadataRefreshMode": "None", "ImageRefreshMode": "FullRefresh", "ReplaceAllImages": "false"})
    print(f"image refresh requested for {len(noimg)} episodes without a primary image")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workdir", type=Path, default=Path.cwd(), help="where state files are written")
    ap.add_argument("--mapping", type=Path, default=Path(__file__).with_name("mapping.toml"))
    ap.add_argument("--nas", default=os.environ.get("NAS_SSH_HOST", "nas"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("export-history").set_defaults(fn=cmd_export_history)
    sub.add_parser("plan").set_defaults(fn=cmd_plan)
    p = sub.add_parser("apply-moves"); p.add_argument("--dry-run", action="store_true"); p.set_defaults(fn=cmd_apply_moves)
    p = sub.add_parser("apply-history"); p.add_argument("--dry-run", action="store_true"); p.set_defaults(fn=cmd_apply_history)
    sub.add_parser("fix-library-options").set_defaults(fn=cmd_fix_library_options)
    p = sub.add_parser("write-nfo"); p.add_argument("--dry-run", action="store_true"); p.add_argument("--no-images", action="store_true"); p.set_defaults(fn=cmd_write_nfo)
    p = sub.add_parser("refresh"); p.add_argument("--wait", type=int, default=900); p.set_defaults(fn=cmd_refresh)
    p = sub.add_parser("fix-names"); p.add_argument("--force-sort", action="store_true"); p.set_defaults(fn=cmd_fix_names)
    sub.add_parser("fix-overviews").set_defaults(fn=cmd_fix_overviews)
    args = ap.parse_args(argv)
    args.workdir.mkdir(parents=True, exist_ok=True)
    args.fn(args)


if __name__ == "__main__":
    main()
