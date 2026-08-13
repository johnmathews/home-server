# 2026-08-13 — Dishwasher energy monitoring (Bosch Home Connect)

## What prompted it

New Bosch dishwasher installed ~May 2026. The old dishwasher's Nous metering plug was
unplugged 2026-04-29 and never reconnected, so the appliance has been completely untracked
since — part of the ~59% of grid import sitting in Rest Of Home. John asked to find the
dishwasher on the wifi network and add it to HA for energy tracking, noting it is controlled
via the Bosch Home Connect app and has a static lease at 192.168.2.39.

## Finding the appliance

Confirmed in a couple of minutes from the static lease:

- Responds to ping at `192.168.2.39`, MAC `48:26:4C:6D:4B:FA`.
- OUI resolves to **BSH Electrical Appliances (Jiangsu)** — Bosch/Siemens. Right device.
- Port scan: **443 only** (80, 8080, 8443 closed).
- `openssl s_client` against 443 returns **no peer certificate** and negotiates a PSK-only
  cipher. That is the signature of the Home Connect **local** protocol — the appliance is
  locally controllable without the cloud, given its PSK key.

## The finding that changed the design

**The dishwasher cannot report its own energy use.** Home Connect appliances have no
internal power meter, and the API's only energy field is
`BSH.Common.Option.EnergyForecast` — a *percentage of maximum*, not kWh. True of the
official integration and of the local protocol.

This matters because the Home Connect phone app *does* show a per-cycle energy figure, which
naturally reads as "the data exists, just fetch it". It doesn't: the app's number is modelled
on the appliance (heater wattage × element run-time, probably decent) and **is not exposed
over the API**. The app is a display, not a data source.

So "add the dishwasher to HA" and "measure its energy" turned out to be two separate jobs,
and the second one needs a metering plug regardless.

### The ±5% question

John asked whether a static per-program lookup ("every eco cycle = 1.1 kWh") would land
within 5%, since that would avoid using the plug at all. Answer: no, and the reasoning is
worth recording.

The dominant term is heating water, `E = m·c·ΔT`. Dutch mains inlet runs ~8 °C in winter to
~18 °C in late summer. For ~9 L heated to 50 °C that is 0.44 kWh vs 0.34 kWh — a 0.105 kWh
spread, **11.4% of a 0.92 kWh eco cycle**, so ±5.7% about the mean. That consumes the entire
error budget on its own, and critically it is a *systematic seasonal bias rather than noise*,
so it does not average out over a month — it just makes winter totals consistently high.

Stacked on top: published figures are EU test-bench numbers (fixed 15 °C inlet, standard
load and soil); Auto programs genuinely vary with the soil sensor; Extra Dry / SpeedPerfect
shift consumption without changing the program name; standby draw is invisible to a lookup;
aborted cycles would count as full ones. Realistic: ±10–20% per cycle, ~±10% monthly.

Agreed plan: use the plug, which John already owns and which is still paired. If a
lookup-only mode is ever wanted, derive the constants from *measured* data — far better than
manufacturer nominals, with a known error instead of an assumed one.

## What was done

1. **`sensor.dishwasher_plug_power` added to the powercalc Rest Of Home subtract group** in
   `/config/configuration.yaml`. Validated via `POST /api/config/core/check_config`
   (`valid`), applied with a core restart.
2. **`sensor.dishwasher_plug_energy` added to the Energy dashboard** as "Dishwasher" via the
   `energy/save_prefs` WebSocket call — device entry 22.
3. **Verified safe while the plug is still unplugged.** This was the actual risk: adding an
   `unavailable` member could have taken the whole subtract group to `unknown` and silently
   broken a working sensor. Post-restart it read `unknown` briefly during warm-up, then
   settled at **314 W with the dishwasher member contributing 0**. Baseline before the
   change was 263 W against a P1 reading of 416 W, so the group is behaving.
4. **Committed and pushed** `/config` to `johnmathews/home-assistant-config` (`0e26a57`).
5. **Documentation**: new `documentation/home_assistant_dishwasher.md`; energy doc updated
   (dashboard table, JTBD #1 rewritten, dropped-devices note).
6. **John reconnected the plug the same session**, and it verified clean: power 0 W (idle),
   energy 496.36 kWh, switch on, Rest Of Home 248 W against P1 386 W.
   I recorded **"no phantom spike"** at this point — the last statistic before the April
   outage was `state=496.36` and it resumed at exactly 496.36, so the counter appeared to pick
   up where it left off. **⚠️ This conclusion was WRONG and is retracted later in this entry —
   see "The -471.62 kWh phantom spike" below.** The state was continuous; the statistics `sum`
   was not, and I had only checked the state. Left here as written, with this pointer, because
   the sequence is the lesson.
   `power_outage_memory` was already `on`, which is the setting we want (relay closes
   unconditionally after a cut); `restore` would have been wrong, since it reinstates the
   pre-cut state.

7. **Home Connect integration went live the same session.** John registered the developer
   app; credentials added via `application_credentials/create` over WebSocket, then the
   config flow driven headlessly (`POST /api/config/config_entries/flow`, handler
   `home_connect`) — it returns an `external` step whose `url` John opened to approve.
   Entry `01KZXXREB7PXKJ5EWDD0B4XPRY`, state `loaded`, **17 entities visible at that moment**.
   The Cloudflare Zero Trust redirect worried me beforehand and turned out to be a non-issue.

   Appliance identified as a **Bosch SMV6YCX00E** (Series 6, 60 cm, 14 place settings).
   Confirmed: **no energy entity**, exactly as predicted.

   *Later correction (same session, during wrap-up):* the registry actually holds **20**
   entities — **16 enabled, 4 disabled by the integration**. Three option switches
   (`extra_dry`, `half_load`, `hygiene`) appeared after that first look, and I had counted the
   4 disabled ones as live. I reported "17" as a fact when it was a snapshot of a still-settling
   integration. Corrected in `documentation/home_assistant_dishwasher.md`; the disabled four
   produce no state, so anything built on them would never fire.

### The label figures sharpen the earlier argument

The model's EU label reads **65 kWh/100 cycles (0.65 kWh eco), 9.5 L, 3:55, class B**. My
rejection of the static-lookup approach had been computed against a *guessed* ~0.92 kWh
cycle and 9 L. Redone with the real figures the case is stronger, not weaker: 9.5 L across
an 8→18 °C inlet swing is a 0.111 kWh spread, which is **17.1% of a 0.65 kWh cycle** (±8.5%
about the mean) rather than 11.4%. Even assuming only ~7 L reaches full temperature it is
12.6%.

The general point is worth remembering: *the lower a cycle's total energy, the larger the
same absolute seasonal swing looms in relative terms.* Guessing the cycle high made the
lookup approach look better than it is.

**⚠️ Retracted later the same day.** The first measured cycle came in at **0.88 kWh** — within
5% of the original ~0.92 kWh guess. So the guess was fine and the 0.65 kWh *label* was the
outlier; the case did not get "stronger", I had just swapped a good denominator for a
test-bench one. Against the measured cycle the spread is 12.6%, not 17.1%. **The conclusion
(reject the static lookup) is unaffected — it clears the ±5% bar on any denominator — but the
reasoning above is wrong and is corrected in `documentation/home_assistant_dishwasher.md`.**
Worth noting how this happened: I "corrected" a sound estimate toward an authoritative-looking
published figure, and the published figure was the one that didn't describe reality.

## Per-cycle attribution (built and smoke-tested the same session)

Two automations subtract the plug's cumulative counter between Home Connect's `run` and
`finished` states, into `sensor.dishwasher_last_cycle_energy`.

The design constraint that shaped it: there is **no `recorder:` block**, so HA runs the
default `purge_keep_days: 10`. State history — and therefore cycle boundaries — is gone
after ten days, which kills the tempting "build nothing, reconstruct it from the recorder
later" approach for a 4–6 week calibration. Long-term statistics survive indefinitely, so
the template sensor carries `state_class: measurement` to get the per-cycle values (and
their spread) into LTS. Deliberately no `device_class: energy`; HA rejects that pairing.

Mid-build improvement: the start trigger began as an enumerated
`from: [ready, inactive, delayedstart]` and was switched to `not_from: [pause, run]`. The
enumeration silently misses `unknown -> run`, which is exactly what happens if HA restarts at
the moment a cycle begins — and I had just restarted HA minutes before what I believed was an
imminent cycle start.

Smoke-tested by driving `operation_state` through the REST API while the machine sat idle:
start snapshot (496.36 + eco_50), finish arithmetic (1.0 kWh, programme copied), and the
pause -> run guard (sentinel 100.0 held, no re-snapshot). **The plug's own
`total_increasing` counter was never overridden** — faking it would have injected a phantom
kWh into the Energy dashboard, the precise artifact avoided earlier the same day.
Consumption was simulated by lowering the start snapshot instead. Helpers reset afterwards
and the test statistic wiped via `recorder/clear_statistics`.

Committed as `6264055` in the HA config repo.

## The -471.62 kWh phantom spike (and a verification mistake)

John spotted a huge bar on the Energy dashboard shortly after the plug went back in, and
guessed the three-month gap was behind it. He was right.

The statistics **cumulative sum** for `sensor.dishwasher_plug_energy` was reset from 471.62
to 0 when the plug returned, rendering as a -471.62 kWh Dishwasher bar. Cause: the plug was
gone ~106 days, but with no `recorder:` block HA purges state history after 10 days, so on
return there was no retained prior state to diff the counter against. HA treated the sensor
as new and restarted the sum at zero.

**The mistake worth recording**: earlier the same session I explicitly reported "no phantom
spike", having verified that the sensor's *state* resumed at exactly 496.36 — matching its
April value. That check was real but insufficient. For a `total_increasing` sensor the
artifact lives in the statistics `sum`, not the state, and the state looking perfectly
continuous is exactly what makes this failure sneaky. State continuity does not imply
statistics continuity across a gap longer than `purge_keep_days`.

Fixed non-destructively with WS `recorder/adjust_sum_statistics` at the reset hour,
`adjustment: 471.62`, unit kWh — it adjusts that hour and every later row, restoring the
original baseline. Verified: the 2026-08-13 daily row now reads sum=471.62, change=0.00.
Reversible by adjusting -471.62. The alternative (`recorder/clear_statistics`) would give
the new appliance a clean slate but destroys the old machine's history irreversibly; John
chose continuity.

Blast radius was narrow: the earlier 24 h energy audit was unaffected, because the
dishwasher's accrual there computed as 0 - 0 = 0 rather than -471.62.

## First real cycle — everything verified

An Eco 50 ran 17:05–21:20 UTC. The whole chain worked on genuine Home Connect transitions:

```
+------------------------------------------+----------------------------------+
| Measured cycle energy                    | 0.88 kWh                         |
| EU label figure                          | 0.65 kWh   -> +35%               |
| Programme captured automatically         | eco_50                           |
| Arithmetic check                         | 497.24 - 496.36 = 0.88  correct  |
| Peak draw                                | 1984 W                           |
| Reconciliation over the cycle window     | 99.4% accounted (0.02 kWh gap)   |
+------------------------------------------+----------------------------------+
```

**+35% over the label on the first cycle, in late summer** — the most favourable point in the
seasonal range, since mains inlet is at its warmest. n=1 is not a calibration, but the
direction matches the seasonal argument that killed the static-lookup idea, and the gap is
far larger than the ±5% that approach needed.

Peak 1984 W confirms the 2400 W gauge max is right and that the original 1800 W would have
pegged — the guess held up, now on evidence.

**Rest Of Home under real load** (the last open verification) behaved as designed: transient
dips to about **-1595 W** in 3 of 4 cycle hours, a magnitude roughly equal to the appliance's
own draw. That is meter lag — the plug reports the ~2 kW load before P1 does — and it averages
out, as the 99.4% reconciliation shows.

## Notes for next time

- Chose the **official cloud integration** over local hcpy: energy is already local via the
  plug, so the cloud only carries cycle labelling, and that did not justify a new
  Ansible-managed service. hcpy stays on the table — it is the only route that might expose
  richer local data points, at the cost of being unofficial and periodically broken by Bosch
  login-flow changes.
- The HA SSH password and the `sudo` + explicit `GIT_SSH_COMMAND` incantation for `/config`
  git were both needed again; already captured in memory, and both still correct.

## Wrap-up (`/done`) — the doc audit earned its keep

The wrap-up's adversarial documentation audit was dispatched to a subagent, and it found
**four blocking errors in docs I had written hours earlier and believed were accurate**. That
is the whole argument for not self-certifying this phase, so it is worth recording concretely:

1. **`Status:` header said per-cycle attribution was "not yet built"** while the same file had
   a section titled "built 2026-08-13" describing it in detail. I updated the body and never
   revisited the header.
2. **The energy doc's backlog still said Home Connect was "blocked on developer credentials"**
   — hours after it went live. A reader consulting the backlog would have concluded the work
   was pending.
3. **The same backlog entry still claimed the counter "resumed with no spike"** — the exact
   claim I had already retracted at length 100 lines earlier in the same file. I corrected the
   narrative section and left the summary table asserting the original error.
4. **"17 entities" was wrong in both directions**: the registry holds 20 — 16 enabled, 4
   disabled by the integration. I had counted 4 dead entities as live and missed 3 option
   switches that appeared later. Consequential, not cosmetic: anything built on
   `sensor.dishwasher_programme_finished` would never fire, because it produces no state.

The pattern in 1–3 is identical and worth naming: **I corrected the prose and left the summary
standing.** Headers, status lines and backlog tables are exactly where stale claims survive a
careful re-read, because re-reading pulls you to the detailed section that is already right.

The audit also caught something I would not have thought to look for: `documentation/vault.md`
now promises that the vaulted Home Connect credentials exist for disaster recovery, but
`disaster-recovery.md` did not mention Home Assistant **at all** — VM 102 was absent from the
backed-up list despite PBS holding 21 snapshots of it (verified, not assumed). One doc made a
promise the receiving doc had never heard of.

Other wrap-up findings:

- **Lint**: `make lint` exits 2 with 16 failures / 240 warnings. Verified pre-existing by
  stashing my changes and re-running — identical result, and no finding references any file
  this session touched. Not fixed, deliberately: it is the repo's documented baseline
  ("warnings only, non-blocking").
- **Security**: clean. Explicitly grepped tracked files for the Home Connect client ID and
  secret, the HA SSH password, and the HA JWT — none present. Vault encrypted at rest,
  `.vault_pass.txt` untracked.
- **`.venv` was tracked as a self-referential symlink** and broke `git pull --rebase`
  mid-session. Fixed upstream by `056efba` ("Stop tracking .venv, and ignore it") — not by me;
  it arrived with a pull.
- **Tests**: no executable code changed, so the bats suite (which covers `roles/sleep_hours`)
  has no bearing. The one machine-consumed change, the vault file, was verified with its real
  consumer: `ansible-inventory` loads 17 hosts, exit 0, both new keys visible.

## What is deliberately not done

- **No per-cycle capture of the option switches** (`extra_dry`, `half_load`, `hygiene`,
  `vario_speed`), even though they demonstrably change a cycle's energy without changing its
  programme name. Two cycles logged as `eco_50` are therefore not strictly comparable. Deferred
  because it is premature to add fields before knowing whether the measured spread is even wide
  enough to need explaining — but it is the first thing to try if it is.
- **hcpy / local Home Connect protocol not pursued.** The appliance speaks it (port 443,
  PSK-only TLS, confirmed). Energy already arrives locally via the plug, so the cloud
  integration only carries cycle labelling; a new Ansible-managed service was not worth it for
  secondary telemetry.
- **The `-471.62 kWh` artifact was repaired, not investigated further.** I know *what* happened
  (statistics sum reset to 0 across a gap longer than `purge_keep_days`) and the fix holds, but
  I did not read HA's recorder source to confirm the precise mechanism. Graded *strongly
  supported*, not confirmed.
- **`purge_keep_days` left at the default 10.** Raising it would make long-gap sum resets less
  likely and allow retrospective cycle reconstruction, but it grows the recorder DB and is a
  whole-instance change made on the strength of one incident. Flagged, not taken.
- **The KAJPLATS bulbs were not repaired** — offline Matter devices, pre-existing backlog,
  outside this session's scope.
- **The four integration-disabled entities were left disabled.** Enabling them would give
  event-based cycle-finished detection, but `operation_state` already works and is proven.

## Still open

- **Calibration**: 4–6 weeks of cycles, then compare measured per-programme energy and its
  spread against the 0.65 kWh label figure.
- **KAJPLATS bulbs** remain offline and contribute nothing (pre-existing backlog).

### Footnote: a timing inference that was wrong

Mid-session I predicted a ~16:27 UTC cycle start from `programme_finish_time` (20:22) minus
the spec-sheet 3:55 duration. `number.dishwasher_start_in_relative` read 16260 s, which did
not reconcile; I noticed the inconsistency and did not chase it. John had set a 5-hour delay
and then cancelled it — that field holds the *configured* delay, not a live countdown.
