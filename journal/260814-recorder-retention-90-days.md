# 2026-08-14 — Recorder retention: 10 → 90 days, and why nothing was excluded

Follow-on from the EV cable watchdog work. Asking why the temperature chart said "5
minutes" led to actually measuring the recorder for the first time, and the numbers were
not what I expected.

## The instance had never been configured

There was **no `recorder:` block in `configuration.yaml`** at all — the only occurrence of
the word was inside a comment. So it had been running on defaults since the VM was created
in April 2025. Verified rather than assumed: oldest raw state 2026-08-04 02:12, oldest
5-minute statistics bucket 2026-08-04 02:15, against a current date of 08-14. Exactly the
default 10 days.

## What was actually on disk

```
+----------------------------------+---------------------------------------------+
| HA DB                            | 260 MB                                      |
| /dev/sda8                        | 30.8 GB total, 10.3 GB used, 19.2 GB free   |
| VM 102                           | 32 GB disk, 2 cores, 2048 MB RAM            |
| /backup                          | 1.3 GB, ad-hoc addon backups, not scheduled |
+----------------------------------+---------------------------------------------+

states (table)                 68 MB  |  10 days
states (5 indexes)             80 MB  |
statistics (hourly, + idx)     69 MB  |  FOREVER - back to 2024-08-12, 212 stat ids
statistics_short_term (+ idx)  15 MB  |  10 days
```

The surprise: `statistics` has **more rows than `states`** (998k vs 862k). Two years of
hourly data at 212 statistic IDs accumulates faster than ten days of raw state changes, and
it is never purged. It grows about 130 MB/year on its own.

## One knob, two resolutions

`purge_keep_days` governs raw states **and** `statistics_short_term` together. Confirmed by
the identical cut-off timestamps above. There is no separate setting for the 5-minute
buckets and no per-entity retention anywhere in HA — the only per-entity lever is
record-or-don't.

Measured rate: ~14.8 MB/day for states+indexes, ~1.5 MB/day for the 5-minute buckets. So
90 days lands the DB at roughly 1.6 GB, about 8% of the free space.

**Disk was never the constraint — the 2 GB of RAM is.** That is what capped this at 90 days
rather than a year.

## The exclusion trap

The obvious optimisation is to drop the noisy P1 sensors. They are overwhelmingly the
biggest writers:

```
sensor.p1_meter_power              159,299
sensor.p1_meter_power_phase_1      156,132
sensor.p1_meter_power_phase_3       91,435
sensor.p1_meter_energy_import       83,203
sensor.p1_meter_power_phase_2       52,357
                                   -------
top 5 of 862,437 total states      542,426  = 63%
```

The three phase sensors alone are 35% of every state row, worth ~464 MB at 90 days. I had
started to write the `exclude:` block before checking what else it would do.

**Excluding an entity stops HA compiling statistics for it, not just recording states.**
`_get_sensor_states` applies the recorder entity filter before statistics compilation. The
phase sensors have 11,685 hourly rows each going back to 2025-04-14 — 16 months of per-phase
history that would have silently stopped accumulating. Existing rows stay, so the failure
would have looked like a chart that just quietly flatlines from the day of the change.

Rejected: 464 MB is 2% of free disk, and the thing it costs is exactly the long-range data
the history UI exists for.

Two related corrections to my own earlier reasoning:

- I had suggested the query-speed benefit of a smaller `states` table. Weaker than it
  sounds — the history UI reads through `ix_states_metadata_id_last_updated_ts`, an index
  range scan per entity, so a fatter table barely affects queries for *other* entities.
  What excluding really buys is a lighter nightly purge and monthly repack.
- I had said the recorder change would be reloadable without a restart. It is not; recorder
  has no reload service.

## On Prometheus not being a substitute

Prometheus already scrapes HA every 30 s and keeps 100 days / 22 GB, including all four P1
power series — so on paper it holds a longer, coarser copy of the same signals. I offered
that as a reason not to extend HA retention. John's push-back was the right call: doing this
analysis in HA itself is the natural workflow, and Prometheus is a separate concern with a
separate UI. Longer retention *in the place you actually look* is not substitutable by the
same data somewhere else.

## Applied

`recorder: purge_keep_days: 90` in `configuration.yaml`, no `exclude:`. Committed and pushed
to the `/config` repo as `5589546`. Validated by parsing `configuration.yaml` with a PyYAML
loader that stubs the `!include` tags (plain `safe_load` chokes on them).

**Needs a restart to take effect.** The DB will grow toward ~1.6 GB over the next 90 days
rather than jumping immediately — nothing purged is coming back.

Related: `documentation/home_assistant_energy.md` ("Recorder retention"),
`journal/260814-ev-cable-refresh-watchdog.md`.
