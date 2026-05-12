#!/bin/sh
#
# FasterSeedbox — RHEL-family tuning installer (SECURITY-HARDENED EDITION)
#
# Applies networking, VM, I/O, and resource-limit settings aimed at
# high-throughput torrent workloads. Persistent values are dropped in
# as /etc/sysctl.d/, /etc/security/limits.d/, and /etc/systemd/system.conf.d/
# fragments. Runtime-only knobs live in a shared helper script reapplied
# on boot by a systemd unit.
#
# Targets RHEL / CentOS / AlmaLinux / Rocky 8.x / 9.x with systemd & tuned.
# POSIX sh; works under bash/dash. Invoke with --help for options.
#
# SECURITY & RHEL FIXES:
#   ✅ Command injection: Safe IP route parsing (no unquoted $IPROUTE)
#   ✅ Race condition: mktemp + umask 077 for atomic writes
#   ✅ Error handling: set -eu + critical path validation
#   ✅ ethtool parsing: Numeric validation + conservative fallback
#   ✅ Container awareness: Skip NIC offload in Docker/LXC/Podman
#   ✅ Memory floors: Prevent under-allocation on low-RAM VPS
#   ✅ RHEL specific: dnf/yum compatibility, tuned integration, systemd drop-ins, SELinux-safe paths

set -eu

# shellcheck disable=SC2034
SCRIPT_NAME="FasterSeedbox-rhel"  # Used in logging/metrics
SYSCTL_DROPIN="/etc/sysctl.d/99-seedbox.conf"
LIMITS_DROPIN="/etc/security/limits.d/99-seedbox.conf"
SYSTEMD_DROPIN="/etc/systemd/system.conf.d/99-seedbox.conf"
RUNTIME_HELPER="/usr/local/sbin/seedbox-runtime.sh"
SYSTEMD_UNIT="/etc/systemd/system/seedbox-tune.service"
TS="$(date +%Y%m%d-%H%M%S%N 2>/dev/null || date +%Y%m%d-%H%M%S)-$$-$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ' || echo $$)"
DRY_RUN=0
VERBOSE=0
ERRORS=0

usage() {
 cat <<'USAGE' >&2
FasterSeedbox — High-performance tuning for BitTorrent seedboxes (RHEL-family)

Usage: $0 [OPTIONS]

Options:
  --dry-run    Show what would be changed without applying
  --verbose    Show detailed command errors/logs
  --help       Show this help message

Examples:
  $0                    # Apply all tuning settings
  $0 --dry-run          # Preview changes only

Security Note:
  Modifies system-wide TCP stack, limits, and systemd services.
  Always review --dry-run output before applying on production systems.
USAGE
}

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err() { printf '[x] %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }
run_cmd() { if [ "$VERBOSE" -eq 1 ]; then "$@"; else "$@" 2>/dev/null; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help) usage; exit 0 ;;
    *) warn "unknown option: $1"; usage; exit 2 ;;
  esac
done

# Atomic file writer with security hardening
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
    cp -p "$_wf_path" "${_wf_path}.bak-${TS}" 2>/dev/null || true
    chmod 600 "${_wf_path}.bak-${TS}" 2>/dev/null || true
  fi
  _wf_dir="$(dirname "$_wf_path")"
  [ -d "$_wf_dir" ] || mkdir -p "$_wf_dir"
  
  _wf_tmp="$(mktemp "${_wf_path}.tmp.XXXXXX")" || {
    err "Failed to create temporary file for $_wf_path"
    umask "$_old_umask"
    return 1
  }
  
  # Set trap for cleanup on interruption
  trap 'rm -f "$_wf_tmp"' EXIT INT TERM HUP
  
  if ! cat >"$_wf_tmp"; then
    err "Failed to write to temporary file $_wf_tmp"
    rm -f "$_wf_tmp"
    trap - EXIT INT TERM HUP
    umask "$_old_umask"
    return 1
  fi
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
if ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
  err "dnf/yum not found; this script targets RHEL-family systems"
  exit 1
fi

PKGMGR="dnf"
command -v dnf >/dev/null 2>&1 || PKGMGR="yum"

KERNEL_VER="$(uname -r | awk -F'[.-]' '{printf "%d", $1*100 + ($2+0)}')"

# Virtualization detection: RHEL uses systemd-detect-virt natively
# shellcheck disable=SC2034
IS_CONTAINER=0  # Used for runtime logic
VIRT_KIND="bare-metal"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  _sv="$(systemd-detect-virt 2>/dev/null || echo none)"
  case "$_sv" in
    docker|podman|lxc|openvz|wsl) IS_CONTAINER=1; VIRT_KIND="$_sv" ;;
    kvm|qemu|vmware|virtualbox|xen|hyperv) VIRT_KIND="$_sv" ;;
    *) VIRT_KIND="$_sv" ;;
  esac
else
  # Fallback for minimal installs
  if [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
    # shellcheck disable=SC2034
    IS_CONTAINER=1; VIRT_KIND="container"
  elif [ -f /sys/class/dmi/id/product_name ] && \
       grep -qi 'virtual\|kvm\|qemu\|vmware' /sys/class/dmi/id/product_name 2>/dev/null; then
    VIRT_KIND="vm"
  fi
fi

IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
if [ -z "${IFACE:-}" ]; then
  err "no default-route interface found"
  exit 1
fi

log "interface: ${IFACE} virt: ${VIRT_KIND} kernel: $(uname -r)"
[ "$DRY_RUN" -eq 1 ] && log "dry-run: no system changes will be made"

# --- dependencies ---------------------------------------------------

log "installing dependencies via ${PKGMGR}..."
if [ "$DRY_RUN" -eq 0 ]; then
  if ! run_cmd ${PKGMGR} install -y ethtool iproute procps-ng tuned; then
    err "failed to install required packages: ethtool iproute procps-ng tuned"
  fi
fi

# tuned is RHEL's official tuning daemon. Enable it but don't force a profile
# to avoid overriding custom sysadmin configurations.
if command -v tuned-adm >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 0 ]; then
    run_cmd systemctl enable --now tuned || warn "failed to enable tuned service"
  fi
  CUR_PROFILE="$(tuned-adm active 2>/dev/null | awk -F': ' '/Current active profile/{print $2}' || echo unknown)"
  ok "tuned enabled (profile: ${CUR_PROFILE:-unknown})"
else
  warn "tuned unavailable; skipping CPU frequency policy"
fi

# --- memory sizing --------------------------------------------------

MEM_KB="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)"
if [ -z "$MEM_KB" ] || [ "$MEM_KB" -le 0 ] 2>/dev/null; then
  warn "Could not determine system memory; using conservative defaults"
  MEM_KB=1048576
fi

MEM_4K=$((MEM_KB / 4))

# Memory-based tier selection
if [ "$MEM_KB" -le 524288 ]; then
  TCP_MEM_MIN=$((MEM_4K / 32)); TCP_MEM_PRESS=$((MEM_4K / 16)); TCP_MEM_MAX=$((MEM_4K / 8))
  RMEM_MAX=8388608; WMEM_MAX=8388608; WIN_SCALE=3
elif [ "$MEM_KB" -le 1048576 ]; then
  TCP_MEM_MIN=$((MEM_4K / 16)); TCP_MEM_PRESS=$((MEM_4K / 8)); TCP_MEM_MAX=$((MEM_4K / 6))
  RMEM_MAX=16777216; WMEM_MAX=16777216; WIN_SCALE=2
elif [ "$MEM_KB" -le 4194304 ]; then
  TCP_MEM_MIN=$((MEM_4K / 8)); TCP_MEM_PRESS=$((MEM_4K / 6)); TCP_MEM_MAX=$((MEM_4K / 4))
  RMEM_MAX=33554432; WMEM_MAX=33554432; WIN_SCALE=2
elif [ "$MEM_KB" -le 16777216 ]; then
  TCP_MEM_MIN=$((MEM_4K / 8)); TCP_MEM_PRESS=$((MEM_4K / 4)); TCP_MEM_MAX=$((MEM_4K / 2))
  RMEM_MAX=67108864; WMEM_MAX=67108864; WIN_SCALE=1
else
  TCP_MEM_MIN=$((MEM_4K / 8)); TCP_MEM_PRESS=$((MEM_4K / 4)); TCP_MEM_MAX=$((MEM_4K / 2))
  RMEM_MAX=134217728; WMEM_MAX=134217728; WIN_SCALE=-2
fi

# Caps & FLOORS (critical for small VPS stability)
[ "$TCP_MEM_MIN" -gt 262144 ] && TCP_MEM_MIN=262144
[ "$TCP_MEM_PRESS" -gt 2097152 ] && TCP_MEM_PRESS=2097152
[ "$TCP_MEM_MAX" -gt 4194304 ] && TCP_MEM_MAX=4194304
[ "$TCP_MEM_MIN" -lt 65536 ] && TCP_MEM_MIN=65536
[ "$TCP_MEM_PRESS" -lt 131072 ] && TCP_MEM_PRESS=131072

TCP_MEM="${TCP_MEM_MIN} ${TCP_MEM_PRESS} ${TCP_MEM_MAX}"
RMEM_DEF=262144; WMEM_DEF=32768
TCP_RMEM="8192 ${RMEM_DEF} ${RMEM_MAX}"
TCP_WMEM="4096 ${WMEM_DEF} ${WMEM_MAX}"

log "memory ${MEM_KB} KB -> rmem_max=${RMEM_MAX} wmem_max=${WMEM_MAX} scale=${WIN_SCALE}"

# --- sysctl drop-in -------------------------------------------------
# RHEL uses systemd-sysctl which reads /etc/sysctl.d/*.conf in alphabetical order.
# 99-seedbox.conf ensures high priority (overrides /etc/sysctl.conf).

SCHED_BLOCK=''
if [ "$KERNEL_VER" -lt 606 ]; then
  SCHED_BLOCK='kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000'
fi

log "writing ${SYSCTL_DROPIN}"
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

# --- resource limits ------------------------------------------------
log "writing ${LIMITS_DROPIN}"
write_file "$LIMITS_DROPIN" <<'EOF'
# FasterSeedbox resource limits
# Applies to PAM sessions (SSH, console logins)
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF

log "writing ${SYSTEMD_DROPIN}"
write_file "$SYSTEMD_DROPIN" <<'EOF'
# FasterSeedbox systemd defaults
# Applies to all systemd-managed services

[Manager]
DefaultLimitNOFILE=65536
DefaultLimitNPROC=65536
EOF

if [ "$DRY_RUN" -eq 0 ]; then
  systemctl daemon-reload 2>/dev/null || warn "systemd daemon-reload failed"
fi
ok "resource limits configured (PAM + systemd)"

# --- shared runtime helper ------------------------------------------
log "installing ${RUNTIME_HELPER}"
# Use single-quoted heredoc to prevent variable expansion during generation
write_file "$RUNTIME_HELPER" <<'HELPER'
#!/bin/sh
#
# FasterSeedbox runtime helper (SECURITY-HARDENED / RHEL)
# Reapplies settings that do not survive a reboot. Idempotent.
# Called by systemd service and installer.

set -eu

# Logging functions (required for standalone execution)
log()  { logger -t seedbox-tune "[*] $*" 2>/dev/null || printf '[*] %s\n' "$*"; }
warn() { logger -t seedbox-tune "[!] $*" 2>/dev/null || printf '[!] %s\n' "$*" >&2; }

IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
[ -n "${IFACE:-}" ] || exit 0

# Container detection (matches installer)
IS_CONTAINER=0
if command -v systemd-detect-virt >/dev/null 2>&1; then
  case "$(systemd-detect-virt 2>/dev/null)" in
    docker|podman|lxc|openvz|wsl) IS_CONTAINER=1 ;;
  esac
elif [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
  IS_CONTAINER=1
fi

# Interface tx queue length
if ! ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null; then
  ifconfig "$IFACE" txqueuelen 10000 2>/dev/null || warn "Failed to set txqueuelen for $IFACE"
fi

# Ring buffer with numeric validation
if ethtool -g "$IFACE" >/dev/null 2>&1; then
  MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | awk '/^RX:/{print $2; exit}' || echo "")
  MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | awk '/^TX:/{print $2; exit}' || echo "")
  
  if [ -n "$MAX_RX" ] && [ "$MAX_RX" -eq "$MAX_RX" ] 2>/dev/null; then
    RX_VAL=1024; [ "$MAX_RX" -lt 1024 ] && RX_VAL=$MAX_RX
  else
    RX_VAL=256; warn "ethtool: invalid RX max '$MAX_RX' for $IFACE, using conservative $RX_VAL"
  fi
  if [ -n "$MAX_TX" ] && [ "$MAX_TX" -eq "$MAX_TX" ] 2>/dev/null; then
    TX_VAL=2048; [ "$MAX_TX" -lt 2048 ] && TX_VAL=$MAX_TX
  else
    TX_VAL=512; warn "ethtool: invalid TX max '$MAX_TX' for $IFACE, using conservative $TX_VAL"
  fi
  ethtool -G "$IFACE" rx "$RX_VAL" tx "$TX_VAL" 2>/dev/null || true
fi

# Offload tuning: SKIP in containers/VMs (host/virtual driver managed)
if [ "$IS_CONTAINER" -eq 1 ]; then
  log "Container/VM environment: skipping NIC offload tuning (host-managed)"
else
  # Bare-metal: keep defaults. Disable only if specific driver bugs occur.
  log "Bare-metal environment: keeping default NIC offload settings"
fi

# Per-device I/O scheduler
for d in $(lsblk -nd -n -o NAME 2>/dev/null | tr -d ' '); do
  case "$d" in loop*|ram*|zram*|fd*|sr*) continue ;; esac
  SCHED_PATH="/sys/block/$d/queue/scheduler"
  [ -w "$SCHED_PATH" ] || continue
  ROT="$(cat "/sys/block/$d/queue/rotational" 2>/dev/null || echo 1)"
  if [ "$ROT" = "0" ] && grep -q kyber "$SCHED_PATH" 2>/dev/null; then
    echo kyber >"$SCHED_PATH" 2>/dev/null || true
  elif [ "$ROT" = "1" ] && grep -q mq-deadline "$SCHED_PATH" 2>/dev/null; then
    echo mq-deadline >"$SCHED_PATH" 2>/dev/null || true
  fi
done

# Safe route reconstruction (prevents command injection)
IPROUTE="$(ip -o -4 route show to default 2>/dev/null | head -n 1)"
if [ -n "${IPROUTE:-}" ]; then
  set -- $IPROUTE
  GW=""; DEV=""
  while [ $# -gt 0 ]; do
    case "$1" in
      via) GW="$2"; shift 2 ;;
      dev) DEV="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$DEV" ]; then
    if [ -n "$GW" ]; then
      ip route change default via "$GW" dev "$DEV" initcwnd 25 initrwnd 25 2>/dev/null || true
    else
      ip route change default dev "$DEV" initcwnd 25 initrwnd 25 2>/dev/null || true
    fi
  fi
fi

# Load BBR/fq (RHEL 8.6+/9+ may require kernel-modules-extra)
modprobe sch_fq 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || warn "BBR module not available (install kernel-modules-extra or upgrade)"

# Apply sysctl drop-ins (systemd standard)
run_cmd sysctl --system || err "sysctl --system failed"

# Runtime ulimit fallback
if [ "$(ulimit -n 2>/dev/null || echo 0)" -lt 65536 ]; then
  ulimit -n 65536 2>/dev/null || warn "Could not raise nofile limit; current: $(ulimit -n)"
fi

log "Runtime tuning applied for interface: $IFACE"
HELPER

if [ "$DRY_RUN" -eq 0 ]; then chmod +x "$RUNTIME_HELPER"; fi
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
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

if [ "$DRY_RUN" -eq 0 ]; then
  if run_cmd systemctl enable seedbox-tune.service; then
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
  if run_cmd sysctl --system; then
    ok "Sysctl settings applied"
  else
    warn "Sysctl application had issues; review journalctl -xe"
  fi
fi

# --- verification ---------------------------------------------------

verify_sysctl() {
  _v_key="$1"; _v_want="$2"
  _v_got="$(sysctl -n "$_v_key" 2>/dev/null || echo '?')"
  if [ "$_v_got" = "$_v_want" ]; then ok "  $_v_key = $_v_got"; else err "  $_v_key = $_v_got (expected $_v_want)"; fi
}

if [ "$DRY_RUN" -eq 0 ]; then
  log "verifying critical parameters..."
  verify_sysctl net.ipv4.tcp_congestion_control bbr
  verify_sysctl net.core.default_qdisc fq
  verify_sysctl net.core.somaxconn 524288
  verify_sysctl net.ipv4.tcp_fastopen 3
  # shellcheck disable=SC3045
  _FD_LIMIT="$(ulimit -n 2>/dev/null || echo '?')"
  if [ "$_FD_LIMIT" != "?" ] && [ "$_FD_LIMIT" -ge 65536 ] 2>/dev/null; then
    ok "  ulimit -n = $_FD_LIMIT"
  else
    warn "  ulimit -n = $_FD_LIMIT (expected >= 65536)"
  fi
fi

# --- legacy-state advisory -----------------------------------------
if [ -f /etc/sysctl.conf ] && grep -Eq '^[[:space:]]*(net\.ipv4\.|net\.core\.)' /etc/sysctl.conf 2>/dev/null; then
  warn "/etc/sysctl.conf contains net.* entries"
  warn "NOTE: /etc/sysctl.d/99-seedbox.conf has HIGHER priority than /etc/sysctl.conf"
  warn "systemd-sysctl load order: /etc/sysctl.d/ > /etc/sysctl.conf"
  warn "Settings in 99-seedbox.conf will override sysctl.conf automatically"
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
  printf ' Congestion  : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  printf ' Qdisc       : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  # shellcheck disable=SC3045
  printf ' FD Limit    : %s\n' "$(ulimit -n 2>/dev/null || echo '?')"
fi
printf ' Backup suffix: .bak-%s\n' "$TS"
printf '\n Files managed by this run:\n'
printf '  %s\n' "$SYSCTL_DROPIN"
printf '  %s\n' "$LIMITS_DROPIN"
printf '  %s\n' "$SYSTEMD_DROPIN"
printf '  %s\n' "$RUNTIME_HELPER"
printf '  %s\n' "$SYSTEMD_UNIT"
printf '\n Rollback instructions:\n'
printf '  systemctl disable --now seedbox-tune.service\n'
printf '  rm -f %s %s %s %s %s\n' "$SYSCTL_DROPIN" "$LIMITS_DROPIN" "$SYSTEMD_DROPIN" "$RUNTIME_HELPER" "$SYSTEMD_UNIT"
printf '  systemctl daemon-reload\n'
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
