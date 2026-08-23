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

Overrides (checked in this order, first hit wins):
  1. a source image in the repo's art/ dir next to this script:
        art/<Series>/poster.jpg            -> that series' thumbcard
        art/<Series>/Season NN/folder.jpg  -> that season's thumbcard
     (.png/.webp also fine). A portrait source (aspect <= 0.8) is used as-is,
     scaled to 1000x1500; a landscape source is letterboxed + name band like
     an episode thumbnail.
  2. `image = "<youtube id>"` on the series or season in mapping.toml -> that
     episode's thumbnail instead of the first one.
  3. default: first episode of the season / of the first season.

Output per show: poster.jpg (2:3 Primary) AND landscape.jpg (16:9 Thumb); per season:
Season NN/folder.jpg (2:3 Primary) AND Season NN/landscape.jpg (16:9 Thumb). The
landscape file matters: TV layouts / "thumb" views draw 16:9 tiles, and without a
Thumb image Jellyfin centre-crops the portrait poster (top of the thumbnail lost,
blurred strip at the bottom). Manual landscape sources: art/<Show>/landscape.jpg,
art/<Show>/Season NN/landscape.jpg (used as-is when already 16:9-ish, else cover-cropped).
Posters and landscapes are uploaded
to the NAS and image-refreshed (series/season items only; ReplaceAllImages).
Uploaded files get a current mtime: Jellyfin's image cache tag is derived from
the file's path + mtime, so without that a regenerated poster keeps the old tag
and browsers/clients keep showing the cached old image.

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
    if img.width / img.height <= 0.8:  # already a portrait poster (manual art): use as-is, no band
        out = io.BytesIO()
        _cover(img, (0, 0, W, H)).save(out, "JPEG", quality=90, optimize=True)
        return out.getvalue()
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


LW, LH, LBAND = 1280, 720, 96


def compose_landscape(thumb: bytes | None, title: str, subtitle: str | None) -> bytes:
    """16:9 thumb: the source cover-cropped to 1280x720 with a slim name band at the bottom."""
    from PIL import Image, ImageDraw
    img = Image.open(io.BytesIO(thumb)).convert("RGB") if thumb else Image.new("RGB", (16, 9), (40, 40, 44))
    canvas = _cover(img, (0, 0, LW, LH))
    draw = ImageDraw.Draw(canvas, "RGBA")
    draw.rectangle((0, LH - LBAND, LW, LH), fill=(12, 12, 14, 215))
    draw.rectangle((0, LH - LBAND, LW, LH - LBAND + 4), fill=(0, 164, 220, 255))
    label = title if not subtitle else f"{title}  ·  {subtitle}"
    size = 52
    while size > 28 and draw.textlength(label, font=_font(size)) > LW - 80:
        size -= 4
    f = _font(size)
    draw.text(((LW - draw.textlength(label, font=f)) / 2, LH - LBAND + (LBAND - size) / 2 - 4), label, font=f, fill=(245, 245, 245, 255))
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
    ap.add_argument("--mapping", type=Path, default=Path(__file__).with_name("mapping.toml"))
    ap.add_argument("--art", type=Path, default=Path(__file__).with_name("art"), help="manual source images (see module docstring)")
    a = ap.parse_args()
    plan = json.loads((a.workdir / "plan.json").read_text())
    import tomllib
    cfg = tomllib.loads(a.mapping.read_text()) if a.mapping.exists() else {"series": []}
    series_image_id = {sr["name"]: sr.get("image") for sr in cfg.get("series", [])}
    season_image_id = {(sr["name"], int(se["number"])): se.get("image") for sr in cfg.get("series", []) for se in sr.get("seasons", [])}

    def manual_art(rel_dir: str, names: tuple[str, ...] = ("poster", "folder")) -> bytes | None:
        for name in names:
            for ext in (".jpg", ".jpeg", ".png", ".webp"):
                f = a.art / rel_dir / (name + ext)
                if f.exists():
                    return f.read_bytes()
        return None
    jf = Jellyfin()
    lib = next(v for v in jf.req("GET", "/Library/VirtualFolders") if v["Name"] == plan["library_name"])
    uid = next(u["Id"] for u in jf.req("GET", "/Users"))
    q = {"userId": uid, "parentId": lib["ItemId"], "recursive": "true", "enableImages": "true", "limit": 2000, "fields": "Path"}
    series = jf.req("GET", "/Items", {**q, "includeItemTypes": "Series"})["Items"]
    seasons = jf.req("GET", "/Items", {**q, "includeItemTypes": "Season"})["Items"]
    episodes = jf.req("GET", "/Items", {**q, "includeItemTypes": "Episode", "fields": "Path,ProviderIds"})["Items"]

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
    by_vid = {}
    for e in episodes:
        vid = (e.get("ProviderIds") or {}).get("YoutubeMetadata")
        if vid:
            by_vid[vid] = e
    sources: dict[str, str] = {}
    for s in sorted(seasons, key=lambda s: (s.get("SeriesName"), s.get("IndexNumber") or 0)):
        eps = by_season.get(s["Id"], [])
        season_dir = str(PurePosixPath(s["Path"]).relative_to("/movies/youtube"))
        art_rel = str(PurePosixPath(season_dir).relative_to(plan["target_subdir"]))
        chosen_id = season_image_id.get((s.get("SeriesName"), s.get("IndexNumber") or 0))
        manual = manual_art(art_rel)
        if manual is not None:
            first, src = manual, f"art/{art_rel}"
        elif chosen_id and chosen_id in by_vid:
            first, src = thumb(by_vid[chosen_id]), f"episode {chosen_id}"
        else:
            if chosen_id:
                print(f"  ! {s.get('SeriesName')} S{s.get('IndexNumber'):02d}: image id {chosen_id} not in this library, using first episode", file=sys.stderr)
            first, src = next((t for t in (thumb(e) for e in eps[:6]) if t), None), "first episode"
        if first is None:
            print(f"  ! no thumbnail for {s.get('SeriesName')} / {s['Name']}", file=sys.stderr)
        files[f"{season_dir}/folder.jpg"] = compose(first, s["Name"], s.get("SeriesName"))
        land = manual_art(art_rel, ("landscape", "thumb"))
        files[f"{season_dir}/landscape.jpg"] = compose_landscape(land or (first if manual is None else None) or first, s["Name"], s.get("SeriesName"))
        sources[f"{s.get('SeriesName')} / {s['Name']}"] = src + (" (+manual landscape)" if land else "")
        if first is not None and manual is None:
            series_first.setdefault(s["SeriesId"], first)
    for sr in series:
        series_dir = str(PurePosixPath(sr["Path"]).relative_to("/movies/youtube"))
        art_rel = str(PurePosixPath(series_dir).relative_to(plan["target_subdir"]))
        chosen_id = series_image_id.get(sr["Name"])
        manual = manual_art(art_rel)
        if manual is not None:
            img, src = manual, f"art/{art_rel}"
        elif chosen_id and chosen_id in by_vid:
            img, src = thumb(by_vid[chosen_id]), f"episode {chosen_id}"
        else:
            img, src = series_first.get(sr["Id"]), "first episode of first season"
        files[f"{series_dir}/poster.jpg"] = compose(img, sr["Name"], None)
        land = manual_art(art_rel, ("landscape", "thumb"))
        files[f"{series_dir}/landscape.jpg"] = compose_landscape(land or (img if manual is None else None) or img, sr["Name"], None)
        sources[sr["Name"]] = src + (" (+manual landscape)" if land else "")
    for k, v in sorted(sources.items()):
        print(f"   {k:40} <- {v}")
    print(f"generated {len(files)} images ({len(series)} series + {len(seasons)} seasons, poster + landscape each)")

    if a.dry_run:
        out = a.workdir / "posters"
        for rel, data in files.items():
            p = out / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        print(f"dry-run: written under {out}")
        return

    buf = io.BytesIO()
    now = int(time.time())
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for rel, data in files.items():
            ti = tarfile.TarInfo(rel); ti.size = len(data); ti.mode = 0o664; ti.mtime = now  # new mtime => new Jellyfin image tag
            tar.addfile(ti, io.BytesIO(data))
    res = subprocess.run(["ssh", "-o", "BatchMode=yes", a.nas, f"cd {shlex.quote(a.nas_root)} && tar -xf - && echo uploaded"],
                         input=buf.getvalue(), capture_output=True)
    sys.stdout.write(res.stdout.decode()); sys.stderr.write(res.stderr.decode())
    if res.returncode != 0:
        raise SystemExit("upload failed")

    # NOTE: this script used to POST each series' DTO back to set a one-line Overview. It no
    # longer touches series metadata at all: (a) an item update on a Series makes Jellyfin queue a
    # full "replace all metadata" refresh of the whole series, and (b) series-level metadata is
    # where the YouTube Metadata plugin's provider id lives — any show carrying that id gets its
    # episodes renumbered by upload date by the plugin's post-scan EpisodeIndexer after every
    # library scan (2026-08-23). Overviews were set once on 2026-08-22; edit in the UI if needed.
    # Image refresh for series + seasons only (metadata untouched), replacing the plugin's images.
    targets = series + seasons
    for it in targets:
        jf.req("POST", f"/Items/{it['Id']}/Refresh", {"MetadataRefreshMode": "None", "ImageRefreshMode": "FullRefresh", "ReplaceAllImages": "true"})
    time.sleep(20)
    hashes: dict[str, str] = {}
    n_thumb = 0
    for it in targets:
        cur = next(x for x in jf.req("GET", "/Items", {"userId": uid, "ids": it["Id"], "enableImages": "true"})["Items"])
        n_thumb += "Thumb" in (cur.get("ImageTags") or {})
        if "Primary" in (cur.get("ImageTags") or {}):
            hashes[f"{it.get('SeriesName') or it['Name']} / {it['Name']}"] = hashlib.md5(
                jf.req("GET", f"/Items/{it['Id']}/Images/Primary", {"format": "Jpg", "maxWidth": "200"}, raw=True)).hexdigest()[:10]
    dup = len(hashes) - len(set(hashes.values()))
    print(f"primary images present on {len(hashes)}/{len(targets)} series+seasons (thumb/landscape on {n_thumb}); duplicate images: {dup}")
    for k, v in sorted(hashes.items()):
        print(f"   {v}  {k}")


if __name__ == "__main__":
    main()
