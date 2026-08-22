# Proxmox Backup Server (PBS)

**Status:** current as of 2026-08-22 (covers: live). The datastore figures below were
re-read from the appliance on that date; re-check them with the command in
[Datastore](#datastore) rather than trusting the numbers.

## Overview

PBS runs on a dedicated host at **192.168.2.200** (port **8007**) and is the destination for all
Proxmox VE guest backups. Every VM and LXC on `pve` (192.168.2.214) is dumped here daily by a
single PVE-side vzdump job. PBS is not Ansible-managed in this repo — its configuration lives on
the appliance itself; this doc describes what's there, why, and how to interact with it.

## Topology

```
+---------------------+         daily 10:00 vzdump          +---------------------+
| pve (192.168.2.214) | ------------------------------------> | pbs (192.168.2.200) |
| all guests          |   PBS protocol, port 8007, root@pam   | datastore "pbs"     |
+---------------------+                                       | /mnt/pbs (/dev/sdh1)|
                                                              +---------------------+
                                                                        |
                                                          GC 11:00, prune 12:00,
                                                          verify 14:00 (daily)
```

## Datastore

A single datastore named `pbs`, mounted at `/mnt/pbs` on `/dev/sdh1`.

**Usage is a moving number — read it, do not trust a figure written down here.** Either of:

```bash
ssh pbs proxmox-backup-manager datastore list      # name, path, and comment
ssh pbs df -h /mnt/pbs                             # size, used, available, use%
```

or the `pbs_datastore_status` tool on the `sre-agent` MCP server, which returns the same
figures without a shell.

At last verification (**2026-08-22**): 386 GiB used of 915 GiB (**42.2%**), 482 GiB available.
When usage exceeds ~85% the prune retention or disk capacity should be reviewed.

The two commands disagree by a few points and both are correct: PBS reports `used / total`,
while `df` reports `used / (used + available)` and so counts the filesystem's reserved blocks
against you. On the figures above that is 42.2% versus `df`'s 45%. Use the PBS number when
comparing against the ~85% threshold.

```
+------------------+----------------------+
| Setting          | Value                |
+------------------+----------------------+
| Name             | pbs                  |
| Path             | /mnt/pbs             |
| Backing device   | /dev/sdh1            |
| Notification     | notification-system  |
| Capacity         | 915 GiB              |
+------------------+----------------------+
```

## Schedule

```
+--------------+--------+----------------------------------------------------+
| Job          | Time   | Purpose                                            |
+--------------+--------+----------------------------------------------------+
| vzdump (PVE) | 10:00  | Snapshot-mode backup of all guests, zstd, sent to  |
|              |        | this datastore. PVE side — not configured here.    |
| Prune        | 12:00  | Drops snapshots that fall outside retention window |
| GC           | 11:00  | Reclaims chunk store space from pruned snapshots   |
| Verify       | 14:00  | Re-verifies snapshots; ignores already-verified;   |
|              |        | flags any older than 30 days as outdated           |
+--------------+--------+----------------------------------------------------+
```

## Retention

**Two prune policies exist and the stricter one wins.** This surprises people, so read the
whole section before relying on a number.

The PVE vzdump job carries its own `prune-backups` line, and PBS runs a *separate* prune job
two hours later. PBS's job is both later and tighter, so **PBS's policy is the one that
determines what you can actually restore.**

```
+-------------------------+-------+--------------------------------------------------+
| Policy                  | Runs  | Keeps                                            |
+-------------------------+-------+--------------------------------------------------+
| PVE vzdump job          | 10:00 | last 14, daily 31, weekly 26, monthly 12,        |
| (/etc/pve/jobs.cfg)     |       | yearly 1  -> up to ~84 snapshots                 |
| PBS prune job  <-- WINS | 12:00 | daily 14, weekly 4, monthly 3                    |
| (proxmox-backup-manager |       | -> 21 snapshots, no yearly                       |
|  prune-job list)        |       |                                                  |
+-------------------------+-------+--------------------------------------------------+
```

**Effective retention is 21 snapshots per guest — roughly 3 months, with no yearly copy.**
Confirmed 2026-08-22: every guest backed up for longer than 21 days holds exactly 21
snapshots (`pbs_list_backups` on the `sre-agent` MCP server, or the command below).

```bash
ssh pbs proxmox-backup-manager prune-job list     # the binding policy
ssh pve grep prune-backups /etc/pve/jobs.cfg      # the PVE-side policy (mostly moot)
```

If you want the longer PVE-side window to be real, relax the PBS prune job to match —
editing only `/etc/pve/jobs.cfg` will not change what is kept. Note also that
`/etc/pve/storage.cfg` sets `prune-backups keep-all=1` on the `pbs` storage, which disables
*storage-level* pruning only; it does not override either job above.

## PVE-side configuration

In `/etc/pve/storage.cfg` on `pve`:

```
pbs: pbs
    datastore pbs
    server 192.168.2.200
    content backup
    fingerprint <fingerprint>
    port 8007
    prune-backups keep-all=1
    username root@pam
```

The vzdump job in `/etc/pve/jobs.cfg`:

```
vzdump: backup-<id>
    schedule 10:00
    all 1
    compress zstd
    enabled 1
    mode snapshot
    storage pbs
    mailnotification failure
    mailto mthwsjc@gmail.com
    prune-backups keep-daily=31,keep-last=14,keep-monthly=12,keep-weekly=26,keep-yearly=1
```

## Common Operations

### List recent backups

```sh
ssh pbs 'proxmox-backup-manager task list --output-format text | head -20'
```

Or via the PBS web UI at `https://192.168.2.200:8007`.

### Manually trigger a backup of a specific guest

From `pve`:

```sh
ssh pve 'vzdump <vmid> --storage pbs --mode snapshot --compress zstd'
```

### Restore a guest

From the PVE web UI: Datacenter → pbs storage → Content → select the snapshot → Restore.
Or from CLI on `pve`:

```sh
ssh pve 'pvesm list pbs'                      # list available snapshots
ssh pve 'qmrestore pbs:backup/vm/<vmid>/<snapshot> <new_vmid>'  # KVM
ssh pve 'pct restore <new_vmid> pbs:backup/ct/<vmid>/<snapshot>'  # LXC
```

### Free space ad-hoc

```sh
ssh pbs 'proxmox-backup-manager garbage-collection start pbs'
```

## Monitoring

- **Alerts**: PVE vzdump is configured with `mailnotification failure` and `mailto
  mthwsjc@gmail.com` — failures email out. Successful runs are silent.
- **Disk space**: monitored via Prometheus node-exporter (running on PBS via standard install).
  Watch `/dev/sdh1` usage in Grafana.
- **Verification failures**: PBS notification system fires for failed verification jobs. Check
  the PBS UI under Tasks → Verification.

## Disaster Recovery Hooks

This is the only off-VM-host backup tier. If `pve` is destroyed, `pbs` has the snapshots needed
to rebuild. If `pbs` itself is destroyed, there is currently **no off-site replication** — the
backups are gone with the disk.

If you ever want off-site or off-machine replication, configure a sync job under
`/etc/proxmox-backup/sync.cfg` pointing at a remote PBS instance or a remote rsync target. None
is configured today.

See `documentation/disaster-recovery.md` for the broader recovery scenarios.

## Troubleshooting

- **vzdump fails with `connection timed out`**: PBS is unreachable from PVE. Check `ping pbs`,
  `nc -zv 192.168.2.200 8007`, and that PBS is up (`ssh pbs uptime`).
- **GC takes too long / disk fills**: chunk store fragmentation accumulates over months.
  Triggering an out-of-band GC (`proxmox-backup-manager garbage-collection start pbs`) usually
  recovers the space the prune released.
- **Verification flags chunks as bad**: a chunk on disk is corrupt. Re-create the affected
  guest's next backup (will re-upload the chunk fresh) and re-run verification. If chunks
  continue to fail, suspect the `/dev/sdh1` device — check SMART status.
- **Web UI shows fingerprint mismatch from PVE**: PBS's TLS cert was regenerated. Update the
  `fingerprint` field in `/etc/pve/storage.cfg` on PVE to match.
