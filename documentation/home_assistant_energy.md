# Home Assistant — Energy Monitoring

**Status:** current as of 2026-08-13 (dishwasher added; reconciliation check and long-gap
runbook documented). Built in the 2026-08-12 powercalc overhaul.

Home Assistant runs as Proxmox **VM 102** (HAOS) at `192.168.2.102:8123`. It is **not
managed by this Ansible repo** — its config lives in its own private repo,
[`johnmathews/home-assistant-config`](https://github.com/johnmathews/home-assistant-config)
(see "Config repo & access" below). This doc records how energy monitoring works because
this repo is the household's operational source of truth.

## Architecture

```
+---------------------------+--------------------------------------------------------------+
| Layer                     | What it does                                                 |
+---------------------------+--------------------------------------------------------------+
| HomeWizard P1 meter       | Whole-home grid import (2 tariffs) + gas. Ground truth.      |
| Nous metering plugs (z2m) | Real measured power/energy for big appliances.               |
| powercalc (HACS)          | Estimated power for lights + dumb plugs; "Rest Of Home".     |
| Energy dashboard          | 2 grid tariffs, gas, 22 device consumption entries.          |
| Prometheus                | Scrapes HA at :8123/api/prometheus (vault_home_assistant_    |
|                           | token) -> Grafana.                                           |
+---------------------------+--------------------------------------------------------------+
```

Grid prices: tariff 1 €0.24111/kWh, tariff 2 €0.27693/kWh, gas €1.3073/m³.

## Device consumption entries (Energy dashboard)

```
+---------------------------+------------------------------------------+---------------------+
| Entry                     | Sensor                                   | Source              |
+---------------------------+------------------------------------------+---------------------+
| Tech Shelf                | sensor.tech_shelf_energy                 | Nous plug (real)    |
| Dishwasher                | sensor.dishwasher_plug_energy            | Nous plug (real) -  |
|                           |                                          |   re-added 08-13    |
| Washer Dryer              | sensor.washer_dryer_plug_energy          | Nous plug (real)    |
| Office Desk               | sensor.desk_plug_energy                  | Nous plug (real)    |
| Oven                      | sensor.oven_plug_energy                  | Nous plug (real)    |
| Kettle                    | sensor.kettle_plug_energy                | Nous plug (real)    |
| Boiler                    | sensor.boiler_energy                     | Nous plug (real)    |
| Heating Pump              | sensor.heating_pump_energy               | Nous plug (real)    |
| Shoe Cupboard LEDs        | sensor.shoe_cupboard_leds_energy         | Nous plug (real)    |
| Entrance Ceiling Light    | sensor.entrance_ceiling_light_energy     | powercalc LUT L2207 |
| Shoe Cupboard Wall Light  | sensor.shoe_cupboard_wall_light_energy   | powercalc LUT T2035 |
| Street Lamp               | sensor.street_lamp_energy                | powercalc LUT       |
|                           |                                          |   LED2103G5         |
| Kajplats Bulb 1 / 2       | sensor.kajplats_bulb_{1,2}_energy        | powercalc linear    |
|                           |                                          |   1–9.5 W           |
| Plug 1 Spotlights         | sensor.plug_1_spotlights_energy          | fixed 13.3 W        |
| Plug 2 Lamp               | sensor.plug_2_lamp_energy                | fixed 9.2 W         |
| Plug 3 Lamp               | sensor.plug_3_lamp_energy                | fixed 0.4 W (plug   |
|                           |                                          |   self-usage only)  |
| Plug 4 Lamp               | sensor.plug_4_lamp_energy                | fixed 15.4 W        |
| Plug 5 / 6 Filament Lamp  | sensor.plug_{5,6}_filament_lamp_energy   | fixed ~6.4 W (EST.) |
| EV Charger (Enyaq)        | sensor.ev_charger_energy                 | Riemann integral of |
|                           |                                          |   local power (~20s)|
|                           |                                          |   - the Voldt's own |
|                           |                                          |   counters are dead |
| Rest of home (untracked)  | sensor.rest_of_home_energy               | subtract group      |
+---------------------------+------------------------------------------+---------------------+
```

TRETAKT fixture mapping (fixed = bulbs + ~0.4 W plug self-usage; bulbs are non-dimmable so
fixed wattage is exact): plug 1 = 3× SOLHETTA GU10 4.3 W; plug 2 = 1× Majestic 8.8 W + 1×
KAJPLATS (measured separately via its light entity); plug 3 = 1× KAJPLATS only; plug 4 = 3×
5 W screw-ins; plugs 5/6 = decorative filament bulbs, **wattage estimated at 6 W** until read
off the bulbs. KAJPLATS spec: 9.5 W @ 1521 lm. The KAJPLATS bulbs sit behind plugs 2/3, so
they read `unavailable` when the plug is off — powercalc counts that as off (0 W).

**Rest Of Home** = `sensor.p1_meter_power` minus every tracked power sensor (21 members
incl. the EV charger),
integrated to `sensor.rest_of_home_energy`. It makes the untracked baseline (fridge, hob,
network gear, …) a visible line in the dashboard. Before the overhaul ~59% of grid import
was invisible. Value can flicker negative briefly when a big load switches (P1 updates lag
plug sensors); it averages out.

## History: what changed 2026-08-12

The previous system (built March 2025) had two home-grown mechanisms, both retired:

1. **Synthetic light power templates** — `power = max_W × brightness/255` in
   `templates.yaml`, integrated by Riemann `integration:` sensors. Three of six were dead
   (stale entity references after devices were renamed/re-paired), silently reporting 0 W
   for months-to-a-year. Replaced by powercalc, which uses *measured* per-model LUT
   profiles where available (handles LED driver overhead and non-linear dimming curves the
   linear model missed).
2. **"Corrected energy" pattern** — per plug, an `input_number` high-water mark maintained
   by an `update_*_energy_total` automation, mirrored by a `_corrected` template sensor.
   Purpose: guard against counter-reset spikes. Flaw: after a real counter reset it
   silently discards all consumption until the raw counter re-passes the old maximum, and
   it freezes when the source goes unavailable. The dashboard now uses the **raw**
   `total_increasing` plug sensors, whose statistics survive resets natively.

Consequences to be aware of:

- Per-device dashboard history for the three re-implemented lights and the corrected->raw
  switches starts fresh from 2026-08-12 for some entries (raw plug sensors keep their full
  history; the powercalc light sensors are new statistic ids). Grid and gas history is
  untouched. Orphaned old statistics remain in the recorder — Developer tools → Statistics
  will offer to delete them; harmless either way.
- Dropped from the dashboard: TV (deliberate — small load), dishwasher (plug unplugged;
  **re-added 2026-08-13**, see `home_assistant_dishwasher.md`),
  electric heater (plug retired), office/bathroom/living-room lights (devices offline, see
  backlog).

### Counter-reset spike runbook

If a metering plug is factory-reset/re-paired and its energy counter restarts, HA treats
the drop as a meter reset (fine), but if the plug then reports its *old* total once (z2m
retained message) you can get a one-off phantom spike. Fix: **Developer tools → Statistics →
(sensor) → adjust statistic** — find the 5-minute slot with the spike and set its value to
the correct amount. No YAML involved.

### Long-gap sum reset (a different, sneakier failure)

Seen 2026-08-13 with the dishwasher plug after ~106 days unplugged. At the time there was
**no `recorder:` block**, so state history purged after the default **10 days**. When a
`total_increasing` sensor returns from a gap longer than the retention window, HA has no
retained prior state to diff against, treats the sensor as new, and **restarts the
statistics `sum` at zero** — producing a large one-off *negative* bar on the Energy
dashboard equal to the old sum.

Retention is **90 days since 2026-08-14** (see "Recorder retention" below), so the window
in which this can bite is now nine times wider — but note the incident that revealed it
involved a 106-day gap, which would still have tripped it. The failure mode is reduced,
not removed.

The trap: the entity's **state** looks perfectly continuous (it resumed at exactly its old
496.36 kWh), so a state-level check passes while the artifact sits in the statistics layer.
**Always check the `sum`, not just the state**, when a counter comes back from a long
absence.

Fix, non-destructively, via WS `recorder/adjust_sum_statistics`:

```
statistic_id: sensor.<x>_energy
start_time:   <exact hour where sum dropped to 0, ISO8601>
adjustment:   <the old sum, e.g. 471.62>
adjustment_unit_of_measurement: kWh
```

This adjusts that hour and all later rows, restoring the original baseline; reverse it by
adjusting by the negative. `recorder/clear_statistics` is the clean-slate alternative but is
**irreversible**.

## "Rest of home (untracked)" vs "Untracked consumption"

Two similarly-named figures on the Electricity tab that mean different things:

```
+------------------------------+----------------------------------------------+
| "Rest of home (untracked)"   | OURS. sensor.rest_of_home_energy, the        |
|                              | powercalc subtract group: P1 power minus     |
|                              | every tracked power sensor, integrated.      |
|                              | Not a device - an estimate of the untracked  |
|                              | baseline, registered as a device entry so it |
|                              | renders as a slice instead of being invisible|
+------------------------------+----------------------------------------------+
| "Untracked consumption"      | HA's BUILT-IN residual, not configurable:    |
|                              | grid total minus the sum of ALL device       |
|                              | entries - which now includes Rest of home.   |
+------------------------------+----------------------------------------------+
```

Because Rest of home is itself a device entry, HA's built-in figure is no longer "the
untracked load" — it is **the leftover after our estimate**, i.e. the error term of the
Rest of home calculation. Read it as a health metric, not a consumption category.

Reference values (2026-08-13): grid 17.329 kWh, real devices 12.914, Rest of home 3.980,
all entries 16.894, so **Untracked consumption = 0.435 kWh (2.5%)**. Before the 08-12
overhaul the built-in figure was the whole untracked baseline, ~59% of import.

Small and stable is healthy. Growth means drift — a plug gone unavailable, a new load, or a
power sensor misreporting. Note the two are not independent: Rest of home derives from the
same P1 signal as the grid total, so `devices + rest ≈ grid` holds largely by construction.
What it genuinely catches is disagreement between the two *signal paths* — instantaneous
power integration versus the meter's cumulative counters. It is the **same quantity** as the
gap in the reconciliation check below, measured over a different window — 0.435 kWh across the
whole of 13 Aug up to ~19:00 local, versus 0.14 kWh across the clean 16-hour window used
there. Different numbers, same metric; always state the window when quoting either.

## Reconciliation health check

The whole point of the Rest Of Home subtract group is that
`grid ≈ Σ(tracked devices) + Rest Of Home`. Checking that identity is the fastest way to
confirm the energy system is honest.

Verified 2026-08-13 over two windows:

```
+------------------------------+--------+-----------+-----------+----------------+
| Window                       | grid   | dev+rest  | gap       | accounted      |
+------------------------------+--------+-----------+-----------+----------------+
| 24 h to 16:00Z               | 29.32  |   31.51   | -2.19     | 107.5%         |
|   18 of 24 hours within +/-0.03 kWh; the 6 bad hours are all the known EV      |
|   backfill artifact below, which over-attributes one hour and under-attributes |
|   the three before it.                                                          |
+------------------------------+--------+-----------+-----------+----------------+
| 16 h to 16:00Z (excludes     |  9.45  |    9.31   | +0.14     | 98.5%          |
|   the artifact window)       |        |           |           |                |
+------------------------------+--------+-----------+-----------+----------------+
| 5 h spanning a real ~2 kW    |  3.72  |    3.70   | +0.02     | 99.4%          |
|   dishwasher cycle           |        |           |           |                |
+------------------------------+--------+-----------+-----------+----------------+
```

Always quote the window with the number — the percentage is meaningless without it, and the
24 h figure exceeding 100% is the artifact, not a fault. (kWh columns are rounded to 2 dp;
the percentages are computed from unrounded values, so recomputing from the table can differ
by ~0.1 pp.)

**Use the statistics `change` field per hour — not first-to-last `sum` deltas.** A sum-delta
over a window silently lies whenever a series has a discontinuity (a counter reset, a
long-gap sum reset, an `adjust_sum_statistics` call) or when sensors in the comparison were
created on different dates. An early attempt at this check using sum deltas produced a
bogus "25% unaccounted" result and a false alarm about Rest Of Home under-reporting; the
per-hour `change` method showed the system was fine all along.

Method: `recorder/statistics_during_period` with `period: hour`, `types: ["change"]`, over
`grid` + every `device_consumption` id from `energy/get_prefs`; then per hour compare
`grid` against `Σtracked + rest`.

Known benign anomaly: the 12 Aug EV backfill injected ~8.9 kWh into the 23:00 local bucket,
so that hour shows a large negative gap and the preceding charging hours show matching
positive gaps. Cosmetic, already accepted, ages out of any recent window.

## powercalc specifics

- Installed via HACS (v1.24.1), config is YAML-only: `powercalc:` block in
  `configuration.yaml`. Autodiscovery is off (`discovery: enabled: false` — the older
  `enable_autodiscovery` spelling was deprecated by powercalc mid-2026) — every sensor
  is explicit.
- Lights whose model has a measured profile in the powercalc library use LUT mode
  automatically (no strategy in YAML): STOFTMOLN `T2035`, TRADFRI `LED2103G5`,
  JETSTROM `L2207`.
- KAJPLATS (`KAJPLATS_WS`) has no library profile yet → linear 1.0–9.5 W. Revisit when
  <https://library.powercalc.nl> gains the profile.
- `unavailable` counts as "off" (standby_power) — this is what makes smart-bulbs-behind-
  plugs and offline devices behave sanely.

## Recorder retention

`purge_keep_days: 90` since 2026-08-14 (`recorder:` block in `configuration.yaml`). Before
that there was no `recorder:` block at all, so it ran on the default of 10 days.

**One knob covers both resolutions.** `purge_keep_days` governs raw `states` *and*
`statistics_short_term` (the 5-minute mean/min/max buckets) together — there is no separate
setting for either, and no per-entity retention anywhere in HA. Hourly long-term statistics
are a different thing entirely: never purged, already reaching back to 2024-08-12.

Which of the three you are actually looking at matters when a number seems wrong:

```
+------------------------+-------------+-----------+----------------------------------+
| Layer                  | Resolution  | Retention | Written when                     |
+------------------------+-------------+-----------+----------------------------------+
| states                 | per change  | 90 days   | the value CHANGES (or an         |
|                        |             |           |   attribute does)                |
| statistics_short_term  | 5 min       | 90 days   | every 5 min, fixed clock         |
| statistics             | 1 hour      | forever   | every hour, fixed clock          |
+------------------------+-------------+-----------+----------------------------------+
```

Sizing, measured 2026-08-14 rather than estimated: 862k state rows per 10 days works out at
~14.8 MB/day for `states` plus its five indexes, and ~1.5 MB/day for the 5-minute buckets.
So 90 days lands the DB around **1.6 GB**, up from 260 MB. The data partition (`/dev/sda8`,
30.8 GB) had 19.2 GB free. **Disk is not the constraint — the VM's 2 GB of RAM is**, which
is why this stopped at 90 days rather than a year.

**There is deliberately no `exclude:` block, and adding one is a trap.** Excluding an entity
stops HA compiling *statistics* for it as well as recording its states. The obvious
candidates to trim are the P1 per-phase power sensors, which alone are 35% of every state
row:

```
sensor.p1_meter_power              159,299     |  top 5 P1 entities  = 542,426
sensor.p1_meter_power_phase_1      156,132     |  all states         = 862,437
sensor.p1_meter_power_phase_3       91,435     |                       = 63%
sensor.p1_meter_energy_import       83,203     |
sensor.p1_meter_power_phase_2       52,357     |
```

Excluding the three phase sensors would save ~464 MB at 90 days — and freeze 16 months of
accumulating hourly per-phase history (11,685 rows each, since 2025-04-14). Rejected on
those grounds: the saving is 2% of free disk, and the cost is exactly the long-range data
the history UI exists to show.

Changing `purge_keep_days` **requires a restart**; recorder has no reload service. The purge
job runs nightly at 04:12, and `auto_repack` on the second Sunday of the month needs
temporary free space roughly equal to the DB size.

Separately, HA metrics are also scraped into Prometheus every 30 s with 100-day / 22 GB
retention (`documentation/prometheus_lxc.md`) — a coarser but longer-lived copy of the same
signals, useful for Grafana but not visible in the HA UI.

## Config repo & access

- `/config` on the HA box is a git repo pushed to **private**
  `github.com/johnmathews/home-assistant-config` via a write-scoped deploy key in
  `/config/.git-ssh/` (gitignored). The `.gitignore` is a **whitelist** — only hand-written
  YAML is tracked; `.storage/`, `secrets.yaml`, `cloudflared/`, `zigbee2mqtt/`,
  `go2rtc.yaml` (RTSP password) and the recorder DB must never be added.
- Shell access: `ssh john@192.168.2.102` (Advanced SSH & Web Terminal add-on, password auth
  — password in the add-on's Configuration tab). `sudo` is passwordless. HA config lives in
  `/config`. Validate YAML before restart: `POST /api/config/core/check_config`.
- API access: long-lived token in Ansible vault as `vault_home_assistant_token`.

## Jobs to be done (backlog, 2026-08-13)

```
+----+------------------------------------------------------------------+----------------+
| #  | Job                                                              | Unblocks       |
+----+------------------------------------------------------------------+----------------+
| 1  | Dishwasher: DONE 2026-08-13, end to end. Nous plug reconnected,  | DONE           |
|    |   energy sensor on the dashboard, power sensor in the Rest Of    |                |
|    |   Home subtract list, Home Connect integration live (16 enabled  |                |
|    |   entities), per-cycle attribution built, first cycle measured   |                |
|    |   at 0.88 kWh vs the 0.65 kWh label. Rest Of Home verified       |                |
|    |   under ~2 kW load (99.4% reconciled). The counter did NOT       |                |
|    |   resume cleanly - the statistics sum reset to 0, a -471.62      |                |
|    |   kWh artifact, repaired with adjust_sum_statistics; see the     |                |
|    |   long-gap runbook above. The appliance itself reports NO        |                |
|    |   energy (Home Connect exposes no kWh) - full detail in          |                |
|    |   home_assistant_dishwasher.md. Remaining: 4-6 weeks of          |                |
|    |   cycles to build a per-programme calibration table              |                |
| 2  | SUPERSEDED 2026-08-14 by home_assistant_lighting.md, and the     | light tracking |
|    |   description below was wrong on both counts. There is no        | for 6 panels   |
|    |   "defunct ZHA network" (the ZHA entry has zero entities and     |                |
|    |   no Matter/Thread entry exists at all), and "Ikea Smart         |                |
|    |   Lightbulb 1/2" are KAJPLATS bulbs, not JETSTROM panels.        |                |
|    |   Reality: 6 of 7 JETSTROM panels are Touchlink-paired direct    |                |
|    |   to their STYRBAR remotes and on NO network. Migration is a     |                |
|    |   z2m group + remote-to-group binding per zone, staged over 5    |                |
|    |   phases. powercalc entries (L2207 has a LUT profile) follow     |                |
|    |   once each panel is on the network.                             |                |
| 3  | Living-room / dinner-table lights: old template referenced       | living room    |
|    |   light.dinner_table_1 (gone). KAJPLATS bulbs now cover plugs    | clarity        |
|    |   2/3; verify nothing else is missing                            |                |
| 4  | Read real wattage off the two filament bulbs (plugs 5/6),        | accuracy       |
|    |   update the two fixed powers in configuration.yaml              |                |
| 5  | Consider a Nous metering plug for the fridge — likely the        | biggest        |
|    |   biggest single untracked load in Rest Of Home                  | untracked sink |
| 6  | Remove electric-heater leftovers if the plug is truly retired    | tidiness       |
|    |   (z2m device removal)                                           |                |
| 7  | EV charger (cable side): DONE, and since 2026-08-13 fully        | DONE           |
|    |   LOCAL via tuya-local (was xtend_tuya cloud 2026-08-12).        |                |
|    |   Static lease for 192.168.2.29 (MAC d8:fc:92:93:f5:7d) on       |                |
|    |   the MikroTik. Rest Of Home verified sane across a full         |                |
|    |   charge (mean +223 W, 0.9% negative samples, all sub-minute     |                |
|    |   switching transients - no kW/W unit error). Power now          |                |
|    |   samples every ~20 s instead of hourly, so the energy           |                |
|    |   integral is a measurement not an estimate; this depends on     |                |
|    |   automation.ev_cable_keep_power_live, which fails QUIETLY.      |                |
|    |   See home_assistant_ev_charging.md.                             |                |
| 8  | EV car side: DONE via MySkoda (HACS) 2026-08-13. Once ~5 kWh     | EV charging    |
|    |   has been charged, sanity-check sensor.ev_charging_efficiency   | efficiency     |
|    |   against the expected mid-80s%; a wildly-off figure means the   |                |
|    |   58 kWh pack constant or the work_state gating needs revisiting |                |
| 9  | OPEN: after the next charge that runs with NO Home Assistant     | confirm the    |
|    |   restart mid-session, compare sensor.voldt_ev_cable_last_charge | energy figures |
|    |   (the device's own meter, finalised at session end) against the |                |
|    |   rise in sensor.ev_charger_energy over that same session.       |                |
|    |   First attempt 2026-08-13 gave 3.18 vs 3.120 kWh = integral     |                |
|    |   1.9% low, with the whole deficit in the 5-min window where HA  |                |
|    |   was restarted to load new YAML - so "the restart caused it" is |                |
|    |   STRONGLY SUPPORTED, not confirmed. Expect <0.5% on a clean     |                |
|    |   run. A persistent multi-percent gap instead means              |                |
|    |   automation.ev_cable_keep_power_live is missing refresh windows |                |
+----+------------------------------------------------------------------+----------------+
```

## Audit numbers (pre-overhaul, for reference)

30 days before 2026-08-12: grid import 374 kWh, tracked devices 152 kWh (41%). Dead
sensors at the time: TV (since 2026-02-10), dishwasher (2026-04-29), office light
(~2025-08), bathroom + living-room lights (≥1 year). The Rest Of Home sensor now makes
any future silent failure visible as an unexplained rise in the untracked line.
