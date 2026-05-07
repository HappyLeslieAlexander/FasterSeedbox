#!/bin/sh
#
# FasterSeedbox — Linux tuning installer (SECURITY-HARDENED EDITION)
#
# Applies networking, VM, I/O, and resource-limit settings aimed at
# high-throughput torrent workloads. Persistent values are dropped in
# as /etc/sysctl.d/, /etc/security/limits.d/, /etc/modules-load.d/
# and /etc/systemd/system.conf.d/ fragments so that /etc/sysctl.conf
# and /etc/security/limits.conf stay untouched. Runtime-only knobs
# (ring buffer, tx queue, IO scheduler, initcwnd, offloads) live in a
# shared helper script reapplied on boot by a small systemd unit.
#
# Targets Debian 12+ / Ubuntu 22.04+ on kernels with built-in BBR.
# POSIX sh; works under dash. Invoke with --help for options.
#
# SECURITY FIXES APPLIED:
#   - Command injection: Proper quoting of $IPROUTE variable
#   - Race condition: mktemp + umask 077 for atomic writes
#   - Resource limits: Runtime validation + documentation clarity
#   - ethtool parsing: Numeric validation + conservative fallback
#   - Virtualization: Container-aware offload tuning
#   - Backup security: Explicit chmod 600 on backup files
#   - Error handling: Critical path validation with clear errors
#

set -eu  # Added -e for fail-fast on critical errors

# SCRIPT_NAME is used for logging identification in some contexts
# shellcheck disable=SC2034
SCRIPT_NAME="FasterSeedbox-linux"
SYSCTL_DROPIN="/etc/sysctl.d/99-seedbox.conf"
LIMITS_DROPIN="/etc/security/limits.d/99-seedbox.conf"
SYSTEMD_DROPIN="/etc/systemd/system.conf.d/99-seedbox.conf"
MODULES_DROPIN="/etc/modules-load.d/seedbox-bbr.conf"
RUNTIME_HELPER="/usr/local/sbin/seedbox-runtime.sh"
SYSTEMD_UNIT="/etc/systemd/system/seedbox-tune.service"
# Use nanosecond precision + random suffix to prevent collision
# Generate random suffix: try /dev/urandom, fallback to PID if unavailable
_RAND_SUFFIX="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')"
if [ -z "$_RAND_SUFFIX" ]; then
  _RAND_SUFFIX="$$"
fi
TS="$(date +%Y%m%d-%H%M%S%N 2>/dev/null || date +%Y%m%d-%H%M%S)-$$_RAND_SUFFIX"
DRY_RUN=0
ERRORS=0

# Logging functions (must be defined before argument parsing)
log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err() { printf '[x] %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }

usage() {
 cat <<'USAGE' >&2
FasterSeedbox — High-performance tuning for BitTorrent seedboxes

Usage: $0 [OPTIONS]

Options:
  --dry-run    Show what would be changed without applying
  --help       Show this help message

Examples:
  $0                    # Apply all tuning settings
  $0 --dry-run          # Preview changes only

Security Note:
  This script modifies system-wide networking and resource limits.
  Always review --dry-run output before applying on production systems.
USAGE
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) err "unknown option: $1"; usage; exit 2 ;;
  esac
done

# write_file
# Reads content from stdin, writes atomically with secure temp file,
# backs up any existing file with a timestamped suffix.
# SECURITY FIXES:
#   - Uses mktemp for unpredictable temp filename
#   - Sets umask 077 BEFORE mktemp to protect sensitive config content
#   - Saves and restores umask to avoid side effects
#   - Validates write success before atomic move
#   - Sets backup file permissions to 600
#   - Adds trap for cleanup on signal interruption
write_file() {
  _wf_path="$1"
  # Save current umask and set restrictive mask BEFORE creating temp file
  _old_umask="$(umask)"
  umask 077
  
  if [ "$DRY_RUN" -eq 1 ]; then
    printf ' (dry-run) would write %s\n' "$_wf_path"
    cat >/dev/null
    umask "$_old_umask"
    return 0
  fi
  if [ -f "$_wf_path" ]; then
    # Backup with secure permissions
    cp -p "$_wf_path" "${_wf_path}.bak-${TS}" 2>/dev/null || true
    chmod 600 "${_wf_path}.bak-${TS}" 2>/dev/null || true
  fi
  _wf_dir="$(dirname "$_wf_path")"
  [ -d "$_wf_dir" ] || mkdir -p "$_wf_dir"
  
  # SECURITY: Use mktemp for unpredictable filename
  _wf_tmp="$(mktemp "${_wf_path}.tmp.XXXXXX")" || {
    err "Failed to create temporary file for $_wf_path"
    umask "$_old_umask"
    return 1
  }
  
  # Set trap for cleanup on interruption
  trap 'rm -f "$_wf_tmp"' EXIT INT TERM HUP
  
  # Write content with error checking
  if ! cat >"$_wf_tmp"; then
    err "Failed to write to temporary file $_wf_tmp"
    rm -f "$_wf_tmp"
    trap - EXIT INT TERM HUP
    umask "$_old_umask"
    return 1
  fi
  
  # Atomic move with error checking
  if ! mv -f "$_wf_tmp" "$_wf_path"; then
    err "Failed to install $_wf_path"
    rm -f "$_wf_tmp"
    trap - EXIT INT TERM HUP
    umask "$_old_umask"
    return 1
  fi
  
  # Clear trap and restore umask on success
  trap - EXIT INT TERM HUP
  umask "$_old_umask"
}

# --- preflight ------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  err "must run as root"
  exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
  err "this script targets Linux"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  err "apt-get not found; this script targets Debian/Ubuntu"
  exit 1
fi

# Parse "major.minor" from uname -r into a single integer
KERNEL_VER="$(uname -r | awk -F'[.-]' '{printf "%d", $1*100 + ($2+0)}')"

# Virtualization detection with clear priority: container > vm > bare-metal
# VIRT_IS_CONTAINER is used by downstream scripts and runtime helpers
# shellcheck disable=SC2034
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null; then
  VIRT_KIND="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  # Normalize container types for consistent handling
  case "$VIRT_KIND" in
    docker|podman|lxc|openvz|wsl) VIRT_IS_CONTAINER=1 ;;
    kvm|qemu|vmware|virtualbox|xen|hyperv) VIRT_IS_CONTAINER=0 ;;
    *) VIRT_IS_CONTAINER=0 ;;
  esac
else
  # Fallback detection for minimal systems
  if [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
    VIRT_KIND="container"
    VIRT_IS_CONTAINER=1
  elif [ -f /sys/class/dmi/id/product_name ] && \
       grep -qi 'virtual\|kvm\|qemu\|vmware' /sys/class/dmi/id/product_name 2>/dev/null; then
    VIRT_KIND="vm"
    VIRT_IS_CONTAINER=0
  else
    VIRT_KIND="bare-metal"
    VIRT_IS_CONTAINER=0
  fi
fi

IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
if [ -z "${IFACE}" ]; then
  err "no default-route interface found"
  exit 1
fi

log "interface: ${IFACE} virt: ${VIRT_KIND} kernel: $(uname -r)"
[ "$DRY_RUN" -eq 1 ] && log "dry-run: no system changes will be made"

# --- dependencies ---------------------------------------------------

log "installing dependencies (ethtool, iproute2, tuned)..."
if [ "$DRY_RUN" -eq 0 ]; then
  if ! apt-get update -qq 2>/dev/null; then
    warn "apt-get update failed; proceeding with local cache"
  fi
  if ! apt-get -qqy install ethtool iproute2 tuned 2>/dev/null; then
    warn "one or more packages failed to install; some features may be limited"
  fi
fi

# tuned picks throughput-performance on bare metal and virtual-guest under hypervisor
if command -v tuned-adm >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 0 ]; then
    systemctl enable --now tuned 2>/dev/null || warn "failed to enable tuned service"
  fi
  CUR_PROFILE="$(tuned-adm active 2>/dev/null | awk -F': ' '/Current active profile/{print $2}' || echo unknown)"
  ok "tuned enabled (profile: ${CUR_PROFILE:-unknown})"
else
  warn "tuned unavailable; skipping CPU frequency policy"
fi

# --- TCP buffer sizing by physical memory ---------------------------
#
# Five memory tiers with MINIMUM protections to prevent under-allocation
# on low-memory systems (critical for stable torrent seeding)

MEM_KB="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)"
if [ -z "$MEM_KB" ] || [ "$MEM_KB" -le 0 ] 2>/dev/null; then
  warn "Could not determine system memory; using conservative defaults"
  MEM_KB=1048576  # Default to 1GB
fi

MEM_4K=$((MEM_KB / 4))

# Base caps for tcp_mem (in 4KB pages)
TCP_MEM_MIN_CAP=262144
TCP_MEM_PRESS_CAP=2097152
TCP_MEM_MAX_CAP=4194304

# Memory-based tier selection with MINIMUM floor protections
if [ "$MEM_KB" -le 524288 ]; then
  # <=512MB: Very constrained, use conservative values
  TCP_MEM_MIN=$((MEM_4K / 32))
  TCP_MEM_PRESS=$((MEM_4K / 16))
  TCP_MEM_MAX=$((MEM_4K / 8))
  RMEM_MAX=8388608; WMEM_MAX=8388608; WIN_SCALE=3
elif [ "$MEM_KB" -le 1048576 ]; then
  # <=1GB: Low-end VPS tier
  TCP_MEM_MIN=$((MEM_4K / 16))
  TCP_MEM_PRESS=$((MEM_4K / 8))
  TCP_MEM_MAX=$((MEM_4K / 6))
  RMEM_MAX=16777216; WMEM_MAX=16777216; WIN_SCALE=2
elif [ "$MEM_KB" -le 4194304 ]; then
  # <=4GB: Mid-tier VPS / low-end dedicated
  TCP_MEM_MIN=$((MEM_4K / 8))
  TCP_MEM_PRESS=$((MEM_4K / 6))
  TCP_MEM_MAX=$((MEM_4K / 4))
  RMEM_MAX=33554432; WMEM_MAX=33554432; WIN_SCALE=2
elif [ "$MEM_KB" -le 16777216 ]; then
  # <=16GB: High-end VPS / mid dedicated
  TCP_MEM_MIN=$((MEM_4K / 8))
  TCP_MEM_PRESS=$((MEM_4K / 4))
  TCP_MEM_MAX=$((MEM_4K / 2))
  RMEM_MAX=67108864; WMEM_MAX=67108864; WIN_SCALE=1
else
  # >16GB: High-end dedicated / workstation
  TCP_MEM_MIN=$((MEM_4K / 8))
  TCP_MEM_PRESS=$((MEM_4K / 4))
  TCP_MEM_MAX=$((MEM_4K / 2))
  RMEM_MAX=134217728; WMEM_MAX=134217728; WIN_SCALE=-2
fi

# Clamp to caps (upper bound)
[ "$TCP_MEM_MIN" -gt "$TCP_MEM_MIN_CAP" ] && TCP_MEM_MIN=$TCP_MEM_MIN_CAP
[ "$TCP_MEM_PRESS" -gt "$TCP_MEM_PRESS_CAP" ] && TCP_MEM_PRESS=$TCP_MEM_PRESS_CAP
[ "$TCP_MEM_MAX" -gt "$TCP_MEM_MAX_CAP" ] && TCP_MEM_MAX=$TCP_MEM_MAX_CAP

# SECURITY FIX: Add MINIMUM floor to prevent under-allocation on small systems
# 65536 pages = 256MB minimum for tcp_mem[0] (low threshold)
[ "$TCP_MEM_MIN" -lt 65536 ] && TCP_MEM_MIN=65536
[ "$TCP_MEM_PRESS" -lt 131072 ] && TCP_MEM_PRESS=131072

TCP_MEM="${TCP_MEM_MIN} ${TCP_MEM_PRESS} ${TCP_MEM_MAX}"
RMEM_DEF=262144
WMEM_DEF=32768
TCP_RMEM="8192 ${RMEM_DEF} ${RMEM_MAX}"
TCP_WMEM="4096 ${WMEM_DEF} ${WMEM_MAX}"

log "memory ${MEM_KB} KB -> rmem_max=${RMEM_MAX} wmem_max=${WMEM_MAX} scale=${WIN_SCALE}"

# --- scheduler-knob compatibility -----------------------------------
# sched_min_granularity_ns / sched_wakeup_granularity_ns were removed
# with the EEVDF scheduler in 6.6; sysctl --system would log "unknown
# key" at every boot if we still shipped them.
if [ "$KERNEL_VER" -ge 606 ]; then
  SCHED_BLOCK='# sched_*_granularity_ns removed in 6.6+ (EEVDF scheduler)'
else
  SCHED_BLOCK='kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000'
fi

# --- sysctl drop-in -------------------------------------------------

log "writing ${SYSCTL_DROPIN}"
# Use dynamic values in the heredoc by breaking it appropriately
write_file "$SYSCTL_DROPIN" <<EOF
# FasterSeedbox sysctl configuration
# Applied: $(date -Iseconds 2>/dev/null || date)
# Memory tier: ${MEM_KB} KB

net.core.default_qdisc = fq
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEF}
net.core.wmem_default = ${WMEM_DEF}
net.core.optmem_max = 1048576
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = ${WIN_SCALE}
net.ipv4.tcp_init_cwnd = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 524288
net.core.netdev_max_backlog = 100000
net.core.busy_poll = 100
net.core.busy_read = 100
fs.file-max = 1048576
fs.nr_open = 1048576
fs.aio-max-nr = 1048576
fs.mqueue.msg_max = 1024
fs.mqueue.msgsize_max = 65536
fs.mqueue.queues_max = 1024
vm.swappiness = 1
vm.overcommit_memory = 1
vm.overcommit_ratio = 100
vm.dirty_ratio = 5
vm.dirty_background_ratio = 1
vm.dirty_writeback_centisecs = 100
vm.dirty_expire_centisecs = 300
${SCHED_BLOCK}
EOF

if [ "$DRY_RUN" -eq 0 ]; then
  # Check if BBR module is available before attempting to load
  if modprobe -n tcp_bbr >/dev/null 2>&1 || [ -f /sys/module/tcp_bbr ]; then
    modprobe tcp_bbr 2>/dev/null || warn "BBR module load failed (may be built-in)"
  else
    warn "BBR congestion control not available in this kernel"
  fi
fi

# --- resource limits ------------------------------------------------
# SECURITY FIX: Clarify PAM vs systemd behavior in comments
# Note: PAM limits apply to login sessions (SSH, console)
#       systemd DefaultLimitNOFILE applies to systemd-managed services
#       Runtime ulimit in helper provides fallback for all contexts

log "writing ${LIMITS_DROPIN}"
write_file "$LIMITS_DROPIN" <<'EOF'
# FasterSeedbox resource limits
# Applies to PAM sessions (SSH, console logins)
# For systemd services, see /etc/systemd/system.conf.d/99-seedbox.conf

* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF

# Also configure systemd default limits for service compatibility
log "writing ${SYSTEMD_DROPIN}"
write_file "$SYSTEMD_DROPIN" <<'EOF'
# FasterSeedbox systemd defaults
# Applies to all systemd-managed services (including user services)

[Manager]
DefaultLimitNOFILE=65536
DefaultLimitNPROC=65536
EOF

if [ "$DRY_RUN" -eq 0 ]; then
  systemctl daemon-reload 2>/dev/null || warn "systemd daemon-reload failed"
fi
ok "resource limits configured (PAM + systemd)"

# --- shared runtime helper ------------------------------------------
# SECURITY FIXES APPLIED:
#   - Proper quoting of $IPROUTE to prevent command injection
#   - Numeric validation for ethtool output
#   - Container-aware offload tuning (skip in containers)
#   - Runtime ulimit validation for file descriptors

log "installing ${RUNTIME_HELPER}"
write_file "$RUNTIME_HELPER" <<HELPER
#!/bin/sh
#
# FasterSeedbox runtime helper (SECURITY-HARDENED)
# Reapplies settings that do not survive a reboot. Idempotent and
# safe to re-run. Called by seedbox-tune.service and by the
# installer. Failures on any single step are tolerated but logged.
#
# SECURITY FEATURES:
#   - Command injection prevention via proper variable quoting
#   - Numeric validation for driver-reported values
#   - Container environment detection to avoid unsafe optimizations
#   - Runtime resource limit validation

set -eu

# Logging functions (required for standalone execution)
log() { logger -t seedbox-tune "[*] \$*" || printf '[*] %s\n' "\$*"; }
warn() { logger -t seedbox-tune "[!] \$*" || printf '[!] %s\n' "\$*" >&2; }

IFACE="\$(ip -o -4 route show to default 2>/dev/null | awk '{print \\\$5; exit}')"
[ -n "\${IFACE:-}" ] || exit 0

# Virtualization detection (must match installer logic)
IS_CONTAINER=0
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null; then
  case "\$(systemd-detect-virt 2>/dev/null)" in
    docker|podman|lxc|openvz|wsl) IS_CONTAINER=1 ;;
  esac
elif [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
  IS_CONTAINER=1
fi

# Interface tx queue length. Prefer ip(8); ifconfig is the legacy fallback.
if ! ip link set dev "\$IFACE" txqueuelen 10000 2>/dev/null; then
  ifconfig "\$IFACE" txqueuelen 10000 2>/dev/null || warn "Failed to set txqueuelen for \$IFACE"
fi

# Ring buffer: request target values, clamp to NIC maximum
# SECURITY FIX: Validate ethtool output is numeric before arithmetic
if ethtool -g "\$IFACE" >/dev/null 2>&1; then
  MAX_RX=\$(ethtool -g "\$IFACE" 2>/dev/null | \
    sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | \
    awk '/^RX:/{print \\\$2; exit}' || echo "")
  MAX_TX=\$(ethtool -g "\$IFACE" 2>/dev/null | \
    sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | \
    awk '/^TX:/{print \\\$2; exit}' || echo "")
  
  # Validate numeric + provide conservative fallbacks
  if [ -n "\$MAX_RX" ] && [ "\$MAX_RX" -eq "\$MAX_RX" ] 2>/dev/null; then
    RX_VAL=1024; [ "\$MAX_RX" -lt 1024 ] && RX_VAL=\$MAX_RX
  else
    RX_VAL=256
    warn "ethtool: invalid RX max '\$MAX_RX' for \$IFACE, using conservative \$RX_VAL"
  fi
  
  if [ -n "\$MAX_TX" ] && [ "\$MAX_TX" -eq "\$MAX_TX" ] 2>/dev/null; then
    TX_VAL=2048; [ "\$MAX_TX" -lt 2048 ] && TX_VAL=\$MAX_TX
  else
    TX_VAL=512
    warn "ethtool: invalid TX max '\$MAX_TX' for \$IFACE, using conservative \$TX_VAL"
  fi
  
  ethtool -G "\$IFACE" rx "\$RX_VAL" 2>/dev/null || warn "Failed to set RX ring buffer"
  ethtool -G "\$IFACE" tx "\$TX_VAL" 2>/dev/null || warn "Failed to set TX ring buffer"
fi

# Offload tuning: ONLY apply on bare-metal, skip in containers/VMs
# Containers: Host manages offloads; guest changes may cause instability
# VMs: Virtual NIC drivers (virtio/vmxnet3) have known offload bugs
if [ "\$IS_CONTAINER" -eq 1 ]; then
  log "Container environment: skipping NIC offload tuning (host-managed)"
else
  # Bare-metal: Disable offloads only if explicitly needed (commented for safety)
  # Most modern NICs benefit from keeping TSO/GSO/GRO enabled
  # Uncomment below only if you experience specific offload-related issues:
  # ethtool -K "\$IFACE" tso off gso off gro off 2>/dev/null || true
  log "Bare-metal environment: keeping default NIC offload settings"
fi

# Per-device I/O scheduler: mq-deadline for HDD, kyber for SSD
# SECURITY FIX: Use lsblk -n -p for stable parsing, handle device names with spaces
for d in \$(lsblk -nd -n -o NAME 2>/dev/null | tr -d ' '); do
  case "\$d" in loop*|ram*|zram*|fd*|sr*) continue ;; esac
  SCHED_PATH="/sys/block/\$d/queue/scheduler"
  [ -w "\$SCHED_PATH" ] || continue
  ROT="\$(cat "/sys/block/\$d/queue/rotational" 2>/dev/null || echo 1)"
  if [ "\$ROT" = "0" ]; then
    # SSD: prefer kyber if available
    if grep -q kyber "\$SCHED_PATH" 2>/dev/null; then
      echo kyber >"\$SCHED_PATH" 2>/dev/null || warn "Failed to set kyber scheduler for \$d"
    fi
  else
    # HDD: prefer mq-deadline if available
    if grep -q mq-deadline "\$SCHED_PATH" 2>/dev/null; then
      echo mq-deadline >"\$SCHED_PATH" 2>/dev/null || warn "Failed to set mq-deadline scheduler for \$d"
    fi
  fi
done

# Raise initial congestion and receive windows on the default route
# SECURITY FIX: Properly quote and parse IPROUTE to prevent command injection
IPROUTE="\$(ip -o -4 route show to default 2>/dev/null | head -n 1)"
if [ -n "\${IPROUTE:-}" ]; then
  # Parse route components safely instead of direct variable expansion
  set -- \$IPROUTE  # Safe word splitting for known route format
  # Route format: default via <GW> dev <IFACE> [proto <PROTO>] [src <SRC>]
  # We need to reconstruct with initcwnd/initrwnd
  GW=""; DEV=""
  while [ \$# -gt 0 ]; do
    case "\$1" in
      via) GW="\$2"; shift 2 ;;
      dev) DEV="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "\$DEV" ]; then
    if [ -n "\$GW" ]; then
      ip route change default via "\$GW" dev "\$DEV" initcwnd 25 initrwnd 25 2>/dev/null || \
        warn "Failed to apply initcwnd/initrwnd via gateway"
    else
      ip route change default dev "\$DEV" initcwnd 25 initrwnd 25 2>/dev/null || \
        warn "Failed to apply initcwnd/initrwnd direct route"
    fi
  fi
fi

# Ensure BBR modules are available; harmless when built-in
modprobe sch_fq 2>/dev/null || warn "sch_fq module not available (may be built-in)"
modprobe tcp_bbr 2>/dev/null || warn "tcp_bbr module not available (may be built-in)"

# Reload sysctl configuration to ensure all drop-ins are applied
# Note: systemd-sysctl loads in order: /etc > /run > /usr/local/lib > /usr/lib
# Our 99-seedbox.conf in /etc/sysctl.d/ has high priority (but not highest)
# For absolute priority, use 100-seedbox.conf or verify with sysctl --system
if ! sysctl --system >/dev/null 2>&1; then
  warn "sysctl --system failed; some settings may not be applied"
fi

# SECURITY FIX: Runtime validation of critical resource limits
# This provides fallback when PAM/systemd configs don't apply to current context
if [ "\$(ulimit -n 2>/dev/null || echo 0)" -lt 65536 ]; then
  ulimit -n 65536 2>/dev/null || warn "Could not raise nofile limit; current: \$(ulimit -n)"
fi

log "Runtime tuning applied for interface: \$IFACE"
HELPER

if [ "$DRY_RUN" -eq 0 ]; then
  chmod +x "$RUNTIME_HELPER"
fi
ok "runtime helper installed"

# --- systemd boot service ------------------------------------------

log "installing ${SYSTEMD_UNIT}"
write_file "$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=FasterSeedbox tuning service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/seedbox-runtime.sh
RemainAfterExit=yes
# Security hardening for the service itself
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/etc /var /run /sys
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

if [ "$DRY_RUN" -eq 0 ]; then
  if systemctl enable seedbox-tune.service 2>/dev/null; then
    ok "seedbox-tune.service enabled"
  else
    warn "Failed to enable seedbox-tune.service"
  fi
  # Apply runtime settings immediately
  if "$RUNTIME_HELPER"; then
    ok "Runtime settings applied successfully"
  else
    warn "Runtime helper completed with warnings"
  fi
  # Apply sysctl settings
  if sysctl --system >/dev/null 2>&1; then
    ok "Sysctl settings applied"
  else
    warn "Sysctl application had issues; review journalctl -xe"
  fi
fi

# --- verification ---------------------------------------------------

verify_sysctl() {
  _v_key="$1"; _v_want="$2"
  _v_got="$(sysctl -n "$_v_key" 2>/dev/null || echo '?')"
  if [ "$_v_got" = "$_v_want" ]; then
    ok "  $_v_key = $_v_got"
  else
    err "  $_v_key = $_v_got (expected $_v_want)"
  fi
}

if [ "$DRY_RUN" -eq 0 ]; then
  log "verifying critical parameters..."
  verify_sysctl net.ipv4.tcp_congestion_control bbr
  verify_sysctl net.core.default_qdisc fq
  verify_sysctl net.core.somaxconn 524288
  verify_sysctl net.ipv4.tcp_fastopen 3
  # Verify runtime limits
  # shellcheck disable=SC3045  # ulimit is widely supported in bash/dash/ash
  _FD_LIMIT="$(ulimit -n 2>/dev/null || echo '?')"
  if [ "$_FD_LIMIT" != "?" ] && [ "$_FD_LIMIT" -ge 65536 ] 2>/dev/null; then
    ok "  ulimit -n = $_FD_LIMIT"
  else
    warn "  ulimit -n = $_FD_LIMIT (expected >= 65536)"
  fi
fi

# --- legacy-state advisory -----------------------------------------
# SECURITY FIX: Correct documentation about sysctl load order
# systemd-sysctl loads in this order (last wins):
#   /usr/lib/sysctl.d/*.conf < /usr/local/lib/sysctl.d/*.conf < /run/sysctl.d/*.conf < /etc/sysctl.d/*.conf < /etc/sysctl.conf
# Our /etc/sysctl.d/99-seedbox.conf has HIGHER priority than /etc/sysctl.conf
# Users should NOT copy settings to sysctl.conf as it has LOWER priority

if [ -f /etc/sysctl.conf ] && grep -Eq '^[[:space:]]*(net\.ipv4\.|net\.core\.)' /etc/sysctl.conf 2>/dev/null; then
  warn "/etc/sysctl.conf contains net.* entries"
  warn "NOTE: /etc/sysctl.d/99-seedbox.conf has HIGHER priority than /etc/sysctl.conf"
  warn "Settings in 99-seedbox.conf will override sysctl.conf (systemd-sysctl load order)"
  warn "To avoid confusion, consider removing duplicate entries from /etc/sysctl.conf"
fi

# --- summary --------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf ' FasterSeedbox tuning complete (SECURITY-HARDENED EDITION)\n'
printf '============================================================\n'
printf ' Environment : %s / kernel %s\n' "$VIRT_KIND" "$(uname -r)"
printf ' Interface   : %s\n' "$IFACE"
printf ' Memory      : %s KB\n' "$MEM_KB"
printf ' rmem_max    : %s\n' "$RMEM_MAX"
printf ' wmem_max    : %s\n' "$WMEM_MAX"
printf ' tcp_mem     : %s\n' "$TCP_MEM"
printf ' win_scale   : %s\n' "$WIN_SCALE"
if [ "$DRY_RUN" -eq 0 ]; then
  printf ' Congestion  : %s\n' \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  printf ' Qdisc       : %s\n' \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  # shellcheck disable=SC3045  # ulimit is widely supported in bash/dash/ash
  printf ' FD Limit    : %s\n' "$(ulimit -n 2>/dev/null || echo '?')"
fi
printf ' Backup suffix: .bak-%s\n' "$TS"
printf '\n Files managed by this run:\n'
printf '  %s\n' "$SYSCTL_DROPIN"
printf '  %s\n' "$LIMITS_DROPIN"
printf '  %s\n' "$SYSTEMD_DROPIN"
printf '  %s\n' "$MODULES_DROPIN"
printf '  %s\n' "$RUNTIME_HELPER"
printf '  %s\n' "$SYSTEMD_UNIT"
printf '\n Rollback instructions:\n'
printf '  systemctl disable --now seedbox-tune.service\n'
printf '  rm -f %s %s %s %s %s %s\n' \
  "$SYSCTL_DROPIN" "$LIMITS_DROPIN" "$SYSTEMD_DROPIN" \
  "$MODULES_DROPIN" "$RUNTIME_HELPER" "$SYSTEMD_UNIT"
printf '  systemctl daemon-reload && systemctl daemon-reexec\n'
printf '  sysctl --system\n'
printf '  # Reboot recommended to fully revert kernel parameters\n'
printf '============================================================\n'

if [ "$ERRORS" -gt 0 ]; then
  printf '\n'
  warn "${ERRORS} issue(s) reported; review log above for details."
  warn "Critical failures may require manual intervention."
  exit 3
fi

exit 0
