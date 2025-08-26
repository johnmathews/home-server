# UPS 

The Uninterruptible Power Supply is controlled by `Network UPS Tools`  (NUT).

## Settings

### Shutdown

The UPS will initiate a shutdown when the battery reaches a threshold level. The current value is 40%.

This threshold is set in `roles/proxmox_node/defaults/main.yml`:

- `nut_shutdown_threshold=40`

This value is used in `ups-battery-monitor.sh`:

```sh
if [[ "$CHARGE" -le "$THRESHOLD" ]]; then
  logger -t ups-battery-monitor "UPS battery at ${CHARGE}% (<= ${THRESHOLD}%) and on battery — initiating shutdown"
    /sbin/shutdown -h now "UPS battery low (${CHARGE}%)"
    fi
```

- `ups-battery-monitor.sh` is run by `ups-battery-monitor.service`. 
- The service runs once every 60 seconds according to the settings in `ups-battery-monitor.timer`.

## Notifications

### Low Battery Notification

The LB notification will fire when the UPS reports LB=1. 
LB=1 when either `runtime < battery.runtime.low` or `charge < battery.charge.low`

Current settings:
- `battery.runtime.low = 360` (6 minutes)
- `battery.charge.low = 10` (10%)

Settings can be updated using `upsrw -s battery.runtime.low=600 ups@localhost`.

## Commands


`upsc ups@localhost` - all values from the nut server
`upsc ups@localhost battery.charge.warning` - specific value from the nut server
`upsrw ups@localhost` - editable values from the nut server

`nut-scanner -U` - find the UPS and get some info about the hardware

If you are logged in to a console and a NUT event occurs, you should see a message in the console. See `upsmon.conf` for details. 

For example:

```sh
NOTIFYMSG ONLINE "UPS %s on line power"
NOTIFYMSG ONBATT "UPS %s on battery"
NOTIFYMSG LOWBATT "UPS %s battery is low"
```

