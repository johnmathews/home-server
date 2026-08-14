# 2026-08-14 — EV cable: a watchdog for the silent failure, and what the "5 minutes" meant

Started as a question about the Temperature tile on the EV Charging dashboard — its chart
says data is aggregated over 5 minutes, but we press DP 27 every 3. Both are true, and
chasing the difference exposed a real gap: nothing anywhere told us when the presses
stopped.

## The 3 vs 5 minutes is two layers, not a contradiction

Ours is the sampling interval. HA's is its own recorder granularity, and it is not
configurable:

```
+-------------------+-----------------------------------------------------------+
| Layer             | What happens                                              |
+-------------------+-----------------------------------------------------------+
| Sampling (ours)   | DP 27 pressed every 3 min idle / 4 min charging.          |
| Raw recording     | A `states` row only on CHANGE - for an integer DP, once    |
|   (HA recorder)   |   per degree crossing.                                     |
| Statistics (HA)   | `statistics_short_term` mean/min/max bucket every 5 min    |
|                   |   on a fixed clock, regardless of sampling.                |
+-------------------+-----------------------------------------------------------+
```

The recorder DB makes it obvious. Raw states for
`sensor.voldt_ev_cable_temperature`: 08:06 → 40, and then nothing for over an hour despite
roughly 25 presses, because it never crossed a degree. Statistics over the same window:

```
09:20  mean 40.0  min 40.0  max 40.0
09:15  mean 40.0  min 40.0  max 40.0
09:10  mean 40.0  min 40.0  max 40.0
09:05  mean 40.0  min 40.0  max 40.0
09:00  mean 40.0  min 40.0  max 40.0
```

Nothing is lost to the aggregation: 3 min sampling puts 1–2 samples in each 5 min bucket,
and with integer degrees and a peak cooling rate of ~1 C per 4 min, mean/min/max collapse
to the same figure. It matters for **retention**, not resolution — raw states purge after
10 days, so the 5 min buckets and the hourly long-term stats are what survive.

## The actual finding: the silent failure had no alarm

Checked three places for any staleness indicator and found none in any of them:

- `lovelace.ev_charging` — the Temperature tile is a bare `tile` card, `entity` + `name`.
  No conditional, no template, no colour logic.
- `automations.yaml` / `templates.yaml` — no reference to `last_changed`, `last_updated`,
  or the temperature entity. The only "stale" hit in the whole config is a doorbell
  automation.
- HA itself — and this is the crux. **A frozen tuya-local reading is not `unavailable`.**
  The LAN connection stays up and the device keeps handing back its last latched value, so
  HA sees a perfectly healthy entity. There is nothing for the UI to grey out.

Which means the failure mode the migration doc has been warning about since 13 Aug — the
keep-alive automation stopping, power silently reverting to ~hourly, the energy integral
degrading to an estimate — was invisible by construction.

## The signal was already there: the button's own state

`button.voldt_ev_cable_refresh` stores the timestamp of its last press **as its state**:

```
button.voldt_ev_cable_refresh   09:30   "2026-08-14T09:30:00.232783+00:00"
button.voldt_ev_cable_refresh   09:27   "2026-08-14T09:27:00.232412+00:00"
```

Both automations act on that one button, so one entity covers both. No new plumbing.

`binary_sensor.ev_cable_refresh_stale` trips at 360 s — the slower automation is the `/4`
keep-alive, so the worst healthy gap is a little over 4 min. A conditional `ha-alert` card
at the top of the dashboard's "Right now" section renders when it trips.

Two decisions worth recording:

**Do not watch the temperature sensor's own `last_changed`.** The obvious approach, and
wrong: DP 24 is an integer and a settled idle cable legitimately holds 40 C for hours. The
data above is a *healthy* cable with no state change for 75 minutes. That rule would alarm
permanently.

**A missing timestamp counts as stale, not as fine.** `as_timestamp(..., 0)` defaults to
the epoch, so an unresolvable or unavailable button trips the banner. Checked before
committing to this: the entity has read `unknown` exactly once, on 2026-08-13 when
tuya-local created it, across three restarts since — so button state does survive
restarts and an absent timestamp really does mean a fault. The cable going offline trips
it too, which is correct: no device, no presses, no fresh readings.

## Loose ends

- **Needs an HA restart to go live.** Storage-mode dashboards are cached in memory —
  `LovelaceStorage` only re-reads the file when its cache is empty — so editing
  `.storage/lovelace.ev_charging` does nothing until a restart. The template sensor would
  reload on its own, but the banner will not.
- `ha core check` is unusable from the SSH addon: protection mode is on, so the CLI has no
  supervisor token (`unauthorized: missing or invalid API token`). Validated the YAML and
  JSON with `python3 -c "import yaml, json..."` on the box instead. The REST
  `check_config` route needs the long-lived token in the Ansible vault.
- `/config/templates.yaml.bak` and `.storage/lovelace.ev_charging.bak` are on the box.
  Delete once the restart confirms the change is good.

Committed and pushed to the `/config` repo as 5cc83a3. The dashboard half is not in that
commit — `.storage` is gitignored by the whitelist `.gitignore`, so the only record of the
banner's shape is `documentation/home_assistant_ev_charging.md`.

Related: `documentation/home_assistant_ev_charging.md`,
`journal/260813-ev-charger-tuya-local-migration.md`.
