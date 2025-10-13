Several services running as docker containers prevent HDD spindown, even when
they are not being used.

Pausing these docker services when they are not being used and when HDDs should
be in standby prevents disk IO and allows the HDDs to spin down.

"Quiet Hours" denotes this time period.

Systemd services `docker-sleep@pause.service` and `docker-sleep@unpause.service`
run on on a schedule defined by the variables `docker_quiet_hours_start` and
`docker_quiet_hours_end`.

_Docker Pause_

Pausing a docker container does not stop it, but it does prevent disk IO.

`docker pause` uses the cgroups `freezer` command.

The state of the container is unaffected (RAM remains allocated, PIDs stay open,
file/socket state is unchanged.

## Deployment

- The service is updated and deployed using Ansible.
- The tasks live in `tasks/sleep_docker_containers.yml`

`make media tags=sleep`

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
`media_vm/templates/sleep_containers`:

- `docker-sleep@.service.j2`
- `docker-sleep@pause.timer.j2`
- `docker-sleep@unpause.timer.j2`
- `docker-sleep.sh`
- `uptimekumactl.py`
- `containers.list`
- `kuma.map`

## Method

- The timer units trigger their respective service unit.

- There are two services, `docker-sleep@pause.service` and
  `docker-sleep@unpause.service`.

- The `@` in the filename shows that the filename is a template, and is invoked
  with an argument. The name of the argument is placed after the `@`. Using a
  template avoids having two files with almost identical content.

- `Systemd` automatically associates a `.timer` unit with a `.service` unit of
  the same base name.

The timer unit invokes a service unit called `docker-sleep@pause.service` or
`docker-sleep@unpause.service`.

- The service unit calls `docker-sleep.sh`

- `docker-sleep.sh` reads `containers.list` and attempts to pause or unpause
  each container. It logs its actions using `logfmt` format. The `alloy` service
  will forward the logs to `Loki` and can be viewed in `Grafana`.

- `docker-sleep.sh` also calls `kumactl.py` which will pause or unpause the
  respective uptime monitor.

## Commands

### Run the service

```sh
sudo systemctl start docker-sleep@pause.service
sudo systemctl start docker-sleep@unpause.service
```

### Don't run the shell script without using the service unit

This wont work because the scripts (`kumactl.py` and `docker-quiet.sh`) use
environment variables that are supplied by the systemd service unit.

### Verify State

```sh
systemctl status docker-sleep@pause.timer
systemctl status docker-sleep@unpause.timer
systemctl status docker-sleep@pause.service
systemctl status docker-sleep@unpause.service
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
```

### View logs

```sh
journalctl -u docker-sleep@unpause.service -n 50
```

## File locations

The Ansible role copies the following files to these locations:

- `docker-sleep.sh` -> `/usr/local/bin/docker-sleep.sh`
- `kuma.map` -> `/etc/sleep-hours/kuma.map`
- `containers.list` -> `/etc/sleep-hours/containers.list`
- Timer Units -> `/etc/systemd/system/docker-sleep@pause.timer`
- Service Units -> `/etc/systemd/system/docker-sleep@.service`
