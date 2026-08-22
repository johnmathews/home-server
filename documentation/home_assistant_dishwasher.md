# Home Assistant — Dishwasher (Bosch / Home Connect)

**Status:** current — verified 2026-08-13 · covers: live
Energy tracking live via the metering plug, Home Connect integration live for
cycle/programme data, per-cycle attribution built and validated on a real cycle. Remaining
work is time: 4–6 weeks of cycles to build a calibration table.

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
| 9.5 L heated to 50 deg C -> seasonal spread 0.111 kWh                       |
+-----------------------------------------------------------------------------+
```

That 0.111 kWh spread as a share of a cycle, against both available denominators:

```
+---------------------------------------------+---------+------------------------+
| vs. the 0.65 kWh EU label figure             | 17.1%   | test-bench conditions  |
| vs. the 0.88 kWh first measured cycle        | 12.6%   | this kitchen, Aug 2026 |
+---------------------------------------------+---------+------------------------+
```

Both are an upper bound, since the cold pre-rinse is not heated to full temperature. Whichever
denominator you take, **the seasonal term alone is two to three times the ±5% budget**, which
is what settles the question.

An earlier version of this section claimed the case got *stronger* once the real label figure
replaced a guessed ~0.92 kWh cycle. That reasoning is now retracted: the first measured cycle
came in at **0.88 kWh**, within 5% of the original guess, so the 0.65 kWh label — not the
guess — was the outlier. The conclusion survives unchanged; the argument for it does not, and
is corrected here rather than left standing.

The seasonal term is a **systematic bias, not noise** —
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
| select.dishwasher_plug_power_...   | leave at 'on'; NOT 'restore' - below   |
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

**There WAS a phantom spike — a −471.62 kWh one — and the initial check missed it.** The
sensor's *state* resumed at exactly 496.36, matching its April value, which looked like clean
continuity. But the statistics **cumulative sum** was reset from 471.62 to 0, which the Energy
dashboard rendered as a −471.62 kWh bar for the Dishwasher.

```
+-------------+----------+-----------+----------------------------------------+
| Date        | sum      | state     | change                                 |
+-------------+----------+-----------+----------------------------------------+
| 2026-04-29  |  471.62  |  496.36   | +0.66   last data before unplugging    |
| 2026-08-13  |    0.00  |  496.36   | -471.62 the artifact                   |
| 2026-08-13  |  471.62  |  496.36   |  0.00   after the fix below            |
+-------------+----------+-----------+----------------------------------------+
```

**Cause**: the plug was gone ~106 days but there is no `recorder:` block, so state history
purges after **10 days**. On return, HA had no retained prior state to diff the counter
against, treated the sensor as new, and restarted `sum` at zero.

**Fix applied**: WS `recorder/adjust_sum_statistics` on `sensor.dishwasher_plug_energy` at
the reset hour, `adjustment: 471.62`, `adjustment_unit_of_measurement: kWh`. That adjusts
the hour and every subsequent row, restoring the original baseline. Reversible by adjusting
by −471.62. (The alternative, `recorder/clear_statistics`, gives the new appliance a clean
slate but destroys the old machine's history irreversibly.)

**The lesson worth carrying**: for a `total_increasing` sensor returning after a gap longer
than `purge_keep_days`, checking that the *state* is continuous is **not** sufficient. Check
the statistics `sum` too — that is where the artifact lives.

Rest Of Home under real load was verified later the same day — see "First measured cycle"
below. Short version: transient dips to ~−1595 W during heating, reconciling to 99.4%.

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

Config entry `01KZXXREB7PXKJ5EWDD0B4XPRY`, state `loaded`. HA keeps the credentials in its
`.storage` (gitignored). A copy also lives in the Ansible vault as
`vault_home_connect_client_id` / `vault_home_connect_client_secret` — **for disaster recovery
only**, since nothing in this repo consumes them; without it, rebuilding HA from scratch would
mean re-registering the application at developer.home-connect.com.

**20 registry entities — 16 enabled, 4 disabled by the integration.** Device "Dishwasher"
(Bosch SMV6YCX00E). Verified against the entity registry 2026-08-13.

```
+-------------------------------------------------+---------------------------------+
| ENABLED (16)                                    |                                 |
+-------------------------------------------------+---------------------------------+
| binary_sensor.dishwasher_connectivity           | on                              |
| binary_sensor.dishwasher_remote_control         | remote control allowed          |
| binary_sensor.dishwasher_remote_start           | remote start allowed            |
| button.dishwasher_stop_programme                | stop the running programme      |
| number.dishwasher_start_in_relative             | CONFIGURED delay, not a live    |
|                                                 |   countdown - see gotcha below  |
| select.dishwasher_active_programme              | e.g. dishcare_dishwasher_       |
| select.dishwasher_selected_programme            |   program_eco_50                |
| sensor.dishwasher_door                          | open / closed / locked          |
| sensor.dishwasher_operation_state               | inactive/ready/delayedstart/    |
|                                                 |   run/pause/actionrequired/     |
|                                                 |   finished/error/aborting       |
| sensor.dishwasher_programme_finish_time         | timestamp                       |
| sensor.dishwasher_programme_progress            | percent                         |
| switch.dishwasher_power                         | on                              |
| switch.dishwasher_vario_speed                   | off                             |
| switch.dishwasher_extra_dry                     | programme option                |
| switch.dishwasher_half_load                     | programme option                |
| switch.dishwasher_hygiene                       | programme option                |
+-------------------------------------------------+---------------------------------+
| DISABLED by the integration (4) - present in    |                                 |
| the registry, produce NO state and NO data      |                                 |
+-------------------------------------------------+---------------------------------+
| sensor.dishwasher_program_aborted               | (note: "program", not           |
| sensor.dishwasher_programme_finished            |   "programme" - the integration |
| sensor.dishwasher_rinse_aid_nearly_empty        |   spells it both ways; the ids  |
| sensor.dishwasher_salt_nearly_empty             |   really are inconsistent)      |
+-------------------------------------------------+---------------------------------+
```

**No energy sensor**, as predicted. `sensor.dishwasher_operation_state` and
`select.dishwasher_active_programme` are the two that matter for per-cycle attribution.

Two things worth knowing:

- **Don't build anything on the four disabled sensors** without enabling them first — a
  "programme finished" automation keyed on `sensor.dishwasher_programme_finished` would never
  fire. Cycle-end detection uses `operation_state` reaching `finished` instead, which is why
  the attribution automations work.
- **The three option switches (`extra_dry`, `half_load`, `hygiene`) are observable**, which
  matters for calibration: options shift a cycle's energy without changing the programme name,
  and they are exactly the confound that would poison a naive per-programme lookup table. They
  are not currently captured per cycle — see the calibration section.

## Per-cycle attribution (built 2026-08-13)

Home Connect gives the cycle boundaries, the plug gives the kWh. Two automations subtract
the plug's cumulative counter across a cycle:

```
operation_state:  ready/delayedstart --> run --> [pause <-> run] --> finished
                                          |                            |
                                    snapshot start                 record delta
```

```
+--------------------------------------------------+--------------------------------+
| input_number.dishwasher_cycle_start_energy       | counter value at cycle start   |
| input_number.dishwasher_last_cycle_energy        | the computed delta             |
| input_text.dishwasher_cycle_programme            | programme, in flight           |
| input_text.dishwasher_last_cycle_programme       | programme, copied at finish    |
| sensor.dishwasher_last_cycle_energy              | template sensor, kWh           |
| automation.dishwasher_snapshot_plug_energy_...   | start                          |
| automation.dishwasher_record_cycle_energy_...    | finish                         |
+--------------------------------------------------+--------------------------------+
```

Design points that matter if you ever debug this:

- **`state_class: measurement` on the template sensor** is load-bearing. There is no
  `recorder:` block, so HA is on the default `purge_keep_days: 10` and state history is gone
  after ten days. Long-term statistics survive indefinitely, so this is what makes a 4–6 week
  calibration possible at all. Deliberately **no** `device_class: energy` — HA rejects that
  pairing with `measurement`.
- **The start trigger uses `not_from: [pause, run]`**, not an enumerated `from:` list. That
  covers `unknown -> run`, which is what happens if HA restarts at the exact moment a cycle
  begins. Enumerating source states silently misses it.
- **Two separate programme helpers.** The in-flight one is copied to the last-cycle one only
  at finish, so starting a new cycle never leaves the reported last-cycle energy paired with
  the new cycle's programme name.
- **Aborted programmes record nothing** — they go `aborting -> ready` and never reach
  `finished`.
- **Standby draw between cycles is not attributed to any cycle.** It still lands in the plug
  total and the Energy dashboard; it just does not inflate a per-cycle figure.
- Shared failure mode with the retired "corrected energy" pattern: if an automation does not
  fire, that cycle is lost quietly. The `not_from` trigger makes the next cycle re-baseline
  cleanly rather than record a doubled value, so it fails safe rather than silently wrong.

### Smoke test (2026-08-13)

Verified by driving `sensor.dishwasher_operation_state` through the REST API while the
machine sat idle at `ready`:

```
+--------+---------------------------------------------+---------------------------+
| Test A | -> run                                      | snapshot 496.36 + eco_50  |
| Test B | start lowered to 495.36, then -> finished   | recorded 1.0 kWh, prog OK |
| Test C | run -> pause -> run with sentinel 100.0     | stayed 100.0, no re-snap  |
+--------+---------------------------------------------+---------------------------+
```

The plug's own `total_increasing` counter was **deliberately never overridden** during
testing — faking it would have injected a phantom kWh into the Energy dashboard, the exact
artifact avoided when the plug was reconnected. Consumption was simulated by lowering the
start snapshot instead. Helpers were reset afterwards and the test statistic wiped with
`recorder/clear_statistics`, so the calibration dataset starts empty.

## Dashboards

```
+---------------------+----------------------------------------------------------+
| Energy dashboard    | sensor.dishwasher_plug_energy as "Dishwasher" (entry 22) |
| Power > Kitchen     | pre-existing heading + gauge + history graph on           |
|   (dashboard-power) |   sensor.dishwasher_plug_power, plus 6 tiles added        |
|                     |   2026-08-13: status, programme, progress, finish time,   |
|                     |   last-cycle energy, door                                 |
| Everything          | Kitchen entities card: added plug energy and last-cycle   |
|   (all-devices)     |   energy alongside the existing power sensor              |
+---------------------+----------------------------------------------------------+
```

The Kitchen view's dishwasher gauge and history graph already existed from the old
dishwasher and needed no repair — the plug entity ids never changed, so they came back to
life on their own when the plug was reconnected. The gauge's `max` was raised **1800 → 2400 W**
because a ~2.2 kW heating element would have pegged it, with severity bands moved to
0 / 800 / 1800. Revisit once a real cycle shows the true peak draw.

**Caveat: Lovelace dashboards are storage-mode and live in `.storage/`, which the config
repo's whitelist `.gitignore` deliberately excludes.** So dashboard edits are *not* version
controlled — they exist only in the running instance and in HA/PBS backups. Unlike the YAML
changes, there is nothing to `git revert` if a card layout goes wrong.

### First measured cycle — 2026-08-13, Eco 50

The whole chain worked end to end on real Home Connect transitions, not simulated ones.

```
+------------------------------------------+----------------------------------+
| Measured cycle energy                    | 0.88 kWh                         |
| EU label figure (eco, test conditions)   | 0.65 kWh                         |
| Difference                               | +35%                             |
| Programme recorded                       | eco_50 (captured automatically)  |
| Arithmetic check                         | 497.24 - 496.36 = 0.88  correct  |
| Peak draw                                | 1984 W                           |
+------------------------------------------+----------------------------------+
```

**+35% over the label on the very first cycle**, and this is a *late-summer* measurement —
mains inlet is at its warmest, the most favourable end of the seasonal range. The same wash
in February should cost more. One cycle is not a calibration, but the direction is exactly
what the seasonal argument above predicted, and it is a far larger gap than the ±5% a static
lookup would have needed.

Peak draw of 1984 W confirms the gauge `max` of 2400 W is sensible (~21% headroom) and that
the original 1800 W would indeed have pegged. No change needed — this closes the "revisit once
a real cycle shows the true peak" note above, and confirms the rating-plate caution (a ~2.2 kW
element was the expectation; 1984 W is the measurement).

**Rest Of Home under real load** — the last unverified thing — behaved correctly. It dips to
about **−1595 W** transiently during the heating phases, in 3 of the 4 cycle hours. That
magnitude is roughly the appliance's own draw, which is the signature of *meter lag*: the
plug reports the ~2 kW load before the P1 meter does, so `P1 − Σtracked` is briefly negative
by about the appliance's consumption. It averages out as designed — reconciliation across
the cycle window came to **99.4% accounted (gap 0.02 kWh)**.

### Calibration

Collect 4–6 weeks, then compare measured per-programme energy against the 0.65 kWh label
figure and, more importantly, look at the **spread**. That decides whether a fixed
per-programme constant could ever replace the plug.

**Known limitation of the current attribution**: only the programme name is captured, not the
option switches (`extra_dry`, `half_load`, `hygiene`, `vario_speed`). Those change a cycle's
energy without changing its programme name, so two cycles logged as `eco_50` are not
necessarily comparable. If the measured spread turns out wide, capturing the option states at
cycle start is the first thing to try before concluding the programme itself is variable.

Programme ids to expect:

```
dishcare_dishwasher_program_eco_50        auto_2        intensiv_70
kurz_60        night_wash        machine_care        pre_rinse
```
