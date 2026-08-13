# Home Assistant — Dishwasher (Bosch / Home Connect)

**Status:** complete as of 2026-08-13. Energy tracking live via the metering plug, Home
Connect integration live for cycle/program data. Per-cycle attribution not yet built.

Bosch **SMV6YCX00E** (Series 6, fully integrated, 60 cm, 14 place settings), installed
~May 2026, controlled day-to-day through the Bosch Home Connect phone app. This doc covers
how it is monitored from Home Assistant and — importantly — why energy tracking does **not**
come from the appliance itself.

Rated figures from the EU energy label, useful as the benchmark to measure against:

```
+--------------------------------------+--------------------------------------+
| Energy efficiency class              | B                                    |
| Eco programme energy                 | 65 kWh / 100 cycles = 0.65 kWh/cycle |
| Eco programme water                  | 9.5 L per cycle                      |
| Eco programme duration               | 3:55                                 |
+--------------------------------------+--------------------------------------+
```

Remember these are EU test-bench conditions — 15 °C inlet, standard load and soil. Real
consumption is expected to differ; quantifying that gap is the point of the calibration
period below.

See also: `home_assistant_energy.md` (the wider energy setup this feeds into).

## The appliance on the network

Discovered 2026-08-13 by probing the static lease:

```
+------------------+-------------------------------------------------------+
| IP               | 192.168.2.39 (static lease on the MikroTik)           |
| MAC              | 48:26:4C:6D:4B:FA                                     |
| OUI vendor       | BSH Electrical Appliances (Jiangsu) - Bosch/Siemens   |
| Open ports       | 443 only (80, 8080, 8443 closed)                      |
| TLS on 443       | Presents no certificate; PSK-only cipher suite        |
|                  |   (ECDHE-PSK). This is the Home Connect *local*       |
|                  |   protocol - the appliance is locally controllable    |
|                  |   without the cloud, if you have its PSK key.         |
+------------------+-------------------------------------------------------+
```

## The key constraint: the appliance reports no energy

**Home Connect dishwashers have no internal power meter, and the Home Connect API exposes
no kWh figure.** The only energy-related field is `BSH.Common.Option.EnergyForecast`, which
is a *percentage of maximum*, not a measurement. This applies to the official
`home_connect` integration and to the local protocol alike.

The Home Connect phone app *does* display a per-cycle energy figure. That number is
modelled by the appliance (heater wattage is known, so element run-time gives a decent
duty-cycle estimate) — but **it is not exposed over the API**, so it cannot be piped into
Home Assistant. The app is a display you can read, not a data source you can consume.

Consequence: connecting the dishwasher to HA gives cycle and program data. It does **not**
give energy. Energy must come from a metering plug.

### Why a static per-program lookup was rejected

The obvious workaround — hard-code "eco = 1.1 kWh, super quick = 2.0 kWh" from the manual —
was evaluated on 2026-08-13 against a ±5% accuracy target and rejected.

The dominant term in a cycle is heating water, `E = m·c·ΔT`, and Dutch mains inlet
temperature swings seasonally from ~8 °C to ~18 °C. Using this model's real label figures
(9.5 L, 0.65 kWh eco):

```
+------------------+---------+---------+------------------+-------------------+
| Condition        | Inlet   | Delta T | Heating energy   | vs. annual mean   |
+------------------+---------+---------+------------------+-------------------+
| Deep winter      |  8 deg C|  42 K   | 0.46 kWh         | +8.5%             |
| Late summer      | 18 deg C|  32 K   | 0.35 kWh         | -8.5%             |
+------------------+---------+---------+------------------+-------------------+
| 9.5 L heated to 50 deg C; spread 0.111 kWh = 17.1% of a 0.65 kWh eco cycle  |
+-----------------------------------------------------------------------------+
```

Upper bound, since the cold pre-rinse is not heated to full temperature — if only ~7 L
reaches 50 °C the spread is 0.082 kWh, still **12.6%** of the cycle. Either way the seasonal
term alone is two to three times the ±5% budget.

Note this is *worse* than a first estimate against a guessed ~0.92 kWh cycle suggested: the
lower the real cycle energy, the larger the same absolute seasonal swing looms in relative
terms.

That alone exceeds the ±5% budget, and it is a **systematic seasonal bias, not noise** —
winter always reads high, summer always low, so it does not average out over a month.
On top of it: published figures are EU test-bench numbers (fixed 15 °C inlet, standard
load/soil); Auto programs vary genuinely with the soil sensor; options like Extra Dry and
SpeedPerfect shift the number without changing the program name; standby draw is invisible
to a lookup; and aborted cycles would count as full ones.

Realistic expectation for a static lookup: ±10–20% per cycle, ~±10% on monthly totals.

**Decision:** measure with the Nous plug. Optionally revisit later using *measured*
per-program constants derived from that plug — those would be far better than manufacturer
nominals, and their real error would be known rather than assumed.

## Energy: the Nous metering plug

The dishwasher's Nous z2m metering plug was unplugged 2026-04-29 (old dishwasher retired)
and read `unavailable` until **reconnected 2026-08-13**. The plug stayed paired in
zigbee2mqtt throughout, so reconnecting was purely physical — no re-pairing needed.

```
+------------------------------------+----------------------------------------+
| sensor.dishwasher_plug_energy      | kWh, total_increasing -> Energy dash   |
| sensor.dishwasher_plug_power       | W, measurement -> Rest Of Home subtract|
| switch.dishwasher_plug             | do NOT switch off - see below          |
| select.dishwasher_plug_power_...   | set to restore-on-power-loss           |
+------------------------------------+----------------------------------------+
```

Configured 2026-08-13 (both live already, contributing 0 until the plug is powered):

- `sensor.dishwasher_plug_power` added to the powercalc **Rest Of Home** subtract group in
  `/config/configuration.yaml`, so the untracked baseline stays honest once the dishwasher
  is drawing load.
- `sensor.dishwasher_plug_energy` added to the Energy dashboard device list as
  **"Dishwasher"** (entry 22).

Verified safe with the plug still offline: Rest Of Home reported 314 W after the change,
with the dishwasher member contributing 0.

### Verification after reconnection (2026-08-13)

```
+------------------------------------------+-----------------------------------+
| sensor.dishwasher_plug_power             | 0 W (machine idle)                |
| sensor.dishwasher_plug_energy            | 496.36 kWh                        |
| switch.dishwasher_plug                   | on                                |
| select.dishwasher_plug_power_outage_...  | 'on' - already correct, see below |
| sensor.rest_of_home_power                | 248 W (P1 386 W) - sane           |
+------------------------------------------+-----------------------------------+
```

**No phantom spike.** The last statistic recorded before the plug went offline in April was
`state=496.36`, and it resumed at exactly 496.36 — so the counter picked up precisely where
it left off and the delta from here is clean. The counter-reset runbook was not needed.

Still unverified: how Rest Of Home behaves while the dishwasher is actually drawing ~2 kW.
Check after the first full cycle that the untracked line does not dip sharply negative.

### Operational cautions

- **Never turn `switch.dishwasher_plug` off.** Cutting power mid-cycle strands the machine.
- **`power_outage_memory` is already set to `on`** (options: `on` / `off` / `restore`), which
  is what we want — after a power cut the relay closes and the dishwasher gets power back
  unconditionally. Do not change it to `restore`, which would reinstate whatever state the
  relay was in before the cut.
- **Check the rating plate.** Nous plugs are rated 16 A / 3680 W; a dishwasher heating
  element is typically ~2.2 kW, so there is headroom, but confirm before relying on it.

## Home Connect integration (live 2026-08-13)

Chosen route: the **official cloud `home_connect` integration**. Rationale — energy already
comes from the plug locally, so the cloud dependency only affects cycle labelling and
convenience data; and it avoids standing up a new service for secondary telemetry.

The local alternative ([hcpy](https://github.com/hcpy2-0/hcpy) → MQTT, running as a Docker
container on infra-vm publishing to Mosquitto on `192.168.2.102:1883`) remains viable and
is the only route that could *possibly* surface richer local data points. It was deferred as
more moving parts for secondary value; hcpy is unofficial and periodically breaks when
Bosch changes their login flow.

### Setup steps (completed 2026-08-13)

At <https://developer.home-connect.com>:

1. Sign up for a developer account.
2. Under **Default Home Connect User Account for Testing**, enter the email of the
   Bosch Home Connect app account — **all lowercase**, or authentication fails.
3. Register an application:
   - Application ID: `Home Assistant`
   - OAuth Flow: **Authorization Code Grant Flow**
   - Redirect URI: `https://my.home-assistant.io/redirect/oauth`
4. Note the **Client ID** and **Client Secret**.
5. **Log out** of the developer portal before continuing.

The credentials were registered via the `application_credentials/create` WebSocket call and
the flow driven headlessly (`POST /api/config/config_entries/flow`, handler `home_connect`),
which returns an `external` step whose `url` John opened to approve. The Cloudflare Zero
Trust Access redirect was **not** a problem in practice.

Config entry `01KZXXREB7PXKJ5EWDD0B4XPRY`, state `loaded`. Credentials are stored in HA's
`.storage` (not tracked in git, not in the Ansible vault).

**17 entities**, device "Dishwasher" (Bosch SMV6YCX00E):

```
+-------------------------------------------------+---------------------------------+
| binary_sensor.dishwasher_connectivity           | on                              |
| binary_sensor.dishwasher_remote_control         | remote control allowed          |
| binary_sensor.dishwasher_remote_start           | remote start allowed            |
| button.dishwasher_stop_programme                | stop the running programme      |
| number.dishwasher_start_in_relative             | delayed start, seconds          |
| select.dishwasher_active_programme              | e.g. dishcare_dishwasher_       |
| select.dishwasher_selected_programme            |   program_eco_50                |
| sensor.dishwasher_door                          | open / closed                   |
| sensor.dishwasher_operation_state               | run / delayedstart / finished   |
| sensor.dishwasher_programme_finish_time         | timestamp                       |
| sensor.dishwasher_programme_progress            | percent                         |
| sensor.dishwasher_program_aborted               | event                           |
| sensor.dishwasher_programme_finished            | event                           |
| sensor.dishwasher_rinse_aid_nearly_empty        | event                           |
| sensor.dishwasher_salt_nearly_empty             | event                           |
| switch.dishwasher_power                         | on                              |
| switch.dishwasher_vario_speed                   | off                             |
+-------------------------------------------------+---------------------------------+
```

**No energy sensor**, as predicted. `sensor.dishwasher_operation_state` and
`select.dishwasher_active_programme` are the two that matter for per-cycle attribution.

## Per-cycle attribution (planned, not built)

Once Home Connect is live, its `operation_state` transitions give clean cycle boundaries,
which combined with the plug's kWh yields "this eco cycle cost 0.83 kWh". Deliberately not
built yet — the plug and the integration land first, then this. Its first job is
calibration: 4–6 weeks of measured per-program energy, producing a real table of constants
and a real variance figure, which is what makes any future lookup-only mode defensible.
