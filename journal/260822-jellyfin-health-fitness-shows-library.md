# 2026-08-22 — Jellyfin: one "Health & Fitness" Shows library instead of five flat libraries

## Problem

Every YouTube-derived Jellyfin library was a `movies`-type library pointed at one flat folder
(`/movies/youtube/<playlist-slug>/`). A Movies library has no sub-grouping, so the only way to
get a "subcategory" had been another top-level library — 18 libraries and climbing, five of them
fitness (Gym, Heavy Club Basics, Heavy Club Exercise Tutorials, Kettlebell Compilations, Turkish
Get-Up). Wanted: one Health & Fitness library with subcategories.

## Options considered

1. **Shows library** — Series = subcategory, Season = sub-subcategory, episode = video. Ordered
   playback, Next Up, resume. Needs `SxxExx` filenames. **Chosen.**
2. Home Videos & Photos library — folder-browsable, zero renaming, but no ordering/Next Up and no
   plugin metadata; right answer for loose grab-bags, not for numbered courses.
3. One Movies library + genres/tags/collections — filters, not a hierarchy; no folder→tag
   automation. Rejected.

Decisions: fitness only for now (`create/humanity/travel/math+engineering/music` stay as they
are); P90X-style DVD rips in `/media/Workouts` are not in any library and stay out; the
non-fitness "health" videos become their own `Health` series rather than moving to Humanity.

## What was done

Tooling: `scripts/jellyfin-fitness-migration/` (`mapping.toml` + `migrate.py`, tests in
`tests/test_jellyfin_fitness_migration.py`, run state under `state/`).

1. **Snapshot** `tank/movies@pre-fitness-migration-20260822` (sudo on the NAS; `truenas_admin`
   cannot `zfs snapshot` unprivileged).
2. **Export history** via the API: every user's Played/PlayCount/PlaybackPositionTicks/IsFavorite
   for the 280 in-scope items, keyed by YouTube ID (john 20 rows, TV 7). Jellyfin keys a movie's
   user data by path-derived item id and an episode's by series+S/E, so nothing carries over by
   itself.
3. **Plan** from a NAS listing + `mapping.toml`: 280 videos → 8 series / 11 seasons. Playlist
   folders keep yt-dlp's `001-` index as the episode number; loose `training/` videos were
   bucketed by ID into Kettlebell S03 / Bodyweight / Mobility & Physio / Endurance / Inspiration /
   Combat Sports / Health and numbered by upload date. Planner refuses strays, duplicates, and any
   destination that does not parse as exactly one `SxxExx`. Cross-check found one stale DB row
   (file deleted) and three not-yet-scanned files (added to Mobility & Physio).
4. **Moves** on the NAS (`mv -n` inside one dataset, pre-flight aborts on missing src / existing
   dst): 280 videos + 198 trickplay dirs + 4 `.vtt`, plus `tvshow.nfo`/`season.nfo`.
5. **Library** "Health & Fitness" (tvshows, `/movies/youtube/fitness`, realtime monitor off)
   created via `POST /Library/VirtualFolders` with `LibraryOptions` in the body.
6. **Re-apply history** by YouTube ID → new episode: 27/27 rows, each verified by read-back.
7. Docs: `documentation/jellyfin_lxc.md` (new section + two landmines).

## What went wrong (and the fixes)

**YouTube Metadata plugin hard-codes episode numbers.** Its `YTDLJsonToEpisode` sets
`IndexNumber = 1; ParentIndexNumber = 1` and a date-based `ForcedSortName` on every episode it
fetches — fine for its intended channel-as-series layout, fatal for curated seasons. 237 of 249
fetched episodes became "E1" during the first scan. Fix: plugin disabled for Series/Season/Episode
in this library (`fix-library-options`), metadata supplied by **per-episode `.nfo` sidecars**
generated from data we already had (`write-nfo`: Jellyfin's own fetched titles/overviews/dates for
272 items, old-library DB rows for the rest; + `-thumb.jpg` exported from Jellyfin for 249).

**`ReplaceAllMetadata=true` made it worse.** Run to force re-parsing, it nulled every episode's
IndexNumber and Overview and the nfo reader did not repopulate them (observed on 10.11.11; root
cause not chased). A plain `FullRefresh` (`ReplaceAllMetadata=false`) does the right thing:
`FillMissingEpisodeNumbersFromPath` re-parses `SxxExx` and the nfo fills empty fields. Never use
ReplaceAll on this library.

**A non-replace refresh never overwrites an existing Name/ForcedSortName**, so `fix-names` does the
cosmetics through `POST /Items/{id}` (full DTO round-trip, diff-checked): cleared the plugin's
forced sort on 280, retitled 10 filename-named episodes, set the 11 season names (Jellyfin had
rewritten my `season.nfo` during the first scan, losing the titles), re-requested images for 31
episodes without a thumbnail.

**Rate limiting.** The plugin shells out to yt-dlp per item; ~200 lookups in got the LXC IP a 429 /
"sign in to confirm you're not a bot" for ~10 min. The yt-dlp in the image also warns no JS runtime
(deno) is installed. Both are moot for this library now but still apply to the remaining Movie
libraries.

**Embedded metadata was mostly absent.** The `yt` wrapper passes `--embed-metadata` today, but
~80% of the fitness files predate that flag (only ENCODER tags). Jellyfin's titles had been coming
from the plugin's remote lookup, not from the files. Irrelevant now that nfo sidecars exist.

## End state

280 episodes, 280/280 numbered as their filenames say, 0 filename titles, 274 overviews (6 have
no YouTube description), 280 air dates, 280 thumbnails, season names set, plugin sort names gone,
user data intact (john 12 in-progress / 6 played, TV 3 / 4).

**Series artwork/overviews were junk too** (noticed in the UI afterwards): while the plugin was
still enabled its *series* provider searched YouTube for "Kettlebell", "Heavy Club" … and attached
some random channel's avatar and "about" text to each series, and seasons with no image of their
own inherit the series image — so all three Kettlebell seasons looked identical. Fixed with
`make_posters.py`: a generated 2:3 poster per series (`poster.jpg`) and per season (`folder.jpg`),
uploaded and image-refreshed (series/season items only); 19/19 primary images verified distinct
by hash; series overviews replaced with a one-line list of seasons. First cut stacked three
episode thumbnails per poster — John found that confusing, so the final design is the season's
*first* episode thumbnail, full width over a blurred copy of itself, plus the name band (series:
first episode of the first season). John also applied the `.nextUpSection` Custom CSS himself.

**Episode descriptions** were the raw YouTube text — mostly Amazon/merch/"follow me" links.
Added `clean_overview()` (+ `fix-overviews`): header `"<channel> · <date>"`, then the first real
prose paragraph with URL lines, social/merch/gear boilerplate, bullet lists, label lines, slogans
and shouty sponsor lines removed, capped on a sentence boundary. 280/280 rewritten in Jellyfin and
in the nfo; 79 end up with a body, the rest (nearly all Mark Wildman) genuinely have no
description. Raw text stays in `state/metadata-sources.json`.

**Grid instead of list on season pages:** jellyfin-web hard-codes `listView` for a Season's
children and exposes no setting or library hook. Prototyped Custom CSS live in Chrome on the
Bodyweight season (3-up cards, 16:9 thumb, title clamped to two lines, one overview line, the
play/info/seen/favourite buttons kept) — snippet recorded in `documentation/jellyfin_lxc.md`; it
applies to every Shows library, as does the `.nextUpSection` hide John applied himself.

One more trap on the way: image fetchers are matched by provider *display name* — `Screen Grabber`
and `Embedded Image Extractor`, with spaces. I had configured `ScreenGrabber`/`EmbeddedImageExtractor`
(copied from an options.xml dump that had been piped through `tr -d " "`), which matches nothing,
so 31 episodes without an exported thumb got no image until the names were fixed.

## 2026-08-23 addendum

- Kettlebell's show and "Compilations" thumbcards still showed the old triptych in John's
  browser although the files on the NAS were the new single-image posters: the tar upload wrote
  them with mtime 0 both times, Jellyfin's image tag is path+mtime, so the tag never changed
  and clients kept the cached image. `make_posters.py` now stamps a current mtime; tags changed,
  19/19 verified distinct at a fresh size.
- Thumbcard overrides added to `make_posters.py`: `art/<Show>/poster.jpg`,
  `art/<Show>/Season NN/folder.jpg` (portrait used as-is, landscape letterboxed+band), or
  `image = "<youtubeId>"` on a show/season in `mapping.toml`.
- New canonical doc `documentation/jellyfin_health_fitness_library.md` (layout, nfo, thumbcards,
  scripts, runbooks, landmines); `jellyfin_lxc.md` keeps a summary and points to it.

## 2026-08-23 addendum 2 — `yt -f` and newest-first "feed" seasons

- `yt -f` (download-video PR #1) adds a video to a show/season interactively or via
  `Show/Season`; first live run exposed two exit-status traps (`[ … ] && printf` as the last
  statement of the listing script; `[[ -n … ]] && printf` at the end of the picker) — both read
  as "nothing listed"/"aborted". Fixed; 38 bats.
- John wants loose seasons **newest first**. Jellyfin orders episodes by number only, so: each
  season carries `Season NN/.order` = `course` (1..N, playlists) or `feed` (numbered down from
  999; a new video gets min−1 and lands on top; nothing existing is renamed). `yt -f` asks for
  the order on a new season / once for an unmarked one; `yt --season-order` sets it.
- `migrate.py reorder-season` renumbered the 7 loose seasons (E01→E999 … newest = lowest),
  renaming media + nfo + thumbs, rewriting `<episode>`, plain refresh, watched state re-applied
  by YouTube id (e.g. Mobility & Physio: 16 episodes → 984..999, 4/4 user rows). The four
  playlist seasons were marked `course`.

## 2026-08-23 addendum 3 — the post-scan renumbering landmine

While verifying the feed renumber, 18 course episodes turned out swapped (adjacent pairs in
Heavy Club S02 / Kettlebell S02 whose upload order differs from playlist order), and after the
17:00 scan the freshly renumbered feed seasons had reverted to 1..N with filename titles, nfo
rewritten to match. Chased through DB snapshot diffs (same item id, only IndexNumber changed,
no refresh timestamp change → not a metadata refresh), plugin DLL strings and the plugin source:
the YouTube Metadata plugin registers an `ILibraryPostScanTask` (`EpisodeIndexer`) that runs
after every scan and renumbers, for every *show* with a `YoutubeMetadata` provider id, each
season's episodes 1..N by PremiereDate (seasons alphabetically). Our shows got the id from the
plugin's series provider during the first scan on 08-22; it had been renumbering since the
19:00 scan that day (my checks pre-dated it). Fix: stripped the id from the 8 shows
(`fix-library-options` now does it; `verify` fails if it reappears), repaired with
`fix-numbers` (two-phase — Jellyfin rejects direct swaps on its (series,S,E) key; also strip
`Trickplay` from DTOs or POST /Items fails with a deserialization 500), `fix-names`, `write-nfo`,
then a deliberate full scan: nothing moved. `make_posters.py` no longer updates series items
(an item update on a Series queues a full replace-all refresh of the series). Lesson written
into the docs: after any scan/refresh, run `verify`.

## Follow-ups

- Delete the five emptied libraries (Gym, Heavy Club ×2, Kettlebell Compilations, Turkish Get-Up)
  after a look at the new one in the UI.
- `yt.sh` fitness mode: write straight into `fitness/<Series>/Season NN/` with the next `SnnEnn`,
  `--write-info-json`/nfo generation, keep `--embed-metadata`. `heavy-club-exercise-tutorials/
  archive.txt` (yt-dlp download archive) was left in the old folder.
- Consider deno in the jellyfin image (the media VM role already installs it for yt-dlp).
- Same treatment for the other YouTube libraries if this one works out.
