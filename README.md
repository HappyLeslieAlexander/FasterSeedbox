# ⚡ FasterSeedbox

> **Kernel-level network, memory, and I/O stack optimization for high-throughput BitTorrent/PT seedboxes.**  
> `POSIX-sh` compliant · Idempotent · Best-effort hardened · Memory-adaptive · Cross-platform parity.

Default Linux/BSD network stacks are tuned for latency-sensitive interactive workloads, not sustained multi-gigabit bulk transfers. `FasterSeedbox` surgically reconfigures the TCP congestion control, socket buffer algebra, queue disciplines, file descriptor ceilings, and disk I/O schedulers. It’s not a magic script; it’s deterministic systems engineering packaged for repeatable, auditable deployment.

---

## 📜 Manifesto

BitTorrent/PT seeding thrives on three things:
1. **Sustained throughput** (BBR + FQ pacing)
2. **Massive connection concurrency** (`somaxconn`, `nofile`, `tcp_mem` pressure)
3. **Predictable I/O** (`kyber`/`mq-deadline`, ring buffers, `initcwnd`)

This project replaces kernel defaults with production-grade parameters derived from RFC standards, kernel documentation, and empirical bulk-transfer telemetry. Every value is calculated, bounded, and verified. No cargo-cult tuning.

---

## ⚙️ Architecture & Engineering Principles

| Principle | Implementation |
|-----------|----------------|
| **Strict POSIX `sh`** | Zero `bash`isms. Runs on `dash`, `busybox ash`, FreeBSD `/bin/sh`. Passes `sh -n` syntax checks. |
| **Idempotent & Atomic** | All writes use `mktemp`-style `.tmp.$$` + `mv`. `trap _cleanup EXIT INT TERM HUP` guarantees zero temp-file leaks. `append_once` markers prevent duplicate injections. |
| **Best-Effort Execution** | No `set -e`. Failures are caught, logged, and tallied. Exit code `0` = success, `3` = completed with warnings/errors. |
| **Memory-Adaptive Scaling** | 5-tier buffer algebra scales from 512MB to 128GB+ RAM. `tcp_mem` pressure thresholds are capped to prevent TCP from starving userspace during OOM pressure. |
| **Safe Route Surgery** | `ip route replace` reconstructs default routes for `initcwnd 25 initrwnd 25`. Explicitly extracts `dev`/`via` to avoid breaking policy routing or multi-homed gateways. |
| **Defense in Depth** | Validates `/proc/meminfo` & `hw.physmem`, sanitizes `ethtool` output with `awk` state machines, checks MAC/SELinux contexts gracefully, uses UTC timestamps for backups. |

---

## 🧠 The Tuning Matrix (Deep Dive)

### 🌐 TCP Congestion & Queue Discipline
| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `tcp_congestion_control` / `tcp.cc.algorithm` | `bbr` | BBRv1/v2 paces packets based on bandwidth-delay product, ignoring loss as congestion signal. Ideal for high-BDP seedbox links. |
| `default_qdisc` | `fq` | Fair Queue enforces pacing intervals, prevents bufferbloat, and works synergistically with BBR's rate control. |
| `net.isr.direct` / `direct_force` | `1` (FreeBSD) | Binds network interrupts to polling threads, bypassing legacy `swi_net` contention on multi-core systems. |

### 📦 Socket Buffers & Window Algebra
| Parameter | Calculation | Rationale |
|-----------|-------------|-----------|
| `rmem_max` / `wmem_max` | `8MB` → `128MB` (5-tier) | Caps per-socket buffer to prevent memory bloat while allowing large BDP windows. |
| `tcp_rmem` / `tcp_wmem` | `4096 87380 $MAX` | Linux auto-tunes between min/default/max. Aligns with `rmem_max` for full-window utilization. |
| `tcp_adv_win_scale` | `3` → `-2` (adaptive) | **Fixed in v1.1.0**. Controls TCP window scaling efficiency. Lower values increase buffer utilization for large windows. |
| `tcp_mem` (4K pages) | `$MEM/32 $MEM/16 $MEM/8` (capped) | TCP memory pressure thresholds. Caps at `2M/4M/8M` pages to guarantee system survivability under load. |

### 🔌 Connection Handling & Fast Path
| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `somaxconn` | `524288` | Unblocks the listen backlog. Prevents `SYN` drops when trackers/peers flood connect queues. |
| `tcp_max_tw_buckets` | `2097152` | Expands TIME-WAIT hash table. Prevents `TCP: request_sock_TCP: Possible SYN flooding` false positives. |
| `tcp_fastopen` | `3` (Linux) / `1` (FreeBSD) | Enables TFO for both client & server. Shaves 1 RTT on repeated peer connections. |
| `initcwnd` / `initrwnd` | `25` | Jumps initial TCP window from ~10 to ~25 MSS (~36KB). Accelerates slow-start for chunk-based protocols. |
| `tcp_tw_reuse` | `1` | Safely reuses `TIME-WAIT` sockets for outbound connections. Kernel-guaranteed safe post-4.12. |

### 💾 Disk I/O & NIC Ring Buffers
| Component | Logic | Rationale |
|-----------|-------|-----------|
| I/O Scheduler | `kyber` (SSD/NVMe) / `mq-deadline` (HDD) | `kyber` isolates sync/async latency on fast media. `mq-deadline` guarantees fairness & deadline compliance on rotational disks. |
| NIC Ring Buffers | `ethtool -G rx $MAX tx $MAX` (clamped) | Safe `awk` parser extracts `Pre-set maximums:` block. Skips `n/a`/non-numeric outputs. Prevents driver crashes. |
| TX Queue Length | `txqueuelen 10000` | Increases kernel NIC send queue depth. Prevents `qdisc drops` during bursty peer uploads. |

### 📁 File Descriptors & Resource Limits
| Layer | Mechanism | Value |
|-------|-----------|-------|
| PAM | `/etc/security/limits.d/99-seedbox.conf` | `nofile=1048576`, `nproc=65535`, `memlock=unlimited` |
| Systemd | `/etc/systemd/system.conf.d/99-seedbox.conf` | `DefaultLimitNOFILE=1048576` (applies to all services) |
| OpenRC | `rc_ulimit="-n 1048576"` in init script | Guarantees daemon inherits limits without PAM |
| FreeBSD | `login.conf` class `seedbox` + `cap_mkdb` | Native capability database integration |

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

## 🛠️ Deployment & Usage

### 1. Download & Verify
```bash
# Choose your platform
curl -fSL -O https://raw.githubusercontent.com/HappyLeslieAlexander/FasterSeedbox/main/debian.sh
# or: rhel.sh | alpine.sh | freebsd.sh

chmod +x *.sh
```

### 2. Audit (Always Run First)
```bash
sudo ./debian.sh --dry-run
```
Outputs full configuration diffs, memory tier calculations, and planned file writes. Zero system mutations.

### 3. Apply
```bash
sudo ./debian.sh
```
- Applies `sysctl` live (best-effort)
- Installs init service & runtime helper
- Prints summary + rollback instructions

### 4. Immediate Activation
```bash
# Linux
sudo modprobe tcp_bbr
sudo systemctl start seedbox-tune

# FreeBSD
sudo kldload tcp_bbr
sudo service seedbox-tune start

# Alpine
sudo modprobe tcp_bbr
sudo rc-service seedbox-tune start
```

### 5. Verify
```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_adv_win_scale
ulimit -n
ss -tnp state established | wc -l  # Connection count check
```

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

## 🛡️ Safety, Idempotency & Rollback

### 🔒 Atomic Writes & Backups
- Every modified file is backed up as `${file}.bak-YYYYMMDD-HHMMSSZ` (UTC)
- Temp files cleaned via `trap` on `EXIT`, `INT`, `TERM`, `HUP`
- `append_once` uses marker grep to prevent duplicate injections

### 🔄 Idempotent Execution
Run the script multiple times. It will:
1. Detect existing markers → skip duplicates
2. Overwrite configs atomically → preserve latest values
3. Reload systemd/OpenRC → sync live state

### 🗑️ Full Rollback
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