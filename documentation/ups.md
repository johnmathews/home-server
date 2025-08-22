# UPS 

The Uninterruptible Power Supply is controlled by `Network UPS Tools`  (NUT).

## Commands


`upsc ups@localhost` - all values from the nut server
`upsc ups@localhost battery.charge.warning` - specific value from the nut server
`upsrw ups@localhost` - editable values from the nut server

`nut-scanner -U` - find the UPS and get some info about the hardware
