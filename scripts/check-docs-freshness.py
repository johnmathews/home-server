#!/usr/bin/env python3
"""Parse every living doc's status stamp and fail when the doc is due.

The convention is documented in readme.md, "Documentation freshness stamps".
One grammar, in the first six lines of the file:

    **Status:** <state> — verified YYYY-MM-DD · covers: <paths|live|none>

Staleness is decided by two signals, matched to the two kinds of claim a doc
can make, because only one of them has a commit to hang off:

  * **Path globs are change-driven.** `git log -1` over the covered paths. A
    commit newer than the stamp means the doc is due at any age; no commits
    mean it cannot have drifted, at any age. There is a grace window so a code
    PR does not red a doc inside the same PR.
  * **`live` is calendar-driven, and only `live`.** Out-of-repo state — a
    datastore's used bytes, a VM's real RAM — rots with no commit at all, so
    those docs age out on a long clock.

That split is the whole design. A calendar-only gate would red 28 accurate
docs at once, of which about four are actually wrong, which is the exact shape
of a gate that gets switched off. A change-only gate is blind to precisely the
claims that were found wrong.

Nothing here is presence-only: a missing stamp, a malformed date, a future
date, a stamp below the window and a `covers:` glob that matches no files are
all errors. Absence of a parse is never a pass.
"""

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

# A stamp is state a reader needs in the first screenful. Below this it is
# prose — `documentation/jellyfin_lxc.md` opens a section with a legitimate
# `**Status:** Disabled on all 17 NFS-backed libraries.` sentence, which is a
# different thing and must not be read as a stamp.
STAMP_WINDOW_LINES = 6

STAMP_PREFIX = "**Status:**"

STAMP_RE = re.compile(
    r"^\*\*Status:\*\*\s+"
    r"(?P<state>.+?)"
    r"\s+—\s+verified\s+(?P<date>\S+)"
    r"\s+·\s+covers:\s+(?P<covers>.+?)\s*$"
)

# A doc in one of these states is a record of something finished. It is correct
# forever, so no staleness check applies and its `covers:` is not resolved —
# the role it describes may legitimately have been deleted. Keyed off the first
# word of the state so "superseded by [x.md](x.md)" still lands here.
# Bare "complete" is deliberately NOT here. `home_assistant_dishwasher.md`
# carried "complete as of 2026-08-13" while describing a live, still-changing
# system — an author saying "the work is complete", not "this document is a
# finished record". Accepting it would have exempted that doc forever.
TERMINAL_STATES = frozenset(
    {"superseded", "archived", "closed", "completed", "decommissioned"}
)

# Enrolment is opt-out: everything here that is not exempt-listed must be
# stamped, so a doc added next month reds on its first CI run rather than being
# silently uncovered. `journal/` is excluded by path rather than by judgement —
# its entries are point-in-time records that are never re-verified.
DISCOVERY_GLOBS = ("documentation/**/*.md", "*.md")

EXEMPT_FILE = "documentation/.freshness-exempt"

# git chokes on an unbounded argv, so the matched file list is fed to
# `git log` in chunks and the newest commit across them wins.
GIT_ARG_CHUNK = 400


class StampError(ValueError):
    """A status line that cannot be read as a stamp. Always an error."""


@dataclass
class Stamp:
    state: str
    verified: date
    globs: list[str] = field(default_factory=list)
    live: bool = False
    terminal: bool = False


def find_stamp_line(lines: list[str]) -> tuple[int, str] | None:
    """Return (1-based line number, text) of the stamp, or None.

    Only the first `STAMP_WINDOW_LINES` lines are considered. That window is
    load-bearing, not cosmetic: it is what separates a stamp from a sentence
    that happens to start the same way.
    """
    for i, line in enumerate(lines[:STAMP_WINDOW_LINES], start=1):
        if line.startswith(STAMP_PREFIX):
            return i, line
    return None


def parse_stamp(line: str) -> Stamp:
    """Parse one canonical status line, or raise StampError."""
    m = STAMP_RE.match(line.rstrip())
    if not m:
        raise StampError(
            "does not match `**Status:** <state> — verified YYYY-MM-DD "
            "· covers: <paths|live|none>`"
        )

    raw_date = m.group("date")
    try:
        verified = datetime.strptime(raw_date, "%Y-%m-%d").date()
    except ValueError:
        raise StampError(f"unparseable verified date {raw_date!r}") from None

    state = m.group("state").strip()
    first_word = re.split(r"[\s,.;:]", state.lower(), maxsplit=1)[0]
    terminal = first_word in TERMINAL_STATES

    items = [c.strip() for c in m.group("covers").split(",")]
    items = [c for c in items if c]
    if not items:
        raise StampError("`covers:` is empty")

    if "none" in items:
        if len(items) > 1:
            raise StampError("`covers: none` cannot be combined with anything else")
        if not terminal:
            raise StampError(
                "`covers: none` is only valid for a terminal state "
                f"({'/'.join(sorted(TERMINAL_STATES))}), not {state!r}"
            )
        return Stamp(state=state, verified=verified, terminal=True)

    live = "live" in items
    globs = [c for c in items if c != "live"]
    return Stamp(state=state, verified=verified, globs=globs, live=live, terminal=terminal)


def _normalise_glob(pattern: str) -> str:
    """`roles/x/**` means "everything under roles/x", including files.

    Python's `**` has meant different things across versions when it is the
    final segment. Spelling it out removes the version dependency.
    """
    if pattern.endswith("/**"):
        return pattern + "/*"
    return pattern


def match_glob(root: Path, pattern: str) -> list[Path]:
    """Files under `root` matching one covers-glob, directories excluded."""
    return sorted(p for p in root.glob(_normalise_glob(pattern)) if p.is_file())


class NotAGitRepo(RuntimeError):
    """`--root` is not inside a git repository, so nothing can be dated."""


def last_commit_date(root: Path, paths: list[Path]) -> date | None:
    """Newest commit date touching any of `paths`, or None if never committed."""
    newest: date | None = None
    rels = [str(p.relative_to(root)) for p in paths]
    for i in range(0, len(rels), GIT_ARG_CHUNK):
        chunk = rels[i : i + GIT_ARG_CHUNK]
        proc = subprocess.run(
            ["git", "-C", str(root), "log", "-1", "--format=%cI", "--", *chunk],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            # The change-driven half of this gate IS git. Without it the check
            # would silently degrade to a presence-only grep, which is the
            # failure mode the whole script exists to avoid.
            raise NotAGitRepo(
                f"git log failed in {root}: {proc.stderr.strip() or 'unknown error'}"
            )
        out = proc.stdout.strip()
        if out:
            when = datetime.fromisoformat(out).date()
            if newest is None or when > newest:
                newest = when
    return newest


def read_exempt(root: Path) -> list[str]:
    """Paths listed in documentation/.freshness-exempt, comments stripped."""
    f = root / EXEMPT_FILE
    if not f.exists():
        return []
    entries = []
    for line in f.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.append(line)
    return entries


def discover(root: Path, exempt: set[str]) -> list[Path]:
    """Every enrolled doc, in a stable order."""
    found: set[Path] = set()
    for pattern in DISCOVERY_GLOBS:
        found.update(p for p in root.glob(pattern) if p.is_file())
    return sorted(p for p in found if str(p.relative_to(root)) not in exempt)


def check_doc(root: Path, doc: Path, today: date, grace_days: int,
              max_age_days: int) -> tuple[list[str], list[str]]:
    """Return (errors, warnings) for one doc, each already formatted."""
    rel = doc.relative_to(root)
    lines = doc.read_text(errors="replace").splitlines()

    hit = find_stamp_line(lines)
    if hit is None:
        below = [i for i, ln in enumerate(lines, 1) if ln.startswith(STAMP_PREFIX)]
        extra = (
            f" (there is one at line {below[0]}, below the {STAMP_WINDOW_LINES}-line window)"
            if below
            else ""
        )
        return ([f"ERROR: {rel}: no status stamp in the first "
                 f"{STAMP_WINDOW_LINES} lines{extra}"], [])

    lineno, text = hit
    try:
        stamp = parse_stamp(text)
    except StampError as exc:
        return ([f"ERROR: {rel}:{lineno}: {exc}"], [])

    if stamp.verified > today:
        return ([f"ERROR: {rel}:{lineno}: verified {stamp.verified} is in the future"], [])

    # A terminal doc describes something finished. It is correct forever, and
    # the paths it once covered may rightly no longer exist.
    if stamp.terminal:
        return ([], [])

    errors: list[str] = []
    warnings: list[str] = []

    covered: list[Path] = []
    for pattern in stamp.globs:
        hits = match_glob(root, pattern)
        if not hits:
            # The highest-value check here: a doc that outlived the role it
            # describes. Nothing else in CI notices that.
            errors.append(
                f"ERROR: {rel}:{lineno}: covers: {pattern} matches no files"
            )
        covered.extend(hits)

    if covered:
        changed = last_commit_date(root, covered)
        if changed is not None and changed > stamp.verified:
            drift = (changed - stamp.verified).days
            what = ", ".join(stamp.globs)
            if drift > grace_days:
                errors.append(
                    f"ERROR: {rel}:{lineno}: {what} last changed {changed}, "
                    f"{drift} days after the stamp (grace is {grace_days}) — re-verify "
                    f"and re-stamp"
                )
            else:
                warnings.append(
                    f"WARN:  {rel}:{lineno}: {what} changed {drift} day(s) after the "
                    f"stamp — inside the {grace_days}-day grace window"
                )

    if stamp.live:
        age = (today - stamp.verified).days
        if age > max_age_days:
            errors.append(
                f"ERROR: {rel}:{lineno}: covers: live and last verified {age} days "
                f"ago (max {max_age_days}) — git cannot see this doc's subject, so "
                f"only the calendar can"
            )

    return errors, warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root to scan (default: the repo this script lives in)",
    )
    parser.add_argument(
        "--grace-days",
        type=int,
        default=14,
        help="days a covered path may be newer than the stamp before it is an "
             "error, so a code PR does not red a doc inside the same PR "
             "(default: 14)",
    )
    parser.add_argument(
        "--max-age-days",
        type=int,
        default=180,
        help="calendar backstop for `covers: live` docs only (default: 180)",
    )
    parser.add_argument(
        "--assert-exempt-max",
        type=int,
        default=None,
        metavar="N",
        help="fail if the exempt list holds more than N entries. This is the "
             "ratchet: lowering N is a one-line commit, raising it is a "
             "visible, arguable diff",
    )
    parser.add_argument(
        "--today",
        type=lambda s: datetime.strptime(s, "%Y-%m-%d").date(),
        default=None,
        metavar="YYYY-MM-DD",
        help="treat this as today's date (for tests)",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    today = args.today or date.today()

    errors: list[str] = []
    warnings: list[str] = []

    exempt = read_exempt(root)
    enrolled = {str(p.relative_to(root)) for p in discover(root, set())}
    seen: set[str] = set()
    for entry in exempt:
        if entry in seen:
            # A duplicate inflates the count the ratchet is measured against,
            # so removing a real entry could leave the number unchanged.
            errors.append(f"ERROR: {EXEMPT_FILE}: duplicate entry: {entry}")
            continue
        seen.add(entry)
        if not (root / entry).is_file():
            # An exemption that outlived its reason is an exemption nobody will
            # ever remove, and it silently shrinks what the ratchet measures.
            errors.append(f"ERROR: {EXEMPT_FILE}: no such file: {entry}")
        elif entry not in enrolled:
            # Exempting something that was never enrolled is padding: it raises
            # the ceiling without exempting anything.
            errors.append(
                f"ERROR: {EXEMPT_FILE}: not an enrolled doc, so exempting it "
                f"does nothing: {entry}"
            )

    if args.assert_exempt_max is not None and len(exempt) > args.assert_exempt_max:
        errors.append(
            f"ERROR: {EXEMPT_FILE}: exempt list has {len(exempt)} entries, "
            f"maximum is {args.assert_exempt_max} — this list only ratchets down"
        )

    docs = discover(root, set(exempt))
    try:
        for doc in docs:
            doc_errors, doc_warnings = check_doc(
                root, doc, today, args.grace_days, args.max_age_days
            )
            errors.extend(doc_errors)
            warnings.extend(doc_warnings)
    except NotAGitRepo as exc:
        print(f"ERROR: {exc}")
        return 1

    for line in warnings:
        print(line)
    for line in errors:
        print(line)

    if errors:
        print(f"\n{len(errors)} documentation freshness problem(s) found")
        return 1

    suffix = f", {len(warnings)} inside the grace window" if warnings else ""
    print(
        f"OK: checked {len(docs)} docs, {len(exempt)} exempt, all stamps parse "
        f"and none are due{suffix}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
