# NFS

## Host

...

## Client

1. Create a directory to mount the NFS share into.
2. Mount the share: `sudo mount -t nfs <TrueNas IP>:/<Full path> <target dir>`

- `sudo mount -t nfs 192.168.2.104:/mnt/tank/paperless /mnt/nfs/paperless`

3. Enter credentials when asked
4. run `du -h -d 3` to see the mount.

## Debugging tips

- run `mount | grep nfs` to see all nfs mounts
- run `findmnt -t nfs` to find all nfs mounts
- run `sudo umount /path/to/mount/dir` to unmount. you can use `-l` flag to
  detach immediatly and clean up when the file is no longer busy. You can also
  use `-f` to force the unmount, but if files are being written this could cause
  trouble.
