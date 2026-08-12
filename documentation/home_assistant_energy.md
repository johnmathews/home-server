# Home Assistant — Energy Monitoring

**Status:** current as of 2026-08-12 (powercalc overhaul).

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
| Energy dashboard          | 2 grid tariffs, gas, 20 device consumption entries.          |
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
| Rest of home (untracked)  | sensor.rest_of_home_energy               | subtract group      |
+---------------------------+------------------------------------------+---------------------+
```

TRETAKT fixture mapping (fixed = bulbs + ~0.4 W plug self-usage; bulbs are non-dimmable so
fixed wattage is exact): plug 1 = 3× SOLHETTA GU10 4.3 W; plug 2 = 1× Majestic 8.8 W + 1×
KAJPLATS (measured separately via its light entity); plug 3 = 1× KAJPLATS only; plug 4 = 3×
5 W screw-ins; plugs 5/6 = decorative filament bulbs, **wattage estimated at 6 W** until read
off the bulbs. KAJPLATS spec: 9.5 W @ 1521 lm. The KAJPLATS bulbs sit behind plugs 2/3, so
they read `unavailable` when the plug is off — powercalc counts that as off (0 W).

**Rest Of Home** = `sensor.p1_meter_power` minus every tracked power sensor (20 members),
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
- Dropped from the dashboard: TV (deliberate — small load), dishwasher (plug unplugged),
  electric heater (plug retired), office/bathroom/living-room lights (devices offline, see
  backlog).

### Counter-reset spike runbook

If a metering plug is factory-reset/re-paired and its energy counter restarts, HA treats
the drop as a meter reset (fine), but if the plug then reports its *old* total once (z2m
retained message) you can get a one-off phantom spike. Fix: **Developer tools → Statistics →
(sensor) → adjust statistic** — find the 5-minute slot with the spike and set its value to
the correct amount. No YAML involved.

## powercalc specifics

- Installed via HACS (v1.24.1), config is YAML-only: `powercalc:` block in
  `configuration.yaml`. `enable_autodiscovery: false` — every sensor is explicit.
- Lights whose model has a measured profile in the powercalc library use LUT mode
  automatically (no strategy in YAML): STOFTMOLN `T2035`, TRADFRI `LED2103G5`,
  JETSTROM `L2207`.
- KAJPLATS (`KAJPLATS_WS`) has no library profile yet → linear 1.0–9.5 W. Revisit when
  <https://library.powercalc.nl> gains the profile.
- `unavailable` counts as "off" (standby_power) — this is what makes smart-bulbs-behind-
  plugs and offline devices behave sanely.

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

## Jobs to be done (backlog, 2026-08-12)

```
+----+------------------------------------------------------------------+----------------+
| #  | Job                                                              | Unblocks       |
+----+------------------------------------------------------------------+----------------+
| 1  | Reconnect dishwasher Nous plug                                   | dishwasher     |
|    |   then: re-add sensor.dishwasher_plug_energy to dashboard and    | tracking       |
|    |   sensor.dishwasher_plug_power to the Rest Of Home subtract list |                |
| 2  | Re-pair office + bathroom JETSTROM panels (currently on the      | office/bath    |
|    |   defunct ZHA network) to zigbee2mqtt, like the entrance panel   | light tracking |
|    |   then: add powercalc entries for the new entities               |                |
| 3  | Living-room / dinner-table lights: old template referenced       | living room    |
|    |   light.dinner_table_1 (gone). KAJPLATS bulbs now cover plugs    | clarity        |
|    |   2/3; verify nothing else is missing                            |                |
| 4  | Read real wattage off the two filament bulbs (plugs 5/6),        | accuracy       |
|    |   update the two fixed powers in configuration.yaml              |                |
| 5  | Consider a Nous metering plug for the fridge — likely the        | biggest        |
|    |   biggest single untracked load in Rest Of Home                  | untracked sink |
| 6  | Remove electric-heater leftovers if the plug is truly retired    | tidiness       |
|    |   (z2m device removal)                                           |                |
| 7  | EV charger (Voldt granny cable): create Tuya IoT account, link   | EV charging    |
|    |   Voldt app, collect device ID + local key, static DHCP lease    | tracking       |
|    |   on MikroTik — full steps in home_assistant_ev_charging.md.     |                |
|    |   (tuya-local + Voldt profile already installed 2026-08-12)      |                |
+----+------------------------------------------------------------------+----------------+
```

## Audit numbers (pre-overhaul, for reference)

30 days before 2026-08-12: grid import 374 kWh, tracked devices 152 kWh (41%). Dead
sensors at the time: TV (since 2026-02-10), dishwasher (2026-04-29), office light
(~2025-08), bathroom + living-room lights (≥1 year). The Rest Of Home sensor now makes
any future silent failure visible as an unexplained rise in the untracked line.
