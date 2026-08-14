# 2026-08-14 — JETSTRÖM panels + STYRBAR remotes: the binding plan

## The question

Several IKEA JETSTRÖM panels around the house are paired directly to their STYRBAR remotes.
That works well, but keeps both out of Home Assistant. An attempt roughly 18 months ago put
them on HA: the lights were fine, the remotes were bad. Has 2026 improved this, and what is
the right way to get the lights onto HA without losing reliable remote control?

## The answer

**No, and it didn't need to.** The 2024 attempt was bad because of *how* it was done, not
because HA lacked something since added. Routing button presses through HA automations is a
six-hop round trip; it feels laggy, drops presses while the remote sleeps, and dies during
an HA restart.

**Zigbee binding** is the fix and was available in 2024 too — the remote talks straight to
the light over Zigbee while both stay visible in HA. The only genuine 2026 improvement is
that Zigbee2MQTT 2.x has a point-and-click Bind tab.

IKEA's January 2026 Matter-over-Thread revamp (BILRESA et al.) is the *wrong* direction
here: Matter has no binding equivalent in HA, so every press round-trips — precisely the
failure mode being designed out.

## What the investigation actually turned up

Went looking to confirm the plan; found the repo docs were wrong in three places. All of the
below is measured against the live system (HA template API + z2m `bridge/devices` over
MQTT), not inferred:

- **There is no "defunct ZHA network".** The ZHA config entry exists but has **zero
  entities**; there is no Matter and no Thread/OTBR config entry at all. Every Zigbee device
  runs on z2m over MQTT (198 entities). Energy backlog item #2 said the office and bathroom
  panels needed re-pairing *from ZHA* — they were never there.
- **`Ikea Smart Lightbulb 1/2` are KAJPLATS_WS bulbs, not JETSTRÖM panels.** The backlog
  conflated two unrelated devices. (Their model string says "(Matter)" but they run as plain
  Zigbee — there is no Matter stack on this box.)
- **z2m `configuration.yaml` still lists `Office Ceiling Light` and `Bathroom Ceiling
  Light`, but neither appears in the live device list.** They are stale entries for panels
  that are Touchlink-paired and on no network. 34 device entries in config vs 32 live.
- Only one JETSTRÖM is actually on the network: `Entrance Ceiling Light`, L2207, fw 2.4.8, a
  Router. It is the working reference implementation.
- The only IKEA remote on z2m is `Ikea Light Switch` — an **E2201 RODRET** (2-button), not a
  STYRBAR. No STYRBAR is on z2m anywhere.
- **Zero groups defined in z2m.** Every bind target has to be created.
- Coordinator `0x00124b0030cc1434` (TI chipset) on `/dev/ttyUSB0`, frontend on `:8099`.

Final inventory, after John filled in what the coordinator cannot see: **7 panels** —
entrance (on z2m), Vienna's bedroom, bathroom, Atlas' bedroom, landing/stairwell, and
**two in the new office running in sync**.

## Decisions

- **Group-per-zone, bind remote to the group** — not device-to-device. It is what keeps the
  office's two panels genuinely in sync, and it avoids the battery-drain/network-spam
  failure mode of binding to a device that goes offline.
- **Rename the two stale z2m entries rather than delete them.** A re-joined panel returns
  under the same IEEE and inherits the existing `friendly_name`, so `0x90ab96fffe6c9690`
  would rejoin as "Office Ceiling Light" — the wrong room, since the office moved. This
  revised the "delete both" instinct.
- **Delete the ZHA config entry outright.** Zero entities, pure confusion.
- **Do not OTA the STYRBARs.** Unresolved left-arrow regression on 2.4.16, and newer
  firmware adds a deliberate ~0.6 s single-click delay. Panels may be updated; remotes not.
- **Stage it, Vienna's bedroom first.** Joining a panel to z2m *breaks* its Touchlink pairing
  — the room has no working remote until the bind lands. One zone per sitting, smallest
  blast radius first, live with it a day before continuing.

## Gotchas worth remembering

- A **SONOFF ZBMINIL2 relay feeding a panel must stay ON** or the panel loses power and the
  bind with it. The entrance already works this way. These switches expose no detach-relay
  entity, so "leave it on" is the entire mechanism.
- STYRBAR is a **sleepy end device**: bind commands sent while it sleeps fail *silently* and
  look successful. Wake it with a button press first.
- The real verification is **restarting HA and pressing the remote**. A bound remote keeps
  working; an unbound one that HA was quietly relaying for does not.

## Room swap

Office → Vienna's bedroom, and the kids' old shared bedroom → office. Every HA entity was
already updated for this; the JETSTRÖM naming is the only thing left behind. Areas
`Vienna's Bedroom`, `Atlas' Bedroom` and `Landing` still need creating.

## State

Plan of record written to `documentation/home_assistant_lighting.md`. Energy backlog item #2
corrected in place. **No changes made to the live system** — Phase 1 (Vienna's bedroom) is
the next action.
