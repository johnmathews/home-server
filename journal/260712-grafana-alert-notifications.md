# Grafana alert notifications made concise; VM disk coverage added

**Date:** 2026-07-12

## Problem

Disk alerts fired correctly but the Pushover text was an unreadable wall of Grafana's
default notification template (labels, annotations, silence URLs). The percentage in
the message was also wrong: the annotation used
`{{ $value | printf "%.1f" }}%`, but in Grafana annotations `$value` is a debug
string of all query refIds, not a number — and the underlying query returns a 0–1
fraction, not a percent.

## Findings

- Only **Disk Utilization** was active; Share Drive State and all four UPS rules are
  paused (left as-is, intentional or not — flagged to future self).
- The disk rule only covered LXCs. `pve_disk_usage_bytes` is 0 for `qemu` guests, so
  **no VM root disk was monitored at all** — and infra-vm's root disk was at 93.6%
  when this was discovered.
- Grafana alerting is not Ansible-managed: rules live in the Grafana DB, edited via
  UI/API. Provisioning dir is empty.
- The `SRE_agent` service account is read-only; admin writes need the vault
  `vault_grafana_username`/`vault_grafana_password` creds.
- Gotcha: a few wrong basic-auth attempts trip Grafana's brute-force lockout and the
  correct password then also 401s for ~5 minutes.

## Changes

1. **Notification template** `pushover` (title + message) — one summary line per
   alert, `🔴/🟢` status in the title, duration on resolve. Contact point *Pushover*
   now uses it via its Title/Message fields.
2. **Disk Utilization (LXC)** (renamed from "Disk Utilization"): summary rewritten to
   `{{ $labels.id }} ({{ $labels.name }}): root disk {{ humanizePercentage $values.A.Value }} full, {{ humanize1024 $values.B.Value }}B free`;
   added query `B` (free bytes) to feed the message.
3. **New rule: Disk Utilization (VM/host)** — node_exporter based,
   `mountpoint="/"`, excludes LXC ZFS subvols (`device!~"rpool/data/subvol-.*"`);
   covers media-vm, infra-vm and the Proxmox host itself. Threshold 90% for 2m, same
   as the LXC rule. Fired immediately for infra-vm (root disk 94%).
4. **grafana container**: added `TZ=Europe/Amsterdam` in
   `roles/infra_vm/templates/docker-compose.yml.j2` so `.StartsAt.Local` in the
   notification template renders local time (deployed with `make infra TAGS=docker`).

Details in `documentation/grafana-alerting.md`.

## Follow-ups

- ~~infra-vm root disk 94% full~~ — resolved same day: `docker image prune -af`
  reclaimed 6.7GB, disk now at 75%.
- ~~Consider unpausing the Share Drive / UPS rules~~ — resolved same day, see below.
- `vault_grafana_*` creds double as the Grafana UI admin login; SRE_agent SA is
  deliberately read-only.

## Same-day follow-up: UPS rules rebuilt, share drive rule deleted

- **Share Drive State** deleted (probe no longer needed).
- All four paused UPS rules deleted. "Days since on battery (OB)" was broken anyway:
  it referenced `ups_days_since_last_ob`, which was renamed to
  `ups_days_since_last_ob_lower_bound`, so with `noDataState: Alerting` it fired
  permanently — likely why everything got paused.
- Replaced with five active rules driven by NUT status flags rather than derived
  metrics: **UPS on battery** (OB flag, immediate), **UPS battery critical** (LB/FSD
  flags, immediate), **UPS runtime low** (<25 min, gated on the OL flag so it is
  quiet during outages), **UPS load high** (>30% for 5m), **UPS monitoring down**
  (up{job="nut"} == 0 or NoData for 10m — so the exporter dying can't silently blind
  the rest).
- Summaries carry live values (battery %, runtime min, load %) via `$values.X.Value`.
- NUT's own upssched Pushover notifications kept as an independent failsafe; a real
  outage sends one notification from each path.
