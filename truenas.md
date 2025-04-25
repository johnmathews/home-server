# TrueNAS setup


Use raw disk passthrough rather than letting proxmox manage the HDDs as part of a ZFS pool.

The idea is that this gives TrueNAS full control of the HDDs.

## Add disks to TrueNAS

- `qm list`
- TrueNAS VM ID is `104`

- use `scsiX` to mount the drives

  ```
  qm set 104 -scsi2 /dev/disk/by-id/ata-WDC_WD10EZRX-00A8LB0_WD-WMC1U7453146
  qm set 104 -scsi3 /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG
  ```
