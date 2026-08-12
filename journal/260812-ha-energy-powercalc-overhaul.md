# 2026-08-12 — Home Assistant energy monitoring overhaul (powercalc)

## What prompted it

Audit of how energy is measured in Home Assistant (VM 102), specifically the accuracy of
the hand-rolled "synthetic power" template sensors (`power = max_W × brightness/255`).

Verdict on the linear model itself: reasonable (±10–30% on small loads — misses LED driver
overhead at low brightness and perceptual dimming curves), but irrelevant next to the real
finding: **5 of 16 tracked devices had been silently recording 0 for months** — TV (dead
since 2026-02), dishwasher (2026-04), office light (~2025-08), bathroom and living-room
lights (≥1 year). Root cause for the lights: templates referenced entity ids that no longer
existed (`light.office_ceiling_light`, `light.bathroom_ceiling_light_2`,
`light.dinner_table_1`), and the template's `unavailable → 0` fallback made the failure
invisible. Only ~41% of grid import was tracked over the prior 30 days.

## What was done

1. **`/config` under real version control.** The existing `.git` there was a false friend —
   March 2025 commits with *zero tracked files* (empty trees). Re-initialised, whitelist
   `.gitignore` (only hand-written YAML; `.storage/`, `secrets.yaml`, `cloudflared/`,
   `zigbee2mqtt/`, `go2rtc.yaml` excluded — all contain credentials), pushed to private
   `johnmathews/home-assistant-config` with a write-scoped deploy key kept gitignored on
   the box.
2. **powercalc v1.24.1 installed** headlessly via HACS WebSocket API; one core restart.
3. **Replaced all synthetic sensors** with powercalc: measured LUT profiles for STOFTMOLN
   T2035, TRADFRI LED2103G5, JETSTROM L2207; linear 1–9.5 W for KAJPLATS (no profile yet);
   fixed wattage for the 6 TRETAKT plugs' dumb bulbs; a **Rest Of Home** subtract group
   (P1 minus 19 tracked power sensors) so the ~59% untracked share is now a visible line.
4. **Retired the corrected-energy pattern**: dashboard repointed to raw `total_increasing`
   plug sensors (full history preserved), 10 `update_*_energy_total` automations deleted,
   11 YAML `input_number` helpers removed, all `_corrected` templates deleted. The pattern
   lost real consumption after any counter reset; raw sensors + HA's native reset handling
   (+ a documented statistics-adjust runbook for the rare spike) are strictly better.
5. **38 orphaned registry entries removed** (old templates, TV chain, ZHA-era cost sensors,
   dead automations). Old statistics left in the recorder on purpose.
6. Energy dashboard rebuilt: 2 grid tariffs + gas unchanged; 20 device entries.

## Decisions & gotchas

- **History break accepted** for the 3 re-implemented lights (~17 kWh/month total): recorder
  can't merge statistics onto renamed entities when orphaned stats hold the target id, and
  the surgery wasn't worth it. Grid/gas/plug history untouched.
- ZHA integration is `not_loaded`; office + bathroom JETSTROM panels are still paired to it
  → still untrackable until re-paired to z2m (backlog). The entrance panel had already been
  migrated, which is why only it worked.
- SSH into HAOS = "Advanced SSH & Web Terminal" add-on, user `john`, password auth,
  passwordless sudo. `git` on the box needs `safe.directory` (or run as root).
- Filament bulbs on plugs 5/6 booked at an estimated 6 W until John reads the real wattage.
- HA restart verified via `POST /api/config/core/check_config` *before* restarting — the
  whole change was one restart, zero failed boots.

Full reference: `documentation/home_assistant_energy.md`.
Session context: memory `ha_energy_monitoring.md`.
