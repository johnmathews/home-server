# Home Assistant — EV Charging (Voldt granny cable + Skoda Enyaq)

**Status:** LIVE. Cable side since 2026-08-12 (official Tuya + xtend_tuya); car side
since 2026-08-13 (MySkoda). Tracks charging of the **Skoda Enyaq** on the **Voldt Type 2
granny cable** (8–13 A, ~2.8 kW, WiFi). In the Energy dashboard as **"EV Charger
(Enyaq)"**.

There are two independent halves, and the distinction matters constantly:

```
+-------------+---------------------------+---------------------------------------------+
| Half        | Source                    | Measures                                    |
+-------------+---------------------------+---------------------------------------------+
| Cable side  | Voldt charger, Tuya cloud | Energy leaving the wall. Feeds the Energy    |
|             |   (xtend_tuya)            |   dashboard and all cost figures.            |
| Car side    | Skoda Enyaq, MySkoda      | State of charge, range, odometer, plug and   |
|             |   cloud (HACS)            |   charging state. Feeds the efficiency calc. |
+-------------+---------------------------+---------------------------------------------+
```

Neither can replace the other: the cable does not know the battery, and the car does not
report kWh drawn from the wall.

## How the cable side works

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

## Cable-side entities

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
   `sensor.voldt_2_4_5g_work_state` is `charger_charging`. Charging away from home (public
   AC, DC rapid) raises SoC with no cable energy behind it and would otherwise inflate
   efficiency past 100%.
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
(car pulls slightly under the 13 A pilot) — self-corrects when real values arrive. The first
charge (8.7 kWh) predated the sensor; it was injected retroactively into the statistics
(2026-08-13, at the 23:00 hour of 12 Aug — the earliest existing stats row). Deliberate
side effect, decided acceptable: 12 Aug's HOURLY detail view shows a +9/−9 kWh pair
(EV vs computed untracked) because the energy sits in a different hour than the grid
import; all daily/weekly/monthly totals and costs are correct. Do not "fix" it.

Also normal: when the car is left plugged in after finishing, it wakes every ~25–30 min
for short top-up/balancing draws (10 s–4 min at ~2.2 kW). Each counts as a "session" in
ev_charging_sessions_today, so the counter reads high on plugged-in evenings. These bursts
also draw cable energy without moving the whole-percent SoC, so a night spent idling on
the plug drags `ev_charging_efficiency_today` down. That is not a fault — the energy
genuinely was consumed without reaching the battery — but it is another reason to read
the lifetime figure rather than a single day's.

## Caveats

- **Cloud-dependent, both halves**: cable data flows through Tuya's cloud and car data
  through Skoda's (MQTT push, near-real-time). Internet outage = no data (charging itself
  is unaffected). Energy is integrated from sparse power updates, so treat kWh as ~±5%
  (good enough for cost tracking; the grid-truth is always the P1 meter).
- Re-pairing the Voldt into a different app/account changes its device ID and breaks the
  entity history.
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

## Where the config lives

All of it is YAML in the `/config` repo — this HA instance uses **no UI helpers**, so
never go looking in Settings → Devices & Services → Helpers for these entities.

```
+--------------------------------------+------------------------------------------------+
| What                                 | Where                                          |
+--------------------------------------+------------------------------------------------+
| ev_charger_power_estimated,          | /config/templates.yaml                         |
| ev_battery_energy_gained,            |                                                |
| ev_charging_efficiency{,_today}      |                                                |
| ev_charger_energy (Riemann),         | /config/configuration.yaml, sensor: block      |
| ev_charging_time/sessions_today      |                                                |
| the four utility_meters              | /config/configuration.yaml, utility_meter:     |
| MySkoda + Tuya credentials           | /config/.storage (never git-tracked)           |
| "EV Charging" dashboard              | storage mode - edit via the UI or the          |
|                                      |   lovelace/config/save websocket command       |
+--------------------------------------+------------------------------------------------+
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

- `192.168.2.29` (MAC `d8:fc:92:93:f5:7d`) is a **static lease on the MikroTik** as of
  2026-08-13, so the cable's address is now safe to hard-code — which is what the
  tuya-local upgrade below needs.
- Cheap-tariff charging automation idea: trigger on `sensor.p1_meter_tariff`, act on
  `switch.voldt_2_4_5g_switch` + `number.voldt_2_4_5g_charging_current`. Now that the car
  side exists, `number.skoda_enyaq_charge_limit` is the gentler lever — cap the target SoC
  instead of interrupting the session.
- Energy monitoring architecture: `home_assistant_energy.md`.
