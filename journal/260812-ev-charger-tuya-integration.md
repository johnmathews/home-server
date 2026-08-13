# 2026-08-12 — EV charger (Voldt granny cable) into Home Assistant

> **Superseded on 2026-08-13** by
> [260813-ev-charger-tuya-local-migration.md](260813-ev-charger-tuya-local-migration.md).
> The cable now runs on **tuya-local**, entities are `*.voldt_ev_cable_*`, and the
> "developer-platform dead end" below was a false blocker — the local key was in
> xtend_tuya's diagnostics all along. Kept as the record of the cloud route.

Goal: track Skoda Enyaq charging (energy, cost, session times) from the Voldt Type 2
granny cable (WiFi, Tuya white-label, category `qccdz`).

## What happened, including the dead end

1. **Plan A: tuya-local** (fully local). Installed via HACS — not in this HACS install's
   default store cache, added as custom repo `make-all/tuya-local`; its built-in
   `voldt_ev_charger` profile matches the device. Needs device ID + **local key** from
   the Tuya developer platform.
2. **The developer-platform "Link App Account" QR flow is broken for John's account**:
   scanning the QR made the app open a URL that returned an S3 `AccessDenied` — in the
   Voldt app *and* in Smart Life, with the correct data center (Central Europe /
   account region Netherlands), the right scanner (Me → Scan), and IoT Core authorized.
   Community reports point at Tuya-side account/billing verification. Not fixable from
   our side today; the same Smart Life account authorized HA's own QR login instantly.
3. **Plan B (live): official Tuya integration + xtend_tuya.** Re-paired the cable from
   the Voldt app into Smart Life (new device ID `bff9a892e0eb9fa22bwmyp`). The official
   integration (user-code + QR login — flow driven headlessly via REST, QR rendered
   locally and sent to John's phone) exposed only a bare switch (`qccdz` unmapped), but
   the cloud diagnostics showed all 12 datapoints flowing. **xtend_tuya** (HACS) exposes
   them all as entities: total/daily/monthly/yearly energy, power (kW), work_state,
   charge current, work mode, temperature.

## Wiring

- `sensor.voldt_2_4_5g_total_energy` → Energy dashboard device "EV Charger (Enyaq)".
- `sensor.voldt_2_4_5g_total_power` → powercalc Rest Of Home `subtract_entities`
  (21st member; kW among W members — powercalc normalises; verify on first real charge).
- `history_stats` sensors `ev_charging_time_today` / `ev_charging_sessions_today`, with
  a **09:00–09:00 "charging day"** so overnight sessions count whole; `customize`
  adds `state_class: measurement` so charging time gets long-term statistics.
- New **"EV Charging" dashboard** (`/ev-charging`): live gauge/controls, 72 h session
  timeline, kWh/day + kWh/month bars, charging hours/day.
- Dashboards repaired along the way: "Everything" (manual) had refs to sensors deleted
  in the morning's overhaul — repointed/pruned; EV cards added to "Everything" and a
  new "EV" view on "Power".

## Gotchas recorded

- Voldt app can't authorize platform QRs at all (opens them as URLs).
- The official Tuya + xtend_tuya pair must stay logged into the same Smart Life account.
- `button.voldt_2_4_5g_clear_energy` resets the lifetime counter — never press.
- Work mode "schedule" blocks immediate charging; keep `charge_now`.
- Local-key upgrade path stays documented in `documentation/home_assistant_ev_charging.md`
  (tuya-local is installed and ready if Tuya's platform linking ever works).
