# TrueNAS setup

Use raw disk passthrough rather than letting Proxmox manage the HDDs as part of
a ZFS pool.

The idea is that this gives TrueNAS full control of the HDDs.

## Add disks to TrueNAS

- `qm list` to get ID of TrueNAS VM. It's `104`.

- use `ls -l /dev/disk/by-id/ | grep -E 'sda|sdb|sdc|sdd'` to get the id of the connected HDDs.

- use `scsi<NUMBER>` flag to mount the drives directly to the TrueNAS VM:

  ```
  # tank pool - 8TB Seagate Ironwolf, mirrored vdev 
  qm set 104 -scsi1 /dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF,backup=0
  qm set 104 -scsi2 /dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90,backup=0

  # Backup pool - 3TB Seagate Barracuda
  qm set 104 -scsi3 /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG,backup=0
  ```

## Remove disks from TrueNAS

1. In TrueNAS, export the data pool associated with the disk and make sure
   nothing is using the disk, like shares, data protection services, etc.

2. In the Proxmox UI go to the TrueNAS VM > Hardware section and remove the disk
   from the list of hardware components.

3. Shutdown before removing the HDD from the back pane.
