# Documentation freshness gate — built, bootstrapped, switched on (W18, W19)

Engineering-team cycle `manual-20260822T061616Z`, Phase 3, session 5 of 9. Batch: W18
(build `scripts/check-docs-freshness.py` and its tests) and W19 (bootstrap the stamps,
turn the gate on). Both landed. This closes the documentation half of the cycle.

## What the gate does

`make check-docs` parses every living doc's `**Status:**` line. One grammar:

```
**Status:** <state> — verified YYYY-MM-DD · covers: <paths|live|none>
```

It must sit in the **first six lines**. Staleness is decided two different ways, and the
split is the whole design:

- **`covers:` path globs are change-driven.** `git log -1` over the covered paths, with a
  14-day grace window so a code PR does not red a doc inside the same PR. Nothing
  committed to those paths since the stamp means the doc cannot have drifted, at any age.
- **`covers: live` is calendar-driven, and only `live`.** Out-of-repo state — a datastore's
  used bytes, a VM's real RAM, a DNS chain — rots with no commit at all, so those docs age
  out after 180 days.

That split comes straight from evaluation finding F12: doc age predicted nothing (the
oldest doc in the repo, `mikrotik-exporter.md` at 215 days, was entirely correct), but
whether the subject lived inside the repo predicted everything. A calendar-only gate would
have reddened 28 accurate docs in one go — 28 docs share an mtime from the 2026-07-12
sweep — of which about four were actually wrong. That is the exact shape of a gate that
gets switched off in week two.

Nothing here is presence-only. A missing stamp, a malformed date, `banana`, a future date,
a stamp below line 6, and a `covers:` glob matching **zero files** are all errors. The
zero-match check is the highest-value one in the design: it is what catches a doc that
outlived the role it describes, and nothing else in CI notices that.

## Proof it goes red

The acceptance criterion was a demonstration, not an assertion. A fixture doc whose
covered path has a commit newer than its stamp:

```console
$ # 13 days newer than the stamp
WARN:  documentation/widget.md:3: roles/widget/** changed 13 day(s) after the stamp
       — inside the 14-day grace window
OK: checked 1 docs, 0 exempt, all stamps parse and none are due, 1 inside the grace window
exit=0

$ # 15 days newer than the stamp
ERROR: documentation/widget.md:3: roles/widget/** last changed 2026-03-16, 15 days after
       the stamp (grace is 14) — re-verify and re-stamp
1 documentation freshness problem(s) found
exit=1
```

And every one of the 23 stamps was removed in turn, one at a time, with the gate re-run
after each: all 23 exit 1. The single doc that stays green with its `**Status:**` line
deleted is `documentation/jellyfin_lxc.md`, which is correct — it is exempt, and its
`**Status:**` line is a mid-document sentence about NFS monitoring, not a stamp. The
6-line window rejecting that sentence is a named test, and it **locates the line rather
than hardcoding it**: it sits at :62 on `main` and at :119 in another session's working
tree, so a hardcoded number was already wrong twice.

`confirmed` — all of the above was run and the output is quoted verbatim.

## Enrolment is opt-out, and the ratchet is the whole mechanism

Every `documentation/**/*.md` and every root-level `*.md` is enrolled — 54 files — unless
listed in `documentation/.freshness-exempt`. A doc created next month therefore reds on
its first CI run rather than being silently uncovered, which is what opt-in would have
given.

**23 stamped, 31 exempt.** `make check-docs` passes `--assert-exempt-max 31` from
`DOCS_EXEMPT_MAX` in the makefile, so the list can only shrink: removing an entry is a
two-line commit, adding one is a visible diff somebody has to defend.

The 31 are grouped in the file by *why*, and the grouping is the roadmap:

1. **Six `covers: live` docs** — `adguard-unbound`, `doorbell`, `index`,
   `iperf3-speedtest`, `systemd`, `ups`. These are the rest of F12's category: out-of-repo
   claims git can never see. Highest value to clear, and the most expensive, because
   clearing one means actually reading the live host.
2. **Twenty-one service docs describing in-repo roles** — cheaper, since the check is
   reading the role.
3. **`jellyfin_lxc.md`** — another session had it open in the main checkout while this
   landed.
4. **Three root-level narrative docs** — `readme.md`, `building.md`,
   `README-TAILSCALE.md`.

## The judgement call, stated plainly

The plan said to stamp "the eight `covers: live` docs". I stamped two of them — `pbs.md`
and `proxmox_host_tuning.md` — and exempted the other six.

A stamp is a claim that somebody re-checked the doc against the thing it describes. Session
4 did that for those two, against live reads. Nobody has done it for the other six. Writing
`verified 2026-08-22` on them today would have manufactured exactly the false verification
this gate exists to catch, on its first commit. Exempting them and putting them at the top
of the ratchet list is the honest version of the same intent, and the mechanism is designed
for precisely this.

Same reasoning for `readme.md`: it now *defines* the convention, and it is still exempt,
because its Proxmox install narrative has not been walked through since it was written.

## Things found while doing it

1. **`home_assistant_dishwasher.md` said "complete as of 2026-08-13"** while describing a
   live, still-changing system. The author meant "the work is complete", not "this document
   is a finished record". That is why bare `complete` is **not** in `TERMINAL_STATES` — if
   it were, that doc would have been silently exempt from every check forever. `completed`,
   `closed`, `superseded`, `archived` and `decommissioned` are terminal; `complete` is not.
   Re-grammared to `current`.
2. **Eight distinct stamp grammars sat in stamp positions on `main`**, not the five the
   evaluation report recorded. Counted by the date-carrying clause: `current as of X`,
   `current as of X (covers: live)` (session 4's addition), `complete as of X`, `plan of
   record as of X`, bare `LIVE.` with no date at all, `superseded by [x](y) (X)`,
   `completed — … Archived X`, `superseded — … (X)`, `closed — … Archived X` — which is
   nine if the two `current as of` variants are counted apart, and they are, because a
   parser has to handle them separately. The count had gone stale twice while being
   written down, so there is now a test that walks the tree and asserts no non-canonical
   status line survives in a stamp position — asserting against the repo rather than
   against a number in a document. Every one of those grammars appears in the test's
   table, checked twice: the raw legacy line must be **rejected** (there is one grammar
   now), and its canonical rewrite must parse to the values the rewrite intended.
3. **The gate is wired into `.github/workflows/lint.yml` as a step, not as its own
   workflow**, which is a deliberate deviation from the plan's `docs-freshness.yml`. That
   job already triggers on every push and PR with no `paths:` filter. A separate workflow
   would create a second status context — and this repo has **no rulesets and no branch
   protection at all** (`gh api .../rulesets` returns `[]`), so it would have been advisory
   while looking like a gate. The checkout step now uses `fetch-depth: 0`, because
   `actions/checkout` defaults to depth 1 and every path would look like it changed in the
   single fetched commit.

## What is deliberately not done

- **The six unverified `covers: live` docs are not stamped.** Reasoning above. This is the
  single biggest open item and it is a work unit's worth of live reads, not a wrap-up task.
- **No stamp-size budget check.** The skill's guidance for new projects suggests one
  (~600 characters on the stamp paragraph). The plan did not ask for it and the existing
  stamps are already well inside any sane budget — median 274 characters, none over 454
  per finding F15. Adding it now would be scope the plan did not authorise.
- **`tests/README.md` and `tests/IMPLEMENTATION_SUMMARY.md` are not enrolled.** Discovery
  is `documentation/**/*.md` plus root-level `*.md`; `tests/` and `roles/**` markdown
  (mostly vendored nvim documentation) are out of scope. `CLAUDE.md` lists the two `tests/`
  files in its index, so they are a defensible future addition — but widening discovery
  would have meant exempting ~25 vendored nvim files in the same commit.
- **No check was made required.** The repo has no branch protection; promoting checks to
  required is its own change with its own ordering rules, and it was not in this batch.

## Follow-ups this creates for later sessions

W20–W26 edit `group_vars/all/main.yml` and the `makefile`. Three docs now declare those
paths in `covers:` — `upgrade-procedures.md`, `ansible_build_commands.md`, `CLAUDE.md` — so
those sessions will see a WARN inside 14 days and an ERROR after. **That is the gate
working, not a defect.** The fix is to re-read the doc against the change and re-stamp the
date; it is not to widen the grace window.
