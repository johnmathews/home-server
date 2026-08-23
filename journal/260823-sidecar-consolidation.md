# One sidecar version, fleet-wide

**Date:** 2026-08-23
**Unit:** W26 (engineering-team cycle, session 7)
**PR:** eng-tidy-up-s7

## 1. What was wrong

Thirteen hosts run the same three monitoring sidecars — Alloy, node-exporter,
cadvisor — and they were running two different sets of them:

```
v1.5.1 / v1.8.2 / v0.49.1   pve, infra, media, immich, jellyfin, open-webui, tube
v1.18.0 / v1.12.1 / v0.55.1  traefik, music, agent, paperless, prometheus, finances
```

One Prometheus, fed by two Alloy generations 13 minors apart. Nothing alerted on
it; the only surface where it was visible at all was the Image Freshness
dashboard.

The cause was structural, not an oversight. Seven roles read `sidecar_*` from
`group_vars/all/main.yml`. Six pinned literals in their own `defaults/main.yml`.
And `jellyfin_lxc` was the odd one out again: it deployed a **static**
`files/docker-compose.yml` rather than a template, so its pins could not reference
a variable at all and were kept in step by a comment that said "keep in sync by
hand".

## 2. What was done

Every role now reaches the version through its own default:

```yaml
<role>_alloy_version: "{{ sidecar_alloy_version }}"
```

and `sidecar_*` was raised to the newer of the two sets. Converging **upward** was
the call: six hosts were already there, and rolling six hosts backwards is the
riskier direction than moving seven forwards.

`roles/jellyfin_lxc/files/docker-compose.yml` became
`roles/jellyfin_lxc/templates/docker-compose.yml.j2`, and the deploy task changed
from `copy:` to `template:`. Two things fell out of that:

- Its compose is now inside `make check-ports`, which globs
  `roles/*/templates/docker-compose.yml.j2`. The one stack the duplicate-port gate
  could never see is now covered — 12 templates checked became 13.
- `portainer_agent_version` had a second hand-synced copy in that file. It doesn't
  now.

## 3. The ordering trap, which is the part worth remembering

`make refresh-sidecars` exists precisely for "the pin moved, go fetch it". It is
**the wrong tool for a tag change**, and the reason is subtle enough that the
playbook's own header comment doesn't cover it: it runs `docker compose pull`
against the compose file **currently on the host**, which still names the old tag.
It will dutifully re-pull what is already there.

Meanwhile every compose handler uses `pull: never`, so deploying the new compose
first means `docker compose up -d` referencing an image the host does not have.

The order that works:

1. Bump `sidecar_*` in `group_vars/all/main.yml`.
2. **Pre-pull the new tags on each affected host** — `docker pull grafana/alloy:<new>`.
   Harmless, reversible, and it is the step that makes step 3 safe.
3. `make <host>`. The handler now finds the image locally and recreates.

`make refresh-sidecars` is still right for the other case: a host sitting on a
stale local image for a tag it is already pinned to.

One registry wrinkle: `infra_vm` pulls node-exporter from `prom/` while everyone
else uses `quay.io/prometheus/`. Same project, same tags, different pull command.

## 4. Blast radius, which was larger than the change

Worth recording because it is a property of the roles, not of this change, and it
will apply to the next sidecar bump too:

- `jellyfin_lxc` and `media_vm` use `recreate: always` on the **whole stack**, so
  any compose change restarts every container on those hosts. Jellyfin itself went
  down for about ten seconds; all 19 media containers were recreated.
- `infra_vm` uses `recreate: auto`, so only the three sidecars moved. Grafana and
  Loki were not touched — they showed "Up 10 hours" straight through the deploy.

If a future bump needs to avoid restarting Jellyfin, that handler is the thing to
change, not the deploy procedure.

## 5. Verification

Before deploying: `make check EXTRA="--diff"` across all 17 hosts, compared against
the session-6 baseline. Zero failed tasks, zero `AnsibleUndefinedVariable`, and
every single changed line in the whole fleet diff was a sidecar image tag on one of
the seven old-side hosts. The six roles that only swapped a literal for
`{{ sidecar_* }}` produced **no diff at all** — which is what proves that half of
the change was value-preserving rather than merely plausible.

After deploying:

- `docker ps` across all 13 hosts returns exactly three distinct images.
- Prometheus: 41 active targets, none down, 13 `node_exporter` and 12 `cadvisor`.
- Alloy v1.18.0 confirmed shipping end-to-end — Jellyfin's post-restart startup
  lines are in Loki. No config-schema break, which is what you would expect
  between two v1.x releases but is not the same as having checked.

## 6. A mistake worth writing down

Partway through I also "fixed" the header comment in eight compose templates —
several named a path that was not their own, and two still pointed at jellyfin's
moved file. The `--check --diff` immediately showed why that was wrong: changing a
comment re-renders the compose on eight hosts and fires their restart handlers.
Restarting the media stack to correct a comment is a bad trade, and it buried the
actual signal in the diff.

Reverted. The acceptance test for this unit was "the only thing that changed is
image tags", and anything that makes that harder to read is working against the
test. Those comments belong in W25, the dead-code-and-comments unit — where the
same cost applies and should be weighed on its own.
