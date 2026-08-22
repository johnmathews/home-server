"""Tests for scripts/check-docs-freshness.py.

The gate's whole value is that it can go red, so most of what is here drives
`main()` end to end against a real throwaway git repo and asserts the exit
code. Parsing is tested directly because "unparseable is red, never skipped"
is a claim about the parser, not about the walk.
"""

import importlib.util
import subprocess
from datetime import date, timedelta
from pathlib import Path

import pytest

# Import the module under test (the filename is hyphenated, so it cannot be
# imported by name).
spec = importlib.util.spec_from_file_location(
    "check_docs_freshness",
    Path(__file__).resolve().parent.parent / "scripts" / "check-docs-freshness.py",
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

parse_stamp = mod.parse_stamp
StampError = mod.StampError
REPO_ROOT = Path(__file__).resolve().parent.parent


# ---------------------------------------------------------------------------
# Helpers: a real git repo, because the change-driven half of the gate is
# `git log` and mocking it would test the mock.
# ---------------------------------------------------------------------------


def _git(repo: Path, *args: str, when: str | None = None) -> None:
    env = {
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.com",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }
    if when:
        env["GIT_AUTHOR_DATE"] = when
        env["GIT_COMMITTER_DATE"] = when
    subprocess.run(["git", "-C", str(repo), *args], check=True, env=env,
                   capture_output=True)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """An empty git repo with the directory layout the checker discovers."""
    _git(tmp_path, "init", "-q", "-b", "main")
    (tmp_path / "documentation").mkdir()
    (tmp_path / "documentation" / "archive").mkdir()
    (tmp_path / "roles" / "widget").mkdir(parents=True)
    (tmp_path / "roles" / "widget" / "tasks.yml").write_text("---\n")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "commit", "-qm", "base", when="2026-01-01T00:00:00Z")
    return tmp_path


def _doc(repo: Path, name: str, stamp: str | None, body: str = "Body.\n") -> Path:
    """Write documentation/<name> with `stamp` as its status line."""
    f = repo / "documentation" / name
    f.parent.mkdir(parents=True, exist_ok=True)
    head = f"# {name}\n\n{stamp}\n\n" if stamp else f"# {name}\n\n"
    f.write_text(head + body)
    return f


def _exempt(repo: Path, *paths: str) -> None:
    (repo / "documentation" / ".freshness-exempt").write_text(
        "# reasons go here\n" + "".join(p + "\n" for p in paths)
    )


def _touch_covered(repo: Path, days_after_stamp: int, stamp_day: str) -> None:
    """Commit to roles/widget/ `days_after_stamp` days after `stamp_day`."""
    when = (date.fromisoformat(stamp_day) + timedelta(days=days_after_stamp))
    (repo / "roles" / "widget" / "tasks.yml").write_text("---\n# changed\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "change", when=f"{when.isoformat()}T12:00:00Z")


def _run(repo: Path, *extra: str, today: str = "2026-08-22") -> int:
    return mod.main(["--root", str(repo), "--today", today, *extra])


# ---------------------------------------------------------------------------
# Parsing: one grammar, and everything else is an error
# ---------------------------------------------------------------------------


def test_parses_the_canonical_form() -> None:
    s = parse_stamp("**Status:** current — verified 2026-08-22 · covers: roles/pve/**")
    assert s.state == "current"
    assert s.verified == date(2026, 8, 22)
    assert s.globs == ["roles/pve/**"]
    assert s.live is False
    assert s.terminal is False


def test_parses_live_and_mixed_covers() -> None:
    s = parse_stamp("**Status:** current — verified 2026-08-22 · covers: live, roles/pve/**")
    assert s.live is True
    assert s.globs == ["roles/pve/**"]


@pytest.mark.parametrize(
    "state",
    ["superseded", "archived", "closed", "completed", "decommissioned"],
)
def test_terminal_states_are_recognised(state: str) -> None:
    s = parse_stamp(f"**Status:** {state} by [x.md](x.md) — verified 2026-01-01 · covers: none")
    assert s.terminal is True


def test_bare_complete_is_not_terminal() -> None:
    """`complete` means "the work is done", not "this document is finished".

    `home_assistant_dishwasher.md` carried "complete as of 2026-08-13" while
    describing a live system. Treating that as terminal would have exempted it
    from every check forever.
    """
    assert "complete" not in mod.TERMINAL_STATES
    with pytest.raises(StampError, match="terminal state"):
        parse_stamp("**Status:** complete — verified 2026-01-01 · covers: none")


def test_none_covers_is_rejected_for_an_active_doc() -> None:
    with pytest.raises(StampError, match="covers: none"):
        parse_stamp("**Status:** current — verified 2026-08-22 · covers: none")


@pytest.mark.parametrize(
    "line",
    [
        "**Status:** current — verified banana · covers: live",
        "**Status:** current — verified 2026-13-01 · covers: live",
        "**Status:** current — verified 2026-08-22",
        "**Status:** current · covers: live",
        "**Status:** verified 2026-08-22 · covers: live",
        "**Status:** current — verified 2026-08-22 · covers:",
    ],
)
def test_malformed_stamps_raise_rather_than_pass(line: str) -> None:
    with pytest.raises(StampError):
        parse_stamp(line)


# ---------------------------------------------------------------------------
# The legacy grammars actually present on main. Each one is checked twice:
# the raw legacy line must be REJECTED (there is one grammar now), and its
# canonical rewrite must parse to the values the rewrite intends.
# ---------------------------------------------------------------------------

LEGACY_GRAMMARS = {
    # session-4's "(covers: live)" form — pbs, proxmox_host_tuning,
    # document_library_lxc, family_finances_lxc
    "current as of": (
        "**Status:** current as of 2026-08-22 (covers: live). The datastore figures below",
        "**Status:** current — verified 2026-08-22 · covers: live",
        ("current", date(2026, 8, 22), True, False),
    ),
    # home_assistant_dishwasher
    "complete as of": (
        "**Status:** complete as of 2026-08-13. Energy tracking live via the metering plug",
        "**Status:** current — verified 2026-08-13 · covers: live",
        ("current", date(2026, 8, 13), True, False),
    ),
    # home_assistant_ev_charging — a state word and no date at all
    "bare LIVE": (
        "**Status:** LIVE. Cable side **fully local via tuya-local since 2026-08-13**",
        "**Status:** current — verified 2026-08-13 · covers: live",
        ("current", date(2026, 8, 13), True, False),
    ),
    # home_assistant_lighting
    "plan of record as of": (
        "**Status:** plan of record as of 2026-08-14. Nothing migrated yet",
        "**Status:** plan of record — verified 2026-08-14 · covers: live",
        ("plan of record", date(2026, 8, 14), True, False),
    ),
    # archive/cloudflare-api, archive/home-assistant-doorbell
    "superseded by (date)": (
        "**Status:** superseded by [cloudflared.md](../cloudflared.md) (2026-07-12).",
        "**Status:** superseded by [cloudflared.md](../cloudflared.md) — verified 2026-07-12 · covers: none",
        (None, date(2026, 7, 12), False, True),
    ),
    # archive/documentation-improvement-plan, archive/domain-migration
    "completed — ... Archived": (
        "**Status:** completed — Stages 0-4 done. Archived 2026-07-12.",
        "**Status:** completed — verified 2026-07-12 · covers: none",
        ("completed", date(2026, 7, 12), False, True),
    ),
    # archive/paperless
    "superseded — ... (date)": (
        "**Status:** superseded - paperless decommissioned (2026-07-04).",
        "**Status:** superseded — verified 2026-07-04 · covers: none",
        ("superseded", date(2026, 7, 4), False, True),
    ),
    # archive/traefik-log-resilience-plan
    "closed — ...": (
        "**Status:** closed - Option B implemented in",
        "**Status:** closed — verified 2026-07-12 · covers: none",
        ("closed", date(2026, 7, 12), False, True),
    ),
    # jellyfin_lxc's mid-document line: a legitimate sentence, not a stamp
    "bare prose": (
        "**Status:** Disabled on all 17 NFS-backed libraries.",
        "**Status:** current — verified 2026-08-22 · covers: roles/jellyfin_lxc/**",
        ("current", date(2026, 8, 22), False, False),
    ),
}


@pytest.mark.parametrize("name", sorted(LEGACY_GRAMMARS))
def test_legacy_grammar_is_rejected(name: str) -> None:
    legacy, _, _ = LEGACY_GRAMMARS[name]
    with pytest.raises(StampError):
        parse_stamp(legacy)


@pytest.mark.parametrize("name", sorted(LEGACY_GRAMMARS))
def test_canonical_rewrite_of_each_legacy_grammar_parses(name: str) -> None:
    _, canonical, (state, verified, live, terminal) = LEGACY_GRAMMARS[name]
    s = parse_stamp(canonical)
    assert s.verified == verified
    assert s.live is live
    assert s.terminal is terminal
    if state is not None:
        assert s.state.startswith(state)


def test_no_legacy_grammar_survives_in_a_stamp_position() -> None:
    """Guard against a grammar existing on main that no test exercises.

    The plan's stamp count was stale twice, so this asserts against the tree
    rather than against a number written down somewhere. Only the window is
    checked: a `**Status:**` sentence further down is prose, not a stamp, and
    rewriting it would be wrong.
    """
    docs = sorted(REPO_ROOT.glob("documentation/**/*.md"))
    assert docs, "no documentation found — is REPO_ROOT right?"
    for doc in docs:
        lines = doc.read_text().splitlines()[: mod.STAMP_WINDOW_LINES]
        for line in lines:
            if not line.startswith("**Status:**"):
                continue
            try:
                parse_stamp(line)
            except StampError as exc:
                pytest.fail(
                    f"{doc.relative_to(REPO_ROOT)} has a non-canonical status "
                    f"line that W19 did not rewrite ({exc}): {line[:90]!r}"
                )


# ---------------------------------------------------------------------------
# The 6-line window
# ---------------------------------------------------------------------------


def test_stamp_below_the_window_does_not_count(repo: Path) -> None:
    f = repo / "documentation" / "deep.md"
    f.write_text(
        "# Deep\n\nintro\n\n## A\n\nprose\n\nmore\n"
        "**Status:** current — verified 2026-08-22 · covers: live\n"
    )
    _exempt(repo)
    assert _run(repo) == 1


def test_jellyfin_mid_document_line_is_rejected_wherever_it_sits() -> None:
    """The real file, at whatever line the sentence currently occupies.

    `documentation/jellyfin_lxc.md` opens a section with a `**Status:**`
    sentence about NFS monitoring. It is a legitimate and different thing, and
    the window must reject it — so the test locates it rather than hardcoding
    a line number that has already moved once (:62 on main, :119 in another
    session's working tree).
    """
    doc = REPO_ROOT / "documentation" / "jellyfin_lxc.md"
    lines = doc.read_text().splitlines()
    hits = [i for i, ln in enumerate(lines, 1) if ln.startswith("**Status:**")]
    mid = [i for i in hits if i > mod.STAMP_WINDOW_LINES]
    assert mid, "expected a mid-document **Status:** line in jellyfin_lxc.md"

    found = mod.find_stamp_line(lines)
    assert found is None or found[0] <= mod.STAMP_WINDOW_LINES
    # And the sentence itself is not a stamp by any reading.
    with pytest.raises(StampError):
        parse_stamp(lines[mid[0] - 1])


# ---------------------------------------------------------------------------
# The 14-day grace boundary — the acceptance criterion, both sides
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "days_newer, expected_exit",
    [(0, 0), (1, 0), (13, 0), (14, 0), (15, 1), (40, 1)],
)
def test_grace_boundary(repo: Path, days_newer: int, expected_exit: int,
                        capsys: pytest.CaptureFixture[str]) -> None:
    stamp_day = "2026-03-01"
    _doc(repo, "widget.md",
         f"**Status:** current — verified {stamp_day} · covers: roles/widget/**")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when=f"{stamp_day}T00:00:00Z")
    _touch_covered(repo, days_newer, stamp_day)

    assert _run(repo, today="2026-08-22") == expected_exit
    out = capsys.readouterr().out
    if expected_exit == 0 and days_newer > 0:
        assert "WARN" in out and "widget.md" in out
    if expected_exit == 1:
        assert "ERROR" in out and "widget.md" in out


def test_untouched_paths_stay_green_however_old_the_stamp(repo: Path) -> None:
    """The case a calendar-only gate fails, and the reason for this design.

    The fixture's base commit lands on 2026-01-01, so the stamp is dated the
    day after it and nothing touches `roles/widget/` again. Four years later
    the doc is still green, because nothing it describes has changed.
    """
    _doc(repo, "widget.md",
         "**Status:** current — verified 2026-01-02 · covers: roles/widget/**")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-01-02T00:00:00Z")
    assert _run(repo, today="2030-01-01") == 0


# ---------------------------------------------------------------------------
# Zero-match globs, live docs, and the calendar backstop
# ---------------------------------------------------------------------------


def test_zero_match_glob_is_an_error(repo: Path, capsys: pytest.CaptureFixture[str]) -> None:
    _doc(repo, "ghost.md",
         "**Status:** current — verified 2026-08-22 · covers: roles/deleted_role/**")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 1
    assert "matches no files" in capsys.readouterr().out


def test_live_doc_ages_out_on_the_calendar(repo: Path) -> None:
    _doc(repo, "pbs.md", "**Status:** current — verified 2026-01-01 · covers: live")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-01-01T00:00:00Z")
    # 233 days elapsed by 2026-08-22.
    assert _run(repo, "--max-age-days", "180") == 1
    assert _run(repo, "--max-age-days", "365") == 0


def test_live_doc_is_not_reddened_by_unrelated_commits(repo: Path) -> None:
    """`covers: live` is calendar-only; nothing in the repo can make it due."""
    _doc(repo, "pbs.md", "**Status:** current — verified 2026-08-01 · covers: live")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-01T00:00:00Z")
    _touch_covered(repo, 20, "2026-08-01")
    assert _run(repo) == 0


def test_terminal_doc_skips_staleness_and_zero_match(repo: Path) -> None:
    f = repo / "documentation" / "archive" / "gone.md"
    f.write_text(
        "# Gone\n\n**Status:** superseded by [x.md](../x.md) — verified 2019-01-01 · covers: none\n"
    )
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 0


def test_future_date_is_an_error(repo: Path, capsys: pytest.CaptureFixture[str]) -> None:
    _doc(repo, "widget.md",
         "**Status:** current — verified 2027-01-01 · covers: roles/widget/**")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 1
    assert "in the future" in capsys.readouterr().out


# ---------------------------------------------------------------------------
# Enrolment is opt-out, and the exempt list is a ratchet
# ---------------------------------------------------------------------------


def test_unstamped_doc_is_an_error_unless_exempt(repo: Path) -> None:
    _doc(repo, "naked.md", None)
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 1

    _exempt(repo, "documentation/naked.md")
    assert _run(repo) == 0


def test_root_level_markdown_is_enrolled_too(repo: Path) -> None:
    (repo / "CLAUDE.md").write_text("# c\n\nno stamp\n")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 1
    _exempt(repo, "CLAUDE.md")
    assert _run(repo) == 0


def test_assert_exempt_max_fails_when_the_list_grows(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _doc(repo, "a.md", None)
    _doc(repo, "b.md", None)
    _exempt(repo, "documentation/a.md", "documentation/b.md")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo, "--assert-exempt-max", "2") == 0
    assert _run(repo, "--assert-exempt-max", "1") == 1
    assert "exempt list has 2 entries" in capsys.readouterr().out


def test_exempt_entry_for_a_missing_file_is_an_error(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A stale exemption is an exemption that outlived its reason."""
    _exempt(repo, "documentation/never-existed.md")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 1
    assert "no such file" in capsys.readouterr().out


def test_duplicate_exempt_entry_is_an_error(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A duplicate inflates the count the ratchet is measured against."""
    _doc(repo, "a.md", None)
    _exempt(repo, "documentation/a.md", "documentation/a.md")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 1
    assert "duplicate entry" in capsys.readouterr().out


def test_exempting_a_never_enrolled_path_is_an_error(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Padding the list raises the ceiling without exempting anything."""
    (repo / "journal").mkdir()
    (repo / "journal" / "260101-a.md").write_text("# entry\n")
    _exempt(repo, "journal/260101-a.md")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 1
    assert "not an enrolled doc" in capsys.readouterr().out


def test_a_root_that_is_not_a_git_repo_fails_loudly(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Without git the change-driven half would degrade to a presence grep."""
    (tmp_path / "documentation").mkdir()
    (tmp_path / "roles" / "widget").mkdir(parents=True)
    (tmp_path / "roles" / "widget" / "tasks.yml").write_text("---\n")
    _doc(tmp_path, "widget.md",
         "**Status:** current — verified 2026-08-22 · covers: roles/widget/**")
    _exempt(tmp_path)
    assert mod.main(["--root", str(tmp_path), "--today", "2026-08-22"]) == 1
    assert "git log failed" in capsys.readouterr().out


def test_journal_is_not_enrolled(repo: Path) -> None:
    (repo / "journal").mkdir()
    (repo / "journal" / "260101-a.md").write_text("# entry\n")
    _exempt(repo)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "doc", when="2026-08-22T00:00:00Z")
    assert _run(repo) == 0


# ---------------------------------------------------------------------------
# The real repository
# ---------------------------------------------------------------------------


def test_the_real_repo_is_green() -> None:
    """W19's acceptance criterion, as a test rather than a shell transcript."""
    assert mod.main(["--root", str(REPO_ROOT)]) == 0


def test_removing_any_one_stamp_reds_the_real_repo(tmp_path: Path) -> None:
    """Not a copy of one doc — the actual tree, minus one stamp.

    Uses a git worktree-free copy so the real checkout is never mutated.
    """
    stamped = [
        p for p in sorted(REPO_ROOT.glob("documentation/*.md"))
        if any(ln.startswith("**Status:**")
               for ln in p.read_text().splitlines()[:mod.STAMP_WINDOW_LINES])
    ]
    assert stamped, "no stamped docs found in documentation/"
    victim = stamped[0]

    original = victim.read_text()
    lines = original.splitlines(keepends=True)
    idx = next(i for i, ln in enumerate(lines) if ln.startswith("**Status:**"))
    try:
        victim.write_text("".join(lines[:idx] + lines[idx + 1:]))
        assert mod.main(["--root", str(REPO_ROOT)]) == 1
    finally:
        victim.write_text(original)

    assert mod.main(["--root", str(REPO_ROOT)]) == 0


def test_help_runs(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as exc:
        mod.main(["--help"])
    assert exc.value.code == 0
    assert "--assert-exempt-max" in capsys.readouterr().out
