# Pin the observability sidecars on the five `:latest` roles

**Date:** 2026-07-22

## Why

Five roles (agent, music, prometheus, traefik, document_library) ran their
monitoring sidecars — alloy, cadvisor, node-exporter — on `:latest`, so they
drifted silently whenever upstream pushed a new build (that is what put five
alloys on the Image Freshness dashboard, see [[260720-refresh-sidecars-target]]).
`:latest` also made the dashboard's version numbers meaningless (current ==
available == a base-image label) and made container recreation non-reproducible.
These sidecars are stable plumbing with no need for automatic updates, so
`:latest` was pure downside. Pinning stops the drift and makes updates a
deliberate, visible act — consistent with `pull: never` and the retired-Diun
philosophy ([[260713-retire-diun]]).

## Versions pinned (read off the running containers, not guessed)

`docker exec` into each sidecar reported identical versions on all five hosts:

    alloy          v1.18.0
    cadvisor       v0.55.1
    node-exporter  v1.12.1   (tag prefixed `v`, matching the registry convention)

Pinning to the *deployed* version was mandatory here: document_library carried a
comment warning that pinning below the running version once triggered a
destructive paperless downgrade. Each `:latest v1.18.0` / `:v1.18.0` pair was
confirmed to be the identical image ID before editing.

## Changes

- Each of the five roles' `defaults/main.yml`: `*_version: "latest"` → the pinned
  version above. Literal per-role pins (not the central `sidecar_*` vars, which
  sit at older versions — pointing these roles there would have been a downgrade).
  The seven already-pinned roles are untouched.
- `documentation/upgrade-procedures.md`: the "exceptions" list no longer says
  these roles track `:latest`; refresh-sidecars section updated.

## The `pull: never` gotcha (and how it was made safe)

The deploy handler is `docker_compose_v2` with `pull: never` + `recreate: always`.
Changing the tag to `v1.18.0` while the host only holds the image as `:latest`
would fail the next `make <host>`/`make site` ("image not present, pull policy
never"). So **before** editing, the pinned tags were pulled onto all five hosts
(near-instant — same digest already local, docker just adds the tag ref). The
image is in use by the running container, so the tag is durable (not prune-bait).
A `--check --diff` on agent_lxc confirmed the rendered compose flips `:latest` →
the pinned tags cleanly.

## State / follow-up

- **Not force-deployed.** The running containers already *are* these exact images,
  and the repo now pins them; the deployed compose file flips to the pinned tags on
  the next routine `make <host>`/`make site` (a brief all-container recreate on that
  host, safe because the tags are pre-pulled). No need to churn the hosts now.
- **Optional:** unify all 12 sidecar hosts by bumping the central `sidecar_*` vars
  (currently alloy v1.5.1 / cadvisor v0.49.1 / node-exporter v1.8.2) up to these
  versions and pointing the five roles at them — deferred, as it would upgrade the
  seven other hosts.
- **Optional:** a Renovate customManager for the `*_version` vars so these get
  update PRs like the rest of the docker images (today Renovate can't see them).
