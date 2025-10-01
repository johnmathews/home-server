## qBittorrent

### Logging in

Auth will work as long as you dont change the password or user. User should be
`admin`. The template config file contains the correct hash for the current
password. The template config file is a copy of a working config file.

If auth breaks, you can `ssh` into the media vm and
`docker compose logs qbittorrent`. The logs will contain the temporary password.

### SMB shares

The media files are stored on disks attached to the NAS not on the media VM.
They are mounted to the media VM using smb shares. For this to work the
permissions on the media VM have to match the permissions on TrueNAS for the
relevant datasets.

`PUID` and `GUID` are set as variables in `roles/media_vm/defaults/main.yml` and
must match the user id in TrueNAS of a user that has access to the relevant
datasets.
