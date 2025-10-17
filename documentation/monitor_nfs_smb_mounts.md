## Ansible

There is a task called `share_drive_probe`. It's added to all the playbooks.

## Setup and Deployment (Ansible)

Add the role `share_drive_probe` to the hosts playbook. It has the tag `shares`.

Deploy it to an individual host using `make <host> tags=shares` or to all hosts
by `make site tags=shares`.

Ensure that `node-exporter` is also running (usually as a docker container)
because it collects the .prom file created by the `share_drive_probe` service
and placed at `/var/lib/nodeExporter/textfile_creator`.

In `inventory.ini` there is a `share_drive_clients` section.

## Background

It is useful to have a chart in Grafana showing which NFS and SMB share drives
are alive. This also enables alerting if they go down.

This is implemented by running `share_drive_probe` - a systemd service (not a
container!) on each VM or LXC that writes Prometheus metrics to the
node_exporter text_file location.

A systemd timer `share_drive_probe.timer` calls a one-shot service
`share_drive_probe.service`. The service calls a shell script
`share_drive_probe.sh` that writes Prometheus metrics to
`/var/lib/node_exporter/textfile_collector/share_drive_probe.prom`.

The `node-exporter` docker service will collect any .prom files in
`/var/lib/node_exporter/textfile_collector` and add them to its output. See the
docker compose file for any host that has NFS or SMB drives mounted.

## Inputs

### Metrics file

```sh
ls -l /var/lib/node_exporter/textfile_collector/share_drive_probe.prom
cat /var/lib/node_exporter/textfile_collector/share_drive_probe.prom
```

### Targets file

```sh
ls -l /etc/share_drive_probe/targets.list
cat /etc/share_drive_probe/targets.list
```

### Script file

```sh
ls -l /usr/local/bin/share_drive_probe.sh
cat /usr/local/bin/share_drive_probe.sh
```

## Outputs

### View Prometheus metrics file

```sh
cat /var/lib/node_exporter/textfile_collector/share_drive_probe.prom
```

### See the service definition file

```sh
systemctl cat share-drive-probe.service
systemctl cat share-drive-probe.timer
```

### View systemd logs

```sh
journalctl -u share-drive-probe.service -n 50
journalctl -u share-drive-probe.timer -u share-drive-probe.service --since "10 minutes ago"

```

### View logs from the last run:

```
sudo systemctl status share-drive-probe.service
```

### Example output:

```sh
> cat /var/lib/node_exporter/textfile_collector/share_drive_probe.prom

# HELP share_drive_probe_success 1 if probe succeeded, else 0
# TYPE share_drive_probe_success gauge
# HELP share_drive_probe_duration_seconds Time to touch+rm
# TYPE share_drive_probe_duration_seconds gauge
# HELP share_drive_probe_last_run_timestamp_seconds UNIX time of last run on this host
# TYPE share_drive_probe_last_run_timestamp_seconds gauge
# HELP share_drive_probe_state -1=error,0=fail,1=success
# TYPE share_drive_probe_state gauge
# HELP share_drive_probe_state_change_timestamp_seconds UNIX time of last state change
# TYPE share_drive_probe_state_change_timestamp_seconds gauge
share_drive_probe_state{host="immich",mount="/mnt/nfs/immich",label="/mnt/tank/immich",reason="success"} 1
share_drive_probe_success{host="immich",mount="/mnt/nfs/immich",label="/mnt/tank/immich"} 1
share_drive_probe_duration_seconds{host="immich",mount="/mnt/nfs/immich",label="/mnt/tank/immich"} 0.012154
share_drive_probe_last_run_timestamp_seconds{host="immich"} 1759421849
```

## Commands:

### Manual reset/start

```sh
systemctl restart share-drive-probe.timer
systemctl start share-drive-probe.service
systemctl daemon-reload
```

### See whats running

```sh

systemctl status share-drive-probe.service
journalctl -xeu share-drive-probe.service
systemctl list-units 'mount-nfs-*.service' 'mnt-nfs-*.mount'
systemctl list-timers share-drive-probe.timer
```
