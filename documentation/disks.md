## Proxmox

The only HDD you need to manage on the host is
`/dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN1TN5X`. This is the disk that contains Proxmox backup data.

Use `hd-idle` package to configure disk spindown. `hdparm` doesn't seem to work reliably.

Current HDD spin state:

`smartctl -n standby -i /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN1TN5X`

### hd-idle

`hd-idle` is a systemd service. The project repo is
[https://github.com/adelolmo/hd-idle](https://github.com/adelolmo/hd-idle). It's
used to manage the spindown of the proxmox backup HDD.

Its configured and deployed using Ansible: `/roles/pve/tasks/hd-idle.yml`

## TrueNAS

TrueNAS HDDs are spun down using a custom script, no other method seems to work.
Perhaps `hd-idle` could be dockerized and deployed as a custom app.

A script measures disk utilisation and, if conditions are met, spins down the HDDs using an hdparm command.

The script is deployed using `make nas tags=hdds`.

The script contains a list of disk ids to monitor. Disk activity and sample duration are parametrised.

The script is deployed to `/mnt/swift/scripts/spindown_hdds.sh` using Ansible.

The script generates logs at `/mnt/swift/logs/spindown_hdds.log`.

## Commands and Enquiries

`sudo smartctl -n standby -i /dev/sdb` - get current status of a disk

`sudo zpool iostat -v 30 24` - this will show IO. The first number is the number
of seconds in each snapshot. The second number is the number of intervals before
stopping.

`sudo smartctl -s standby,now /dev/sdb` - this will force the backup HDD to spin
down.

`sudo smbstatus` - will show info about SMB connections including locked files

`sudo systemctl status netdata` - the netdata service must be stopped (or just
leaves the HDDs alone)

- Apps cannot run on the tank datapool. Can they run on the boot pool? If not
  use an SSD and have an `apps` pool.

- SMB shares are noisy.

- SMART service, and NFS service dont seem to cause any IO.

### findings:

1. Using `sudo smbstatus` shows that some SMB shares were touching the drives
   too often. Paperless Consume directory had a lock on a directory that would
   keep the drive spinning

2. NFS service and SMART service didnt make any difference, i dont think. But
   something woke up the drives when SMB service was off and the apps were off,
   so maybe it runs intermittently.

3. The apps need to run on a different pool. If they are on the Tank pool they
   will write to it a bit.

### How to make the truenas backup HDD spin down:

- `atime=off`
- `trim=off`
- stop `smartctl-exporter` app
- stop `netdata` service (This is TrueNAS built-in monitoring)

### netdata

netdata config file: `/var/lib/netdata/cloud.d/cloud.conf`

```
[plugins]
    apps = no
    cgroups = no
    python.d = no
    go.d = no
    charts.d = no
    fping = no
    diskspace = no
    proc = no
```

Maybe netdata will go away now

```
sudo systemctl unmask netdata && sudo systemctl stop netdata && \
sudo systemctl disable netdata && sudo systemctl mask netdata && \
sudo systemctl status netdata && sudo systemctl daemon-reload
```

Use `sudo systemctl unmask netdata` to temp turn it on when changing SMART
settings or getting errors.

- disable SMART service - not necessary for `backup`
- disable NFS service - not necessary for `backup`
- disable node-exporter app - not necessary for `backup`
- disable SMART on the disk - not necessary for `backup`

## hdparm

`hdparm` doesn't seem to work reliably.

`sudo hdparm -S 120 /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN1TN5X` - This will
make it spin down after 10 minutes. (`-S 242` will make it spindown after 60
minutes.)

On modern Debian/Proxmox (systemd-based), there is no hdparm.service anymore.
Instead:

- `hdparm` is only called once at boot via udev rules (see `/lib/udev/hdparm`
  which can be run manually).
- That script parses `/etc/hdparm.conf` and applies settings to matching devices
  when udev adds them.

So if you edit `/etc/hdparm.conf` after the disk is already present, the
settings won’t be re-applied automatically. You need to:

1. Re-apply manually with the helper:

   ```
   sudo /lib/udev/hdparm start
   ```

2. To check what happened when you ran `/lib/udev/hdparm start`, look at `dmesg`
   or `syslog` for `hdparm` output. (`journalctl` and `dmesg` give the same
   output):

   `journalctl -b | grep hdparm` `journalctl -f | grep -i sdg`
   `journalctl -k | grep -i sdg`

### command flags:

- `hdparm -y` - puts the drive into standby mode immediately
- `hdparm -C` - asks the disk what state it is currently in. But this might (?)
  wake it, if it is in standby.
- `smartctl -n standby -i` - check the disk state without waking it.
- `hdparm -s` - toggles security settings. Don't use this.
- `hdparm -S` - set spindown time.
- `smartctl -a ` - lots of info
- `sudo hdparm -I` - spindown settings
