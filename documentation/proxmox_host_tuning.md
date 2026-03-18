# Proxmox Host Performance Tuning

## Hardware

- CPU: AMD Ryzen 5 PRO 4655G (12 threads)
- RAM: 62 GB
- Storage: 472 GB ZFS pool (`rpool`)

## ZFS ARC (Adaptive Replacement Cache)

ARC is ZFS's in-memory read cache. It keeps frequently accessed disk blocks in RAM so reads
don't hit disk. Larger ARC = better read performance for all VMs/CTs.

### Current config

- ARC max: 8 GB (`/etc/modprobe.d/zfs.conf`)
- ARC min: default (~1.9 GB, 1/32 of system RAM)
- Config file: `/etc/modprobe.d/zfs.conf`

### Sizing guidance

Proxmox docs recommend: **2 GB base + 1 GB per TB of storage**. Our pool is ~0.5 TB so the
minimum is ~2.5 GB. We use 8 GB to reduce `arc_prune` CPU overhead and improve I/O.

ARC memory is reclaimable — the kernel can shrink it under memory pressure, unlike VM
allocations which are locked.

### How to change ARC max

Three steps required:

1. **Runtime** (immediate, lost on reboot):
   ```bash
   echo 8589934592 > /sys/module/zfs/parameters/zfs_arc_max
   ```

2. **Persistent** — edit `/etc/modprobe.d/zfs.conf`:
   ```
   options zfs zfs_arc_max=8589934592
   ```

3. **Rebuild initramfs** (required because root is ZFS):
   ```bash
   update-initramfs -u -k all
   ```

If decreasing ARC max, also run `echo 3 > /proc/sys/vm/drop_caches` to free the already
allocated memory.

`zfs_arc_min` only needs adjustment if the desired max is lower than 1/32 of system RAM.

### Monitoring

```bash
# Current ARC size and limits
cat /proc/spl/kstat/zfs/arcstats | grep -E '^(size|c_max|c_min|c) '

# Hit ratio (should be >95%)
cat /proc/spl/kstat/zfs/arcstats | grep -E '^(hits|misses) '

# arc_prune CPU (should be ~0% when ARC has headroom)
top -b -n2 -d2 -p $(pgrep arc_prune) | tail -5
```

### History

The ARC max was originally set to 1.58 GB (Proxmox default for PVE 8.1+ installs: 10% of RAM,
capped at 16 GB). This caused `arc_prune` to consume ~25% CPU constantly as it evicted entries
to stay within the cap. Increased to 8 GB on 2026-03-17 which dropped `arc_prune` to 0%.

## KSM (Kernel Same-page Merging)

KSM deduplicates identical memory pages across VMs/CTs. Managed by `ksmtuned` service which
automatically adjusts scan aggressiveness based on memory pressure.

### Current config

- Config: `/etc/ksmtuned.conf` (all defaults, nothing uncommented)
- Service: `systemctl status ksmtuned`
- `ksmtuned` checks memory every 60 seconds and enables/disables KSM automatically

### Key parameters

```
/sys/kernel/mm/ksm/run             # 1=enabled, 0=disabled (managed by ksmtuned)
/sys/kernel/mm/ksm/sleep_millisecs # ms between scans (lower = more CPU, faster dedup)
/sys/kernel/mm/ksm/pages_to_scan   # pages per scan cycle
```

### Behaviour

- When free RAM is low, `ksmtuned` enables KSM and sets aggressive scan rates
- When free RAM is plentiful, `ksmtuned` disables KSM (`run=0`)
- Already-merged pages stay merged even when KSM is disabled — only new duplicates need scanning
- On this server (62 GB RAM), KSM saves ~6 GB when active

### Tuning

If `ksmd` CPU is high (~15-20%), `ksmtuned` is being too aggressive. Options:

1. Uncomment `KSM_SLEEP_MSEC=200` in `/etc/ksmtuned.conf` (default scales to ~26ms for 62 GB)
2. This reduces scan rate from ~48k pages/s to ~6k pages/s, dropping CPU from ~16% to ~2%
3. Trade-off: new duplicate pages take ~27 min to merge instead of ~3.5 min
4. Restart: `systemctl restart ksmtuned`

As of 2026-03-17, `ksmtuned` manages this automatically and no manual tuning was needed after
freeing RAM via VM balloon and ARC changes.

### Monitoring

```bash
# Check if KSM is active and how much it saves
echo "run: $(cat /sys/kernel/mm/ksm/run)"
echo "sleep_ms: $(cat /sys/kernel/mm/ksm/sleep_millisecs)"
echo "saved_MB: $(( $(cat /sys/kernel/mm/ksm/pages_sharing) * 4 / 1024 ))"

# ksmd CPU
top -b -n2 -d2 -p $(pgrep ksmd) | tail -5
```

## VM Memory and Ballooning

### Current VM allocations

| VM   | Name           | Config  | Balloon | Notes                          |
|------|----------------|---------|---------|--------------------------------|
| 102  | home-assistant | 2048 MB | none    | Reduced from 4 GB (2026-03-17) |
| 104  | truenas        | 16384 MB| 0 (off) | Needs full allocation for ZFS  |
| 106  | infra          | 2048 MB | none    | Tight, leave as-is             |
| 114  | media          | 16384 MB| 6144    | Balloon reclaims ~10 GB idle   |

### How balloon works

- VMs lock their full memory allocation at start (unlike CTs which only use what they need)
- Balloon driver inside the guest can return unused pages to the host
- `balloon: 6144` on media means minimum 6 GB guaranteed, up to 16 GB on demand
- When media is idle (~3.5 GB actual use), host reclaims ~10 GB
- Risk: sudden RAM spikes in the guest may briefly stall while balloon deflates

### LXC memory

LXCs use cgroups — the config `memory:` value is just a ceiling. They only consume what they
actually use. No ballooning needed.

### Monitoring

```bash
# VM actual RSS (host-side)
for vmid in 102 104 106 114; do
  pid=$(cat /run/qemu-server/$vmid.pid 2>/dev/null)
  rss=$(ps -p $pid -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
  echo "VM $vmid: ${rss}MB RSS"
done

# CT actual usage
for ctid in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
  used=$(cat /sys/fs/cgroup/lxc/$ctid/memory.current | awk '{printf "%.0f", $1/1024/1024}')
  echo "CT $ctid: ${used}MB"
done

# Overall
free -h
```
