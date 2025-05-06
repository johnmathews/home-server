# TrueNAS setup

Use raw disk passthrough rather than letting Proxmox manage the HDDs as part of
a ZFS pool.

The idea is that this gives TrueNAS full control of the HDDs.

## Add disks to TrueNAS

- `qm list` to get ID of TrueNAS VM. It's `104`.

- use `ls -l /dev/disk/by-id/ | grep -E 'sda|sdb|sdc|sdd'` to get the id of the connected HDDs.

- use `scsi<NUMBER>` flag to mount the drives directly to the TrueNAS VM:

  ```
  qm set 104 -scsi2 /dev/disk/by-id/ata-WDC_WD10EZRX-00A8LB0_WD-WMC1U7453146
  qm set 104 -scsi3 /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG
  ```

## Remove disks from TrueNAS

1. In TrueNAS, export the datapool associated with the disk and make sure
   nothing is using the disk, like shares, data protection services, etc.

2. In the Proxmox UI go to the TrueNAS VM > Hardware section and remove the disk
   from the list of hardware components.

3. Shutdown before removing the HDD from the back pane.
