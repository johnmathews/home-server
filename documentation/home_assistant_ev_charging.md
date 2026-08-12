# Home Assistant — EV Charging (Voldt granny cable)

**Status:** LIVE since 2026-08-12 — cloud integration via official Tuya + xtend_tuya.
Tracks charging of the **Skoda Enyaq** on the **Voldt Type 2 granny cable**
(8–13 A, ~2.8 kW, WiFi). In the Energy dashboard as **"EV Charger (Enyaq)"**.

## How it works

The cable is a white-label **Tuya** device (category `qccdz`, EV charger). Two cloud
integrations cooperate:

1. **Official Tuya integration** — logged into the Smart Life account via user-code + QR
   scan. Only maps a bare switch for this category.
2. **xtend_tuya** (HACS, `azerty9971/xtend_tuya`) — same login, exposes ALL the device's
   datapoints as entities, including the energy/power sensors the official integration
   hides.

The device lives in the **Smart Life** app (it was re-paired out of the Voldt app, which
is now retired — same backend, same features). Device ID `bff9a892e0eb9fa22bwmyp`,
MAC `d8:fc:92:93:f5:7d`, LAN IP `192.168.2.29`.

## Entities

```
+---------------------------------------------+----------------------------------------+
| Entity                                      | Notes                                  |
+---------------------------------------------+----------------------------------------+
| sensor.ev_charger_energy                    | THE energy sensor: Riemann-integrated  |
|                                             |   from ev_charger_power_estimated (see |
|                                             |   "Known issue") -> Energy dashboard   |
|                                             |   "EV Charger (Enyaq)" + all cards     |
| sensor.voldt_2_4_5g_total_energy            | DEAD - device firmware never updates   |
|   /_daily_ /_monthly_ /_yearly_ /_balance_  |   its energy counters via cloud (all   |
|                                             |   stuck at 0; do not use)              |
| sensor.ev_charger_power_estimated           | THE power sensor (template): cloud     |
|                                             |   value when fresh; set-current x 230V |
|                                             |   while charging with a stale 0. Feeds |
|                                             |   energy integration, Rest Of Home,    |
|                                             |   dashboard gauges.                    |
| sensor.voldt_2_4_5g_total_power             | raw cloud power: correct but pushed    |
|                                             |   only HOURLY (~hh:58) + on session end|
| sensor.voldt_2_4_5g_single_phase_power      | per-phase power, kW (same cadence)     |
| sensor.voldt_2_4_5g_work_state              | charger_free / charging / fault ...    |
| number.voldt_2_4_5g_charging_current        | 8-13 A charge rate control             |
| select.voldt_2_4_5g_work_mode               | charge_now / schedule / ... - LEAVE ON |
|                                             |   charge_now; "schedule" blocks        |
|                                             |   immediate charging                   |
| switch.voldt_2_4_5g_switch                  | starts/stops the CURRENT session (not  |
|                                             |   a device power switch)               |
| sensor.voldt_2_4_5g_temperature             | internal temp, safety                  |
| button.voldt_2_4_5g_clear_energy            | RESETS the lifetime counter - do NOT   |
|                                             |   press; it breaks dashboard history   |
+---------------------------------------------+----------------------------------------+
```

## Answering the usual questions

```
+--------------------------------------+------------------------------------------------+
| Question                             | Where to look                                  |
+--------------------------------------+------------------------------------------------+
| Energy + cost per day/week/month/    | Energy dashboard -> pick the period at the top |
| quarter                              | -> "EV Charger (Enyaq)" row in the device      |
|                                      | breakdown. Costs use the real tariff prices.   |
|                                      | Data is long-term statistics: kept forever.    |
| When do charges start and end?       | History page -> sensor.voldt_2_4_5g_work_state |
|                                      | -> coloured timeline of charger_charging       |
|                                      | blocks. Raw history kept ~10 days (recorder    |
|                                      | default); older start/stop times are gone, but |
|                                      | hourly energy statistics remain forever.       |
| How long do we spend charging?       | sensor.ev_charging_time_today (hours; the      |
|                                      | "charging day" runs 09:00-09:00 so overnight   |
|                                      | sessions count whole; long-term stats enabled  |
|                                      | via customize state_class; max-per-day =       |
|                                      | charging h/day).                               |
| How many sessions?                   | sensor.ev_charging_sessions_today (count per   |
|                                      | 09:00-09:00 day).                              |
| Everything in one place              | "EV Charging" dashboard (sidebar, /ev-charging)|
|                                      | - live gauge/controls, session timeline (72h), |
|                                      | daily+monthly energy bars, charging h/day.     |
| Ad-hoc analysis / Grafana            | HA exports all sensors to Prometheus           |
|                                      | (prometheus: block; scraped by prometheus_lxc) |
|                                      | -> voldt sensors are queryable in Grafana too. |
+--------------------------------------+------------------------------------------------+
```

`charger_charging` is one of the work_state enum values: charger_free, charger_insert,
charger_wait, charger_charging, charger_pause, charger_end, charger_fault
(charger_free_fault). "How long was the car plugged in but NOT charging" could be a
future history_stats on charger_insert/charger_wait/charger_end if wanted.

## Known issue: the device's own energy counters are dead

Verified on the first real charge (2026-08-12, ~3.05 h at ~2.86 kW ≈ 8.7 kWh, confirmed
against the P1 meter): `work_state` and `total_power` report correctly, but
`forward_energy_total` (and daily/monthly/yearly/balance) **never left 0** — the firmware
doesn't maintain or push them. Also, the raw power DP is pushed only **hourly** (at
~hh:58) plus instantly on session end — so each session's first up-to-60 min would read
0 kW. Fix, two layers: `sensor.ev_charger_power_estimated` (template in templates.yaml)
uses the cloud value when fresh and falls back to set-current × 230 V while
`work_state = charger_charging` with a stale 0; `sensor.ev_charger_energy` (Riemann
`integration:`, method left, `max_sub_interval` 5 min) integrates that, and everything
(Energy dashboard entry, Rest Of Home, dashboard cards) points at the estimated pair.
Accuracy: the estimator ran ~4% high vs the observed 2.86 kW during the fallback hour
(car pulls slightly under the 13 A pilot) — self-corrects when real values arrive. The first charge
(8.7 kWh) predates the sensor and is missing from the dashboard history — injectable via
Developer tools → Statistics → adjust if it ever matters.

## Caveats

- **Cloud-dependent**: sensor updates flow through Tuya's cloud (MQTT push, updates are
  near-real-time). Internet outage = no data (charging itself is unaffected). Energy is
  integrated from sparse power updates, so treat kWh as ~±5% (good enough for cost
  tracking; the grid-truth is always the P1 meter).
- Re-pairing the device into a different app/account changes its device ID and breaks the
  entity history.

## The developer-platform dead end (context)

The plan A was **tuya-local** (fully local, no cloud) — it is installed with its
`voldt_ev_charger` profile ready, but it needs the device's **local key**, and Tuya's
developer-platform "Link App Account" QR flow failed persistently: scanning the QR (both
in the Voldt and Smart Life apps, correct data center, IoT Core authorized, Me→Scan
scanner) made the app open a URL that returned an S3 `AccessDenied`. The same account
authorized HA's QR login instantly, so the failure is on Tuya's platform side — community
reports point at account/billing verification requirements for new developer accounts.

**Optional future upgrade to local**: if the platform link ever works (retry after
completing billing verification at iot.tuya.com, project "Voldt cable", Central Europe
link DC), fetch the local key via API Explorer → "Query Device Details", then add the
device in the Tuya Local integration (IP `192.168.2.29`, device ID + local key) and swap
the dashboard/Rest-Of-Home sensors. Until then the cloud route is fully functional.

## Related

- Reserve `192.168.2.29` for MAC `d8:fc:92:93:f5:7d` on the MikroTik (needed for the
  local upgrade; harmless to do now — see JTBD in `home_assistant_energy.md`).
- Cheap-tariff charging automation idea: trigger on `sensor.p1_meter_tariff`, act on
  `switch.voldt_2_4_5g_switch` + `number.voldt_2_4_5g_charging_current`.
- Energy monitoring architecture: `home_assistant_energy.md`.
