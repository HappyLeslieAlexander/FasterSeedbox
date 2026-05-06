# ⚡ FasterSeedbox

> **Kernel-level network, memory, and I/O stack optimization for high-throughput BitTorrent/PT seedboxes.**  
> `POSIX-sh` compliant · Idempotent · Best-effort hardened · Memory-adaptive · Cross-platform parity

```sh
# One-liner audit (Debian/Ubuntu)
curl -fsSL https://raw.githubusercontent.com/HappyLeslieAlexander/FasterSeedbox/main/debian.sh | sudo sh -s -- --dry-run

# Apply after review
curl -fsSL https://raw.githubusercontent.com/HappyLeslieAlexander/FasterSeedbox/main/debian.sh | sudo sh
```

---

## 🎯 The Problem

Default Linux/BSD network stacks are tuned for **latency-sensitive interactive workloads**, not sustained multi-gigabit bulk transfers. Your seedbox is capped by:

| Bottleneck | Default | After FasterSeedbox |
|------------|---------|---------------------|
| TCP Congestion | CUBIC/Reno | **BBR** (bandwidth-delay product aware) |
| Queue Discipline | pfifo_fast | **FQ** (Fair Queue, pacing-enabled) |
| Socket Buffers | 212KB max | **8MB–128MB** (5-tier adaptive) |
| Connection Queue | 128–4096 | **524,288** (`somaxconn`) |
| File Descriptors | 1024 | **1,048,576** (`nofile`) |
| Disk Scheduler | BFQ/default | **kyber** (SSD) / **mq-deadline** (HDD) |
| Initial Window | 10 MSS (~1.4KB) | **25 MSS** (~36KB) |

This isn't cargo-cult tuning. It's **deterministic systems engineering** packaged for repeatable, auditable deployment.

---

## 🔥 Quick Start

### 1. Download & Verify
```bash
# Platform-specific scripts
curl -fSL -O https://raw.githubusercontent.com/HappyLeslieAlexander/FasterSeedbox/main/debian.sh
# or: rhel.sh | alpine.sh | freebsd.sh

chmod +x *.sh
```

### 2. Audit First (Always!)
```bash
sudo ./debian.sh --dry-run
```
Outputs full configuration diffs, memory tier calculations, and planned file writes. **Zero system mutations.**

### 3. Apply
```bash
sudo ./debian.sh
```

### 4. Activate Immediately
```bash
# Linux
sudo modprobe tcp_bbr
sudo systemctl start seedbox-tune

# FreeBSD
sudo kldload tcp_bbr
sudo service seedbox-tune start
```

### 5. Verify
```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
ulimit -n
ss -tnp state established | wc -l
```

---

## 🧠 The Tuning Matrix

### TCP Congestion & Queue Discipline
| Parameter | Value | Why It Matters |
|-----------|-------|----------------|
| `tcp_congestion_control` | `bbr` | BBRv1/v2 paces packets based on **BDP**, ignoring loss as congestion signal. Ideal for high-latency, high-bandwidth seedbox links. |
| `default_qdisc` | `fq` | Fair Queue enforces pacing intervals, prevents bufferbloat, synergizes with BBR's rate control. |
| `net.isr.direct` (FreeBSD) | `1` | Binds network interrupts to polling threads, bypassing legacy `swi_net` contention on multi-core. |

### Socket Buffers & Window Algebra
| Parameter | Calculation | Rationale |
|-----------|-------------|-----------|
| `rmem_max` / `wmem_max` | `8MB` → `128MB` (5-tier) | Caps per-socket buffer to prevent memory bloat while allowing large BDP windows. |
| `tcp_rmem` / `tcp_wmem` | `4096 87380 $MAX` | Linux auto-tunes between min/default/max. Aligns with `rmem_max` for full-window utilization. |
| `tcp_adv_win_scale` | Adaptive (`1` to `-2`) | Controls TCP window scaling efficiency. Lower values increase buffer utilization for large windows. |
| `tcp_mem` (4K pages) | `$MEM/32 $MEM/16 $MEM/8` (capped) | TCP memory pressure thresholds. **Capped at 2M/4M/8M pages** to guarantee system survivability under OOM. |

### Connection Handling & Fast Path
| Parameter | Value | Impact |
|-----------|-------|--------|
| `somaxconn` | `524288` | Unblocks listen backlog. Prevents SYN drops when trackers/peers flood connect queues. |
| `tcp_max_tw_buckets` | `2097152` | Expands TIME-WAIT hash table. Prevents SYN flooding false positives. |
| `tcp_fastopen` | `3` (Linux) / `1` (FreeBSD) | Enables TFO for client & server. Shaves 1 RTT on repeated peer connections. |
| `initcwnd` / `initrwnd` | `25` | Jumps initial TCP window from ~10 to ~25 MSS (~36KB). Accelerates slow-start for chunk-based protocols. |
| `tcp_tw_reuse` | `1` | Safely reuses TIME-WAIT sockets for outbound connections. Kernel-guaranteed safe post-4.12. |

### Disk I/O & NIC Ring Buffers
| Component | Logic | Benefit |
|-----------|-------|---------|
| I/O Scheduler | `kyber` (SSD/NVMe) / `mq-deadline` (HDD) | `kyber` isolates sync/async latency on fast media. `mq-deadline` guarantees fairness on rotational disks. |
| NIC Ring Buffers | `ethtool -G rx $MAX tx $MAX` (clamped) | Safe `awk` parser extracts `Pre-set maximums`. Skips `n/a` outputs. Prevents driver crashes. |
| TX Queue Length | `txqueuelen 10000` | Increases kernel NIC send queue depth. Prevents qdisc drops during bursty uploads. |

### File Descriptors & Resource Limits
| Layer | Mechanism | Value |
|-------|-----------|-------|
| PAM | `/etc/security/limits.d/99-seedbox.conf` | `nofile=1048576`, `nproc=65535`, `memlock=unlimited` |
| Systemd | `/etc/systemd/system.conf.d/99-seedbox.conf` | `DefaultLimitNOFILE=1048576` (applies to all services) |
| OpenRC | `rc_ulimit="-n 1048576"` in init script | Guarantees daemon inherits limits without PAM |
| FreeBSD | `login.conf` class `seedbox` + `cap_mkdb` | Native capability database integration |

---

## 🛡️ Security & Hardening

### Atomic Writes & Backups
- Every modified file is backed up as `${file}.bak-YYYYMMDD-HHMMSSZ` (UTC)
- Temp files created via **`mktemp "${_wf_path}.tmp.XXXXXX"`** with `umask 077`
- `trap _cleanup EXIT INT TERM HUP` guarantees zero temp-file leaks
- `append_once` uses marker grep to prevent duplicate injections

### Container-Aware Execution
```sh
# Auto-detects virtualization environment
systemd-detect-virt -q && VIRT_KIND="$(systemd-detect-virt)"
# Disables offload tweaks inside containers to avoid namespace conflicts
```

### Memory Pressure Caps
```sh
# Prevents TCP from starving userspace during OOM
TCP_MEM_MIN_CAP=262144    # 1GB floor
TCP_MEM_PRESS_CAP=2097152 # 8GB cap
TCP_MEM_MAX_CAP=4194304   # 16GB cap
[ "$TCP_MEM_MIN" -gt "$TCP_MEM_MIN_CAP" ] && TCP_MEM_MIN=$TCP_MEM_MIN_CAP
```

### POSIX Compliance Verified
```bash
# All scripts pass strict syntax checks
dash -n debian.sh     # ✅ OK
dash -n alpine.sh     # ✅ OK
dash -n freebsd.sh    # ✅ OK
dash -n rhel.sh       # ✅ OK
```

---

## 🖥️ Platform Parity Matrix

| Feature | Debian/Ubuntu | RHEL/Rocky/Alma | Alpine | FreeBSD |
|---------|---------------|-----------------|--------|---------|
| **Init System** | `systemd` | `systemd` | `OpenRC` | `rc.d` |
| **Sysctl Path** | `/etc/sysctl.d/` | `/etc/sysctl.d/` | `/etc/sysctl.d/` | `/etc/sysctl.conf` (append) |
| **Limits** | `limits.d` + `systemd` | `limits.d` + `systemd` | `limits.d` + `rc_ulimit` | `login.conf` + `cap_mkdb` |
| **Modules** | `modules-load.d` | `modules-load.d` | `/etc/modules` | `rc.conf` (`kld_list`) |
| **Queue/ISR** | `fq` + `ethtool` | `fq` + `ethtool` | `fq` + `ethtool` | `net.isr.direct` |
| **Virtualization** | `systemd-detect-virt` | `systemd-detect-virt` | `virt-what`/DMI/proc | `kern.vm_guest` |
| **BBR Load** | `modprobe tcp_bbr` | `modprobe tcp_bbr` | `modprobe tcp_bbr` | `kldload tcp_bbr` |

> ✅ All four scripts share identical tuning algebra, `--dry-run` behavior, backup semantics, and exit codes. Platform-specific code is isolated to init-system and kernel-toolchain abstractions.

---

## 🔍 Verification & Telemetry

| Check | Command | Expected |
|-------|---------|----------|
| **BBR Active** | `sysctl net.ipv4.tcp_congestion_control` | `bbr` |
| **Queue Discipline** | `sysctl net.core.default_qdisc` | `fq` |
| **Window Scale** | `sysctl net.ipv4.tcp_adv_win_scale` | `1` to `-2` (tier-dependent) |
| **FD Limits** | `ulimit -n` | `1048576` |
| **NIC Ring** | `ethtool -g eth0 \| grep -i current` | Matches `Pre-set maximums` or clamped defaults |
| **Disk Scheduler** | `cat /sys/block/sda/queue/scheduler` | `[kyber]` or `[mq-deadline]` |
| **Service Status** | `systemctl is-active seedbox-tune` | `active` / `exited` (oneshot) |

---

## 🔄 Idempotency & Rollback

### Run Multiple Times Safely
The script is **idempotent**:
1. Detects existing markers → skips duplicates
2. Overwrites configs atomically → preserves latest values
3. Reloads systemd/OpenRC → syncs live state

### Full Rollback
```bash
# Disable & remove service
sudo systemctl disable --now seedbox-tune  # or rc-update del / rm rc.d
sudo rm -f /usr/local/sbin/seedbox-runtime.sh

# Remove drop-ins
sudo rm -f /etc/sysctl.d/99-seedbox.conf \
           /etc/security/limits.d/99-seedbox.conf \
           /etc/systemd/system.conf.d/99-seedbox.conf \
           /etc/modules-load.d/seedbox-bbr.conf

# Restore & reload
sudo sysctl --system
sudo systemctl daemon-reload
sudo reboot  # Recommended for full kernel stack reset
```
*Backup files remain for manual inspection.*

---

## 🧪 Edge Cases & Constraints

| Scenario | Behavior |
|----------|----------|
| **Containers (Docker/LXC)** | Warns about host vs namespace limits. `sysctl` inside containers requires `--privileged` or host-side execution. |
| **SELinux Enforcing** | Scripts use `|| true` on privileged calls. Logs `WARN` if denied. Standard paths (`/etc/sysctl.d/`) are SELinux-policy compliant. |
| **`/proc/meminfo` Missing/Corrupt** | Falls back to conservative `1GB` tier. Never crashes on non-numeric/empty values. |
| **Multi-Default Routes** | Extracts lowest-metric route via `awk`. Applies `initcwnd` safely without dropping gateways. |
| **RAM > 128GB** | `tcp_mem` caps at `2M/4M/8M` pages to prevent TCP from monopolizing physical memory during pressure events. |
| **FreeBSD < 12.2** | `sysrc +=` fallback to manual read-append-write. `kldstat` uses `>/dev/null` instead of unsupported `-q`. |

---

## 📜 License & Credits

- **License**: GNU GPL 3.0
- **Author**: HappyLeslieAlexander
- **Dependencies**: `awk`, `iproute2`/`ip`, `ethtool` (optional), `systemd`/`OpenRC`/`rc.d`, `modprobe`/`kldload`
- **Philosophy**: *"Tune the stack, not the script. Let the kernel do the heavy lifting."*

---

> 🐧 **Ready to seed at line rate.** Run `--dry-run`, verify the diff, apply, and monitor your `iperf3`/`qBittorrent`/`Transmission` throughput graphs. The stack is now yours.
