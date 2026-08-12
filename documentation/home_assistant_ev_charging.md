# Home Assistant — EV Charging (Voldt granny cable)

**Status:** integration installed, waiting on Tuya credentials (John's steps below) — 2026-08-12.

Tracks charging of the **Skoda Enyaq** via the **Voldt Type 2 granny cable** (8–13 A,
~2.8 kW max, WiFi, Voldt app). The cable is a white-label **Tuya** device.

## Integration approach

**tuya-local** (HACS, `make-all/tuya-local`, installed 2026-08-12, v2026.8.0) with its
built-in **`voldt_ev_charger`** device profile. Fully local: HA polls the cable directly
on the LAN (TCP 6668) — no Tuya cloud dependency after setup, works during internet
outages. The Voldt app keeps working alongside (one local connection at a time is used
by HA; the app falls back to cloud).

Entities the profile provides:

```
+---------------------------+-------------------------------------------------------+
| Entity                    | Notes                                                 |
+---------------------------+-------------------------------------------------------+
| Total energy (kWh)        | lifetime counter -> Energy dashboard device entry     |
| Power (W)                 | live draw; also joins the Rest Of Home subtract list  |
| Voltage / Current         | diagnostics                                           |
| Set current (number)      | 8-13 A charge rate control from HA                    |
| Switch                    | starts/stops the CURRENT charge session (it is NOT    |
|                           | a device on/off switch)                               |
| Charging mode (select)    | charge_now / charge_pct / charge_energy / schedule.   |
|                           | "schedule" BLOCKS immediate charging even when        |
|                           | plugged in - leave on charge_now unless scheduling    |
| Status / fault / temp     | free / charging / fault states, safety monitoring     |
+---------------------------+-------------------------------------------------------+
```

## Setup steps — John (one-time, ~20 min)

1. **Tuya developer account**: free signup at <https://iot.tuya.com> → create a Cloud
   project (data center: **Central Europe**) → subscribe to the trial of "IoT Core".
2. **Link the app account**: project → Devices → "Link App Account" → scan the QR with
   the **Voldt app** (Me → scan). If the Voldt app can't/won't scan it, re-pair the
   cable into the **Smart Life** app instead (same Tuya platform, no feature loss) and
   link that account.
3. **Collect credentials**: from the linked devices list note the charger's
   **device ID**; get the **local key** via Cloud → API Explorer → "Query Device
   Details" (it changes if the device is ever re-paired — re-fetch then).
4. **Static IP**: give the cable a static DHCP lease on the MikroTik and note the IP.
5. Hand device ID + local key + IP to Claude (or add the integration yourself:
   Settings → Devices → Add integration → Tuya Local).

## Remaining work — Claude (once credentials exist)

- Add the charger via the tuya-local config flow (IP + device ID + local key, select the
  Voldt EV charger profile).
- Energy dashboard: add the total-energy sensor as device entry "EV Charger (Enyaq)".
- Add the power sensor to the `Rest Of Home` `subtract_entities` list in
  `configuration.yaml` (powercalc block) and commit to the config repo.
- Update this doc with the final entity ids; consider a cheap-tariff charging automation
  (tariff sensor: `sensor.p1_meter_tariff`).

## Notes

- Granny-cable sessions are long (~2.3–2.8 kW → overnight for meaningful range); the
  lifetime kWh counter makes per-session and per-month cost visible in the Energy
  dashboard using the standard tariff prices.
- tuya-local was not in this HACS install's default store cache — it is added as a
  custom repository (`make-all/tuya-local`), which HACS remembers for updates.
- Energy monitoring architecture: see `home_assistant_energy.md`.
