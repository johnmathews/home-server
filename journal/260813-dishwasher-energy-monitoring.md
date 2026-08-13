# 2026-08-13 — Dishwasher energy monitoring (Bosch Home Connect)

## What prompted it

New Bosch dishwasher installed ~May 2026. The old dishwasher's Nous metering plug was
unplugged 2026-04-29 and never reconnected, so the appliance has been completely untracked
since — part of the ~59% of grid import sitting in Rest Of Home. John asked to find the
dishwasher on the wifi network and add it to HA for energy tracking, noting it is controlled
via the Bosch Home Connect app and has a static lease at 192.168.2.39.

## Finding the appliance

Confirmed in a couple of minutes from the static lease:

- Responds to ping at `192.168.2.39`, MAC `48:26:4C:6D:4B:FA`.
- OUI resolves to **BSH Electrical Appliances (Jiangsu)** — Bosch/Siemens. Right device.
- Port scan: **443 only** (80, 8080, 8443 closed).
- `openssl s_client` against 443 returns **no peer certificate** and negotiates a PSK-only
  cipher. That is the signature of the Home Connect **local** protocol — the appliance is
  locally controllable without the cloud, given its PSK key.

## The finding that changed the design

**The dishwasher cannot report its own energy use.** Home Connect appliances have no
internal power meter, and the API's only energy field is
`BSH.Common.Option.EnergyForecast` — a *percentage of maximum*, not kWh. True of the
official integration and of the local protocol.

This matters because the Home Connect phone app *does* show a per-cycle energy figure, which
naturally reads as "the data exists, just fetch it". It doesn't: the app's number is modelled
on the appliance (heater wattage × element run-time, probably decent) and **is not exposed
over the API**. The app is a display, not a data source.

So "add the dishwasher to HA" and "measure its energy" turned out to be two separate jobs,
and the second one needs a metering plug regardless.

### The ±5% question

John asked whether a static per-program lookup ("every eco cycle = 1.1 kWh") would land
within 5%, since that would avoid using the plug at all. Answer: no, and the reasoning is
worth recording.

The dominant term is heating water, `E = m·c·ΔT`. Dutch mains inlet runs ~8 °C in winter to
~18 °C in late summer. For ~9 L heated to 50 °C that is 0.44 kWh vs 0.34 kWh — a 0.105 kWh
spread, **11.4% of a 0.92 kWh eco cycle**, so ±5.7% about the mean. That consumes the entire
error budget on its own, and critically it is a *systematic seasonal bias rather than noise*,
so it does not average out over a month — it just makes winter totals consistently high.

Stacked on top: published figures are EU test-bench numbers (fixed 15 °C inlet, standard
load and soil); Auto programs genuinely vary with the soil sensor; Extra Dry / SpeedPerfect
shift consumption without changing the program name; standby draw is invisible to a lookup;
aborted cycles would count as full ones. Realistic: ±10–20% per cycle, ~±10% monthly.

Agreed plan: use the plug, which John already owns and which is still paired. If a
lookup-only mode is ever wanted, derive the constants from *measured* data — far better than
manufacturer nominals, with a known error instead of an assumed one.

## What was done

1. **`sensor.dishwasher_plug_power` added to the powercalc Rest Of Home subtract group** in
   `/config/configuration.yaml`. Validated via `POST /api/config/core/check_config`
   (`valid`), applied with a core restart.
2. **`sensor.dishwasher_plug_energy` added to the Energy dashboard** as "Dishwasher" via the
   `energy/save_prefs` WebSocket call — device entry 22.
3. **Verified safe while the plug is still unplugged.** This was the actual risk: adding an
   `unavailable` member could have taken the whole subtract group to `unknown` and silently
   broken a working sensor. Post-restart it read `unknown` briefly during warm-up, then
   settled at **314 W with the dishwasher member contributing 0**. Baseline before the
   change was 263 W against a P1 reading of 416 W, so the group is behaving.
4. **Committed and pushed** `/config` to `johnmathews/home-assistant-config` (`0e26a57`).
5. **Documentation**: new `documentation/home_assistant_dishwasher.md`; energy doc updated
   (dashboard table, JTBD #1 rewritten, dropped-devices note).
6. **John reconnected the plug the same session**, and it verified clean: power 0 W (idle),
   energy 496.36 kWh, switch on, Rest Of Home 248 W against P1 386 W.
   **No phantom spike** — the last statistic before the April outage was `state=496.36` and
   it resumed at exactly 496.36, so the counter picked up where it left off and the
   counter-reset runbook was not needed. `power_outage_memory` was already `on`, which is the
   setting we want (relay closes unconditionally after a cut); `restore` would have been
   wrong, since it reinstates the pre-cut state.

7. **Home Connect integration went live the same session.** John registered the developer
   app; credentials added via `application_credentials/create` over WebSocket, then the
   config flow driven headlessly (`POST /api/config/config_entries/flow`, handler
   `home_connect`) — it returns an `external` step whose `url` John opened to approve.
   Entry `01KZXXREB7PXKJ5EWDD0B4XPRY`, state `loaded`, **17 entities**. The Cloudflare Zero
   Trust redirect worried me beforehand and turned out to be a non-issue.

   Appliance identified as a **Bosch SMV6YCX00E** (Series 6, 60 cm, 14 place settings).
   Confirmed: **no energy entity** among the 17, exactly as predicted.

### The label figures sharpen the earlier argument

The model's EU label reads **65 kWh/100 cycles (0.65 kWh eco), 9.5 L, 3:55, class B**. My
rejection of the static-lookup approach had been computed against a *guessed* ~0.92 kWh
cycle and 9 L. Redone with the real figures the case is stronger, not weaker: 9.5 L across
an 8→18 °C inlet swing is a 0.111 kWh spread, which is **17.1% of a 0.65 kWh cycle** (±8.5%
about the mean) rather than 11.4%. Even assuming only ~7 L reaches full temperature it is
12.6%.

The general point is worth remembering: *the lower a cycle's total energy, the larger the
same absolute seasonal swing looms in relative terms.* Guessing the cycle high made the
lookup approach look better than it is.

## Still open

- **Check Rest Of Home during the first real cycle.** Everything so far was verified with the
  dishwasher idle at 0 W; the interesting case is ~2 kW of heating element, where a unit or
  sign error would show as the untracked line dipping sharply negative.
- **Per-cycle attribution**, deliberately not built — the design was never presented in
  detail, so it needs John's sign-off first. `sensor.dishwasher_operation_state` and
  `select.dishwasher_active_programme` are the inputs; combined with plug kWh they give
  per-program measured constants over a 4–6 week calibration window.
- **First calibration cycle is already queued**: at the moment the integration came up the
  machine was sitting in `delayedstart` with `dishcare_dishwasher_program_eco_50` selected,
  finishing 20:14 UTC. Even without attribution built, that cycle is reconstructable after
  the fact from the plug's statistics over the run window — measured vs. the 0.65 kWh label
  figure.

## Notes for next time

- Chose the **official cloud integration** over local hcpy: energy is already local via the
  plug, so the cloud only carries cycle labelling, and that did not justify a new
  Ansible-managed service. hcpy stays on the table — it is the only route that might expose
  richer local data points, at the cost of being unofficial and periodically broken by Bosch
  login-flow changes.
- The HA SSH password and the `sudo` + explicit `GIT_SSH_COMMAND` incantation for `/config`
  git were both needed again; already captured in memory, and both still correct.
