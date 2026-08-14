# Home Assistant — Zigbee Lighting (JETSTRÖM panels + STYRBAR remotes)

**Status:** plan of record as of 2026-08-14. Nothing migrated yet — Phase 1 is the next
action. Supersedes the lighting half of backlog item #2 in
[`home_assistant_energy.md`](home_assistant_energy.md), which misdescribed both the network
and the hardware.

Home Assistant runs as Proxmox **VM 102** (HAOS) at `192.168.2.102:8123`, and is **not
managed by this Ansible repo** — its config lives in
[`johnmathews/home-assistant-config`](https://github.com/johnmathews/home-assistant-config).
Everything below is done by hand on the HA box or through the Zigbee2MQTT frontend; this doc
is the record, because this repo is the household's operational source of truth.

## The problem this solves

Six of the seven IKEA JETSTRÖM panels are paired **directly** to their STYRBAR remotes and
are invisible to Home Assistant. That pairing is Touchlink: the remote and panel form their
own tiny network with no coordinator involved. It is fast and reliable, and it is why nobody
has wanted to change it.

The obvious migration — join everything to Zigbee2MQTT and write automations — is what was
tried around 2024 and it was bad. Every press became a six-hop round trip:

```
remote -> coordinator -> MQTT -> HA automation -> MQTT -> coordinator -> light
```

That feels laggy, drops presses while the remote is asleep, and stops working entirely
during an HA restart.

**Zigbee binding is the answer, and it is not new** — it was available in 2024 too. A bind
makes the remote talk *straight to the light over Zigbee*, with no coordinator and no HA in
the path, while both devices remain fully visible in Home Assistant. Same latency as the
Touchlink pairing it replaces, and it survives an HA reboot. The remote's `action` events
still reach HA, so extra behaviour (double-press → scene) can be layered on top without
touching the basic on/off/dim path.

Nothing about 2026 changed this calculus. The one genuine improvement since 2024 is that
Zigbee2MQTT 2.x has a point-and-click **Bind** tab, so it no longer needs hand-built MQTT
messages.

### Why not Matter-over-Thread

IKEA began a full range revamp in January 2026 — 20+ Matter-over-Thread products, including
the ~€5 BILRESA remote. **It is the wrong direction for this house.** Matter has no
equivalent of Zigbee binding in Home Assistant, so every button press round-trips through
HA — exactly the failure mode being designed out here. (Tellingly, the BILRESA silicon has a
working Zigbee mode that people use precisely to escape this.)

There is no Matter and no Thread/OTBR config entry in this HA instance at all. The two
KAJPLATS bulbs whose model string reads "(Matter)" are running as ordinary Zigbee devices on
z2m.

## Current state (measured 2026-08-14)

```
+---------------------+-------+---------------------------------+--------------------------+
| Zone                | Panels| Current state                   | IEEE / notes             |
+---------------------+-------+---------------------------------+--------------------------+
| Entrance            |   1   | ON z2m. L2207, fw 2.4.8, Router | Working reference impl.  |
|                     |       |   No remote bound.              |                          |
| Vienna's bedroom    |   1   | Direct-paired. Stale z2m config | 0x90ab96fffe6c9690,      |
|   (was the office)  |       |   entry, not on the network.    |   named "Office Ceiling  |
|                     |       |                                 |   Light" — WRONG ROOM    |
| Bathroom            |   1   | Direct-paired. Stale z2m config | 0x287681fffed207e9       |
|                     |       |   entry, not on the network.    |                          |
| Office (was the     |   2   | Direct-paired, operate in sync. | Not in z2m config        |
|   kids' shared room)|       |                                 |                          |
| Atlas' bedroom      |   1   | Direct-paired.                  | Not in z2m config        |
| Landing/stairwell   |   1   | Direct-paired.                  | Not in z2m config        |
+---------------------+-------+---------------------------------+--------------------------+
                        7 panels total; 6 off-network
```

Supporting facts, all verified against the live system rather than assumed:

```
+------------------------------------------------+------------------------------------------+
| Fact                                           | Why it matters                           |
+------------------------------------------------+------------------------------------------+
| ZHA config entry exists but has 0 entities.    | There is no "defunct ZHA network" to     |
|   No Matter, no Thread/OTBR entries.           |   re-pair from. The panels are on NO     |
|   All Zigbee is z2m over MQTT (198 entities).  |   network. Delete the ZHA entry.         |
| z2m coordinator 0x00124b0030cc1434 on          | TI chipset. Binding well supported.      |
|   /dev/ttyUSB0, frontend on :8099.             |                                          |
| Zero groups defined in z2m.                    | Every bind target must be created.       |
| Only IKEA remote on z2m is "Ikea Light Switch" | A 2-button RODRET, not a STYRBAR. No     |
|   = E2201, fw 1.0.57, battery, no area.        |   STYRBAR is on z2m anywhere yet.        |
| "Ikea Smart Lightbulb 1/2" = KAJPLATS_WS bulbs | These are NOT the JETSTRÖM panels. The   |
|   on z2m, currently unavailable.               |   energy-doc backlog conflated them.     |
| SONOFF ZBMINIL2 relays on Office / Bathroom /  | A relay feeding a panel must stay ON.    |
|   Entrance / Toilet. Office one unavailable.   |   See trap 2.                            |
| HA areas today: attic, bathroom, bedroom,      | Vienna's Bedroom, Atlas' Bedroom and     |
|   toilet, entrance, kitchen, living_room,      |   Landing do not exist yet.              |
|   office, shoe_cupboard, staging.              |                                          |
+------------------------------------------------+------------------------------------------+
```

The HA-side room swap (office → Vienna's bedroom, kids' shared room → office) has **already
been applied to every entity except the JETSTRÖM panels**. The `Office` area already means
the new office. Only the stale z2m panel entry still carries the old room's name.

## The pattern

Applied identically to every zone:

1. Create a z2m **group** for the zone.
2. Join the zone's panel(s) to z2m and add them to the group.
3. Join the STYRBAR to z2m.
4. **Bind the remote to the group** on `genOnOff`, `genLevelCtrl`, `genScenes` and
   `lightingColorCtrl`.

Binding to a group rather than to devices is what keeps the office's two panels in sync —
one group, one bind, both panels move together. It is a real solution rather than two
independent binds that happen to agree. It also avoids trap 4 below.

Newer STYRBAR firmware binds to individual devices **or one group**, not several, and needs
all four clusters bound: `genOnOff` for toggling, `genLevelCtrl` for dimming, `genScenes`
for the arrow keys' scene cycling, `lightingColorCtrl` for the white-spectrum colour
temperature.

## Traps

These are the things that will actually bite. Read before starting a zone.

**1. Joining a panel to z2m breaks its existing direct pairing.** Touchlink pairs live on a
separate ad-hoc network; the moment the panel joins the z2m network the old pairing is gone.
The room therefore has **no working remote** between the join and the successful bind. Do
one zone per sitting, at a time when that room isn't needed, and don't start a second zone
until the first is verified. This is the single biggest risk in the job.

**2. A ZBMINIL2 relay feeding a panel must stay ON.** Cut the relay and the panel loses
power entirely — it drops off the mesh and the bind is dead until it returns. The entrance
already works this way: its ZBMINIL2 is simply left `on` permanently and the panel is
controlled over Zigbee. Replicate that. These switches expose no detach-relay entity, so
"leave it on" is the whole mechanism.

**3. Do not delete the two stale z2m entries — rename them.** A re-joined panel comes back
under the *same* IEEE address and inherits whatever `friendly_name` the config already
holds. Left alone, `0x90ab96fffe6c9690` rejoins as "Office Ceiling Light" and lands in the
wrong room. Rename it to `Viennas Bedroom Ceiling Light` *before* re-joining.

**4. Bind to the group, never to individual devices.** A remote bound to a device that goes
offline will spam the network and drain its own battery. Group binds have no such failure
mode.

**5. Do not OTA-update the STYRBARs.** Current firmware is 2.4.16/2.4.17. There is an
unresolved report of the **left arrow going completely dead on 2.4.16** (closed as stale,
never fixed), and newer firmware deliberately adds **~0.6 s of delay to every single click**
to allow double-press detection. If a remote works, leave its firmware alone. Panels are
fine to update; remotes are not.

**6. Wake the remote immediately before binding, and join it via the coordinator.** STYRBAR
is a sleepy end device — a bind sent while it sleeps fails silently and looks like success.
Press a button, then hit Bind. Pairing through a "bad" router rather than the coordinator is
a documented cause of buttons that never work afterwards.

## Per-zone runbook

Reset and join, in this order:

```
+---+------------------------------------------------------------------------------------+
| 1 | Rename the zone's stale z2m entry if it has one (trap 3).                           |
| 2 | Confirm the zone's ZBMINIL2, if any, is ON and will stay on (trap 2).               |
| 3 | Create the z2m group for the zone.                                                  |
| 4 | Factory-reset the panel: pin-press the reset button on the controller until it      |
|   |   flashes. (Toggling mains 6x also works on IKEA gear.)                             |
| 5 | Permit-join in z2m; confirm the panel interviews as L2207 and is a Router.          |
| 6 | Add the panel to the group. Repeat 4-6 for the second panel in the office.          |
| 7 | Factory-reset the STYRBAR: 4 presses of the pair button under the back cover.       |
| 8 | Permit-join; confirm it interviews as E2001/E2002/E2313.                            |
| 9 | Press a STYRBAR button to wake it, then bind remote -> group on all four clusters.  |
+---+------------------------------------------------------------------------------------+
```

**Verification before declaring a zone done:**

- All four button behaviours work from the remote: on, off, dim up (hold), dim down (hold),
  and both arrows.
- Latency is indistinguishable from the old direct pairing. If it is visibly slower, the
  bind did not take and HA is relaying — check the bind actually registered.
- The light's state in HA tracks changes made from the remote. IKEA devices report
  attributes properly, and for group binds z2m polls, so this should hold.
- **Restart Home Assistant and press the remote again.** This is the real test: a bound
  remote keeps working through an HA restart. If it stops, it isn't bound.

## Migration order

```
+-------+---------------------------+------------------------------------------------------+
| Phase | Zone                      | Rationale                                            |
+-------+---------------------------+------------------------------------------------------+
|   1   | Vienna's bedroom          | Single panel, single remote, and its stale entry     |
|       |                           |   needs renaming anyway. Proves the whole pattern    |
|       |                           |   end to end at the smallest possible blast radius.  |
|   2   | Bathroom                  | Second single-panel case; has a ZBMINIL2, so it      |
|       |                           |   also proves trap 2.                                |
|   3   | Atlas' bedroom, landing   | Remaining single-panel zones. Routine by now.        |
|   4   | Office (2 panels)         | The 2-member group — the only structurally new       |
|       |                           |   case. Do it once the pattern is proven.            |
|   5   | Entrance (optional)       | Already on z2m but has no remote. Retrofit a group   |
|       |                           |   + STYRBAR only if you want one there.              |
+-------+---------------------------+------------------------------------------------------+
```

Stop after Phase 1 and live with it for a day before continuing. If binding turns out to be
unreliable in this mesh, that is the moment to find out — with one room affected, not six.

## Follow-on work

Once panels are on the network they become visible to everything else:

- **Areas.** Create `Vienna's Bedroom`, `Atlas' Bedroom`, `Landing`. Assign each panel, and
  assign the STYRBARs too — the existing RODRET (`Ikea Light Switch`) has no area either and
  should get one while you're there.
- **powercalc.** Add entries for the six newly-visible panels. `L2207` has a measured LUT
  profile in the powercalc library, so no strategy block is needed — same as the entrance
  panel. This closes the second half of energy backlog item #2 and puts roughly six more
  fixtures into the Energy dashboard and out of "Rest Of Home".
- **Delete the ZHA config entry.** It has zero entities and exists only to confuse the next
  person reading the integrations list.
- **The two KAJPLATS bulbs and the Office ZBMINIL2 are all `unavailable`** — a separate
  question from this work, but worth resolving, since an offline ZBMINIL2 in the new office
  weakens the mesh exactly where Phase 4 needs it.

## Fallback

If binding proves unreliable, the fallback is HA automations on the remote's `action`
events — the 2024 arrangement. It is worse, but it is not catastrophic: z2m round-trip
latency is typically 100–300 ms, and the real 2024 complaints were as much about remotes
dropping off a poor mesh as about latency. Six mains-powered panels acting as routers will
themselves improve the mesh considerably, so the network after this migration is not the
network that made 2024 unpleasant.

## References

- Zigbee2MQTT binding guide — <https://www.zigbee2mqtt.io/guide/usage/binding.html>
- STYRBAR E2001/E2002/E2313 — <https://www.zigbee2mqtt.io/devices/E2001_E2002_E2313.html>
- JETSTRÖM L2207 — <https://www.zigbee2mqtt.io/devices/L2207.html>
- STYRBAR left-button regression on 2.4.16 —
  <https://github.com/Koenkk/zigbee2mqtt/issues/25546>
- Group-bind failure report — <https://github.com/Koenkk/zigbee2mqtt/issues/23659>
- Energy monitoring and powercalc conventions —
  [`home_assistant_energy.md`](home_assistant_energy.md)
- HA box access, `/config` git incantation — "Config repo & access" in
  [`home_assistant_energy.md`](home_assistant_energy.md)
