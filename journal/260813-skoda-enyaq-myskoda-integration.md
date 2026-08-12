# 2026-08-13 — Skoda Enyaq in Home Assistant, and measuring charging efficiency

Yesterday gave the EV charging setup its cable side (Voldt granny cable via Tuya +
xtend_tuya). Today added the car side, which is what makes the interesting question
answerable: of the electricity we pay for, how much actually reaches the battery?

## Which integration

No Skoda integration exists in HA core. Two community options, and only one is alive:

```
+---------------------------------------+---------------------------------------------+
| Option                                | Verdict                                     |
+---------------------------------------+---------------------------------------------+
| skodaconnect/homeassistant-myskoda    | PICKED. v1.35.0 (2026-07-19), releases      |
|                                       |   roughly monthly. Client of the same API   |
|                                       |   the MySkoda phone app uses.               |
| skodaconnect/homeassistant-           | Deprecated by its own authors - targets the |
|   skodaconnect                        |   dead pre-MySkoda API.                     |
+---------------------------------------+---------------------------------------------+
```

Installed headlessly through the HACS websocket API (`hacs/repositories/add`, then
`hacs/repository/refresh` — needed, or `available_version` stays empty — then
`hacs/repository/download`). Config flow over REST wanted only email and password; the
S-PIN is for privileged commands (lock/unlock, remote climate) and was never asked for.
55 entities, clean log, no errors.

## The pack size was a lucky find

The efficiency calculation needs kWh per percentage point, which needs the usable pack
size. Enyaq is sold as 60 / 80 / 85, and the device registry only said "Enyaq" — model_id
was null. Rather than ask and risk a wrong constant, I pulled the integration's
diagnostics (`/api/diagnostics/config_entry/<id>`), which carries the full vehicle
specification: **58 kWh battery**, 132 kW, MY2024 Selection, 100 kW max DC. That is the
Enyaq 60's usable figure, straight from Skoda. So 1% = 0.58 kWh, sourced rather than
assumed.

Worth remembering as a general move: HA's diagnostics endpoint often holds far more raw
API data than the integration surfaces as entities.

## Why not use the car's own charging_power

The obvious way to get car-side energy is to Riemann-integrate
`sensor.skoda_enyaq_charging_power`, exactly as the cable side does. Comparing the two
live during a charge killed that idea:

```
car  sensor.skoda_enyaq_charging_power   3.0   kW   (flat, never moves)
cable sensor.ev_charger_power_estimated  2.863 kW   (measured)
```

The car reports a coarse, rounded value — and worse, it measures AC power at its own
inlet, so integrating it would measure cable loss only, not conversion loss. It would have
produced a meaningless ~99% efficiency.

So the battery side is derived from **state of charge** instead: 0.58 kWh per percentage
point gained. That measures energy actually stored, which is the number worth having.

## The design, and its three sharp edges

A trigger template accumulates SoC increases; two pairs of `utility_meter`s (daily on the
existing 09:00 charging day, and lifetime) meter both sides; template sensors take the
ratio.

1. **Gated on the cable, not the car.** The accumulator only counts while
   `sensor.voldt_2_4_5g_work_state == charger_charging`. Without this, a public or DC
   charge would raise SoC with no cable energy behind it and push efficiency past 100%.
2. **Only increases count**, and single steps above 10% are discarded (at ~2.9 kW that is
   two hours — beyond any plausible polling gap). SoC drops from preconditioning are
   ignored rather than subtracted, so energy spent heating the battery correctly reads as
   loss.
3. **Whole-percent SoC is the accuracy floor.** The error is ±0.58 kWh *regardless of how
   big the charge was* — ±12% on a 5 kWh day, ±3% on a 20 kWh overnight charge. I saw this
   immediately in live data: over 22 minutes SoC moved 82→84% (1.16 kWh) while the cable
   delivered 0.962 kWh, i.e. 121% efficiency, which is pure quantisation. Both efficiency
   sensors therefore report `unknown` below 5 kWh, and a lifetime pair was added as the
   figure actually worth quoting. Publishing a confident-looking daily percentage built on
   ±0.58 kWh would have been the easy mistake here.

## Verified, not assumed

Watched a live charge for 15 minutes after the final restart: SoC ticked 84→85% and
`sensor.ev_battery_energy_gained` moved 0.0 → 0.58 kWh — exactly one percentage point's
worth. Both utility meters began tracking a little later than expected, which turned out
to be normal: a `utility_meter` stays `unknown` until its **second** source update, since
it meters deltas. The ratio arithmetic was checked separately through `/api/template`
(17.2/20.0 → 86.0%) along with the delta clamp, since the real sensors are suppressed
until 5 kWh accumulates.

## Dashboard

Two new sections on the existing EV Charging dashboard (storage mode, edited via
`lovelace/config/save`): **"The car (Enyaq)"** — SoC gauge, 24 h SoC history, charging
state, plugged-in, power, charge type, limit, time-to-limit, range added, range, odometer,
online, data freshness — and **"Charging efficiency"** — lifetime and daily ratios, both
today's meters, and a 30-day bar chart of cable-delivered vs battery-received.

No battery-temperature entity exists; the API does not expose one for this car, so it was
left out rather than approximated.

## Snags

- The documented SSH password was wrong; the working one is different. Cost a round trip.
- `/config` git operations need `sudo` (root-owned index) **and** an explicit
  `GIT_SSH_COMMAND` pointing at `/config/.git-ssh/id_deploy` — the repo has no
  `core.sshCommand` set, so a plain `sudo git push` fails on host-key verification. Now
  documented, since this will bite again.
- Three restarts, not the intended one: the third was a deliberate redesign after live
  data showed the daily-only efficiency figure was too noisy to publish.

## Known risks, recorded

MySkoda is an unofficial client. VW Group is introducing a formal third-party access
framework requiring app attestation (upstream issue #1112) which may eventually lock it
out. Write commands (lock, charge limit) already 500 on some MY27 cars, and the odometer
has an open freezing bug (#1105). All of that is confined to the car half — every cost and
Energy-dashboard figure depends only on the cable half, which is independent.

## Untouched, deliberately

The Energy dashboard device list, the 12 Aug statistics (the +9/−9 hourly artifact stays —
it is a known, accepted cosmetic quirk), the `ev_charger_power_estimated` →
`ev_charger_energy` Riemann chain, and the Tuya / xtend_tuya logins.

One stale line was corrected in `home_assistant_energy.md`: the device table still listed
`sensor.voldt_2_4_5g_total_energy` for the EV charger, but the dashboard has used
`sensor.ev_charger_energy` since yesterday (verified against `energy/get_prefs`). Doc-only
fix — the dashboard itself was not touched.
