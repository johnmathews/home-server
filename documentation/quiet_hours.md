## Deployment

- The service is updated and deployed using Ansible.
- The tasks live in `tasks/sleep_docker_containers.yml`

`make site tags=sleep`

`make media tags=sleep`

`make paperless tags=sleep`

`make tube tags=sleep`

## Context

Several services running as docker containers prevent HDD spindown, even when
they are not being used.

Pausing these docker services when they are not being used and when HDDs should
be in standby prevents disk IO and allows the HDDs to spin down.

"Quiet Hours" denotes this time period.

Systemd services run on a schedule defined by the variables `docker_quiet_hours_start` and
`docker_quiet_hours_end`. Four operations are supported:
- `docker-sleep@pause.service` - Pause containers during quiet hours
- `docker-sleep@unpause.service` - Resume paused containers
- `docker-sleep@stop.service` - Stop containers during quiet hours
- `docker-sleep@start.service` - Start stopped containers

_Docker Pause_

Pausing a docker container does not stop it, but it does prevent disk IO.

`docker pause` uses the cgroups `freezer` command.

The state of the container is unaffected (RAM remains allocated, PIDs stay open,
file/socket state is unchanged.

## Variables

The following template variables are used.

They can be edited in `media_vm/defaults/main.yml`.

```yaml
uptime_kuma_url: "http://192.168.2.106:3001"
uptime_kuma_user: "john"
docker_quiet_hours_start: "23:55"
docker_quiet_hours_end: "08:45"
```

Ansible vault:

- `vault_uptime_kuma_password`

## Template files

The Ansible role uses the following files and templates, located in
`roles/sleep_hours/templates/`:

- `docker-sleep@.service` - Unified service unit template for all operations
- `docker-sleep@pause.timer.j2`
- `docker-sleep@unpause.timer.j2`
- `docker-sleep@stop.timer.j2`
- `docker-sleep@start.timer.j2`
- `docker-sleep.sh` - Main script that performs all operations
- `uptimekumactl.py` - Uptime Kuma integration
- `containers.list.j2` - Container list template
- `kuma.map.j2` - Monitor mapping template

## Method

- The timer units trigger their respective service unit based on schedule.

- All four operations (pause, unpause, stop, start) use a single consolidated
  service unit template: `docker-sleep@.service`. Systemd templating automatically
  instantiates the correct service based on the timer's `Unit=` directive.

- The `@` in the filename indicates systemd templating. The parameter after `@`
  is passed as `%i` to the service, avoiding file duplication:
  - `docker-sleep@pause.timer` → triggers `docker-sleep@pause.service` → `%i=pause`
  - `docker-sleep@unpause.timer` → triggers `docker-sleep@unpause.service` → `%i=unpause`
  - `docker-sleep@stop.timer` → triggers `docker-sleep@stop.service` → `%i=stop`
  - `docker-sleep@start.timer` → triggers `docker-sleep@start.service` → `%i=start`

- The service unit calls `docker-sleep.sh %i` with the operation name.

- `docker-sleep.sh` reads the appropriate container list and attempts to perform
  the operation on each container. It logs its actions using `logfmt` format.
  The `alloy` service will forward the logs to `Loki` and can be viewed in `Grafana`.

- `docker-sleep.sh` also notifies Uptime Kuma monitors (via `kumactl.py`) when
  containers are paused/resumed/stopped/started.

## Commands

### Run the service

```sh
sudo systemctl start docker-sleep@pause.service
sudo systemctl start docker-sleep@unpause.service
sudo systemctl start docker-sleep@stop.service
sudo systemctl start docker-sleep@start.service
```

### Don't run the shell script without using the service unit

This wont work because the scripts (`kumactl.py` and `docker-quiet.sh`) use
environment variables that are supplied by the systemd service unit.

### Verify State

```sh
systemctl status docker-sleep@pause.timer
systemctl status docker-sleep@unpause.timer
systemctl status docker-sleep@stop.timer
systemctl status docker-sleep@start.timer
systemctl status docker-sleep@pause.service
systemctl status docker-sleep@unpause.service
systemctl status docker-sleep@stop.service
systemctl status docker-sleep@start.service
```

### List timers

```sh
TZ=Europe/Amsterdam systemctl list-timers --all
```

### View logs from last run only:

Timers do not generate logs.

```sh
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@pause.service)
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@unpause.service)
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@stop.service)
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@start.service)
```

### View logs

```sh
journalctl -u docker-sleep@pause.service -n 50
journalctl -u docker-sleep@unpause.service -n 50
journalctl -u docker-sleep@stop.service -n 50
journalctl -u docker-sleep@start.service -n 50
```

## File locations

The Ansible role copies the following files to these locations:

- `docker-sleep.sh` -> `/usr/local/bin/docker-sleep.sh`
- `truenas-shares.sh` -> `/usr/local/bin/truenas-shares.sh`
- `uptimekumactl.py` -> `/usr/local/bin/kumactl.py`
- `containers.pause.list` -> `/etc/sleep-hours/containers.pause.list`
- `containers.stop.list` -> `/etc/sleep-hours/containers.stop.list`
- `kuma.map` -> `/etc/sleep-hours/kuma.map`
- `truenas.conf` -> `/etc/sleep-hours/truenas.conf` (if NFS/SMB control enabled)
- Timer Units -> `/etc/systemd/system/docker-sleep@*.timer`
- Service Unit Template -> `/etc/systemd/system/docker-sleep@.service`
