[TOC]

## Setup a new NFS Share without Ansible

1. Create the directory to mount onto `mkdir -p /mnt/nfs/books`
2. Add the mount in `etc/fstab`:
   `192.168.2.104:/mnt/tank/books  /mnt/nfs/books  nfs  nofail,_netdev,x-systemd.automount,retrans=2,timeo=5  0  0`
3. Reload systemd: `systemctl daemon-reload`
4. Restart remote-fs: `systemctl restart remote-fs.target`
5. Check the status of the systemd unit: `systemctl status mnt-nfs--books.automount`
6. `ls` the share drive to trigger it and check it reads correctly - you should see the drive contents.

## TrueNAS

TrueNAS can be a bit buggy. Toggle the individual share to refresh the
connection or update settings. Or toggle the entire service.

## Client

1. Create a directory to mount the NFS share into, if its a VM. If its an LXC
   then `autofs` is used and you don't need to.
1. Mount the share: `sudo mount -t nfs <TrueNas IP>:/<Full path> <target dir>`
1. Enter credentials when asked
1. run `du -h -d 3` to check the file tree of the external drive.

## Debugging tips

### NFS shares

- run `mount | grep nfs` to see all nfs mounts
- run `findmnt -t nfs4` to find all nfs mounts
- run `sudo umount /path/to/mount/dir` to unmount. you can use `-l` flag to
  detach immediatly and clean up when the file is no longer busy. You can also
  use `-f` to force the unmount, but if files are being written this could cause
  trouble.

`sudo mount -t nfs4 192.168.2.104:/mnt/tank/library /mnt/nfs/library`

`du -h -d 3`

### SMB shares

Toggle the share on and off in TrueNAS after changing ACLs to restart the
service.

- manually mount:

```bash
sudo mount -t cifs //192.168.2.104/media /mnt/media/media -o credentials=/etc/smb-media-credentials,uid=1001,gid=1001,vers=3.1.1

`du -h -d 3`
```

- see available shares:

  ```bash
  smbclient -L //192.168.2.104 -U media_vm
  ```

## Share Drive Probe

See documentation `Monitor NFS and SMB mounts` for more info.

The probe is a systemd service and writes results into the node_exporter text
file location.

## Mount Commands

### NFS

- `sudo mount -t nfs 192.168.2.104:/mnt/tank/books /mnt/nfs/books`
- `sudo mount -t nfs 192.168.2.104:/mnt/tank/immich /mnt/nfs/immich`
- `sudo mount -t nfs 192.168.2.104:/mnt/tank/library /mnt/nfs/library`
- `sudo mount -t nfs 192.168.2.104:/mnt/tank/media /mnt/nfs/media`
- `sudo mount -t nfs 192.168.2.104:/mnt/tank/movies /mnt/nfs/movies`
- `sudo mount -t nfs 192.168.2.104:/mnt/tank/photos /mnt/nfs/photos`
- `sudo mount -t nfs 192.168.2.104:/mnt/tank/youtube-kids /mnt/nfs/youtube-kids`

### SMB

...
