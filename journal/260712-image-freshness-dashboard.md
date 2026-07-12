# Image Freshness dashboard: current vs available for every running container

**Date:** 2026-07-12

## What was built

Option 1 from the update-visibility discussion: extend the existing
container-status-exporter (not a new repo — it already had the Portainer fleet
loop, tests, CI, and a Prometheus scrape job) with registry digest comparison, then
surface it in Grafana.

- **Exporter** (`container-status-exporter` repo, `freshness.py`, 24 new tests):
  every 6h, joins running-container digests (Portainer image inspect →
  `RepoDigests`, OCI version label, build date) against the digest each registry
  serves for the tag (anonymous OCI token flow; HEAD requests don't count against
  Hub limits). New metrics: `container_image_outdated`, `container_image_info`
  (status + current/available versions), current/available created timestamps.
- **Dashboard** `Image Freshness` (uid `image-freshness`, reference JSON in
  `roles/infra_vm/files/grafana/dashboards/`): stat row (outdated / ok / errors /
  total / last-check age), "days behind" table sorted worst-first, filterable
  full inventory with color-coded status.
- **Alerts** (folder "Containers"): *Container image stale* — build-date distance
  > 30 days for 6h, grouped Pushover digest repeating weekly; *Image freshness
  data missing* — watchdog on the last-check timestamp (NoData alerts).

## First-scan findings (the tool paid for itself immediately)

- 76 containers: 42 ok, **31 outdated**, 1 local (jellyfin's own build), 1 pinned
  (valkey), 1 error (booklore's dead Docker Hub repo — correctly flagged).
- **Immich `release` upstream is v3.0.2** — the v2.6.3 we deployed earlier today
  was itself a 3-month-stale cached pull. `pull: never` means even rolling tags
  are only as fresh as the last manual pull; the dashboard now makes that visible.
- cadvisor's `:latest` tag is 662 days behind (upstream stopped moving it — the
  sidecar pin strategy is the right one), and the hand-run portainer_agents are
  ~a year stale.

## Gotchas

- Prometheus renames the exporter's `hostname` label → `exported_hostname`
  (scrape target labels win without `honor_labels`). All dashboard/alert queries
  join on `exported_hostname`.
- Dashboards POSTed via `/api/dashboards/db` MUST include `schemaVersion` and
  per-panel `id`s or Grafana 12 renders an empty page (no console errors).
- Playwright full-page screenshots of Grafana come out blank (virtualized
  scroller) — viewport screenshots work.
- The compose service is `container-health-exporter` while the container is named
  `container-status-exporter` — mind the service name when recreating.

## Follow-ups

- 6 Dependabot vulnerabilities flagged on the container-status-exporter repo
  (predate this change) — worth a dependency bump pass.
- Portainer coverage is 8 hosts; music, open-webui, prometheus, traefik, agent
  are invisible to the dashboard until they get (Ansible-managed) portainer
  agents. The hand-run agents on the existing hosts should come under Ansible too.
- Consider upgrading Immich to v3 (major version — read release notes first).
