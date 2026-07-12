# Traefik Log Resilience Plan

**Status:** closed — Option B (json-file log driver with rotation) implemented in
`roles/traefik_lxc/templates/docker-compose.yml.j2`; Option A (Loki staleness alert) was never created; Option C
deferred. Archived 2026-07-12.
**Created:** 2026-05-06
**Owner:** John

Plan for making traefik's logging more resilient to a "silent stop" failure mode observed on 2026-05-06, where the
container kept serving traffic but stopped emitting access logs for ~40 minutes. Three options are presented in
increasing order of effort. The recommendation is to start with the cheapest and only escalate if the failure recurs.

## Motivation

On 2026-05-06 around 10:09 CEST a journal-server upload from an iPhone failed with a generic "try again" error. The
backend (`journal-server`) had no record of the request, so we walked up the stack to find where it was lost. We
discovered:

```
+-----------------+----------------------------------+--------------------------------+
| Layer           | Logged the request?              | Why                            |
+-----------------+----------------------------------+--------------------------------+
| journal-server  | No                               | Request never arrived          |
| traefik         | Cannot tell — logging stopped    | Last log line at 09:30 CEST,   |
|                 | ~40 min before the incident      | no entries after that point    |
| cloudflared     | No errors logged                 | Only logs failures, not access |
| Cloudflare edge | (not checked — dashboard only)   |                                |
+-----------------+----------------------------------+--------------------------------+
```

Traefik continued to route traffic during the gap (verified via Prometheus `traefik_service_requests_total` and the
fact that the dashboard kept loading). But it emitted no access logs to journald, and consequently nothing reached
Loki via Alloy. Restarting the container would have unwedged it. The user's upload succeeded on retry, so this is not
a critical outage — but a recurrence with worse symptoms (e.g. a real backend bug that we cannot diagnose because
traefik's logs are missing) would be a problem.

The single actionable improvement: ensure that when something fails on a `*.itsa-pizza.com` route, we always have
traefik's access log to walk through.

## Context

### Current logging pipeline

```
traefik (Go process) -> stdout
  -> Docker daemon (journald log driver -- inherited from daemon default)
    -> systemd-journald (/var/log/journal/*.journal)
      -> Alloy reads Docker logs API (loki.source.docker)
        -> Loki
```

Two important facts about this LXC's setup:

1. The traefik service in `roles/traefik_lxc/templates/docker-compose.yml.j2` does **not** explicitly set a `logging`
   driver. Docker's daemon default applies, which is `journald` on this host.
2. The `cadvisor` and `alloy` services on the *same* host explicitly set `json-file` with rotation. The default has
   already been overridden where it mattered for those services.

### Where Alloy reads from

Alloy on this LXC uses `loki.source.docker` (see `roles/traefik_lxc/files/config.alloy` line 44). This component
attaches to the Docker daemon's logs API via the socket. The data Alloy receives is whatever the Docker daemon was
fed by the container's stdout — *regardless of the configured log driver* in most cases. This means:

- When traefik's stdout pipe wedges, Alloy stops receiving lines too — Loki goes silent for traefik.
- Switching the Docker log driver does not require reconfiguring Alloy — the `loki.source.docker` source remains
  valid.

### What "silent stop" likely is

A wedged stdout buffer between the traefik Go process and the Docker daemon. We did not get to the root cause; the
following ruled it out as a journald-side issue:

- journald disk: 296 MB, well below limits (no full-disk drop)
- journald rate-limit: no `Suppressed` or `kept` messages in the window
- journald restart history: no journald restart in the window

That points to either Docker's log driver wedging or traefik's own stdout buffer. The cheapest mitigation does not
need to identify which.

## Options

```
+----------+---------------------------+------------+-------------+---------------------------+
| Option   | Change                    | Effort     | Risk        | Resilience                |
+----------+---------------------------+------------+-------------+---------------------------+
| A        | Loki staleness alert      | ~10 min    | None        | Detect, not prevent       |
| B        | Switch log driver to      | ~30 min    | Loses       | Removes journald hop;     |
|          | json-file (matches        |            | journalctl  | likely fixes the          |
|          | cadvisor/alloy on host)   |            | as path     | observed wedge            |
| C        | File-based access log     | ~1-2 hours | Most            | Decouples from Docker     |
|          | + bind mount + logrotate  |            | invasive    | stdout entirely; needs    |
|          | + Alloy reconfiguration   |            |             | Alloy file source         |
+----------+---------------------------+------------+-------------+---------------------------+
```

### Option A: Loki staleness alert

Add an alert that fires when no traefik log lines have arrived in Loki for some time during business hours.

```logql
absent_over_time({hostname="traefik", service_name="traefik"}[10m])
```

Wire that as a Grafana alert with a notification to the user's preferred channel (email / Telegram / Slack — same
path as other homelab alerts). When it fires, the runbook is `docker restart traefik` on the traefik LXC.

**Pros:** zero infrastructure change. Catches not just this failure mode but any other reason traefik logs stop.
**Cons:** does not prevent the gap; only detects it. Still need to manually restart.

### Option B: Switch traefik to the `json-file` log driver

Replicate what the `cadvisor` and `alloy` services on the same host already do: explicitly set the Docker log driver
on the traefik service. This bypasses journald entirely while preserving Alloy → Loki shipping (which uses the Docker
logs API, not journald).

In `roles/traefik_lxc/templates/docker-compose.yml.j2`, add to the `traefik:` service:

```yaml
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
```

Then `make traefik` to redeploy. The container restart drops in-flight long-lived streams — schedule it during a
quiet window.

**Pros:** smallest config change. Removes the journald hop entirely. Aligns traefik with the existing convention used
by the other two services on the same LXC. Fixes the wedge mode if it was journald-side, and still helps if it was
Docker-side (a `json-file` writer is simpler and less likely to wedge than the journald driver).
**Cons:** loses `journalctl CONTAINER_NAME=traefik` as a debug path. All historical traefik queries must go through
`docker logs traefik` (now reliable, since rotation is configured) or Loki. Existing runbooks that mention
`journalctl` for traefik must be updated.

### Option C: File-based traefik access log

Bypass Docker's log handling for access logs entirely by having traefik write to a file directly:

1. Update `roles/traefik_lxc/templates/traefik.yml.j2` to add:
   ```yaml
   accessLog:
     filePath: /var/log/traefik/access.log
     bufferingSize: 100
   log:
     level: INFO
     filePath: /var/log/traefik/traefik.log
   ```
2. Update `docker-compose.yml.j2` to add a bind mount `/var/log/traefik:/var/log/traefik` and ensure the host
   directory exists with appropriate ownership.
3. Add a logrotate config on the traefik LXC for `/var/log/traefik/*.log`. Use `copytruncate` (traefik does not
   handle `kill -USR1` reopen by default in this version) or wire up the reopen signal.
4. Update `roles/traefik_lxc/files/config.alloy` to add a `loki.source.file` source for the new files, with the same
   relabeling and forwarding chain as the existing Docker source.
5. Verify Loki still receives traefik logs after the change. **Without step 4, traefik vanishes from Loki entirely.**

**Pros:** most decoupled — survives Docker daemon hiccups, log driver bugs, journald wedges. Files persist across
container restarts.
**Cons:** four moving parts that must land together. Highest risk of a configuration mistake silently regressing log
shipping. Solves a problem we have only seen once.

## Recommendation

**Land Option A this week. Plan Option B for the next time touching the traefik role anyway. Defer Option C unless
the failure recurs.**

Reasons:

- Option A is cheap, broadly useful (catches future unknown failure modes too), and gives us the data we need to
  judge whether this is a one-off or a recurring problem.
- Option B aligns traefik with the convention already used by `cadvisor` and `alloy` on the same host, and is a
  plausible root-cause fix without Alloy changes. There's no reason traefik should be the only service on this LXC
  using the daemon-default log driver.
- Option C is a good idea in principle but is overkill given current evidence. Reconsider if Option A's alert fires
  more than twice or if Option B doesn't prevent recurrence.

## Implementation steps

### Step 1: Add the Loki staleness alert (Option A)

```
+----+-----------------------------------------------+----------------+
| #  | Action                                        | Where          |
+----+-----------------------------------------------+----------------+
| 1  | Open Grafana -> Alerting -> New alert rule    | infra-vm       |
| 2  | Use LogQL: absent_over_time(                  | (alert config) |
|    | {hostname="traefik", service_name="traefik"}  |                |
|    | [10m]) == 1                                   |                |
| 3  | Evaluate every 1m, fire after 10m             |                |
| 4  | Schedule: only during 07:00-23:00 CEST (avoid |                |
|    | quiet-hours pauses producing false positives) |                |
| 5  | Notification channel: same as other homelab   |                |
|    | alerts                                        |                |
| 6  | Alert summary should link to                  |                |
|    | sre-agent/runbooks/traefik-reverse-proxy.md   |                |
|    | "silent stop logging" section                 |                |
+----+-----------------------------------------------+----------------+
```

**Validation:** trigger by stopping the traefik container briefly (`docker stop traefik`, wait 11 minutes, restart).
The alert should fire and resolve. Note this also flags real outages — that's fine.

### Step 2: Switch the log driver (Option B, when next touching the traefik role)

```
+----+----------------------------------------------------+
| #  | Action                                             |
+----+----------------------------------------------------+
| 1  | Edit roles/traefik_lxc/templates/docker-compose.   |
|    | yml.j2: add `logging:` block to the `traefik:`     |
|    | service (mirror cadvisor's block)                  |
| 2  | Run `make check t=traefik` to dry-run              |
| 3  | Run `make traefik` during a quiet window           |
| 4  | Verify: `docker inspect traefik --format            |
|    | '{{.HostConfig.LogConfig.Type}}'` returns           |
|    | json-file                                          |
| 5  | Verify Loki still receives lines:                  |
|    | {hostname="traefik", service_name="traefik"}       |
|    | should still be returning recent access logs       |
| 6  | Update                                              |
|    | sre-agent/runbooks/traefik-reverse-proxy.md to     |
|    | replace the journalctl recipes with docker logs    |
|    | (now reliable) or just Loki                        |
+----+----------------------------------------------------+
```

**Caveat:** the container restart drops in-flight long-lived streams (`writeTimeout: 0` means audio/video sessions
can be hours long). Schedule outside peak listening times.

### Step 3 (only if Step 2 doesn't prevent recurrence): file-based access log

Detailed steps deferred until justified. The four-part change is described in Option C above.

## References

- SRE runbook: `sre-agent/runbooks/traefik-reverse-proxy.md` — investigation steps including the silent-stop failure
  mode and its diagnostic checklist.
- SRE runbook: `sre-agent/runbooks/cloudflared-tunnel.md` — what cloudflared does and doesn't log.
- SRE runbook: `sre-agent/runbooks/request-failure-investigation.md` — bottom-up playbook used during the
  2026-05-06 investigation.
- Service docs: `documentation/traefik.md` — traefik routing, config, and adding services.
- Role: `roles/traefik_lxc/` — the Ansible role that owns the templates touched by Option B and Option C.
