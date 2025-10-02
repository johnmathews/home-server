It is useful to have a chart in grafana showing which NFS and SMB share drives
are alive. This also enables alerting if they go down.

This is implemented by running a service on each VM or LXC that writes
prometheus metrics to the node_exporter text_file location.

An ansible role `share_drive_probe` is added to each playbook. It has the tag
`shares`. This will setup the metrics.

The metrics are produced by a systemd timer that calls a one-shot service. The
service calls a shell script that creates
`/var/lib/node_exporter/textfile_collector/mount_touch_probe.prom`.

Some useful commands:

```sh
# manual reset/start
systemctl daemon-reload
systemctl restart mount-touch-probe.timer
systemctl start mount-touch-probe.service

# see if the file exists
ls -l /var/lib/node_exporter/textfile_collector/mount_touch_probe.prom
cat /var/lib/node_exporter/textfile_collector/mount_touch_probe.prom

# see whats running
systemctl list-units 'mount-nfs-*.service' 'mnt-nfs-*.mount'
systemctl list-timers mount-touch-probe.timer

# see the logs
journalctl -u mount-touch-probe.service
journalctl -u mount-touch-probe.timer -u mount-touch-probe.service --since "1 hour ago"

```
