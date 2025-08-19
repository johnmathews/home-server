# HDD Power Management

### spindown

On modern Debian/Proxmox (systemd-based), there is no hdparm.service anymore.

Instead:

- hdparm is only called once at boot via udev rules (see /lib/udev/hdparm which
  you ran manually).
- That script parses /etc/hdparm.conf and applies settings to matching devices
  when udev adds them.

So if you edit /etc/hdparm.conf after the disk is already present, the settings
won’t be re-applied automatically. You need to:

1. Re-apply manually with the helper:

```
sudo /lib/udev/hdparm start
```

To check what happened when you ran /lib/udev/hdparm start, look at dmesg or syslog for hdparm output:

`journalctl -b | grep hdparm`


## Proxmox

The only HDD you need to manage on the host is `/dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN1TN5X`.

`sudo hdparm -S 12 /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN1TN5X` works as expected - disk will spin down after 1 minute.


Trying:

`sudo hdparm -S 120 /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN1TN5X` - This should make it spin down after 1 hour.

## TrueNAS
...

`sudo smartctl -s standby,now /dev/sdb`  - this will put the backup HDD to spin down.

`sudo zpool iostat -v 30 24` - this will show IO

`sudo smbstatus` - will show info about SMB connections including locked files 

- Apps cannot run on the tank datapool. Can they run on the boot pool? If not use an SSD and have an `apps` pool.

- SMB shares are noisy.

- SMART service, and NFS service dont seem to cause any IO.
