"""Tests for scripts/jellyfin-fitness-migration/migrate.py (pure planning / nfo logic)."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_MIGRATION_DIR = Path(__file__).resolve().parent.parent / "scripts" / "jellyfin-fitness-migration"
spec = importlib.util.spec_from_file_location("jellyfin_fitness_migrate", _MIGRATION_DIR / "migrate.py")
assert spec is not None and spec.loader is not None
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m  # dataclasses + `from __future__ import annotations` need this
spec.loader.exec_module(m)


def _seasons() -> list[m.SeasonSpec]:
    return [
        m.SeasonSpec("Heavy Club", 1, "Basics", "heavy-club-basics", None),
        m.SeasonSpec("Bodyweight", 1, "Bodyweight", "training", ["aaaaaaaaaaa", "bbbbbbbbbbb"]),
        m.SeasonSpec("Health", 1, "Health", "training", ["ccccccccccc"]),
    ]


def _listing() -> dict[str, list[str]]:
    return {
        "heavy-club-basics": [
            "001-Side_swing-[LMau5vr7qx4].mkv",
            "001-Side_swing-[LMau5vr7qx4].trickplay",
            "002-Dead_clean-[NoZCHTlmrCg].mkv",
            "002-Dead_clean-[NoZCHTlmrCg].trickplay",
            "archive.txt",
        ],
        "training": [
            "Chan-Older_video-[aaaaaaaaaaa].mp4",
            "Chan-Older_video-[aaaaaaaaaaa].en.vtt",
            "Chan-Newer_video-[bbbbbbbbbbb].mkv",
            "Doc-Health_thing-[ccccccccccc].mp4",
        ],
    }


def test_youtube_id_extraction() -> None:
    assert m.youtube_id("Foo-[LMau5vr7qx4].mkv") == "LMau5vr7qx4"
    assert m.youtube_id("Foo-[LMau5vr7qx4].en.vtt") == "LMau5vr7qx4"
    assert m.youtube_id("Foo-[LMau5vr7qx4].trickplay") == "LMau5vr7qx4"
    assert m.youtube_id("Foo-[-xw66-Ggl9s].mp4") == "-xw66-Ggl9s"
    assert m.youtube_id("Foo-[-xw66-Ggl9s]_1.mkv") == "-xw66-Ggl9s"  # yt-dlp collision suffix
    assert m.youtube_id("archive.txt") is None


def test_playlist_prefix() -> None:
    assert m.strip_playlist_prefix("001-Side_swing-[x]") == (1, "Side_swing-[x]")
    assert m.strip_playlist_prefix("Side_swing-[x]") == (None, "Side_swing-[x]")


def test_plan_numbering_and_sidecars() -> None:
    plan = m.build_plan(_listing(), _seasons(), "fitness", "Health & Fitness",
                        premiere_dates={"aaaaaaaaaaa": "2020-01-01", "bbbbbbbbbbb": "2024-05-05"})
    assert plan.unmapped == []
    media = {x.src: x for x in plan.moves if x.kind == "media"}
    # playlist folder keeps its NNN- numbering
    assert media["heavy-club-basics/002-Dead_clean-[NoZCHTlmrCg].mkv"].dst == \
        "fitness/Heavy Club/Season 01/Heavy Club S01E02 - Dead_clean-[NoZCHTlmrCg].mkv"
    # id-based season numbered by premiere date
    assert media["training/Chan-Older_video-[aaaaaaaaaaa].mp4"].episode == 1
    assert media["training/Chan-Newer_video-[bbbbbbbbbbb].mkv"].episode == 2
    assert media["training/Chan-Newer_video-[bbbbbbbbbbb].mkv"].dst == \
        "fitness/Bodyweight/Season 01/Bodyweight S01E02 - Chan-Newer_video-[bbbbbbbbbbb].mkv"
    # sidecars follow the new stem
    side = {x.src: x.dst for x in plan.moves if x.kind != "media"}
    assert side["heavy-club-basics/001-Side_swing-[LMau5vr7qx4].trickplay"] == \
        "fitness/Heavy Club/Season 01/Heavy Club S01E01 - Side_swing-[LMau5vr7qx4].trickplay"
    assert side["training/Chan-Older_video-[aaaaaaaaaaa].en.vtt"] == \
        "fitness/Bodyweight/Season 01/Bodyweight S01E01 - Chan-Older_video-[aaaaaaaaaaa].en.vtt"
    # archive.txt is not a sidecar of anything and is left alone
    assert not any(x.src.endswith("archive.txt") for x in plan.moves)
    # nfo files
    assert "fitness/Heavy Club/tvshow.nfo" in plan.nfo_files
    assert "<title>Basics</title>" in plan.nfo_files["fitness/Heavy Club/Season 01/season.nfo"]
    assert "<title>Health &amp; Fitness</title>" not in plan.nfo_files.get("fitness/Health/tvshow.nfo", "")


def test_plan_reports_strays() -> None:
    listing = _listing()
    listing["training"].append("Chan-Unassigned-[ddddddddddd].mp4")
    plan = m.build_plan(listing, _seasons(), "fitness", "L", {})
    assert plan.unmapped == ["training/Chan-Unassigned-[ddddddddddd].mp4"]


def test_plan_rejects_missing_id() -> None:
    seasons = _seasons()
    seasons[2].ids = ["zzzzzzzzzzz"]
    with pytest.raises(SystemExit):
        m.build_plan(_listing(), seasons, "fitness", "L", {})


def test_width_goes_to_three_digits_for_long_playlists() -> None:
    listing = {"pl": [f"{i:03d}-v-[{i:011d}].mkv" for i in range(1, 101)]}
    seasons = [m.SeasonSpec("S", 1, "", "pl", None)]
    plan = m.build_plan(listing, seasons, "f", "L", {})
    assert plan.moves[0].dst.endswith("S S01E001 - v-[00000000001].mkv")


def test_mapping_toml_loads_and_is_consistent() -> None:
    cfg, seasons = m.load_mapping(_MIGRATION_DIR / "mapping.toml")
    assert cfg["target_subdir"] == "fitness"
    assert len({(s.series, s.number) for s in seasons}) == len(seasons)


def test_episode_nfo_contents() -> None:
    nfo = m.episode_nfo("A & B", "Kettlebell", 3, 12, "plot <x>", "2024-05-05T00:00:00Z", 2024, "abc-DEF_123", "Mark Wildman")
    assert "<title>A &amp; B</title>" in nfo
    assert "<showtitle>Kettlebell</showtitle>" in nfo
    assert "<season>3</season>" in nfo and "<episode>12</episode>" in nfo
    assert "<plot>plot &lt;x&gt;</plot>" in nfo
    assert "<aired>2024-05-05</aired>" in nfo
    assert '<uniqueid type="YoutubeMetadata" default="true">abc-DEF_123</uniqueid>' in nfo
    assert "<studio>Mark Wildman</studio>" in nfo
    assert "<sorttitle>A &amp; B</sorttitle>" in nfo


def test_filename_title_detection() -> None:
    assert m.looks_like_filename_title("Kettlebell S03E02 - Mark_Wildman-Kettlebell_Snatch_Technique")
    assert not m.looks_like_filename_title("Kettlebell Snatch Technique")
    assert not m.looks_like_filename_title("Scott Johnston's Winning Formula — Season 7 Ep. 10")


def test_poster_foreground_box_is_full_width_uncropped_and_centred() -> None:
    spec2 = importlib.util.spec_from_file_location("jellyfin_fitness_posters", _MIGRATION_DIR / "make_posters.py")
    assert spec2 is not None and spec2.loader is not None
    mp = importlib.util.module_from_spec(spec2)
    sys.modules[spec2.name] = mp
    spec2.loader.exec_module(mp)  # pillow is imported lazily, so this needs no extra deps
    x0, y0, x1, y1 = mp.foreground_box(1280, 720, 1000, 1500, 260)
    assert (x0, x1) == (0, 1000)                      # full width
    assert y1 - y0 == round(1000 * 720 / 1280)       # aspect preserved (no crop)
    assert y0 == (1500 - 260 - (y1 - y0)) // 2       # centred above the band
    # a portrait source is capped to the area above the band rather than overflowing it
    assert mp.foreground_box(500, 2000, 1000, 1500, 260)[3] <= 1500 - 260


WILDMAN = """Follow me on Instagram: http://bit.ly/MarkInsta
Have any questions? Leave a comment below.

FAQ & ANSWERS:

What workout gear do you use?
— Heavy Clubbells: http://amzn.to/2ks1FOJ
— Main Camera: http://amzn.to/2k6g2aq"""

BEAU = """Beau Miles laces up for a different kind of world first, running 650+km of the Australian Alpine Walking Track. Traversing through some of the highest peaks in Australia, Beau battles injury, fatigue and ultimately himself.

For all the latest on tours, Patreon, books and other Beauisms - https://linktr.ee/beauisms

Produced, Ran & Directed by Beau Miles
Director of Photography, Produced & Edited by Brett Campbell"""

GINGER = """GET THE BONUS FEATURE: https://store.dftba.com/x
JOIN THE CREW: http://bit.ly/GingerRunnerCrew
SUPPORT THIS FILM, GIVE A 'SUPER THANKS' BELOW!

Where Dreams Go To Die is a documentary that follows Canadian ultrarunner Gary Robbins during his two attempts at The Barkley Marathons.

A huge thank you to all involved. #barkley"""

SALOMON = """Join Kilian Jornet on a journey around the summits of his Norwegian home and be inspired to live your own adventure!

Kilian's equipment in the video:
• Salomon X-Alp shoes
• Salomon Skin Pro 15 SET Backpack
• Suunto 9 watch

Subscribe to SalomonTV on Youtube:
https://www.youtube.com/user/officialsalomon"""


def test_clean_overview_drops_pure_boilerplate() -> None:
    out = m.clean_overview(WILDMAN, "Mark Wildman", "2020-02-14T00:00:00Z")
    assert out == "Mark Wildman · 14 Feb 2020"


def test_clean_overview_keeps_first_prose_paragraph_only() -> None:
    out = m.clean_overview(BEAU, "Beau Miles", "2016-12-13")
    assert out.startswith("Beau Miles · 13 Dec 2016\n\nBeau Miles laces up")
    assert "linktr" not in out and "Directed" not in out


def test_clean_overview_skips_leading_boilerplate_and_hashtags() -> None:
    out = m.clean_overview(GINGER, "TheGingerRunner", None)
    assert out.startswith("TheGingerRunner\n\nWhere Dreams Go To Die")
    assert "BONUS" not in out and "SUPER THANKS" not in out and "#barkley" not in out


def test_clean_overview_drops_bullet_lists_and_urls() -> None:
    out = m.clean_overview(SALOMON, "Salomon TV", "2019-04-01")
    assert "Suunto" not in out and "youtube.com" not in out
    assert "Join Kilian Jornet" in out


def test_clean_overview_caps_length_on_sentence() -> None:
    long = "Sentence one is here. " * 60
    out = m.clean_overview(long, None, None, limit=200)
    assert len(out) <= 200 and out.endswith(".")


def test_clean_overview_empty() -> None:
    assert m.clean_overview(None, None, None) == ""
    assert m.clean_overview("", "Chan", None) == "Chan"


def test_clean_overview_keeps_sentence_that_ends_with_a_link() -> None:
    raw = ("Relive this iconic UFC matchup from UFC 236 where both men fought for the title. "
           "Tune in to the induction ceremony ➡️ https://ufcfightpass.com/\n\nOrder UFC PPV on ESPN+ ➡️ https://ufc.ac/x (U.S. only)")
    out = m.clean_overview(raw, "UFC", None)
    assert "Relive this iconic UFC matchup" in out and "ufcfightpass" not in out and "Order UFC PPV" not in out
