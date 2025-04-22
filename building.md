# What next:

### Reserving space

#### What happened:
- Files were being copied from a soon-to-be wiped HDD to a backup location `/root/backup`.
- The size of the backup was larger than expected and filled all the disk that `/root` was on.
- This meant all the VMs and LXCs had no space to operate
- Everything stopped working.
-

#### How to fit it:
- `zpool list`
- `zfs list` - shows all the ZFS datasets (file systems, snapshots, volumes)
- `lsblk` will show all the drives
