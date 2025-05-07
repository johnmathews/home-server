# Media VM

## qBittorrent

### Logging in

Auth is awkward for this.

The default username is `admin`.

It will probably generate its own password the first time. `ssh` into the media
vm and `docker compose logs qbittorrent`. The logs will contain the temporary
password.

There are some tasks and a template to try to fix this but it doesn't work, yet.

For now, if you need to, you can run:
`docker logs qbittorrent 2>&1 | grep -i password`


### SMB shares

The media files are stored on disks attached to the NAS not on the media VM.
They are mounted to the media VM using smb shares. For this to work the
permissions on the media VM have to match the permissions on TrueNAS for the
relevant datasets.

`PUID` and `GUID` are set as variables in `roles/media_vm/defaults/main.yml` and
must match the user id in TrueNAS of a user that has access to the relevant
datasets.

