# Grafana Alerting

How alert rules and notifications are configured on the infra VM's Grafana
(`http://192.168.2.106:3000`, `charts.{{ primary_domain_name }}`).

## Where things live

Unlike the rest of the stack, **alert rules are not managed by Ansible**. They are
stored in Grafana's own database (`/srv/infra/grafana/data/grafana.db`) and edited via
the Grafana UI (Alerting → Alert rules) or the HTTP API. The Ansible role
(`roles/infra_vm`) only deploys the Grafana container, `grafana.ini`, and dashboards.

Grafana's file-based provisioning directory (`/etc/grafana/provisioning/alerting/`) is
empty and unused. If alerting is ever migrated to Ansible, be aware that provisioned
rules become read-only in the UI.

## Alert rules

```
+----------------------------+---------------------------------------------------------------+------+-------+
| Rule                       | Condition                                                     | For  | Notes |
+----------------------------+---------------------------------------------------------------+------+-------+
| Disk Utilization (LXC)     | pve_disk_usage/pve_disk_size > 0.9, joined to pve_guest_info  | 2m   | 1     |
| Disk Utilization (VM/host) | 1 - node_filesystem_avail/size on "/" > 0.9                   | 2m   | 2     |
| UPS on battery             | ups_status{flag="OB"} == 1                                    | 0s   | 3     |
| UPS battery critical       | ups_status{flag=~"LB|FSD"} == 1                               | 0s   | 3     |
| UPS runtime low            | battery_runtime < 25 min AND on mains (OL flag)               | 10m  | 4     |
| UPS load high              | ups_load > 30%                                                | 5m   |       |
| UPS monitoring down        | up{job="nut"} == 0 (NoData also alerts)                       | 10m  | 5     |
+----------------------------+---------------------------------------------------------------+------+-------+
```

All rules are active (none paused). The old rules "Share Drive State" (probe no longer
needed), "Days since on battery (OB)" (referenced the since-renamed
`ups_days_since_last_ob` metric, so it was permanently NoData), "UPS Load", "UPS
Battery Charge" and "UPS Battery Runtime" were deleted on 2026-07-12 and replaced by
the set above.

Notes:

1. **LXC disks** come from `pve_exporter` (`pve_disk_usage_bytes / pve_disk_size_bytes`,
   filtered to `type="lxc"`). Proxmox reports real usage for LXC rootfs. A second query
   (refId `B`) computes free bytes so the notification can show them.
2. **VM and Proxmox-host root disks** come from `node_exporter`
   (`node_filesystem_*{mountpoint="/"}`). `pve_disk_usage_bytes` is always **0 for
   `type="qemu"`** guests (Proxmox cannot see inside VM disks), so VMs need this
   separate rule. LXCs also run node_exporter and would be double-counted; they are
   excluded by `device!~"rpool/data/subvol-.*"` (LXC rootfs datasets are ZFS subvols).

3. **UPS event alerts** fire immediately (`for: 0s`) on the NUT status flags. NUT's
   own `upssched-cmd.sh` also sends Pushover for ONBATT/ONLINE/LOWBATT etc. (see
   `ups.md`) — that path is independent of the monitoring stack and stays as a
   failsafe; the Grafana alerts add battery %, runtime and load detail plus resolved
   messages. Expect two notifications for a mains-loss event, one from each path.
4. **UPS runtime low** is gated on the `OL` (online) flag so it stays quiet during an
   actual outage — it exists to catch battery ageing / creeping load while on mains.
5. **UPS monitoring down** has `noDataState: Alerting` and `execErrState: Alerting`,
   so losing the NUT exporter (or its scrape target) alerts instead of silently
   blinding the other four UPS rules.

Known gaps: `nas_vm` (TrueNAS has its own alerting) and `home-assistant` (no
node_exporter) are not covered by the VM/host disk rule.

## Notification text

Both disk rules put the whole story in the `summary` annotation, one line, using
Grafana's annotation template functions:

```
{{ $labels.id }} ({{ $labels.name }}): root disk {{ humanizePercentage $values.A.Value }} full, {{ humanize1024 $values.B.Value }}B free
```

which renders like `lxc/113 (immich): root disk 92.4% full, 1.2GiB free`.

- `$values.A.Value` is the **numeric** result of query A for this alert instance.
  Do **not** use `$value` in annotations — it is a debug string of *all* query refIds
  (`[ var='A' labels={...} value=0.92 ] ...`), which is both verbose and unformattable
  (`printf "%.1f"` on it renders garbage). This was the cause of the old unreadable
  notifications.
- `humanizePercentage` turns the 0–1 fraction into `92.4%`.
- `humanize1024` turns bytes into `1.2Gi`.

## Pushover contact point

Notifications route per-rule to the **Pushover** contact point (the notification
policy default is still the unused `grafana-default-email`). The contact point's
*Title* and *Message* fields reference a custom notification template named
`pushover` (Alerting → Notification templates):

```
{{ define "pushover.title" }}{{ if .Alerts.Firing }}🔴 {{ .CommonLabels.alertname }}{{ else }}🟢 Resolved: {{ .CommonLabels.alertname }}{{ end }}{{ end }}

{{ define "pushover.message" -}}
{{ range .Alerts.Firing -}}
{{ .Annotations.summary }} — firing since {{ .StartsAt.Local.Format "15:04" }}
{{ end -}}
{{ range .Alerts.Resolved -}}
Resolved after {{ .EndsAt.Sub .StartsAt }} — {{ .Annotations.summary }}
{{ end -}}
{{ end }}
```

So a firing notification is just:

```
🔴 Disk Utilization (LXC)
lxc/113 (immich): root disk 92.4% full, 1.2GiB free — firing since 14:32
```

`.StartsAt.Local` renders in Europe/Amsterdam because the grafana container has
`TZ=Europe/Amsterdam` set in the compose template (that env var exists **only** for
this — Grafana's UI timezone is a per-user preference, but Go template `.Local` uses
the container TZ).

The Pushover API token and user key are stored encrypted in Grafana's DB
(`secureFields`), not in Ansible Vault. When updating the contact point via the
Alertmanager config API, keep `secureFields: {apiToken: true, userKey: true}` in the
receiver payload and Grafana preserves the stored secrets.

## API access

- The `SRE_agent` service account token (in `/srv/infra/.env`, from vault) is
  **Viewer/read-only** — fine for `GET`s, cannot modify rules or notification config.
- Admin (write) access uses `vault_grafana_username` / `vault_grafana_password` from
  `group_vars/all/vault.yml` — this is the same `admin` account used for the UI.
- Useful endpoints (all under `http://192.168.2.106:3000`):
  - `GET/PUT /api/v1/provisioning/alert-rules[/{uid}]` — rule definitions
    (send header `X-Disable-Provenance: true` on writes to keep rules UI-editable)
  - `GET/POST /api/alertmanager/grafana/config/api/v1/alerts` — notification
    templates + contact points
  - `GET/POST /api/ruler/grafana/api/v1/rules/{folderUID}?subtype=cortex` — rule
    groups (alternative write path)
- **Beware Grafana's login lockout**: ~5 consecutive bad basic-auth attempts lock the
  account for ~5 minutes, during which the *correct* password also returns 401.
