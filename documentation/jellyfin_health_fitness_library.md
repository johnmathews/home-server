# Jellyfin — Health & Fitness library

**Status:** current — verified 2026-08-23 · covers: live, scripts/jellyfin-fitness-migration/**
Layout, options and counts were read from the NAS and the Jellyfin API on that date.

**What it is:** one Jellyfin *Shows*-type library for fitness/health YouTube videos, where each
**Show = a subgenre** (Kettlebell, Heavy Club, Bodyweight, …) and each **Season = a sub-subgenre**
(Kettlebell → Compilations / Turkish Get-Up / Tutorials). It replaced five flat per-playlist
"movie" libraries on 2026-08-22 (history in
[`journal/260822-jellyfin-health-fitness-shows-library.md`](../journal/260822-jellyfin-health-fitness-shows-library.md)).

This is the canonical doc for the library. Host-level Jellyfin notes (versions, OOM brownouts,
realtime monitoring, Custom CSS storage) are in [`jellyfin_lxc.md`](jellyfin_lxc.md).

```
+-------------------------------------------------------------------------------------------+
| Jellyfin library  "Health & Fitness"  (tvshows)  ->  /movies/youtube/fitness              |
| NAS path          /mnt/tank/movies/youtube/fitness   (dataset tank/movies, daily snapshots)|
| Jellyfin host     jellyfin_lxc 192.168.2.110  (`ssh jelly`, compose in /srv/apps)          |
| Tooling           scripts/jellyfin-fitness-migration/  (this repo)                        |
| API key           vault_jellyfin_key  (group_vars/all/vault.yml) -> env JELLYFIN_API_KEY  |
+-------------------------------------------------------------------------------------------+
```

## 1. Layout on disk

```
fitness/
├── <Show>/                               e.g. Kettlebell/
│   ├── tvshow.nfo                        <title>Kettlebell</title>
│   ├── poster.jpg                        the show's 2:3 thumbcard (generated, see §4)
│   ├── landscape.jpg                     the show's 16:9 thumbcard (generated, see §4)
│   └── Season NN/                        e.g. Season 03/
│       ├── season.nfo                    <title>Tutorials</title><seasonnumber>3</seasonnumber>
│       ├── folder.jpg                    the season's 2:3 thumbcard (generated, see §4)
│       ├── landscape.jpg                 the season's 16:9 thumbcard (generated, see §4)
│       ├── <Show> SNNEnn - <original name>-[<youtubeId>].mkv
│       ├── <Show> SNNEnn - <original name>-[<youtubeId>].nfo      episode metadata (§3)
│       ├── <Show> SNNEnn - <original name>-[<youtubeId>]-thumb.jpg episode thumbnail
│       └── <Show> SNNEnn - <original name>-[<youtubeId>].trickplay/ (Jellyfin, regenerates)
```

Rules that everything else relies on:

- **Episode filename** = `<Show> S<season,2 digits>E<episode,2 or 3 digits> - <whatever>-[<youtubeId>].<ext>`.
  Jellyfin derives season/episode numbers from the `SxxExx` token; the `[youtubeId]` (11 chars
  in square brackets) is what every script uses as the stable key. Keep both.
- **Episode order** inside a season is the episode number. Playlist seasons carry yt-dlp's
  `001-` index; loose seasons were numbered by upload date at migration time; new videos just
  take the next free number.
- **Names shown in Jellyfin** come from `tvshow.nfo` (show), `season.nfo` (season) and the
  episode `.nfo` (title, plot, aired date, sort title). The folder names are only for humans.
- **No metadata comes from the internet for this library.** The YouTube Metadata plugin is
  disabled for it on purpose (§6) — it breaks numbered seasons.

Current contents (2026-08-23):

```
+-------------------+-----+--------------------+------+-----------------------------------------+
| Show              | Snn | Season name        | eps  | origin                                  |
+-------------------+-----+--------------------+------+-----------------------------------------+
| Heavy Club        | 01  | Basics             |  55  | playlist heavy-club-basics              |
| Heavy Club        | 02  | Exercise Tutorials | 100  | playlist heavy-club-exercise-tutorials  |
| Kettlebell        | 01  | Compilations       |  17  | playlist kettlebell-compilations        |
| Kettlebell        | 02  | Turkish Get-Up     |  26  | playlist turkish-get-up                 |
| Kettlebell        | 03  | Tutorials          |   9  | singles from training/                  |
| Bodyweight        | 01  | Bodyweight         |  22  | singles from training/                  |
| Mobility & Physio | 01  | Mobility & Physio  |  16  | singles from training/                  |
| Endurance         | 01  | Endurance          |  23  | singles from training/                  |
| Inspiration       | 01  | Inspiration        |   4  | singles from training/                  |
| Combat Sports     | 01  | Combat Sports      |   3  | singles from training/                  |
| Health            | 01  | Health             |   5  | singles from training/                  |
+-------------------+-----+--------------------+------+-----------------------------------------+
```

## 2. Scripts (all in `scripts/jellyfin-fitness-migration/`)

Run from the repo root. Everything talks to Jellyfin over its REST API and to the NAS over
`ssh nas`; nothing needs to run on the LXC.

```sh
export JELLYFIN_API_KEY=$(ansible-vault view --vault-password-file .vault_pass.txt group_vars/all/vault.yml | grep '^vault_jellyfin_key' | awk '{print $2}' | tr -d '"')
W=scripts/jellyfin-fitness-migration/state      # working dir: plan, snapshots, logs
```

```
+------------------------------------------+-----------------------------------------------------------+
| Command                                  | What it does                                              |
+------------------------------------------+-----------------------------------------------------------+
| migrate.py --workdir $W export-history   | Save every user's played/position/favourite state for the |
|                                          | in-scope items, keyed by YouTube ID (read-only).          |
| migrate.py --workdir $W plan             | Build the old->new rename plan from a NAS listing and      |
|                                          | mapping.toml; writes plan.json + plan.md; touches nothing. |
| migrate.py --workdir $W apply-moves      | Execute the plan on the NAS (mv within the dataset) and    |
|                                          | write tvshow/season nfo. Pre-flight aborts on any clash.   |
| migrate.py --workdir $W fix-library-     | Set the library options: no metadata fetchers, Nfo-only    |
|   options                                | local reader, image fetchers "Embedded Image Extractor"   |
|                                          | + "Screen Grabber", realtime monitor off.                 |
| migrate.py --workdir $W write-nfo        | (Re)write every episode .nfo from Jellyfin's current data  |
|   [--no-images] [--dry-run]              | + the metadata snapshot, plus tvshow/season nfo; export   |
|                                          | -thumb.jpg unless --no-images; upload to the NAS.         |
| migrate.py --workdir $W refresh          | Plain FullRefresh of the library (never ReplaceAll, §6)   |
|                                          | and verify every episode's S/E matches its filename.      |
| migrate.py --workdir $W apply-history    | Re-apply the exported watched state by YouTube ID.        |
| migrate.py --workdir $W fix-names        | Clear plugin sort names, retitle filename-named episodes, |
|   [--force-sort]                         | apply season names from mapping.toml, re-extract missing  |
|                                          | thumbnails. Needed after a refresh (it never overwrites   |
|                                          | an existing Name).                                        |
| migrate.py --workdir $W fix-overviews    | Rewrite every episode overview with the cleaned YouTube   |
|                                          | description (§3).                                         |
| make_posters.py --workdir $W [--dry-run] | Generate + upload + refresh the thumbcards for every show |
|                                          | and season (§4). Needs pillow: run with                   |
|                                          | `uv run --python 3.13 --with pillow ...`.                 |
| retry_metadata.py <library-id>           | Only for Movie-type YouTube libraries: slow re-fetch of   |
|                                          | items the plugin failed on (YouTube 429). Not used here.  |
+------------------------------------------+-----------------------------------------------------------+
```

Files the scripts read/write:

- `mapping.toml` — the show/season ↔ folder/video-id map. It drove the migration and still
  carries the **season names** (`fix-names`) and optional **`image = "<youtubeId>"`** thumbcard
  picks (§4). Edit it, don't regenerate it.
- `art/` — manual thumbcard sources (§4).
- `state/` — `plan.json` (the episode list the scripts iterate), `metadata-sources.json` (raw
  YouTube titles/descriptions/dates/uploaders keyed by ID — the source for overviews),
  `history.json`, `listing.json`, logs. Committed; small.
- Tests: `tests/test_jellyfin_fitness_migration.py` (`.venv/bin/python -m pytest tests/ -q`).

## 3. Episode metadata (nfo)

Each episode `.nfo` is Kodi-style and fully describes the episode:

```xml
<episodedetails>
  <title>Kettlebell Snatch Technique</title>
  <showtitle>Kettlebell</showtitle>
  <season>3</season>
  <episode>2</episode>
  <plot>Mark Wildman · 14 Feb 2020

If it HURTS, you're doing it WRONG...</plot>
  <aired>2020-02-14</aired>
  <year>2020</year>
  <studio>Mark Wildman</studio>
  <sorttitle>Kettlebell Snatch Technique</sorttitle>
  <uniqueid type="YoutubeMetadata" default="true">xQqCyl-2ixQ</uniqueid>
  <lockdata>false</lockdata>
</episodedetails>
```

- The **plot** is the *cleaned* YouTube description: first line `"<channel> · <d Mon YYYY>"`, then
  the first real paragraph with link/merch/social/"follow me"/gear-list boilerplate stripped and
  capped (~480 chars) on a sentence boundary (`clean_overview()` in `migrate.py`, unit-tested).
  Most Mark Wildman videos have no real description, so they show just the channel/date line.
- Raw descriptions live in `state/metadata-sources.json`; `fix-overviews` rewrites Jellyfin,
  `write-nfo --no-images` rewrites the files. Re-run both after changing the cleaner.
- Jellyfin reads nfo on a **plain** refresh into *empty* fields only. Title/sort name already set
  in Jellyfin are not overwritten by a refresh — that is what `fix-names` (and the UI's
  "Edit metadata") are for.

## 4. Thumbcards (show and season posters)

Jellyfin has two thumbcard shapes and clients pick whichever fits the view: the 2:3 **Primary**
(`poster.jpg` for a show, `Season NN/folder.jpg` for a season) and the 16:9 **Thumb**
(`landscape.jpg` in the same folders). TV layouts, "thumb" view modes and home-screen rows draw
16:9 tiles; **if no Thumb exists Jellyfin centre-crops the portrait poster** (top of the picture
lost, blurred strip at the bottom — seen on the TV 2026-08-23). **A season without its own
images inherits the show's**, so several seasons look identical. `make_posters.py` guarantees
both: it writes one poster *and* one landscape per show and per season and image-refreshes them.

**Default art:** the season's *first* episode thumbnail. Poster (2:3): full width and uncropped
over a blurred copy of itself, dark band with the season name (and show name, smaller).
Landscape (16:9): the thumbnail cover-fitted with a slim name band. Shows use the first episode
of their first season. Generated art is deliberately labelled so it stays legible on the TV and
in home-screen rows that print no caption.

**To set a specific thumbcard** — pick whichever is easier, re-run `make_posters.py`, done:

```
+--------------------------------------------+--------------------------------------------------+
| You want                                   | Do                                               |
+--------------------------------------------+--------------------------------------------------+
| Use a different *episode's* thumbnail for  | In mapping.toml, on the season:                  |
|   a season                                 |   image = "<youtubeId>"                          |
| Use a different episode's thumbnail for    | In mapping.toml, on the show (same level as      |
|   a show                                   |   name): image = "<youtubeId>"                   |
| Use your own image for a season            | Save it as art/<Show>/Season NN/folder.jpg       |
|                                            |   (.png/.webp fine); it is used for both shapes  |
| Use your own image for a show              | Save it as art/<Show>/poster.jpg                 |
| Use a *different* image just for the 16:9  | Add art/<Show>/landscape.jpg or                  |
|   shape                                    |   art/<Show>/Season NN/landscape.jpg             |
+--------------------------------------------+--------------------------------------------------+
```

A manual image that is already portrait (width/height ≤ 0.8) is used as-is, scaled to
1000×1500 — no band. A landscape image is letterboxed with the band like an episode thumbnail.
`art/` wins over `image =`, which wins over the default. The script prints which source it used
for every poster.

```sh
uv run --python 3.13 --with pillow scripts/jellyfin-fitness-migration/make_posters.py --workdir $W            # apply
uv run --python 3.13 --with pillow scripts/jellyfin-fitness-migration/make_posters.py --workdir $W --dry-run  # preview under state/posters/
```

The script also replaces each show's overview with a one-line list of its seasons (the YouTube
plugin had attached random channel blurbs) and uploads with a **current mtime** — Jellyfin's
image cache tag is path+mtime, so without that a regenerated poster keeps its old tag and
browsers keep showing the cached old image (this bit us once).

## 5. Runbooks

### 5.1 Add a video to an existing season

Until the `yt` wrapper grows a fitness mode (open item), this is manual:

1. Download as usual (`yt -g <url>` lands it in `/movies/youtube/training/`).
2. Move + rename it into the season with the next episode number, keeping the yt-dlp name and
   `[id]`:
   `fitness/Kettlebell/Season 03/Kettlebell S03E10 - Mark_Wildman-Some_Title-[VIDEOID].mkv`
   (any `.en.vtt`/`.jpg` sidecars: same new stem). 3-digit episode numbers are fine.
3. Give it an nfo: copy a neighbour's `.nfo`, set title / season / episode / plot / aired /
   uniqueid. (Or add the ID to `state/metadata-sources.json` "api" section and run
   `write-nfo --no-images` — it rewrites *all* nfo, harmless.)
4. `migrate.py --workdir $W refresh` (picks up the file; numbers from the filename; nfo fills
   the rest), then `make_posters.py` only if it is the new first episode of the season.

### 5.2 Add a season to a show

Create `fitness/<Show>/Season NN/` with a `season.nfo` (`<title>` + `<seasonnumber>`), add the
episodes as in 5.1, add the season to `mapping.toml` (name, number — and ids if you want the
planner to know about it), run `refresh`, `fix-names` (applies the season name if Jellyfin
already created the season as "Season NN"), then `make_posters.py`.

### 5.3 Add a show (subgenre)

Create `fitness/<Show>/` with `tvshow.nfo` (`<title>`), at least one season as in 5.2, add the
show to `mapping.toml`, `refresh`, `fix-names`, `make_posters.py`.

### 5.4 Move a video between seasons / shows, or rename a show or season

- **Video:** `mv` it (and its nfo/thumb) and rename the `SxxExx` + show prefix; fix
  `<showtitle>/<season>/<episode>` in its nfo; `refresh`. Watched state follows the item only if
  Jellyfin sees it as the same item — it does not across a rename, so export/re-apply it with
  `export-history` / `apply-history` when it matters (scope them by editing `mapping.toml`).
- **Season name:** `season.nfo` + `mapping.toml` + `fix-names` (or Edit metadata in the UI).
- **Show name:** rename the folder, `tvshow.nfo`, every episode filename prefix and its
  `<showtitle>`; `refresh`. (Folder rename = new items for Jellyfin → history as above.)

### 5.5 Episode titles/descriptions look wrong

`fix-overviews` (cleaned descriptions into Jellyfin) + `write-nfo --no-images` (same into the
files). For a one-off, Edit metadata in the UI; the nfo saver updates the file only if
`SaveLocalMetadata` is on (it is off) — so also fix the nfo by hand to keep disk in step.

### 5.6 Rebuild from scratch

If the library ever has to be recreated: create it as `tvshows` on `/movies/youtube/fitness`,
run `fix-library-options`, scan, `fix-names`, then `apply-history` from `state/history.json`
(or a fresh `export-history` taken before deleting). Everything else is on disk.

## 6. Landmines (all hit on 2026-08-22)

- **YouTube Metadata plugin + numbered seasons = broken.** Its episode provider hard-codes
  `IndexNumber = 1` (and a date sort name); 237/249 fetched episodes collapsed to "E1". Keep it
  disabled for this library (`fix-library-options`). It is fine for channel-as-series libraries.
- **Never refresh with `ReplaceAllMetadata=true`.** It nulls every episode's number and overview
  and the nfo reader does not refill them. Plain `FullRefresh` (the `refresh` command) is right.
- **Image fetcher names have spaces**: `Embedded Image Extractor`, `Screen Grabber`.
  `ScreenGrabber` silently matches nothing → no thumbnails.
- **Regenerated images need a new mtime** or clients keep the cached old one (§4).
- **A non-replace refresh never overwrites existing Name/ForcedSortName** → `fix-names`.
- **YouTube rate-limits the LXC** after a few hundred yt-dlp lookups (429/bot-check). Moot here
  (no fetchers), still true for the remaining Movie-type YouTube libraries.
- Library default `EnableRealtimeMonitor=true` must be turned off (NFS) — `fix-library-options`
  does; see [`jellyfin_lxc.md`](jellyfin_lxc.md).

## 7. UI tweaks that go with it

Server-wide Custom CSS (Dashboard → General; stored in `branding.xml` on the LXC, see
[`jellyfin_lxc.md`](jellyfin_lxc.md) for the snippet and the server-vs-browser distinction):
hides "Next Up" on series pages and renders a season's episodes as a responsive card grid
instead of the list (4/3/2/1 columns by width). Both apply to every Shows-type library — there is
no per-library hook in jellyfin-web. The grid CSS deliberately avoids `aspect-ratio` and CSS
custom properties because the TV runs jellyfin-web on an old engine (first version showed only
the middle band of each thumbnail there); the live snippet is mirrored in
`scripts/jellyfin-fitness-migration/state/custom-css.css`.

## 8. Open items

- The five emptied libraries (Gym, Heavy Club Basics, Heavy Club Exercise Tutorials, Kettlebell
  Compilations, Turkish Get-Up) still exist in Jellyfin and should be deleted.
- `yt` wrapper fitness mode (`photo-video-music-tools/download-video/yt.sh`): download straight
  into `fitness/<Show>/Season NN/` with the next `SnnEnn`, write the nfo, rerun posters.
- Same treatment for the other YouTube libraries (Create, Humanity, Travel, Math + Engineering,
  Ukraine Lectures) if wanted.
