# What next:

## Problems

### Reserving space

#### What happened:

- Files were being copied from a soon-to-be wiped HDD to a backup location
  `/root/backup`.
- The size of the backup was larger than expected and filled all the disk that
  `/root` was on.
- This meant all the VMs and LXCs had no space to operate
- Everything stopped working.

#### How to fix it:

- `zpool list` - shows all ZFS storage pools.
- `zfs list` - shows all the ZFS datasets (file systems, snapshots, volumes).
- Each pool in `zpool list` will be a top level (root) name in `zfs list`
  results.
- `lsblk -f` will show all block devices - drives, partitions, LVM modules. The
  `-f` flag adds info about file systems.

### Zpool Quota, Reservation.
* zpool quota = maximum space the VM can use
* zpool reservation = minimum space the VM will ever have access to, even if/when other VMs on the disk grow.
* zpool reservation cannot be larger than zpool quota.

* `zfs list` - show all datasets
* `zfs get quota,reservation rpool/data/vm-105-disk-1` - get current info about a dataset
* `zfs set quota=32G rpool/data/vm-XXX-disk-1` - set quota
* `zfs set reservation=10G rpool/data/vm-XXX-disk-1` - set reservation
