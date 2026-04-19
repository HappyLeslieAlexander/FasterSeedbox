#!/bin/sh
#
# FasterSeedbox — Alpine Linux tuning installer.
#
# Applies networking, VM, I/O, and resource-limit settings aimed at
# high-throughput torrent workloads. Persistent values are dropped
# in as /etc/sysctl.d/, /etc/security/limits.d/, /etc/modules, and
# /etc/rc.conf fragments so base configuration files stay intact.
# Runtime-only knobs (ring buffer, tx queue, IO scheduler, initcwnd,
# offloads) live in a shared helper script reapplied on boot by a
# small OpenRC service.
#
# Targets Alpine 3.19+ on kernels with built-in BBR (linux-lts 6.1+
# or linux-virt). Differs from the Debian/Ubuntu installer in three
# main ways:
#
#   1. OpenRC replaces systemd for the boot service and for service
#      resource limits (rc_ulimit in /etc/rc.conf). Alpine ships no
#      equivalent to systemd's DefaultLimitNOFILE.
#   2. PAM is optional on Alpine. /etc/security/limits.d is written
#      defensively (it takes effect only when PAM is installed); the
#      rc_ulimit path covers OpenRC-supervised daemons regardless.
#   3. Virtualization is detected from /proc/cpuinfo, DMI, and
#      /proc/1/environ since systemd-detect-virt is unavailable.
#
# POSIX sh; works under dash and busybox ash. Invoke with --help
# for options.
#

set -u

SCRIPT_NAME="FasterSeedbox-alpine"
SYSCTL_DROPIN="/etc/sysctl.d/99-seedbox.conf"
LIMITS_DROPIN="/etc/security/limits.d/99-seedbox.conf"
MODULES_FILE="/etc/modules"
RCCONF="/etc/rc.conf"
RUNTIME_HELPER="/usr/local/sbin/seedbox-runtime.sh"
OPENRC_UNIT="/etc/init.d/seedbox-tune"
RCCONF_MARKER="# --- FasterSeedbox rc_ulimit ---"
MODULES_MARKER="# --- FasterSeedbox modules ---"
TS="$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
ERRORS=0

usage() {
    cat <<EOF
${SCRIPT_NAME}

Usage: $0 [--dry-run] [--help]

  --dry-run   Show every file that would be written or modified, but
              do not touch the system.
  --help      Print this message and exit.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --help|-h)  usage; exit 0 ;;
        *)          printf 'Unknown option: %s\n\n' "$arg" >&2
                    usage >&2; exit 2 ;;
    esac
done

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
err()  { printf '[x] %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }

# write_file <path>
# Reads content from stdin, writes atomically, backs up any existing
# file with a timestamped suffix. Obeys DRY_RUN by consuming and
# discarding stdin.
write_file() {
    _wf_path="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    (dry-run) would write %s\n' "$_wf_path"
        cat >/dev/null
        return 0
    fi
    if [ -f "$_wf_path" ]; then
        cp -p "$_wf_path" "${_wf_path}.bak-${TS}" 2>/dev/null || true
    fi
    _wf_dir="$(dirname "$_wf_path")"
    [ -d "$_wf_dir" ] || mkdir -p "$_wf_dir"
    _wf_tmp="${_wf_path}.tmp.$$"
    cat >"$_wf_tmp"
    mv "$_wf_tmp" "$_wf_path"
}

# append_once <path> <marker>
# Appends stdin to the given file only when the marker string is not
# already present (idempotent). Also honors DRY_RUN. Used for edits
# to /etc/rc.conf and /etc/modules where rewriting the whole file
# would clobber unrelated entries.
append_once() {
    _ao_path="$1"; _ao_marker="$2"
    if [ ! -f "$_ao_path" ]; then
        warn "${_ao_path} does not exist; skipping append"
        cat >/dev/null
        return 0
    fi
    if grep -Fq "$_ao_marker" "$_ao_path" 2>/dev/null; then
        log "${_ao_path} already contains '${_ao_marker}', skipping"
        cat >/dev/null
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    (dry-run) would append block marked %s to %s\n' \
               "'${_ao_marker}'" "$_ao_path"
        cat >/dev/null
        return 0
    fi
    cp -p "$_ao_path" "${_ao_path}.bak-${TS}" 2>/dev/null || true
    cat >>"$_ao_path"
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

if ! command -v apk >/dev/null 2>&1; then
    err "apk not found; this script targets Alpine Linux"
    exit 1
fi

if [ ! -f /etc/alpine-release ]; then
    err "/etc/alpine-release not found; not an Alpine system"
    exit 1
fi

ALPINE_VER="$(cat /etc/alpine-release 2>/dev/null || echo unknown)"

# Parse "major.minor" from uname -r into a single integer (major*100
# + minor) so version gates like "is this 6.6 or newer" become plain
# arithmetic. awk's "+0" coerces missing minor components to zero.
KERNEL_VER="$(uname -r | awk -F'[.-]' '{printf "%d", $1*100 + ($2+0)}')"

# Alpine has no systemd-detect-virt. Try virt-what first (only
# available if the user installed it from the community repo), then
# fall back to the "hypervisor" CPU flag plus DMI product_name for
# vendor identification, plus explicit container markers.
VIRT_KIND="none"
if command -v virt-what >/dev/null 2>&1; then
    _vw="$(virt-what 2>/dev/null | head -n 1)"
    [ -n "$_vw" ] && VIRT_KIND="$_vw"
fi
if [ "$VIRT_KIND" = "none" ] \
     && grep -q 'hypervisor' /proc/cpuinfo 2>/dev/null; then
    if [ -r /sys/class/dmi/id/product_name ]; then
        _prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
        case "$_prod" in
            *KVM*)                VIRT_KIND="kvm" ;;
            *VMware*)             VIRT_KIND="vmware" ;;
            *VirtualBox*)         VIRT_KIND="oracle" ;;
            *QEMU*|*Bochs*)       VIRT_KIND="qemu" ;;
            *"Virtual Machine"*)  VIRT_KIND="microsoft" ;;
            *)                    VIRT_KIND="vm" ;;
        esac
    else
        VIRT_KIND="vm"
    fi
fi
# Container markers override bare-metal/vm classification. /.dockerenv
# is created by the Docker engine; /proc/1/environ's container= is
# set by LXC, Podman, and systemd-nspawn. Matching hides bytes after
# the marker (grep -a).
if [ -f /.dockerenv ]; then
    VIRT_KIND="docker"
fi
if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
    VIRT_KIND="lxc"
fi
# Note: the runtime helper performs its own, equivalent detection at
# boot time (see HELPER block below). The VIRT_KIND value here is
# used only for the installer's banner and log lines.

IFACE="$(ip -o -4 route show to default 2>/dev/null \
         | awk '{print $5; exit}')"
if [ -z "${IFACE}" ]; then
    # BusyBox ip does not implement -o; fall back to `ip route` plain
    # output, which is the same first token on the default line.
    IFACE="$(ip -4 route show default 2>/dev/null \
             | awk '/^default/{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
fi
if [ -z "${IFACE}" ]; then
    err "no default-route interface found"
    exit 1
fi

log "alpine: ${ALPINE_VER}   kernel: $(uname -r)   virt: ${VIRT_KIND}"
log "interface: ${IFACE}"
[ "$DRY_RUN" -eq 1 ] && log "dry-run: no system changes will be made"

# --- dependencies ---------------------------------------------------
# BusyBox ships minimal variants of these tools; we need the full
# versions for ethtool(8), `ip -o`, `lsblk -o`, `sysctl --system`, and
# proper module dependency resolution via modprobe.

log "installing dependencies (ethtool, iproute2, util-linux, procps, kmod)..."
if [ "$DRY_RUN" -eq 0 ]; then
    apk update -q \
        || warn "apk update failed; proceeding with local cache"
    apk add -q --no-progress \
        ethtool iproute2 util-linux procps kmod \
        || warn "one or more packages failed to install"
fi

# --- TCP buffer sizing by physical memory ---------------------------
#
# Five memory tiers (<=512M, <=1G, <=4G, <=16G, >16G) pick appropriate
# rmem_max/wmem_max and tcp_adv_win_scale. tcp_mem is expressed in
# 4 KiB pages and capped so very-large-memory hosts do not pin
# gigabytes to TCP state.

MEM_KB="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)"
MEM_4K=$((MEM_KB / 4))

TCP_MEM_MIN_CAP=262144
TCP_MEM_PRESS_CAP=2097152
TCP_MEM_MAX_CAP=4194304

if   [ "$MEM_KB" -le 524288 ]; then
    TCP_MEM_MIN=$((MEM_4K / 32))
    TCP_MEM_PRESS=$((MEM_4K / 16))
    TCP_MEM_MAX=$((MEM_4K / 8))
    RMEM_MAX=8388608;   WMEM_MAX=8388608;   WIN_SCALE=3
elif [ "$MEM_KB" -le 1048576 ]; then
    TCP_MEM_MIN=$((MEM_4K / 16))
    TCP_MEM_PRESS=$((MEM_4K / 8))
    TCP_MEM_MAX=$((MEM_4K / 6))
    RMEM_MAX=16777216;  WMEM_MAX=16777216;  WIN_SCALE=2
elif [ "$MEM_KB" -le 4194304 ]; then
    TCP_MEM_MIN=$((MEM_4K / 8))
    TCP_MEM_PRESS=$((MEM_4K / 6))
    TCP_MEM_MAX=$((MEM_4K / 4))
    RMEM_MAX=33554432;  WMEM_MAX=33554432;  WIN_SCALE=2
elif [ "$MEM_KB" -le 16777216 ]; then
    TCP_MEM_MIN=$((MEM_4K / 8))
    TCP_MEM_PRESS=$((MEM_4K / 4))
    TCP_MEM_MAX=$((MEM_4K / 2))
    RMEM_MAX=67108864;  WMEM_MAX=67108864;  WIN_SCALE=1
else
    TCP_MEM_MIN=$((MEM_4K / 8))
    TCP_MEM_PRESS=$((MEM_4K / 4))
    TCP_MEM_MAX=$((MEM_4K / 2))
    RMEM_MAX=134217728; WMEM_MAX=134217728; WIN_SCALE=-2
fi

# POSIX arithmetic has no '?:' ternary, so clamp component-by-component.
[ "$TCP_MEM_MIN"   -gt "$TCP_MEM_MIN_CAP"   ] && TCP_MEM_MIN=$TCP_MEM_MIN_CAP
[ "$TCP_MEM_PRESS" -gt "$TCP_MEM_PRESS_CAP" ] && TCP_MEM_PRESS=$TCP_MEM_PRESS_CAP
[ "$TCP_MEM_MAX"   -gt "$TCP_MEM_MAX_CAP"   ] && TCP_MEM_MAX=$TCP_MEM_MAX_CAP

TCP_MEM="${TCP_MEM_MIN} ${TCP_MEM_PRESS} ${TCP_MEM_MAX}"
RMEM_DEF=262144
WMEM_DEF=32768
TCP_RMEM="8192 ${RMEM_DEF} ${RMEM_MAX}"
TCP_WMEM="4096 ${WMEM_DEF} ${WMEM_MAX}"

log "memory ${MEM_KB} KB -> rmem_max=${RMEM_MAX} wmem_max=${WMEM_MAX} scale=${WIN_SCALE}"

# --- scheduler-knob compatibility -----------------------------------
# sched_min_granularity_ns / sched_wakeup_granularity_ns were removed
# with the EEVDF scheduler in 6.6; sysctl --system would log "unknown
# key" at every boot if we still shipped them. Alpine's linux-lts on
# 3.20+ is already past this cutoff, so the removal path is the
# common case.
if [ "$KERNEL_VER" -ge 606 ]; then
    SCHED_BLOCK='# sched_*_granularity_ns removed in 6.6+ (EEVDF scheduler)'
else
    SCHED_BLOCK='kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000'
fi

# --- sysctl drop-in -------------------------------------------------

log "writing ${SYSCTL_DROPIN}"
write_file "$SYSCTL_DROPIN" <<EOF
# FasterSeedbox tuning, generated ${TS}. Do not edit by hand;
# this file is overwritten by the installer.

# Kernel.
kernel.pid_max = 4194303
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
${SCHED_BLOCK}

# Filesystem.
fs.file-max = 1048576
fs.nr_open = 1048576

# VM / writeback.
vm.dirty_background_ratio = 5
vm.dirty_ratio = 30
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 100
vm.swappiness = 10

# Network core.
net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 100000
net.core.rmem_default = ${RMEM_DEF}
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_default = ${WMEM_DEF}
net.core.wmem_max = ${WMEM_MAX}
net.core.optmem_max = 4194304
net.core.somaxconn = 524288
net.core.default_qdisc = fq

# IPv4 routing and neighbor tables.
net.ipv4.route.mtu_expires = 1800
net.ipv4.route.min_adv_mss = 536
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.neigh.default.unres_qlen_bytes = 16777216

# TCP connection queues.
net.ipv4.tcp_max_syn_backlog = 524288
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 10240

# TCP MTU probing.
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1460
net.ipv4.tcp_min_snd_mss = 536

# SACK / retransmit.
net.ipv4.tcp_sack = 1
net.ipv4.tcp_comp_sack_delay_ns = 250000
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_ecn = 0

# Memory-tiered buffer sizes.
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = ${WIN_SCALE}
net.ipv4.tcp_wmem = ${TCP_WMEM}

# Reordering tolerance.
net.ipv4.tcp_reordering = 10
net.ipv4.tcp_max_reordering = 600

# Retries and keepalive.
net.ipv4.tcp_synack_retries = 10
net.ipv4.tcp_syn_retries = 7
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_probes = 15
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_orphan_retries = 2

# General TCP behavior.
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_workaround_signed_windows = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_limit_output_bytes = 3276800

# Congestion control.
net.ipv4.tcp_congestion_control = bbr
EOF
ok "sysctl drop-in written"

# --- BBR module persistence -----------------------------------------
# Alpine's canonical list is /etc/modules (loaded by the OpenRC
# 'modules' service). We append_once rather than overwrite because
# /etc/modules may already contain entries from other packages
# (e.g. fuse, zfs).

log "adding sch_fq / tcp_bbr to ${MODULES_FILE}"
append_once "$MODULES_FILE" "$MODULES_MARKER" <<EOF

${MODULES_MARKER}
sch_fq
tcp_bbr
EOF

if [ "$DRY_RUN" -eq 0 ]; then
    modprobe sch_fq  2>/dev/null || true
    modprobe tcp_bbr 2>/dev/null || true
fi

# --- resource limits ------------------------------------------------
# Two paths cover the two ways processes get their rlimits on Alpine:
#
#   * /etc/security/limits.d/* is read by pam_limits.so. On a default
#     Alpine install PAM is not present, so this file is dormant; on
#     systems where `linux-pam` has been installed (e.g. to support
#     SSH-from-AD setups) the file is honored. Writing it is cheap
#     and forward-compatible.
#   * rc_ulimit in /etc/rc.conf applies to every OpenRC-supervised
#     service at startup. This is what actually raises the limit for
#     torrent daemons running under OpenRC (qbittorrent-nox, rtorrent
#     via a wrapper, etc.). Idempotent via marker check.

log "writing ${LIMITS_DROPIN}"
write_file "$LIMITS_DROPIN" <<EOF
# FasterSeedbox tuning, generated ${TS}
# Effective only on Alpine hosts with linux-pam installed.
*    hard nofile 1048576
*    soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
EOF

log "adding rc_ulimit to ${RCCONF}"
append_once "$RCCONF" "$RCCONF_MARKER" <<EOF

${RCCONF_MARKER}
# Raise nofile for every OpenRC-managed service. Shell sessions and
# daemons outside OpenRC are unaffected; operators running torrent
# clients interactively should set ulimit -n 1048576 in ~/.profile
# or use the PAM limits file above.
rc_ulimit="-n 1048576"
EOF
ok "resource limits configured"

# --- shared runtime helper ------------------------------------------
# Everything the kernel or driver forgets across reboots (ring buffer,
# txqueuelen, offloads, per-device IO scheduler, initcwnd/initrwnd,
# BBR module load) is centralized here and invoked both now and by
# the OpenRC seedbox-tune service on every boot.

log "installing ${RUNTIME_HELPER}"
write_file "$RUNTIME_HELPER" <<'HELPER'
#!/bin/sh
#
# FasterSeedbox runtime helper (Alpine Linux).
# Reapplies settings that do not survive a reboot. Idempotent and
# safe to re-run. Called by the seedbox-tune OpenRC service and by
# the installer. Failures on any single step are tolerated.
#

set -u

# Prefer iproute2's `ip -o`; fall back to BusyBox-parsable form.
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
if [ -z "${IFACE:-}" ]; then
    IFACE="$(ip -4 route show default 2>/dev/null \
             | awk '/^default/{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
fi
[ -n "${IFACE:-}" ] || exit 0

# Virt detection without systemd-detect-virt (see installer notes).
IS_VIRT=0
if grep -q 'hypervisor' /proc/cpuinfo 2>/dev/null; then
    IS_VIRT=1
fi
if [ -f /.dockerenv ] \
     || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
    IS_VIRT=1
fi

# Interface tx queue length. Prefer ip(8); ifconfig is the legacy
# fallback for hosts still shipping net-tools.
ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null \
    || ifconfig "$IFACE" txqueuelen 10000 2>/dev/null \
    || true

# Ring buffer: request target values, clamp to NIC maximum so the
# write does not fail on low-end virtual NICs (e.g. e1000).
if ethtool -g "$IFACE" >/dev/null 2>&1; then
    MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null \
             | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' \
             | awk '/^RX:/{print $2; exit}')
    MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null \
             | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' \
             | awk '/^TX:/{print $2; exit}')
    MAX_RX=${MAX_RX:-256}
    MAX_TX=${MAX_TX:-256}
    RX_VAL=1024; [ "$MAX_RX" -lt 1024 ] && RX_VAL=$MAX_RX
    TX_VAL=2048; [ "$MAX_TX" -lt 2048 ] && TX_VAL=$MAX_TX
    ethtool -G "$IFACE" rx "$RX_VAL" 2>/dev/null || true
    ethtool -G "$IFACE" tx "$TX_VAL" 2>/dev/null || true
fi

# virtio/vmxnet3 offload implementations have historically had
# stalls and checksum issues; turn TSO/GSO/GRO off only when the
# host is virtualized. Bare-metal NICs benefit from leaving them on.
if [ "$IS_VIRT" -eq 1 ]; then
    ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null || true
fi

# Per-device I/O scheduler: mq-deadline for spinning rust, kyber
# for flash. Skip loopback, ramdisk, zram and floppy devices.
for d in $(lsblk -nd -o NAME 2>/dev/null); do
    case "$d" in loop*|ram*|zram*|fd*) continue ;; esac
    SCHED_PATH="/sys/block/$d/queue/scheduler"
    [ -w "$SCHED_PATH" ] || continue
    ROT="$(cat "/sys/block/$d/queue/rotational" 2>/dev/null || echo 1)"
    if [ "$ROT" = "0" ]; then
        if grep -q kyber "$SCHED_PATH" 2>/dev/null; then
            echo kyber >"$SCHED_PATH" 2>/dev/null || true
        fi
    else
        if grep -q mq-deadline "$SCHED_PATH" 2>/dev/null; then
            echo mq-deadline >"$SCHED_PATH" 2>/dev/null || true
        fi
    fi
done

# Raise initial congestion and receive windows on the default route.
# The IPROUTE value holds multiple fields and MUST stay unquoted in
# the subsequent ip-route invocation for word splitting.
IPROUTE="$(ip -o -4 route show to default 2>/dev/null | head -n 1)"
if [ -z "${IPROUTE:-}" ]; then
    IPROUTE="$(ip -4 route show default 2>/dev/null | head -n 1)"
fi
if [ -n "${IPROUTE:-}" ]; then
    # shellcheck disable=SC2086
    ip route change $IPROUTE initcwnd 25 initrwnd 25 2>/dev/null || true
fi

# Ensure BBR modules are available; harmless when built into the
# kernel (modprobe returns 0 silently).
modprobe sch_fq  2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# Reload every sysctl.d fragment. procps' sysctl --system is
# preferred; BusyBox sysctl lacks --system so the fallback applies
# our drop-in directly.
if sysctl --system >/dev/null 2>&1; then
    :
else
    sysctl -p /etc/sysctl.d/99-seedbox.conf >/dev/null 2>&1 || true
fi
HELPER

if [ "$DRY_RUN" -eq 0 ]; then
    chmod +x "$RUNTIME_HELPER"
fi
ok "runtime helper installed"

# --- OpenRC boot service --------------------------------------------
# OpenRC equivalent of the systemd unit in the Debian installer.
# Marked as a oneshot by defining stop() as a no-op; the service
# stays in the 'started' state once run. `need net` pulls in the
# networking service so $IFACE is resolvable at start.

log "installing ${OPENRC_UNIT}"
write_file "$OPENRC_UNIT" <<RCSCRIPT
#!/sbin/openrc-run
# shellcheck shell=sh
#
# FasterSeedbox runtime tuning (OpenRC).
# Invokes the shared runtime helper at boot.
#

# shellcheck disable=SC2034  # description is read by OpenRC framework.
description="FasterSeedbox runtime tuning"

depend() {
    need net
    after firewall
}

start() {
    ebegin "Applying FasterSeedbox runtime tuning"
    ${RUNTIME_HELPER}
    eend \$?
}

stop() {
    # Runtime settings persist in the kernel / driver until reboot;
    # nothing to unwind here.
    return 0
}
RCSCRIPT

if [ "$DRY_RUN" -eq 0 ]; then
    chmod +x "$OPENRC_UNIT"
    rc-update add seedbox-tune default >/dev/null 2>&1 \
        || warn "rc-update add failed"
    "$RUNTIME_HELPER" || warn "runtime helper returned non-zero"
    # Reload sysctls via OpenRC's own service first (it knows how to
    # iterate /etc/sysctl.d/ even with busybox sysctl), then fall back.
    rc-service sysctl restart >/dev/null 2>&1 \
        || sysctl --system >/dev/null 2>&1 \
        || sysctl -p "$SYSCTL_DROPIN" >/dev/null 2>&1 \
        || true
fi
ok "seedbox-tune service enabled and runtime settings applied"

# --- verification ---------------------------------------------------

verify_sysctl() {
    _v_key="$1"; _v_want="$2"
    _v_got="$(sysctl -n "$_v_key" 2>/dev/null || echo '?')"
    if [ "$_v_got" = "$_v_want" ]; then
        ok "  ${_v_key} = ${_v_got}"
    else
        err "  ${_v_key} = ${_v_got} (expected ${_v_want})"
    fi
}

if [ "$DRY_RUN" -eq 0 ]; then
    log "verifying critical parameters..."
    verify_sysctl net.ipv4.tcp_congestion_control bbr
    verify_sysctl net.core.default_qdisc fq
    verify_sysctl net.core.somaxconn 524288
    verify_sysctl net.ipv4.tcp_fastopen 3
fi

# --- legacy-state advisory -----------------------------------------
# Entries written to /etc/sysctl.conf by previous installers can
# override our drop-in because sysctl loads sysctl.conf last.

if [ -f /etc/sysctl.conf ] \
     && grep -Eq '^[[:space:]]*net\.(ipv4|core)\.' /etc/sysctl.conf \
          2>/dev/null; then
    warn "/etc/sysctl.conf contains net.* entries that may override"
    warn "  the drop-in at ${SYSCTL_DROPIN}. Review and clean up."
fi

# --- summary --------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf '                  FasterSeedbox tuning complete\n'
printf '============================================================\n'
printf ' Alpine       : %s\n' "$ALPINE_VER"
printf ' Environment  : %s  /  kernel %s\n' "$VIRT_KIND" "$(uname -r)"
printf ' Interface    : %s\n' "$IFACE"
printf ' Memory       : %s KB\n' "$MEM_KB"
printf '   rmem_max   : %s\n' "$RMEM_MAX"
printf '   wmem_max   : %s\n' "$WMEM_MAX"
printf '   tcp_mem    : %s\n' "$TCP_MEM"
printf '   win_scale  : %s\n' "$WIN_SCALE"
if [ "$DRY_RUN" -eq 0 ]; then
    printf ' Congestion   : %s\n' \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    printf ' Qdisc        : %s\n' \
        "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
fi
printf ' Backup suffix: .bak-%s\n' "$TS"
printf '\n Files managed by this run:\n'
printf '   %s\n' "$SYSCTL_DROPIN"
printf '   %s\n' "$LIMITS_DROPIN"
printf '   %s   (append, marked)\n' "$MODULES_FILE"
printf '   %s   (append, marked)\n' "$RCCONF"
printf '   %s\n' "$RUNTIME_HELPER"
printf '   %s\n' "$OPENRC_UNIT"
printf '\n Notes:\n'
printf '   * Interactive shells do NOT inherit rc_ulimit; set\n'
printf '     ulimit -n 1048576 in ~/.profile or install linux-pam.\n'
printf '   * /etc/security/limits.d is effective only under PAM.\n'
printf '\n Rollback:\n'
printf '   rc-service seedbox-tune stop\n'
printf '   rc-update del seedbox-tune default\n'
printf '   rm -f %s %s %s %s\n' \
    "$SYSCTL_DROPIN" "$LIMITS_DROPIN" "$RUNTIME_HELPER" "$OPENRC_UNIT"
printf '   # Restore marked blocks from .bak-%s copies of:\n' "$TS"
printf '   #   %s  %s\n' "$MODULES_FILE" "$RCCONF"
printf '   # Or strip the marker blocks manually; markers are:\n'
printf '   #   %s\n' "$MODULES_MARKER"
printf '   #   %s\n' "$RCCONF_MARKER"
printf '   rc-service sysctl restart\n'
printf '   reboot\n'
printf '============================================================\n'

if [ "$ERRORS" -gt 0 ]; then
    printf '\n'
    warn "${ERRORS} issue(s) reported; review log above."
    exit 3
fi

exit 0
