## Background

- `systemd` is the service manager and init system on most modern Linux
  distributions.
- The init system is the first process that starts when Linux boots (PID
  1). It brings up the system: mounts filesystems, starts daemons (background
  services), manages targets (like runlevels) and shuts everything down
  cleanly.
- `systemd` replaced older init systems like `SysV` `init` and `Upstart`,
  offering:
  - Faster booting
  - Parallel startup of services
  - Better dependency management
  - Unified logging (via `journald`)
  - Advanced service supervision

## What is a service

A service in Linux is usually a long-running background process (`daemon`), like
`sshd`, `nginx`, `docker`, `prometheus`. `systemd` manages these processes, ensuring they:

- Start in the right order.
- Restart automatically if they crash.
- Start at boot.

Services are defined by unit files.

## Unit files

A unit file is a configuration file that tells systemd how to manage something.

Types of units:


- `.service` Background processes/daemons (most common)
- `.mount` Mount points
- `.timer` Scheduled jobs (systemd’s replacement for cron)
- `.socket` Socket activation
- `.target` Groups of units (like `runlevels`)

`systemctl` `journalctl`

## Useful commands

Use `systemctl` to manage services. Use `journalctl` to monitor them.

### Start/stop/restart a service immediately

```
sudo systemctl start nginx
sudo systemctl stop nginx
sudo systemctl restart nginx
```

### Check status and logs

```
systemctl status nginx
journalctl -u nginx
```

### Enable/disable at boot

```
sudo systemctl enable nginx
sudo systemctl disable nginx
```

### Reload configs (without restart if supported)

```
sudo systemctl reload nginx
```

### Debug

```
systemctl start mount-touch-probe.service
journalctl -u mount-touch-probe.service -n 50 -e

```

## Service Lifecycle

When you enable and start a service: 

1. `systemd` reads the unit file (from /etc/systemd/system/ or /lib/systemd/system/) 

2. It checks dependencies (e.g., networking must be up first). 

3. It spawns the process with the correct user, working directory, and options. 

4. It monitors the process. If it dies unexpectedly, `systemd` can restart it (depends on Restart=). 

5. `systemd` logs stdout/stderr to the journal. View it with `journalctl -u <service>`.
