# 2026-08-13 — EV cable: Tuya cloud → tuya-local (and the DP 27 discovery)

Migrated the Voldt granny cable off the Tuya cloud onto **tuya-local**, fully local
polling. The headline result is not "local is faster" — it is that a **local-only
datapoint (DP 27) is the only way to make the device report real power at all**.

## The blocker that wasn't

The whole upgrade had been parked since 12 Aug because the local key supposedly needed
Tuya's developer platform, whose "Link App Account" QR flow returns an S3 `AccessDenied`
on this account.

The key was in Home Assistant the entire time. **`xtend_tuya`'s diagnostics download
contains `local_key` unredacted** (HA core's own Tuya integration redacts it, which is why
nobody looked). One REST call:

```
GET /api/diagnostics/config_entry/<xtend_tuya_entry_id>
  -> data.devices[0].local_key
```

No developer account, no cloud project, no QR scan, no third-party tool. Worth remembering
as a general trick for any Tuya device already paired to HA via xtend_tuya.

## What the probe found

Local access: protocol **3.5**, port 6668, 238/238 polls over 12 min with zero errors.
The local connection coexists happily with the cloud one — both were live throughout.

**Four** DPs exist locally that the Tuya cloud never declares: **DP 6** (voltage +
current + power in one base64 blob), **DP 10** (fault bitmask), **DP 23** (firmware,
V4.1.6) and **DP 27**. Conversely the cloud declares three — 5, 16, 17 — that the device
never returns. Most pointed of all: the cloud advertises DP 5 (`sigle_phase_power`,
permanently 0) while hiding DP 6, which actually works. Full reconciliation table in
`documentation/home_assistant_ev_charging.md`.

Two firmware facts, both verified rather than assumed:

1. **`forward_energy_total` (DP 1) is dead in firmware, not just over the cloud.** Reads 0
   locally after ~19.8 kWh delivered. Going local did not fix it and nothing will.
2. **`charge_energy_once` (DP 25) is a genuine, accurate per-session meter** — the docs'
   claim that "all the energy counters are dead" was too broad. Checked against the
   recorder DB for two sessions:

```
+---------------------+----------+----------+-------------+-----------+--------+
| Session             | Duration | Power    | Expected    | DP 25     | Error  |
+---------------------+----------+----------+-------------+-----------+--------+
| 20:44:57 - 22:21:34 | 96.6 min | 2.847 kW | 4.58 kWh    | 4.58 kWh  | 0.0 %  |
| 23:55:42 - 02:12:18 | 136.6 min| 2.87 kW  | 6.53 kWh    | 6.54 kWh  | +0.2 % |
+---------------------+----------+----------+-------------+-----------+--------+
```

It is still not usable as *the* energy source: it reads 0.01 for the entire session and
only finalises at session end, so feeding the Energy dashboard from it would dump each
session's kWh into one hour. Kept as an independent cross-check.

## The finding that made the migration worth doing

The initial live test looked like a **failure**. Thirteen minutes into a real 2.9 kW
charge (P1 meter confirming the draw), the local power sensor read 0.0 — exactly as stale
as the cloud one. Direct polling returned `DP9=0` forty times over 3.5 minutes, and a
persistent socket received zero unsolicited pushes in 7 minutes. The firmware genuinely
does not maintain its metering registers between its ~3600 s report ticks.

Then pressing **DP 27** — which tuya-local's `voldt_ev_charger` profile exposes as a
"Refresh" button — changed everything within 10 seconds:

```
+----------+---------+---------+---------+---------------------------+
| Time     | Power   | Voltage | Current | Cross-check               |
+----------+---------+---------+---------+---------------------------+
| 14:32:48 | 0.0 kW  | 235.3 V | 0.0 A   | stale (pre-press)         |
| 14:32:58 | 2.86 kW | 227.0 V | 12.6 A  | 227.0 x 12.6 = 2860 W  ok |
| 14:33:18 | 2.887   | 227.4 V | 12.7 A  | 227.4 x 12.7 = 2888 W  ok |
| 14:34:38 | 2.887   | 227.4 V | 12.7 A  |                           |
+----------+---------+---------+---------+---------------------------+
```

Voltage and current — `unknown` since setup — came alive too, so DP 6 works after all.

**The effect decays.** Two measurements: presses at 14:32:58 and 14:42:17 gave live
windows of **295 s and 281 s** with 20 s updates, then silence. Hence a keep-alive
automation pressing every 4 minutes while charging.

**DP 27 is absent from the device's cloud `status_range` entirely.** No cloud integration
can press it. That is the actual reason cloud power was stuck at hourly, and it is the
entire justification for this migration. (Amusingly, once refreshed the device reports
upstream too, so the *cloud* power sensor also goes live — the data isn't local-only, but
the trigger is.)

## What changed

- New tuya-local config entry **"Voldt EV Cable"** → `*.voldt_ev_cable_*` (12 entities).
  Named deliberately to avoid colliding with the existing `ev_charger_*` sensors.
- New automation **"EV cable keep power live"**: press Refresh on entry to `charging` and
  every 4 min while charging.
- `ev_charger_power_estimated` now reads the local power DP; the set-current × 230 V
  fallback survives but now only covers the seconds before the first refreshed reading.
- `ev_battery_energy_gained` condition, and both `history_stats` sensors, re-pointed to
  `sensor.voldt_ev_cable_status` **with the new enum value** (`charging`, not
  `charger_charging`) — the profile remaps the values, which is a second silent-break
  vector on top of the entity rename.
- Three storage dashboards (ev-charging, power, all-devices) re-pointed: 16 entity refs.
  The dead `voldt_2_4_5g_daily_total_energy` tile was swapped for `ev_cable_energy_today`,
  which is real.
- `sensor.ev_charger_energy` deliberately **not** renamed, so the Energy dashboard entry,
  all four utility_meters, Rest Of Home and every statistic carry over untouched.

## Verification (observed, not assumed)

12 minutes of continuous monitoring during a real charge, post-restart:

```
updates: 33    gap min 15 s   median 20 s   MAX 61 s
mean local power  2896 W  (143 samples)
mean P1 phase 1   3189 W  -> 293 W house baseline, matches idle
```

End-to-end through the integration chain:

```
sensor.ev_charger_energy  7.884 kWh @ 14:54:19 -> 8.577 kWh @ 15:08:42
   = 0.693 kWh over 14.38 min = 2891 W mean
   vs measured mean local power = 2896 W   -> 0.2 % agreement
```

`automation.ev_cable_keep_power_live` confirmed firing on the /4 boundary.

### Session end, observed (the last unverified link)

John disconnected at 15:26:19. DP 25 finalised **in the same second** the status left
`charging` — 0.01 → 3.18 kWh — so the "finalises at session end" behaviour holds locally,
not just over the cloud. The automation stopped pressing immediately (13:24 UTC was the
last press; the 13:28 tick was correctly blocked by the `charging` condition).

That gave the first independent audit of the integral, device meter vs Riemann:

```
+----------------------------------+-----------+------------+
| Source                           | Session   | Mean power |
+----------------------------------+-----------+------------+
| DP 25 (device meter)             | 3.18 kWh  | 2871 W     |
| sensor.ev_charger_energy delta   | 3.120 kWh | 2816 W     |
+----------------------------------+-----------+------------+
```

1.9% low — and bucketing the integral into 5-minute windows puts the **entire** deficit in
14:49–14:54, which is exactly when HA was restarted mid-session to load the new YAML.
Every other window implies 2885–2889 W against a directly measured 2896 W (<0.5%). So the
chain is sound and the gap was self-inflicted by the migration itself; a session without a
restart should agree far more closely. Worth re-checking on the next clean session.

Useful consequence: DP 25 is now a standing post-hoc audit of the integral. A persistent
multi-percent gap would indicate the keep-alive automation is missing windows.

### Follow-up: idle temperature

Noticed while verifying: the device still reported 53 C after the session ended, with the
cable physically cooling. Temperature shares the refresh-window behaviour, so it froze at
its end-of-charge value — an idle cable reads hot forever.

Fixed rather than just documented, because the DP 27 press **does** work while idle:
a manual press at 15:37 moved it 53 -> 50 C within 12 s. Added a second automation, **"EV
cable refresh temperature while idle"**, on a /5 time pattern gated on status != charging.
Verified firing at 15:45:00 exactly, temperature 50 -> 48 C. Applied with
`automation/reload` — no restart, so no repeat of the integral gap this time.

An idle press gives one fresh sample, not a rolling window.

**Interval chosen by measurement, after getting it wrong once.** I first set 15 min,
justified by "idle temperature drifts ~1 C per 10 min". That figure was an artifact: I had
compared 53 C at 15:05 (still charging) against 50 C at 15:37, and the 32-minute gap was
simply the absence of sampling, not slow drift. John pushed back and was right. The real
post-charge rate is ~1 C per 4 min, so 15 min was skipping ~4 C across exactly the phase
where a fault would show.

Re-measured properly by pressing every 60 s during the fastest cooling phase: **12 presses
produced 2 distinct readings** (48->47 immediately, 47->46 four minutes later, then eight
flat minutes). Cooling is asymptotic, so it only gets more redundant as the cable settles
toward ~40 C. Combined with DP 24 being an integer, that puts two hard ceilings on the
useful rate — 1 min would be >83% redundant at its best moment and buys latency, never
resolution.

Landed on **3 min** (480 presses/day), just below the fastest observed change rate. I had
first argued for 5 min partly on device-wear grounds, which John challenged — rightly, as
it turned out. A press is a Tuya LAN command setting DP 27; there is no physical actuation
and no evidence it writes anything non-volatile. (DP 18, the session switch, *does* drive a
contactor — that one must never go on a timer.) With an unsupported cost argument removed,
nothing favoured 5 over 3.

Charging needs no equivalent tuning: the /4 keep-alive holds a window open continuously
and the device pushes on every degree crossing inside it, so temperature is already
effectively 20 s sampled while charging — confirmed by a nine-minute flat stretch at
52-53 C mid-charge with the window open throughout.

Voltage and current stay at 0 while idle regardless — DP 6 only reports during a
session, which is worth knowing before anyone tries to "fix" that too.

## Gotchas recorded

- The keep-alive automation is **load-bearing and fails quietly**. If it stops, power
  reverts to ~hourly and the energy integral silently degrades back to an estimate.
- The tuya-local profile remaps enum values (`charger_charging` → `charging`). Renaming
  the entity alone is not enough.
- Cable-side history splits at 2026-08-13; Energy-dashboard history does not.
- The Voldt is the **only** device on the Smart Life account, so the official Tuya and
  xtend_tuya integrations now serve no purpose beyond being a fallback and the easiest
  local-key source. Left installed.
- `voldt_ev_charger` was not tuya-local's top-ranked profile match (`afyeev_16a_evcharger`
  scored marginally higher because it also maps the dead `balance_energy` DP). The Voldt
  profile is still the right one.
- HA's REST `/api/history/period` returned empty for these entities while the recorder DB
  plainly had the rows; querying a snapshot copy of `home-assistant_v2.db` directly was
  the reliable route.
