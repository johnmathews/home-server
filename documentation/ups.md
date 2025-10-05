[TOC]

The UPS is controlled and understood using the `Network UPS Tools` (NUT)
[package](https://networkupstools.org/).

## Event/Data flow

1. UPS hardware - speaks HID or vendor protocol over USB.

2. The driver (`usbhid-ups`) runs under `upsd` which acts as the NUT server.

   - The driver talks directly to the UPS.
   - Exposes variables (status, charge, runtime, etc.).
   - Applies overrides set in `ups.conf`.

3. `upsd` is the nut server and listens on TCP (127.0.0.1:3493).

   - Handles authentication (`upsd.users`).
   - Provides status and commands to clients (including `upsmon`).

4. `upsmon` is the monitoring daemon.

   - Connects to `upsd` using the 'monitor' user credentials.
   - Polls UPS state (`OL`, `OB`, `LB`, etc.)
   - Evaluates shutdown thresholds from `upsmon.conf`.
   - When an event occurs, it fires `NOTIFY` commands.
   - If `NOTIFYCMD` "/usr/sbin/upssched" is set and `NOTIFYFLAG ... +EXEC` is
     present, it calls `upssched`.

5. `upssched` is the event scheduler.

   - Reads `upssched.conf`.
   - For each event emitted from `upsmon`, it decides:
     - Run `EXECUTE <token>` immediately, or
     - `START-TIMER <token> <secs>` and later trigger `EXECUTE <token>`, or
     - `CANCEL-TIMER <token>` to suppress pending actions.
   - When executing, it calls the script defined by `CMDSCRIPT`.

6. Your `upssched-cmd.sh` - runs with `$1 = token` (onbatt, online, …) and
   `$UPSNAME` set in `env`.
   - Logs to syslog.
   - Optionally calls Node Exporter, Pushover, etc.

## Settings

### Shutdown

The UPS will initiate a shutdown when the battery reaches a threshold level. The
current value is 40%.

This threshold is set in `roles/proxmox_node/defaults/main.yml`:

- `nut_shutdown_threshold=40`

## Notifications

Pushover notifications are set up in `upsched-cmd.sh.j2`. A pushover notification will be sent for the following events:

- ONBATT
- LOWBATT
- FSD
- ONLINE
- COMMBAD
- COMMOK

If power is lost and you have a terminal session connected to Proxmox, you will
see a notification like below:

```
Broadcast message from root@proxmox (somewhere) (Tue Aug 26 12:35:50 2025):

UPS ups@localhost on battery
```

### Low Battery Notification

The LB notification will fire when the UPS reports LB=1. 

LB=1 occurs when either `runtime < battery.runtime.low` or `charge < battery.charge.low`

Current settings:

- `battery.runtime.low = 360` (6 minutes)
- `battery.charge.low = 10` (10%)

Settings can be updated using `upsrw -s battery.runtime.low=600 ups@localhost`.

## Commands

`upsc ups@localhost` - all values from the nut server
`upsc ups@localhost battery.charge.warning` - specific value from the nut server
`upsrw ups@localhost` - editable values from the nut server

`nut-scanner -U` - find the UPS and get some info about the hardware

If you are logged in to a console and a NUT event occurs, you should see a
message in the console. See `upsmon.conf` for details.

```sh
NOTIFYMSG ONLINE "UPS %s on line power"
NOTIFYMSG ONBATT "UPS %s on battery"
NOTIFYMSG LOWBATT "UPS %s battery is low"
```

## Writable Parameters

`upsrw ups@localhost` will show which values can be changed.

For example:

- `override.battery.charge.low = {{ ups_battery_charge_low }}`

Update `ups.conf` then run `make pve --tags=nut`. 

### Normal parameters

- `nut_shutdown_threshold=40`
- `ups_battery_charge_low: 20`
- `ups_battery_runtime_low: 600` (10 minutes)

### Testing parameters

If `nut_shutdown_threshold` is lower than `battery.charge.low` then the
`ups-battery-monitor` service wont be used, but instead the `upsmon` service
will initiate shutdown. `ups-battery-monitor` seems redundant.

- `nut_shutdown_threshold=70`
- `ups_battery_charge_low: 75`
- `ups_battery_runtime_low: 2100` (35 minutes)

## Notes

- `FINALDELAY 600` in `upsmon.conf` is how long `upsmon` waits after beginning
  its own shutdown sequence to tell the UPS to begin shutting itself down and
  cutting AC power. The shutdown command itself is issued as soon as LB status
  begins.
- `ups.delay.shutdown: 20` means that the UPS will wait 20 seconds after it
  receives a shutdown command from NUT before it switches its outlets off. The
  delay is meant to give the server time to finish halting cleanly (after
  they've already been told to shutdown) before AC power is cut.
- `ups.delay.start: 30` means that the UPS will wait 30 seconds after AC power
  is restored before turning the power back on.
