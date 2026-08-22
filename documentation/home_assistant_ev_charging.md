# Home Assistant — EV Charging (Voldt granny cable + Skoda Enyaq)

**Status:** current — verified 2026-08-13 · covers: live
Cable side **fully local via tuya-local since 2026-08-13** (was Tuya cloud 2026-08-12 to
2026-08-13); car side since 2026-08-13 (MySkoda). Tracks charging of the **Skoda Enyaq** on
the **Voldt Type 2 granny cable** (8–13 A, ~2.9 kW, WiFi). In the Energy dashboard as
**"EV Charger (Enyaq)"**.

There are two independent halves, and the distinction matters constantly:

```
+-------------+---------------------------+----------------------------------------------+
| Half        | Source                    | Measures                                     |
+-------------+---------------------------+----------------------------------------------+
| Cable side  | Voldt charger, LAN        | Energy leaving the wall. Feeds the Energy    |
|             |   (tuya-local)            |   dashboard and all cost figures.            |
| Car side    | Skoda Enyaq, MySkoda      | State of charge, range, odometer, plug and   |
|             |   cloud (HACS)            |   charging state. Feeds the efficiency calc. |
+-------------+---------------------------+----------------------------------------------+
```

Neither can replace the other: the cable does not know the battery, and the car does not
report kWh drawn from the wall.

## If something looks wrong, start here

```
+------------------------------------+--------------------------------------------------+
| Symptom                            | Most likely cause                                |
+------------------------------------+--------------------------------------------------+
| EV kWh drifting from the P1 meter, | automation.ev_cable_keep_power_live is off or    |
| or power flat at one value for     |   broken. It presses DP 27 every 4 min while     |
| ~an hour at a time                 |   charging; without it the firmware only         |
|                                    |   refreshes power ~hourly. Used to fail          |
|                                    |   silently; since 2026-08-14 the red banner on   |
|                                    |   the dashboard catches it. Check FIRST.         |
|                                    |   See "The refresh trick" and "The watchdog".    |
| Battery-side energy stopped, or    | sensor.ev_battery_energy_gained is gated on      |
| efficiency creeping upward         |   sensor.voldt_ev_cable_status == 'charging'.    |
| toward 100%                        |   Renaming that entity, OR changing the enum     |
|                                    |   value, breaks it SILENTLY.                     |
| Charging time / session counters   | Same entity + same enum value, via the two       |
| stuck at 0                         |   history_stats sensors. Also silent.            |
| Dashboard cards "not available"    | Cable entity renamed. Visible, so easy.          |
| Lifetime energy sensor reads 0     | Expected. DP 1 is dead in firmware. Not a bug,   |
| (sensor.voldt_ev_cable_energy)     |   and it is not the sensor anything uses.        |
| Cable temperature more than 3 min  | Both refresh automations are off/broken. While   |
| stale while idle                   |   idle, temperature is refreshed every 3 min     |
|                                    |   by "EV cable refresh temperature while idle".  |
|                                    |   binary_sensor.ev_cable_refresh_stale now       |
|                                    |   detects this - see "The watchdog".             |
| Red banner at the top of the EV    | Exactly what it says: DP 27 has not been pressed |
| Charging dashboard                 |   for over 6 min, so every cable reading on the  |
|                                    |   page is frozen. Check both automations.        |
| Voltage / current read 0 while     | Expected, always. DP 6 only reports during a     |
| idle                               |   session; refreshing does not change that.      |
| Want to check the energy figures   | Compare sensor.voldt_ev_cable_last_charge (the   |
| are actually right                 |   device's own meter) against the rise in        |
|                                    |   sensor.ev_charger_energy over that session.    |
|                                    |   See "Use DP 25 to audit the integral".         |
| 12 Aug shows a +9/-9 kWh hourly    | Known, accepted, cosmetic. Do NOT "fix" it.      |
| pair in the Energy dashboard       |                                                  |
+------------------------------------+--------------------------------------------------+
```

Two things never to do: press `button.voldt_2_4_5g_clear_energy` (resets the lifetime
counter), and set the charging mode to anything but `immediate` (`scheduled_charge`
blocks charging outright).

## How the cable side works

The cable is a white-label **Tuya** device (category `qccdz`, EV charger). Since
2026-08-13 it is read **locally over the LAN** by **tuya-local** (HACS,
`make-all/tuya-local`), using its built-in `voldt_ev_charger` profile. No cloud is in the
path for any sensor that matters.

> **"DP" = datapoint.** Tuya models every device as a set of numbered, typed datapoints —
> that is the entire protocol surface, over both the cloud API and the LAN. Each HA entity
> is a mapping of one DP. Numbers, not names, are what the protocol addresses.

### The full datapoint map

Enumerated 2026-08-13 by read-only local queries **while the cable was idle**, reconciled
against what the Tuya cloud declares (`local_strategy` in the xtend_tuya diagnostics) and
what tuya-local's `voldt_ev_charger` profile maps. The "device" column therefore means
"returned by an idle status query" — DP 6 is the one entry that is absent at idle but
present during a session.

```
+-----+---------+--------+----------+--------------------------------------------------+
| DP  | device  | cloud  | profile  | What it is                                       |
+-----+---------+--------+----------+--------------------------------------------------+
|  1  |  yes    |  yes   |  yes     | forward_energy_total, /100 = kWh. DEAD - always  |
|     |         |        |          |   0, in firmware, not just over the cloud.       |
|  3  |  yes    |  yes   |  yes     | work_state (enum) -> sensor..._status            |
|  4  |  yes    |  yes   |  yes     | charge_cur_set, A -> number..._set_current       |
|  5  |   -     |  yes   |   -      | sigle_phase_power. Cloud declares it; the device |
|     |         |        |          |   never returns it, and it read 0 via the cloud. |
|  6  |   -     |   -    |  yes     | voltage + current + power packed into one base64 |
|     |         |        |          |   blob. NOT declared by the cloud. Appears only  |
|     |         |        |          |   during a session. The working power source.    |
|  9  |  yes    |  yes   |  yes     | power_total, /1000 = kW -> sensor..._power       |
| 10  |  yes    |   -    |  yes     | fault bitmask. NOT declared by the cloud.        |
|     |         |        |          |   -> binary_sensor..._problem                    |
| 14  |  yes    |  yes   |  yes     | work_mode (enum) - keep on immediate             |
| 15  |  yes    |  yes   |   -      | balance_energy. Dead (always 0); the profile     |
|     |         |        |          |   deliberately leaves it unmapped.               |
| 16  |   -     |  yes   |   -      | clear_energy. Declared, never returned locally.  |
| 17  |   -     |  yes   |   -      | energy_charge. Declared, never returned locally. |
| 18  |  yes    |  yes   |  yes     | switch -> switch.voldt_ev_cable. DRIVES A        |
|     |         |        |          |   CONTACTOR. Never put this on a timer.          |
| 22  |   -     |   -    |  yes     | software_version. Profile maps it; absent here.  |
| 23  |  yes    |   -    |  yes     | firmware version, "V4.1.6". NOT declared by the  |
|     |         |        |          |   cloud.                                         |
| 24  |  yes    |  yes   |  yes     | temp_current, integer C -> sensor..._temperature |
| 25  |  yes    |  yes   |  yes     | charge_energy_once, /100 = kWh. Accurate         |
|     |         |        |          |   per-session meter; finalises at session end.   |
| 27  |  yes    |   -    |  yes     | metering refresh / link state. NOT declared by   |
|     |         |        |          |   the cloud - the DP this whole migration is     |
|     |         |        |          |   about. -> button..._refresh                    |
+-----+---------+--------+----------+--------------------------------------------------+
```

Three things worth drawing out:

- **Four DPs (6, 10, 23, 27) are invisible to the Tuya cloud.** They are absent from the
  device's declared `status_range`, so no cloud integration can read or write them at any
  price. DP 27 is the one that matters; DP 6 and DP 10 are useful bonuses.
- **The cloud advertises a broken power DP and hides the working one.** It declares DP 5
  (`sigle_phase_power`, permanently 0) and never mentions DP 6, which carries real
  voltage, current and power together.
- **Three DPs (5, 16, 17) are declared but never returned.** Do not build on them.

A press of `button..._refresh` writes the string `online` to DP 27. The value sticks — it
reads back `online` afterwards — and re-writing the same value still triggers a refresh,
so the automations do not need to toggle it. Caveat on completeness: the enumeration only
sees DPs the device volunteers in a status query, so a write-only DP would not appear.

Device ID `bff9a892e0eb9fa22bwmyp`, MAC `d8:fc:92:93:f5:7d`, LAN IP `192.168.2.29`
(static lease), protocol 3.5, firmware V4.1.6. The tuya-local config entry is named
**"Voldt EV Cable"**, so its entities are `*.voldt_ev_cable_*`.

The two cloud integrations (**official Tuya** + **xtend_tuya**, both logged into the Smart
Life account) are still installed but nothing depends on them. They are kept only as a
fallback and as the easiest source of the local key. The Voldt is the **only** device on
that Smart Life account, so removing them would cost nothing else.

```
+------------------+-------------------------------------------------------+
| Path             | Role                                                  |
+------------------+-------------------------------------------------------+
| tuya-local (LAN) | LIVE. Every sensor the EV chain uses.                 |
| Tuya + xtend     | Idle fallback. Same DPs, hourly, and no DP 27.        |
+------------------+-------------------------------------------------------+
```

### The refresh trick — the whole reason local is better

The Voldt's firmware does **not** keep its power/voltage/current registers up to date. It
refreshes them only on an internal ~3600 s timer, so `power_total` reads a stale value
(usually `0`) for up to an hour into a charge. This is a firmware behaviour, not a cloud
throttle: polling the device directly over the LAN returns the same stale `0`.

The device has a hidden datapoint, **DP 27**, which forces a metering refresh. tuya-local
exposes it as `button.voldt_ev_cable_refresh`. Pressing it makes the device report real
power, voltage and current **every ~20 s for about 5 minutes**, then it falls silent again.

```
+---------------------------+--------------------------------------------------+
| Measured (2026-08-13)     | Two presses gave live windows of 295 s and 281 s |
|                           |   with 20 s updates (occasional 40 s).           |
+---------------------------+--------------------------------------------------+
```

**DP 27 is reachable only locally.** It is absent from the device's Tuya cloud
`status_range` entirely, so no cloud integration can ever press it. That is the real
reason the cloud route was stuck at hourly power, and the single biggest gain from
going local.

The automation **"EV cable keep power live"** (`automations.yaml`) presses the button when
`sensor.voldt_ev_cable_status` becomes `charging` and every 4 minutes while it stays
charging — comfortably inside the ~5 minute window.

**Temperature needs the same treatment when idle.** The refresh also updates the
temperature register, and nothing else does — so between charges the reading would freeze
at its end-of-charge value and a cooling cable would keep reading hot indefinitely. A
second automation, **"EV cable refresh temperature while idle"**, presses every 3 minutes
whenever the status is not `charging`. Verified 2026-08-13: presses tracked the cable
cooling 53 -> 50 -> 48 -> 47 -> 46 C.

Idle presses yield a **single** fresh sample rather than a rolling window.

### Why 3 minutes

A "press" here is just a Tuya LAN command setting DP 27 — no relay, no moving part, and
nothing that appears to be written to non-volatile memory. (DP 18, the session switch,
*does* drive a contactor. Never put that on a timer.) So the cost of polling is
essentially nil, and the interval is set purely by what the data can support.

Two hard ceilings cap the useful rate:

1. **DP 24 is an integer.** Whole degrees only — 1 C is the finest resolution obtainable
   at any sampling rate.
2. **The value only moves on a degree crossing.** Post-charge cooling is asymptotic:
   ~1 C per 4 min immediately after a charge, stretching past 8 min within half an hour,
   then effectively flat near the ~40 C settled idle figure.

3 min sits just below that fastest observed change rate, so every crossing is caught
promptly. Going faster was measured, not guessed: pressing every 60 s during the fastest
cooling phase gave **2 distinct readings from 12 presses**, and it only gets more redundant
as the cable settles. Sampling below the change rate buys detection *latency*, never
resolution — and a cable and plug have enough thermal mass that nothing develops in 60 s
that is not equally visible minutes later.

```
+----------+-----------+------------------------------------------------------+
| Interval | Presses   | Verdict                                              |
|          | /day      |                                                      |
+----------+-----------+------------------------------------------------------+
|  15 min  |       96  | Too coarse - skips ~4 C during early cooldown.       |
|   5 min  |      288  | Fine, but can lag a crossing by ~1 min.              |
|   3 min  |      480  | CURRENT. Just below the fastest change rate.         |
|   1 min  |     1440  | ~83% redundant at best, >95% once settled. No new    |
|          |           |   information at any point.                          |
+----------+-----------+------------------------------------------------------+
```

**Charging needs no equivalent tuning.** The `/4` keep-alive holds a window open
continuously, and inside a window the device pushes on every degree crossing — so
temperature is already effectively 20 s sampled while charging. Confirmed by a nine-minute
flat stretch at 52-53 C mid-charge with the window open throughout: not under-sampling,
just no crossing to report.

Voltage and current stay at 0 while idle no matter how often you refresh: DP 6 only
reports during a session.

### The watchdog — added 2026-08-14

Everything above depends on two automations that fail *silently*. When they stop, the
tuya-local entities do not go `unavailable` — the LAN connection is fine, the device just
keeps handing back the last value it latched. A cooling cable reads hot forever and the
energy integral quietly degrades from a measurement to an estimate, with nothing on screen
to say so.

`binary_sensor.ev_cable_refresh_stale` (in `/config/templates.yaml`) closes that gap. It
watches **`button.voldt_ev_cable_refresh`**, whose state *is* an ISO timestamp of its own
last press:

```
button.voldt_ev_cable_refresh   09:30   "2026-08-14T09:30:00.232783+00:00"
button.voldt_ev_cable_refresh   09:27   "2026-08-14T09:27:00.232412+00:00"
```

That single entity covers both automations at once, since both act on it. It trips at
**360 s** — the slower automation is the `/4` keep-alive, so the worst healthy gap is a
little over 4 min. A missing or unparseable timestamp counts as stale: button state
survives a restart (the entity has read `unknown` exactly once, when tuya-local created it
on 2026-08-13, across every restart since), so an absent one is a real fault. The cable
going offline also trips it, correctly — no device, no presses, no fresh readings.

**Do not be tempted to watch `sensor.voldt_ev_cable_temperature`'s own `last_changed`
instead.** DP 24 is an integer and a settled idle cable legitimately holds 40 C for hours;
that rule would alarm more or less permanently. The press timestamp is the honest signal.

A `conditional` card at the top of the dashboard's "Right now" section renders an
`ha-alert` when it trips. The dashboard is storage-mode, so that half lives in
`/config/.storage/lovelace.ev_charging` and is **not** git-tracked — it is only in the
GitHub repo as this description.

### Why the temperature chart says "5 minutes" when we poll every 3

Both numbers are real and they belong to different layers. Ours is the 3 min press
interval — how often HA *asks* the cable. HA's is its own, and is not configurable:

```
+-------------------+-----------------------------------------------------------+
| Layer             | What happens                                              |
+-------------------+-----------------------------------------------------------+
| Sampling (ours)   | DP 27 pressed every 3 min idle / 4 min charging.          |
| Raw recording     | A `states` row is written only when the value CHANGES -    |
|   (HA recorder)   |   for an integer DP, once per degree crossing.             |
| Statistics (HA)   | `statistics_short_term` gets a mean/min/max bucket every   |
|                   |   5 min on a fixed clock, regardless of sampling.          |
+-------------------+-----------------------------------------------------------+
```

Observed on 2026-08-14: the last raw state row was 08:06 (40 C) and none followed for over
an hour despite ~25 presses, because nothing crossed a degree — while the statistics table
emitted 09:00, 09:05, 09:10, 09:15, 09:20, every one of them `mean 40.0 min 40.0 max 40.0`.

So the aggregation discards nothing here: 3 min sampling puts 1–2 samples in each 5 min
bucket, and with integer degrees and a peak cooling rate of ~1 C per 4 min, mean, min and
max are almost always the same number. It matters for retention rather than resolution —
raw states are purged after 10 days, so those 5 min buckets and the hourly long-term ones
are what survive.

## Cable-side entities

All `voldt_ev_cable_*` entities come from tuya-local over the LAN.

```
+---------------------------------------------+----------------------------------------+
| Entity                                      | Notes                                  |
+---------------------------------------------+----------------------------------------+
| sensor.ev_charger_energy                    | THE energy sensor: Riemann integral of |
|                                             |   ev_charger_power_estimated -> Energy |
|                                             |   dashboard "EV Charger (Enyaq)" + all |
|                                             |   cards + the four utility_meters.     |
| sensor.ev_charger_power_estimated           | THE power sensor (template): the local |
|                                             |   power DP, with a set-current x 230 V |
|                                             |   fallback for the seconds before the  |
|                                             |   first refreshed reading. Feeds the   |
|                                             |   integration, Rest Of Home, gauges.   |
|                                             |   Name kept for continuity; it is no   |
|                                             |   longer mostly an estimate.           |
| sensor.voldt_ev_cable_power                 | raw local power, kW. ~20 s while the   |
|                                             |   refresh window is open, else frozen. |
| sensor.voldt_ev_cable_voltage / _current    | V and A, same window. `unknown` until  |
|                                             |   the first refresh after a restart,   |
|                                             |   and 0 whenever idle - DP 6 only      |
|                                             |   reports during a session.            |
| sensor.voldt_ev_cable_status                | available / plugged_in / waiting /     |
|                                             |   charging / paused / charged / fault  |
|                                             |   / fault_unplugged. NOTE the values   |
|                                             |   differ from the old cloud enum       |
|                                             |   (charger_charging -> charging).      |
| sensor.voldt_ev_cable_last_charge           | DP 25: energy of the LAST completed    |
|                                             |   session, kWh. Accurate (see below)   |
|                                             |   but only finalised at session end.   |
| sensor.voldt_ev_cable_energy                | DEAD - lifetime counter, always 0.     |
| number.voldt_ev_cable_set_current           | 8-13 A charge rate control             |
| select.voldt_ev_cable_charging_mode         | immediate / charge_to_percent /        |
|                                             |   fixed_charge / scheduled_charge -    |
|                                             |   LEAVE ON immediate; scheduled blocks |
|                                             |   immediate charging                   |
| switch.voldt_ev_cable                       | starts/stops the CURRENT session (not  |
|                                             |   a device power switch)               |
| sensor.voldt_ev_cable_temperature           | internal temp. Refreshed every 4 min   |
|                                             |   charging, 3 min idle. ~53 C at 13 A  |
|                                             |   is normal; ~40 C settled idle.       |
| button.voldt_ev_cable_refresh               | DP 27. Opens the ~5 min live-metering  |
|                                             |   window; driven by the keep-alive     |
|                                             |   automation. Safe to press manually.  |
| binary_sensor.voldt_ev_cable_problem        | fault bitmask (DP 10) - LOCAL ONLY,    |
|                                             |   the cloud never exposed it           |
| sensor.voldt_2_4_5g_*                       | the old cloud entities. Still present, |
|                                             |   nothing depends on them.             |
| button.voldt_2_4_5g_clear_energy            | RESETS the lifetime counter - do NOT   |
|                                             |   press                                |
+---------------------------------------------+----------------------------------------+
```

## How the car side works (MySkoda)

**MySkoda** (HACS, `skodaconnect/homeassistant-myskoda`, v1.35.0) logs into the Skoda
Connect account with email + password and talks to exactly the API the MySkoda phone app
uses. Setup asked for no S-PIN — that is only needed for privileged commands (lock/unlock,
remote climate). Updates are event-driven over MQTT with a 30-minute full poll as backstop.

Vehicle: Enyaq, MY2024 Selection, VIN `TMBJB9NY6RF022788`, 132 kW, **58 kWh usable pack**,
100 kW max DC. The pack size is not guesswork — the API reports it in the vehicle
specification, visible via the integration's diagnostics download.

It creates 55 entities. The ones that matter here:

```
+-----------------------------------------------+--------------------------------------+
| Entity                                        | Notes                                |
+-----------------------------------------------+--------------------------------------+
| sensor.skoda_enyaq_battery_percentage         | State of charge, %. WHOLE PERCENT    |
|                                               |   only - 1% = 0.58 kWh. Drives the   |
|                                               |   efficiency calc; its resolution is |
|                                               |   that calc's accuracy floor.        |
| sensor.skoda_enyaq_range                      | Remaining range, km                  |
| sensor.skoda_enyaq_charging_state             | charging / ready / conserving        |
| binary_sensor.skoda_enyaq_charger_connected   | plugged in (plug device class)       |
| sensor.skoda_enyaq_charging_power             | kW as the CAR sees it. Coarse -      |
|                                               |   reads a flat 3.0 kW against the    |
|                                               |   cable's measured 2.863 kW. Do not  |
|                                               |   use it for energy maths; it is a   |
|                                               |   display value only.                |
| sensor.skoda_enyaq_charge_type                | ac / dc                              |
| number.skoda_enyaq_charge_limit               | target SoC, 50-100%, writable        |
| sensor.skoda_enyaq_target_battery_percentage  | same target, read-only               |
| sensor.skoda_enyaq_remaining_charging_time    | minutes to the limit                 |
| sensor.skoda_enyaq_charging_rate              | range added, km/h                    |
| sensor.skoda_enyaq_mileage                    | odometer, km (see caveats)           |
| binary_sensor.skoda_enyaq_reachable           | car online / asleep                  |
| sensor.skoda_enyaq_last_updated               | freshness of the car's own data -    |
|                                               |   check this before believing a      |
|                                               |   surprising SoC                     |
+-----------------------------------------------+--------------------------------------+
```

**There is no battery-temperature entity.** The MySkoda API does not expose one for this
vehicle, so it is absent from the dashboard rather than approximated.

Six entities sit permanently at `unknown` (camping mode, AC timer 3, last operation, AC
time-to-target, second inspection counter, vehicle render). All are unrelated to charging;
they are capabilities this car does not report.

## Charging efficiency

Compares energy that **left the wall** with energy that **reached the battery**. The gap
is real loss — onboard-charger conversion, BMS and 12 V loads, and any preconditioning.

```
+-----------------------------------------+--------------------------------------------+
| Entity                                  | What it is                                 |
+-----------------------------------------+--------------------------------------------+
| sensor.ev_battery_energy_gained         | Battery side, lifetime. Trigger template:  |
|                                         |   accumulates SoC INCREASES at 0.58 kWh/%. |
| sensor.ev_cable_energy_total            | utility_meter, no cycle, on                |
|                                         |   sensor.ev_charger_energy                 |
| sensor.ev_battery_energy_total          | utility_meter, no cycle, on                |
|                                         |   sensor.ev_battery_energy_gained          |
| sensor.ev_charging_efficiency           | THE number. Ratio of the two above.        |
| sensor.ev_cable_energy_today            | Same pair on the 09:00-09:00 charging day  |
| sensor.ev_battery_energy_today          |   (utility_meter, cycle daily, offset 9 h) |
| sensor.ev_charging_efficiency_today     | Daily ratio - for spotting outliers only   |
+-----------------------------------------+--------------------------------------------+
```

Three design decisions worth knowing:

1. **Gated on the cable, not the car.** The accumulator only counts SoC increases while
   `sensor.voldt_ev_cable_status` is `charging`. Charging away from home (public
   AC, DC rapid) raises SoC with no cable energy behind it and would otherwise inflate
   efficiency past 100%. This gate fails **silently** if that entity is renamed — battery
   energy would simply stop accumulating. Check it after any integration change.
2. **Only increases count.** SoC drops — preconditioning, vampire drain — are ignored, not
   subtracted. Energy spent heating the battery therefore shows up honestly as lost.
   Single steps above 10% are discarded as implausible: at ~2.9 kW that is over two hours,
   far beyond any polling gap.
3. **Suppressed below 5 kWh.** Whole-percent SoC means the battery figure is worth ±0.58
   kWh *regardless of session size* — about ±12% on a 5 kWh day, ±3% on a 20 kWh overnight
   charge, and negligible over a lifetime. Below 5 kWh the ratio is noise and both
   efficiency sensors report `unknown` rather than a number that looks meaningful.

Both lifetime meters started together on 2026-08-13, so the lifetime ratio needs no
baseline correction — but it needs a few real charges before it settles. Expect the mid
80s%: a granny cable spreads a near-constant onboard-charger overhead across a low
~2.9 kW charge rate, which is the worst case for AC efficiency.

## Answering the usual questions

```
+--------------------------------------+------------------------------------------------+
| Question                             | Where to look                                  |
+--------------------------------------+------------------------------------------------+
| Energy + cost per day/week/month/    | Energy dashboard -> pick the period at the top |
| quarter                              | -> "EV Charger (Enyaq)" row in the device      |
|                                      | breakdown. Costs use the real tariff prices.   |
|                                      | Data is long-term statistics: kept forever.    |
| When do charges start and end?       | History page -> sensor.voldt_ev_cable_status   |
|                                      | -> coloured timeline of "charging" blocks.     |
|                                      | Raw history kept ~10 days (recorder default);  |
|                                      | older start/stop times are gone, but hourly    |
|                                      | energy statistics remain forever. This entity  |
|                                      | only has history from 2026-08-13.              |
| How long do we spend charging?       | sensor.ev_charging_time_today (hours; the      |
|                                      | "charging day" runs 09:00-09:00 so overnight   |
|                                      | sessions count whole; long-term stats enabled  |
|                                      | via customize state_class; max-per-day =       |
|                                      | charging h/day).                               |
| How many sessions?                   | sensor.ev_charging_sessions_today (count per   |
|                                      | 09:00-09:00 day).                              |
| How full is the car / how far can    | "The car (Enyaq)" section of the EV Charging   |
| it go?                               | dashboard, or sensor.skoda_enyaq_battery_      |
|                                      | percentage / _range. Check _last_updated if a  |
|                                      | value looks wrong - the car may be asleep.     |
| How much of the electricity I pay    | sensor.ev_charging_efficiency (lifetime).      |
| for reaches the battery?             | Blank until 5 kWh has been charged; see        |
|                                      | "Charging efficiency" above for why.           |
| Everything in one place              | "EV Charging" dashboard (sidebar, /ev-charging)|
|                                      | - 6 sections: live gauge/controls, the car,    |
|                                      | this charging day, session timeline (72h),     |
|                                      | trends (daily+monthly bars), efficiency.       |
| Ad-hoc analysis / Grafana            | HA exports all sensors to Prometheus           |
|                                      | (prometheus: block; scraped by prometheus_lxc) |
|                                      | -> voldt sensors are queryable in Grafana too. |
+--------------------------------------+------------------------------------------------+
```

`charging` is one of the `voldt_ev_cable_status` values: available, plugged_in, waiting,
charging, paused, charged, fault, fault_unplugged. (The old cloud entity used the raw Tuya
names — charger_free, charger_insert, charger_wait, charger_charging, charger_pause,
charger_end, charger_fault, charger_free_fault. Anything written before 2026-08-13 that
compares against those strings is stale.) "How long was the car plugged in but NOT
charging" could be a future history_stats on plugged_in/waiting/charged if wanted.

## Known issue: the lifetime energy counter is dead

`forward_energy_total` (and daily/monthly/yearly/balance) **never left 0**, verified twice:
first over the cloud on 2026-08-12 after 8.7 kWh, then again on 2026-08-13 by reading the
DP directly over the LAN after ~19.8 kWh cumulative. It is dead **in firmware**, not a
cloud problem, and going local did not fix it. Never press
`button.voldt_2_4_5g_clear_energy` in the hope of resetting it into life.

So lifetime energy is still integrated (`sensor.ev_charger_energy`, Riemann `integration:`,
method left, `max_sub_interval` 5 min) from `sensor.ev_charger_power_estimated`. What
changed is the quality of the input: that template now reads a real power measurement
every ~20 s instead of an hourly one, so the integral is a measurement rather than the old
±5% estimate.

**The one energy DP that does work** is DP 25, `sensor.voldt_ev_cable_last_charge` — the
energy of the last *completed* session. It is accurate, checked against duration × power:

```
+---------------------+----------+----------+-------------+-----------+--------+
| Session             | Duration | Power    | Expected    | DP 25     | Error  |
+---------------------+----------+----------+-------------+-----------+--------+
| 20:44:57 - 22:21:34 | 96.6 min | 2.847 kW | 4.58 kWh    | 4.58 kWh  | 0.0 %  |
| 23:55:42 - 02:12:18 | 136.6 min| 2.87 kW  | 6.53 kWh    | 6.54 kWh  | +0.2 % |
+---------------------+----------+----------+-------------+-----------+--------+
```

Under tuya-local it finalises **instantly** at session end — verified 2026-08-13 15:26:19,
where it jumped 0.01 -> 3.18 kWh in the same second the status left `charging`.

### Use DP 25 to audit the integral

Because DP 25 is the device's own meter, it is an independent check on the Riemann
integral. First comparison, for the 66.5 min session ending 15:26:19:

```
+----------------------------------+-----------+------------------------------------+
| Source                           | Session   | Mean power                         |
+----------------------------------+-----------+------------------------------------+
| DP 25 (device meter)             | 3.18 kWh  | 2871 W                             |
| sensor.ev_charger_energy delta   | 3.120 kWh | 2816 W                             |
+----------------------------------+-----------+------------------------------------+
| Integral runs 1.9 % low                                                           |
+-----------------------------------------------------------------------------------+
```

The gap is **not** a design flaw: bucketing the integral into 5-minute windows puts the
entire deficit in one window, 14:49-14:54, which is exactly when Home Assistant was
restarted mid-session. Every other window implies 2885-2889 W against a directly measured
2896 W — better than 0.5 %. Expect near-exact agreement on a session with no restart, and
treat a persistent multi-percent gap as a signal that the keep-alive automation is
missing windows.

It is **not** used as the energy source, because it only finalises when a session ends —
it reads `0.01` throughout a session, even locally, even inside a refresh window. Feeding
the Energy dashboard from it would dump each session's whole kWh into its final hour.
It is worth keeping as an independent cross-check of the integral.

### The 12 Aug statistics artifact — leave it alone

The first charge (8.7 kWh) predated the energy sensor and was injected retroactively into
the statistics at the 23:00 hour of 12 Aug. Deliberate, and accepted: 12 Aug's HOURLY
detail view shows a +9/−9 kWh pair (EV vs computed untracked) because the energy sits in a
different hour than the grid import. All daily/weekly/monthly totals and costs are
correct. Do not "fix" it.

Also normal: when the car is left plugged in after finishing, it wakes every ~25–30 min
for short top-up/balancing draws (10 s–4 min at ~2.2 kW). Each counts as a "session" in
ev_charging_sessions_today, so the counter reads high on plugged-in evenings. These bursts
also draw cable energy without moving the whole-percent SoC, so a night spent idling on
the plug drags `ev_charging_efficiency_today` down. That is not a fault — the energy
genuinely was consumed without reaching the battery — but it is another reason to read
the lifetime figure rather than a single day's.

## Caveats

- **The cable half is now local; the car half is still cloud.** An internet outage no
  longer affects cable energy or cost data at all. Car data still flows through Skoda's
  cloud (MQTT push). Charging itself is unaffected by either.
- **The keep-alive automation is load-bearing.** If
  `automation.ev_cable_keep_power_live` is disabled or broken, power silently reverts to
  refreshing about once an hour and the energy integral degrades back to an estimate — it
  will not error, it will just get worse. Check it first if kWh figures start drifting
  from the P1 meter.
- Energy is still an integral of sampled power, so it is not perfect — but at ~20 s
  sampling of a near-constant 2.9 kW load the error is small. The grid-truth is always
  the P1 meter.
- **History splits at 2026-08-13.** The cable-side entity IDs changed
  (`voldt_2_4_5g_work_state` -> `voldt_ev_cable_status`, etc.), so charger-state history,
  the session timeline and charging-time/session counters start fresh from that date.
  `sensor.ev_charger_energy` and its statistics were deliberately **not** renamed, so all
  Energy-dashboard history and cost data is continuous across the cutover.
- Re-pairing the Voldt into a different app/account changes its device ID and breaks the
  entity history; it would also change the local key.
- If the local key ever stops working (factory reset, re-pair), see "Getting the local
  key" below — do not go near the Tuya developer platform.
- **MySkoda's long-term viability is not guaranteed.** It is an unofficial client of the
  phone app's API; there is no Skoda integration in HA core. VW Group is introducing a
  formal third-party access framework requiring app attestation
  ([upstream issue #1112](https://github.com/skodaconnect/homeassistant-myskoda/issues/1112)),
  which could lock out unattested clients. Nothing to do now beyond knowing that the car
  half may one day stop; the cable half — and therefore all cost and Energy-dashboard
  data — is entirely independent of it.
- **Write commands are flakier than reads.** Upstream reports 500s on lock/unlock and on
  setting the charge limit for some MY27 cars. All sensors used here are read-only. If
  tapping `number.skoda_enyaq_charge_limit` fails, set the limit in the phone app.
- **Odometer may freeze.** Upstream issue #1105 reports `mileage` and service-interval
  sensors sticking. Cross-check against the car before trusting it for anything that
  matters.
- Changing the MySkoda account password breaks the integration — reconfigure the config
  entry, no reinstall needed.

## Getting the local key (for reference)

The device's **local key** was never actually hard to obtain — the developer-platform
route was simply the wrong route.

Historically the plan was Tuya's developer platform ("Link App Account" QR at
iot.tuya.com), which failed persistently: scanning the QR in either app, with the correct
data center and IoT Core authorized, opened a URL returning an S3 `AccessDenied`.
Community reports blame account/billing verification on new developer accounts. **Do not
spend time on that route** — it is unnecessary.

The key is already inside Home Assistant. `xtend_tuya` includes it, unredacted, in its
diagnostics download (HA core's own Tuya integration *does* redact it, which is why this
is easy to miss):

```sh
curl -H "Authorization: Bearer $HA_TOKEN" \
  http://192.168.2.102:8123/api/diagnostics/config_entry/<xtend_tuya_entry_id> \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["devices"][0]["local_key"])'
```

Other routes that need no developer account, if xtend_tuya is ever removed:
`vineetchoudhary/tuya-local-key` (docker / CLI / HA add-on), which rides HA's own public
app registration via the `tuya-device-sharing-sdk` and the same Smart Life QR login that
already works on this account.

Connection parameters that matter: protocol **3.5**, port 6668, IP `192.168.2.29`
(static MikroTik lease), device ID `bff9a892e0eb9fa22bwmyp`.

## Where the config lives

All of it is YAML in the `/config` repo — this HA instance uses **no UI helpers**, so
never go looking in Settings → Devices & Services → Helpers for these entities.

```
+--------------------------------------+------------------------------------------------+
| What                                 | Where                                          |
+--------------------------------------+------------------------------------------------+
| ev_charger_power_estimated,          | /config/templates.yaml                         |
| ev_battery_energy_gained,            |                                                |
| ev_charging_efficiency{,_today},     |                                                |
| ev_cable_refresh_stale (watchdog)    |                                                |
| ev_charger_energy (Riemann),         | /config/configuration.yaml, sensor: block      |
| ev_charging_time/sessions_today      |                                                |
| the four utility_meters              | /config/configuration.yaml, utility_meter:     |
| "EV cable keep power live"           | /config/automations.yaml (id 1786623900000)    |
|   (DP 27 keep-alive, /4 charging)    |                                                |
| "EV cable refresh temperature        | /config/automations.yaml (id 1786626600000)    |
|   while idle" (DP 27, /3 idle)       |                                                |
| MySkoda + Tuya creds, tuya-local     | /config/.storage (never git-tracked) - the     |
|   device id + LOCAL KEY              |   local key lives in core.config_entries       |
| "EV Charging" dashboard              | storage mode - edit via the UI or the          |
|   (+ Power, All Devices)             |   lovelace/config/save websocket command       |
+--------------------------------------+------------------------------------------------+
```

Consumers that reference the cable entities, and must all be checked together if the
integration is ever changed again — `grep -rn 'voldt' /config/*.yaml` plus the three
storage dashboards:

```
+---------------------------------------+-------------------------------------------+
| Consumer                              | Failure mode if left stale                |
+---------------------------------------+-------------------------------------------+
| ev_charger_power_estimated (template) | Power reads 0 -> energy stops. Visible.   |
| ev_battery_energy_gained (condition)  | SILENT. Battery energy just stops         |
|                                       |   accumulating; efficiency drifts up.     |
| ev_charging_time/sessions_today       | SILENT. Counters sit at 0.                |
|   (history_stats, entity + state)     |                                           |
| ev_cable_refresh_stale (watchdog) -   | Banner stuck ON permanently. Loud by      |
|   references button..._refresh, not   |   design: an unresolvable entity gives no |
|   any sensor                          |   timestamp, which counts as stale.       |
| Rest Of Home subtract_entities        | Points at the template, not the raw DP -  |
|                                       |   needs no change.                        |
| Energy dashboard "EV Charger (Enyaq)" | Points at sensor.ev_charger_energy -      |
|                                       |   needs no change.                        |
| the four utility_meters               | Point at ev_charger_energy /              |
|                                       |   ev_battery_energy_gained - no change.   |
| dashboards: ev-charging, power,       | Cards show "Entity not available".        |
|   all-devices                         |   Visible.                                |
+---------------------------------------+-------------------------------------------+
```

Editing procedure: `ssh john@192.168.2.102`, edit under `sudo`, then **always**
`POST /api/config/core/check_config` before restarting. Committing and pushing needs both
`sudo` (the git index is root-owned) and an explicit deploy key, since the repo has no
`core.sshCommand` set:

```sh
cd /config && sudo git add -A <files> && sudo git commit -F <msgfile>
sudo env GIT_SSH_COMMAND="ssh -i /config/.git-ssh/id_deploy \
  -o UserKnownHostsFile=/config/.git-ssh/known_hosts -o IdentitiesOnly=yes" \
  git push origin HEAD
```

## Related

- `192.168.2.29` (MAC `d8:fc:92:93:f5:7d`) is a **static lease on the MikroTik**, which is
  what makes the hard-coded tuya-local host safe.
- Cheap-tariff charging automation idea: trigger on `sensor.p1_meter_tariff`, act on
  `switch.voldt_ev_cable` + `number.voldt_ev_cable_set_current`. Now that the car
  side exists, `number.skoda_enyaq_charge_limit` is the gentler lever — cap the target SoC
  instead of interrupting the session.
- Possible cleanup: the official Tuya and xtend_tuya integrations now serve no purpose
  (the Voldt is the only device on that account). Removing them would drop ~14 permanently
  dead entities. Kept for now as a fallback path and as the simplest local-key source.
- Energy monitoring architecture: `home_assistant_energy.md`.
