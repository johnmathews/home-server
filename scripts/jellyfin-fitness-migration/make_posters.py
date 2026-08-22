#!/usr/bin/env python3
"""Generate unique, labelled posters for every series and season of the
Health & Fitness library, ship them to the NAS, and make Jellyfin pick them up.

Why: the YouTube Metadata plugin's *series* provider searches YouTube for the
series name and attaches a random channel's avatar + "about" text as the series
poster/overview, and Jellyfin shows a season with no image of its own with the
series image — so every season of a series looked identical.

Poster design (2:3, 1000x1500): the thumbnail of the season's FIRST episode,
full width and uncropped, over a blurred/darkened copy of itself that fills the
portrait canvas, plus a dark band with the season name (and series name,
smaller) at the bottom. Series posters use the first episode of the first
season. (An earlier 3-thumbnail stack was judged confusing.)

Output: <out>/fitness/<Series>/poster.jpg and <out>/fitness/<Series>/Season NN/folder.jpg
(Jellyfin's local image names for series and season primaries), then uploaded
to the NAS and image-refreshed (series/season items only; ReplaceAllImages).

Run:  JELLYFIN_API_KEY=... uv run --python 3.13 --with pillow scripts/jellyfin-fitness-migration/make_posters.py --workdir scripts/jellyfin-fitness-migration/state [--dry-run]
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shlex
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any

W, H = 1000, 1500
BAND_H = 260
FONT_CANDIDATES = ["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]
FONT_REG_CANDIDATES = ["/System/Library/Fonts/Supplemental/Arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]


def foreground_box(img_w: int, img_h: int, width: int = W, height: int = H, band: int = BAND_H) -> tuple[int, int, int, int]:
    """Box (x0, y0, x1, y1) for the sharp, uncropped thumbnail: full width, centred vertically in
    the area above the title band. Pure, testable."""
    fh = round(width * img_h / max(1, img_w))
    fh = min(fh, height - band)
    y0 = (height - band - fh) // 2
    return (0, y0, width, y0 + fh)


def _font(size: int, bold: bool = True):  # type: ignore[no-untyped-def]
    from PIL import ImageFont
    for c in FONT_CANDIDATES if bold else FONT_REG_CANDIDATES:
        if Path(c).exists():
            return ImageFont.truetype(c, size)
    return ImageFont.load_default()


def _cover(img, box):  # type: ignore[no-untyped-def]
    """Scale+centre-crop img to fill box."""
    from PIL import Image
    bw, bh = box[2] - box[0], box[3] - box[1]
    s = max(bw / img.width, bh / img.height)
    r = img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.LANCZOS)
    x = (r.width - bw) // 2
    y = (r.height - bh) // 2
    return r.crop((x, y, x + bw, y + bh))


def compose(thumb: bytes | None, title: str, subtitle: str | None) -> bytes:
    from PIL import Image, ImageDraw, ImageEnhance, ImageFilter
    img = Image.open(io.BytesIO(thumb)).convert("RGB") if thumb else Image.new("RGB", (16, 9), (40, 40, 44))
    # background: the same image, cover-cropped to the full canvas, blurred and darkened
    bg = _cover(img, (0, 0, W, H)).filter(ImageFilter.GaussianBlur(28))
    canvas = ImageEnhance.Brightness(bg).enhance(0.45)
    # foreground: the thumbnail itself, full width, uncropped
    box = foreground_box(img.width, img.height)
    fg = img.resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS)
    canvas.paste(fg, (box[0], box[1]))
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rectangle((0, H - BAND_H, W, H), fill=(12, 12, 14, 235))
    draw.rectangle((0, H - BAND_H, W, H - BAND_H + 6), fill=(0, 164, 220, 255))  # jellyfin-ish accent line
    size = 96
    while size > 40 and draw.textlength(title, font=_font(size)) > W - 100:
        size -= 6
    f = _font(size)
    y = H - BAND_H + (BAND_H - size - (56 if subtitle else 0)) // 2
    draw.text(((W - draw.textlength(title, font=f)) / 2, y), title, font=f, fill=(245, 245, 245, 255))
    if subtitle:
        fs = _font(40, bold=False)
        draw.text(((W - draw.textlength(subtitle, font=fs)) / 2, y + size + 18), subtitle, font=fs, fill=(190, 190, 195, 255))
    out = io.BytesIO()
    canvas.save(out, "JPEG", quality=88, optimize=True)
    return out.getvalue()


class Jellyfin:
    def __init__(self) -> None:
        self.url = os.environ.get("JELLYFIN_URL", "http://192.168.2.110:8096").rstrip("/")
        self.key = os.environ["JELLYFIN_API_KEY"]

    def req(self, method: str, path: str, params: dict[str, Any] | None = None, body: Any = None, raw: bool = False) -> Any:
        q = ("?" + urllib.parse.urlencode(params)) if params else ""
        r = urllib.request.Request(self.url + path + q, data=json.dumps(body).encode() if body is not None else None, method=method)
        r.add_header("Authorization", f'MediaBrowser Token="{self.key}", Client="fitness-migration", Device="cli", DeviceId="fitness-migration", Version="1"')
        r.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(r, timeout=120) as resp:
            data = resp.read()
            return data if raw else (json.loads(data) if data else None)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", type=Path, required=True)
    ap.add_argument("--nas", default=os.environ.get("NAS_SSH_HOST", "nas"))
    ap.add_argument("--nas-root", default="/mnt/tank/movies/youtube")
    ap.add_argument("--dry-run", action="store_true", help="write posters under --workdir/posters only")
    a = ap.parse_args()
    plan = json.loads((a.workdir / "plan.json").read_text())
    jf = Jellyfin()
    lib = next(v for v in jf.req("GET", "/Library/VirtualFolders") if v["Name"] == plan["library_name"])
    uid = next(u["Id"] for u in jf.req("GET", "/Users"))
    q = {"userId": uid, "parentId": lib["ItemId"], "recursive": "true", "enableImages": "true", "limit": 2000, "fields": "Path"}
    series = jf.req("GET", "/Items", {**q, "includeItemTypes": "Series"})["Items"]
    seasons = jf.req("GET", "/Items", {**q, "includeItemTypes": "Season"})["Items"]
    episodes = jf.req("GET", "/Items", {**q, "includeItemTypes": "Episode"})["Items"]

    def thumb(ep: dict[str, Any]) -> bytes | None:
        if "Primary" not in (ep.get("ImageTags") or {}):
            return None
        return jf.req("GET", f"/Items/{ep['Id']}/Images/Primary", {"format": "Jpg", "maxWidth": "1000"}, raw=True)

    by_season: dict[str, list[dict[str, Any]]] = {}
    for e in episodes:
        by_season.setdefault(e["SeasonId"], []).append(e)
    for v in by_season.values():
        v.sort(key=lambda e: (e.get("IndexNumber") or 0, e["Name"]))

    files: dict[str, bytes] = {}  # relative path under nas-root -> bytes
    series_first: dict[str, bytes] = {}  # series id -> first episode thumb of its first season
    for s in sorted(seasons, key=lambda s: (s.get("SeriesName"), s.get("IndexNumber") or 0)):
        eps = by_season.get(s["Id"], [])
        first = next((t for t in (thumb(e) for e in eps[:6]) if t), None)
        if first is None:
            print(f"  ! no thumbnail for {s.get('SeriesName')} / {s['Name']}", file=sys.stderr)
        season_dir = str(PurePosixPath(s["Path"]).relative_to("/movies/youtube"))
        files[f"{season_dir}/folder.jpg"] = compose(first, s["Name"], s.get("SeriesName"))
        if first is not None:
            series_first.setdefault(s["SeriesId"], first)
    for sr in series:
        series_dir = str(PurePosixPath(sr["Path"]).relative_to("/movies/youtube"))
        files[f"{series_dir}/poster.jpg"] = compose(series_first.get(sr["Id"]), sr["Name"], None)
    print(f"generated {len(files)} posters ({len(series)} series, {len(seasons)} seasons)")

    if a.dry_run:
        out = a.workdir / "posters"
        for rel, data in files.items():
            p = out / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        print(f"dry-run: written under {out}")
        return

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for rel, data in files.items():
            ti = tarfile.TarInfo(rel); ti.size = len(data); ti.mode = 0o664
            tar.addfile(ti, io.BytesIO(data))
    res = subprocess.run(["ssh", "-o", "BatchMode=yes", a.nas, f"cd {shlex.quote(a.nas_root)} && tar -xf - && echo uploaded"],
                         input=buf.getvalue(), capture_output=True)
    sys.stdout.write(res.stdout.decode()); sys.stderr.write(res.stderr.decode())
    if res.returncode != 0:
        raise SystemExit("upload failed")

    # Overviews: the plugin attached a random channel's "about" text to each series. Replace with a
    # one-line description listing the seasons (UpdateItem round-trip; only Overview changes).
    fields = ("Overview,Genres,Tags,Studios,People,ProviderIds,PremiereDate,ProductionYear,DateCreated,OriginalTitle,Taglines,"
              "SortName,ForcedSortName,OfficialRating,CustomRating,CommunityRating,CriticRating,LockData,LockedFields,Path,DisplayOrder,"
              "PreferredMetadataLanguage,PreferredMetadataCountryCode,EndDate,Status,AirTime,AirDays,ExternalUrls,DateLastMediaAdded,RunTimeTicks")
    for sr in series:
        names = [s["Name"] for s in sorted(seasons, key=lambda s: s.get("IndexNumber") or 0) if s["SeriesId"] == sr["Id"]]
        dto = jf.req("GET", f"/Users/{uid}/Items/{sr['Id']}", {"fields": fields})
        dto["Overview"] = f"{sr['Name']} — " + ", ".join(names) if names else sr["Name"]
        jf.req("POST", f"/Items/{sr['Id']}", None, dto)
    print(f"series overviews replaced: {len(series)}")

    # Image refresh for series + seasons only (metadata untouched), replacing the plugin's images.
    targets = series + seasons
    for it in targets:
        jf.req("POST", f"/Items/{it['Id']}/Refresh", {"MetadataRefreshMode": "None", "ImageRefreshMode": "FullRefresh", "ReplaceAllImages": "true"})
    time.sleep(20)
    hashes: dict[str, str] = {}
    for it in targets:
        cur = next(x for x in jf.req("GET", "/Items", {"userId": uid, "ids": it["Id"], "enableImages": "true"})["Items"])
        if "Primary" in (cur.get("ImageTags") or {}):
            hashes[f"{it.get('SeriesName') or it['Name']} / {it['Name']}"] = hashlib.md5(
                jf.req("GET", f"/Items/{it['Id']}/Images/Primary", {"format": "Jpg", "maxWidth": "200"}, raw=True)).hexdigest()[:10]
    dup = len(hashes) - len(set(hashes.values()))
    print(f"primary images present on {len(hashes)}/{len(targets)} series+seasons; duplicate images: {dup}")
    for k, v in sorted(hashes.items()):
        print(f"   {v}  {k}")


if __name__ == "__main__":
    main()
