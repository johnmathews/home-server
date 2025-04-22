# What next:

### Reserving space

#### What happened:

- Files were being copied from a soon-to-be wiped HDD to a backup location
  `/root/backup`.
- The size of the backup was larger than expected and filled all the disk that
  `/root` was on.
- This meant all the VMs and LXCs had no space to operate
- Everything stopped working.
-

#### How to fit it:

- `zpool list` - shows all ZFS storage pools.
- `zfs list` - shows all the ZFS datasets (file systems, snapshots, volumes).
- Each pool in `zpool list` will be a top level (root) name in `zfs list`
  results.

- `lsblk -f` will show all block devices - drives, partitions, LVM modules. The
  `-f` flag adds info about file systems.
