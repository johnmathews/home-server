It is useful to have a chart in Grafana showing which NFS and SMB share drives
are alive. This also enables alerting if they go down.

This is implemented by running a service on each VM or LXC that writes
Prometheus metrics to the node_exporter text_file location.

An Ansible role `share_drive_probe` is added to each playbook. It has the tag
`shares`. This will setup the metrics.

The metrics are produced by a systemd timer that calls a one-shot service. The
service calls a shell script that creates
`/var/lib/node_exporter/textfile_collector/mount_touch_probe.prom`.

Some useful commands:

### Manual reset/start

```sh
systemctl daemon-reload
systemctl restart mount-touch-probe.timer
systemctl start mount-touch-probe.service
```

### See whats running

```sh

systemctl status mount-touch-probe.service
journalctl -xeu mount-touch-probe.service
systemctl list-units 'mount-nfs-*.service' 'mnt-nfs-*.mount'
systemctl list-timers mount-touch-probe.timer
```

### See if the file exists

```sh
ls -l /var/lib/node_exporter/textfile_collector/mount_touch_probe.prom
cat /var/lib/node_exporter/textfile_collector/mount_touch_probe.prom
```
### See the logs

```sh
journalctl -u mount-touch-probe.service
journalctl -u mount-touch-probe.timer -u mount-touch-probe.service --since "1 hour ago"

```

## Example output:

```sh
> cat /var/lib/node_exporter/textfile_collector/mount_touch_probe.prom

# HELP mount_touch_probe_success 1 if probe succeeded, else 0
# TYPE mount_touch_probe_success gauge
# HELP mount_touch_probe_duration_seconds Time to touch+rm
# TYPE mount_touch_probe_duration_seconds gauge
# HELP mount_touch_probe_last_run_timestamp_seconds UNIX time of last run on this host
# TYPE mount_touch_probe_last_run_timestamp_seconds gauge
# HELP mount_touch_probe_state -1=error,0=fail,1=success
# TYPE mount_touch_probe_state gauge
# HELP mount_touch_probe_state_change_timestamp_seconds UNIX time of last state change
# TYPE mount_touch_probe_state_change_timestamp_seconds gauge
mount_touch_probe_state{host="immich",mount="/mnt/nfs/immich",label="/mnt/tank/immich",reason="success"} 1
mount_touch_probe_success{host="immich",mount="/mnt/nfs/immich",label="/mnt/tank/immich"} 1
mount_touch_probe_duration_seconds{host="immich",mount="/mnt/nfs/immich",label="/mnt/tank/immich"} 0.012154
mount_touch_probe_last_run_timestamp_seconds{host="immich"} 1759421849
```
