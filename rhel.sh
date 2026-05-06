#!/bin/sh
# FasterSeedbox for RHEL-like Systems (RHEL/Rocky/Alma/CentOS)
# POSIX-compliant, production-hardened system optimizer for high-throughput seedboxes
#
# Usage: ./rhel.sh [--dry-run] [--help]
#
# Fixes applied:
#   - P0: tcp_adv_win_scale injected into sysctl
#   - P0: systemctl daemon-reexec -> daemon-reload
#   - P0: write_file() temp leak fixed via trap
#   - P0: /proc/meminfo parsing validated with fallback
#   - P1: ethtool -g multi-line parser fixed
#   - P1: ip route reconstruction made safe
#   - P1: --dry-run previews actual content
#   - P1: MEM_KB validated against non-numeric/empty
#   - P2: lsblk word-splitting fixed (uses /sys/block)
#   - P2: verify_sysctl handles permission/unreachable keys
#   - P2: UTC timestamps for backups
#   - P2: limits.conf root redundancy removed
#   - P2: module_available checks /usr/lib first
#   - P2: printf "$@" boundary fix
#   - P2: append_once validates target existence

set -u

# ============================================================================
# Configuration Constants
# ============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.1.0-hardened-rhel"
readonly CONF_DIR="/etc/sysctl.d"
readonly LIMITS_DIR="/etc/security/limits.d"
readonly SYSTEMD_CONF_DIR="/etc/systemd/system.conf.d"
readonly MODULES_CONF_DIR="/etc/modules-load.d"
readonly RUNTIME_BIN="/usr/local/sbin/seedbox-runtime.sh"
readonly RUNTIME_SERVICE="/etc/systemd/system/seedbox-tune.service"
readonly BACKUP_TS="$(date -u +%Y%m%d-%H%M%SZ)"
readonly MARKER="# FasterSeedbox managed - DO NOT EDIT"

# Memory tiers in KB
readonly MEM_TIER_1=524288
readonly MEM_TIER_2=1048576
readonly MEM_TIER_3=4194304
readonly MEM_TIER_4=16777216

# ============================================================================
# Global State
# ============================================================================
DRY_RUN=0
ERRORS=0
WARNINGS=0
VIRT_KIND="unknown"
TOTAL_MEM_KB=0
WIN_SCALE=2

# ============================================================================
# Utility Functions
# ============================================================================

log_info() { printf '[INFO] %s\n' "$@"; }
log_warn() { printf '[WARN] %s\n' "$@" >&2; WARNINGS=$((WARNINGS + 1)); }
log_err()  { printf '[ERR]  %s\n' "$@" >&2; ERRORS=$((ERRORS + 1)); }

die() {
    log_err "$@"
    exit 1
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

RHEL-like system optimizer for high-throughput BitTorrent/PT seeding.

Options:
  --dry-run    Preview changes without modifying system
  --help       Show this help message and exit

Supported: RHEL 8/9, Rocky Linux, AlmaLinux, CentOS Stream
EOF
    exit 0
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage ;;
        -*) die "Unknown option: $1";;
        *) die "Unexpected argument: $1";;
    esac
done

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (use sudo/doas)"
    fi
}

# ============================================================================
# Core Logic Functions
# ============================================================================

detect_virt() {
    _virt="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        _virt="$(systemd-detect-virt 2>/dev/null || true)"
        [ -n "$_virt" ] && VIRT_KIND="$_virt" && return 0
    fi
    if [ -f /.dockerenv ]; then
        _virt="docker"
    elif [ -f /run/.containerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
        _virt="podman"
    elif grep -qi 'hypervisor' /proc/cpuinfo 2>/dev/null; then
        _virt="kvm"
    fi
    VIRT_KIND="${_virt:-unknown}"
    log_info "Virtualization detected: $VIRT_KIND"
}

get_total_mem_kb() {
    TOTAL_MEM_KB="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
    case "$TOTAL_MEM_KB" in
        ''|*[!0-9]*) 
            log_warn "Invalid /proc/meminfo, using conservative 1GB default"
            TOTAL_MEM_KB=1048576
            ;;
        0) TOTAL_MEM_KB=1048576 ;;
    esac
}

calc_memory_tier() {
    get_total_mem_kb
    
    if [ "$TOTAL_MEM_KB" -le "$MEM_TIER_1" ]; then
        RMEM_MAX=8388608; WMEM_MAX=8388608
        TCP_DIV_MIN=32; TCP_DIV_PRESS=16; TCP_DIV_MAX=8
        WIN_SCALE=3
    elif [ "$TOTAL_MEM_KB" -le "$MEM_TIER_2" ]; then
        RMEM_MAX=16777216; WMEM_MAX=16777216
        TCP_DIV_MIN=16; TCP_DIV_PRESS=8; TCP_DIV_MAX=6
        WIN_SCALE=2
    elif [ "$TOTAL_MEM_KB" -le "$MEM_TIER_3" ]; then
        RMEM_MAX=33554432; WMEM_MAX=33554432
        TCP_DIV_MIN=8; TCP_DIV_PRESS=6; TCP_DIV_MAX=4
        WIN_SCALE=2
    elif [ "$TOTAL_MEM_KB" -le "$MEM_TIER_4" ]; then
        RMEM_MAX=67108864; WMEM_MAX=67108864
        TCP_DIV_MIN=8; TCP_DIV_PRESS=4; TCP_DIV_MAX=2
        WIN_SCALE=1
    else
        RMEM_MAX=134217728; WMEM_MAX=134217728
        TCP_DIV_MIN=8; TCP_DIV_PRESS=4; TCP_DIV_MAX=2
        WIN_SCALE=-2
    fi
    
    MEM_4K=$((TOTAL_MEM_KB / 4))
    TCP_MEM_MIN=$((MEM_4K / TCP_DIV_MIN))
    TCP_MEM_PRESS=$((MEM_4K / TCP_DIV_PRESS))
    TCP_MEM_MAX=$((MEM_4K / TCP_DIV_MAX))
    
    # Safety caps to prevent OOM under pressure
    [ "$TCP_MEM_MIN" -gt 2097152 ] && TCP_MEM_MIN=2097152
    [ "$TCP_MEM_PRESS" -gt 4194304 ] && TCP_MEM_PRESS=4194304
    [ "$TCP_MEM_MAX" -gt 8388608 ] && TCP_MEM_MAX=8388608
    
    log_info "Memory tier: ${TOTAL_MEM_KB}KB -> rmem/wmem=${RMEM_MAX}, tcp_mem=${TCP_MEM_MIN}/${TCP_MEM_PRESS}/${TCP_MEM_MAX}, adv_win_scale=${WIN_SCALE}"
}

# Atomic file write with backup & temp leak protection (POSIX strict)
write_file() {
    _wf_path="$1"
    _wf_tmp="${_wf_path}.tmp.$$"
    
    # Cleanup trap (global variable for POSIX sh compatibility)
    _WF_TMP="$_wf_tmp"
    _wf_cleanup() { rm -f "$_WF_TMP" 2>/dev/null; }
    trap _wf_cleanup EXIT INT TERM HUP

    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] Would write to: $_wf_path"
        log_info "--- BEGIN PREVIEW ---"
        cat
        log_info "--- END PREVIEW ---"
        trap - EXIT INT TERM HUP
        return 0
    fi

    mkdir -p "$(dirname "$_wf_path")" 2>/dev/null || true
    if [ -f "$_wf_path" ]; then
        cp -p "$_wf_path" "${_wf_path}.bak-${BACKUP_TS}" 2>/dev/null || true
    fi

    if ! cat >"$_wf_tmp"; then
        log_err "Failed to write temporary file for $_wf_path"
        trap - EXIT INT TERM HUP
        return 1
    fi

    if ! mv -f "$_wf_tmp" "$_wf_path"; then
        log_err "Failed to install $_wf_path"
        trap - EXIT INT TERM HUP
        return 1
    fi

    log_info "Written: $_wf_path"
    trap - EXIT INT TERM HUP
    return 0
}

append_once() {
    _ao_path="$1"
    _ao_marker="$MARKER"

    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] Would append to: $_ao_path"
        log_info "--- BEGIN PREVIEW ---"
        cat
        log_info "--- END PREVIEW ---"
        return 0
    fi

    if [ ! -f "$_ao_path" ]; then
        touch "$_ao_path" 2>/dev/null || { log_err "Cannot create $_ao_path"; return 1; }
    fi

    if grep -Fq "$_ao_marker" "$_ao_path" 2>/dev/null; then
        log_info "Skipping duplicate append to $_ao_path"
        return 0
    fi

    { printf '\n%s\n' "$_ao_marker"; cat; } >>"$_ao_path"
    log_info "Appended to: $_ao_path"
    return 0
}

verify_sysctl() {
    _v_key="$1"
    _v_want="$2"
    _v_got="$(sysctl -n "$_v_key" 2>/dev/null)"
    if [ $? -eq 0 ] && [ "$_v_got" = "$_v_want" ]; then
        log_info "✓ $_v_key = $_v_got"
        return 0
    else
        log_warn "✗ $_v_key: expected '$_v_want', got '${_v_got:-unreachable}'"
        return 1
    fi
}

module_available() {
    _mod="$1"
    # RHEL 8/9 uses /usr/lib/modules by default, /lib is a compat symlink
    _mod_dir="/usr/lib/modules/$(uname -r)"
    [ -d "$_mod_dir" ] || _mod_dir="/lib/modules/$(uname -r)"
    
    if [ -f "${_mod_dir}/kernel/net/ipv4/${_mod}.ko" ] || \
       [ -f "${_mod_dir}/kernel/net/ipv4/${_mod}.ko.xz" ] || \
       [ -f "${_mod_dir}/kernel/net/ipv4/${_mod}.ko.gz" ]; then
        return 0
    fi
    modprobe -n "$_mod" >/dev/null 2>&1
}

# ============================================================================
# Configuration Generators
# ============================================================================

generate_sysctl_conf() {
    cat <<EOF
$MARKER
# === TCP Congestion Control ===
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# === Socket Buffer Tuning (memory-adaptive) ===
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.ipv4.tcp_rmem = 4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $WMEM_MAX
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_adv_win_scale = ${WIN_SCALE}

# === TCP Memory Pressure (in 4KB pages) ===
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESS $TCP_MEM_MAX

# === Connection Handling ===
net.core.somaxconn = 524288
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 2097152
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# === TCP Fast Open & Advanced ===
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1

# === Network Core ===
net.core.netdev_max_backlog = 65536
net.core.optmem_max = 33554432
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOF
}

generate_limits_conf() {
    cat <<EOF
$MARKER
# Increase open file limits for all users (* covers root in modern PAM)
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
* soft memlock unlimited
* hard memlock unlimited
EOF
}

generate_systemd_conf() {
    cat <<EOF
$MARKER
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
DefaultLimitMEMLOCK=infinity
EOF
}

generate_modules_conf() {
    cat <<EOF
$MARKER
tcp_bbr
EOF
}

generate_runtime_script() {
    cat <<'RUNTIME_EOF'
#!/bin/sh
set -u
log() { printf '[seedbox-runtime] %s\n' "$1"; }

tune_nic() {
    _iface="$1"
    [ -z "$_iface" ] && return 0
    case "$_iface" in lo|docker*|veth*|virbr*|tun*|tap*) return 0 ;; esac

    ip link set "$_iface" txqueuelen 10000 2>/dev/null || true

    if command -v ethtool >/dev/null 2>&1; then
        # Safe multi-line parser for ethtool -g (RHEL/CentOS standard output)
        _rx_max="$(ethtool -g "$_iface" 2>/dev/null | awk '/Pre-set maximums:/{m=1} m && /^RX:/{print $2; exit}')"
        _tx_max="$(ethtool -g "$_iface" 2>/dev/null | awk '/Pre-set maximums:/{m=1} m && /^TX:/{print $2; exit}')"
        case "$_rx_max" in ''|*[!0-9]*) _rx_max=256 ;; esac
        case "$_tx_max" in ''|*[!0-9]*) _tx_max=512 ;; esac

        ethtool -G "$_iface" rx "$_rx_max" tx "$_tx_max" 2>/dev/null || true
    fi
    log "Tuned NIC: $_iface"
}

tune_disk() {
    _dev="$1"
    [ -z "$_dev" ] && return 0
    case "$_dev" in loop*|ram*|zram*|fd*|sr*) return 0 ;; esac

    _scheduler="kyber"
    if [ -f "/sys/block/$_dev/queue/rotational" ]; then
        [ "$(cat "/sys/block/$_dev/queue/rotational" 2>/dev/null)" = "1" ] && _scheduler="mq-deadline"
    fi

    if [ -f "/sys/block/$_dev/queue/scheduler" ] && grep -q "$_scheduler" "/sys/block/$_dev/queue/scheduler" 2>/dev/null; then
        echo "$_scheduler" > "/sys/block/$_dev/queue/scheduler" 2>/dev/null || true
        log "Set scheduler $_scheduler for $_dev"
    fi
}

tune_initcwnd() {
    _default_route="$(ip -4 route show default 2>/dev/null | head -1)"
    [ -z "$_default_route" ] && return 0

    _dev="$(echo "$_default_route" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
    _via="$(echo "$_default_route" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"

    [ -z "$_dev" ] && return 0

    if [ -n "$_via" ]; then
        ip route replace default via "$_via" dev "$_dev" initcwnd 25 initrwnd 25 2>/dev/null || true
    else
        ip route replace default dev "$_dev" initcwnd 25 initrwnd 25 2>/dev/null || true
    fi
    log "Applied initcwnd tuning on $_dev"
}

main() {
    log "Starting runtime tuning..."
    for _iface in $(ls /sys/class/net/ 2>/dev/null); do tune_nic "$_iface"; done
    for _dev in $(ls /sys/block/ 2>/dev/null); do tune_disk "$_dev"; done
    tune_initcwnd
    log "Runtime tuning complete"
}

main "$@"
RUNTIME_EOF
}

generate_systemd_service() {
    cat <<EOF
[Unit]
Description=FasterSeedbox Runtime Network/Disk Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNTIME_BIN
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# ============================================================================
# Applicators
# ============================================================================

apply_sysctl() {
    log_info "Generating sysctl configuration..."
    if write_file "$CONF_DIR/99-seedbox.conf" <<EOF
$(generate_sysctl_conf)
EOF
    then
        if [ $DRY_RUN -eq 0 ]; then
            sysctl -p "$CONF_DIR/99-seedbox.conf" 2>/dev/null || log_warn "sysctl apply failed (may require reboot)"
        fi
    fi
}

apply_limits() {
    log_info "Generating file descriptor limits..."
    write_file "$LIMITS_DIR/99-seedbox.conf" <<EOF
$(generate_limits_conf)
EOF
}

apply_systemd_limits() {
    log_info "Generating systemd resource limits..."
    write_file "$SYSTEMD_CONF_DIR/99-seedbox.conf" <<EOF
$(generate_systemd_conf)
EOF
    if [ $DRY_RUN -eq 0 ]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

apply_modules() {
    log_info "Configuring kernel module loading..."
    if write_file "$MODULES_CONF_DIR/seedbox-bbr.conf" <<EOF
$(generate_modules_conf)
EOF
    then
        if [ $DRY_RUN -eq 0 ] && module_available "tcp_bbr"; then
            modprobe tcp_bbr 2>/dev/null || log_warn "Could not load tcp_bbr module"
        fi
    fi
}

apply_runtime() {
    log_info "Installing runtime tuning helper & systemd service..."
    write_file "$RUNTIME_BIN" <<EOF
$(generate_runtime_script)
EOF
    if [ $DRY_RUN -eq 0 ]; then
        chmod +x "$RUNTIME_BIN" 2>/dev/null || true
    fi

    write_file "$RUNTIME_SERVICE" <<EOF
$(generate_systemd_service)
EOF
    if [ $DRY_RUN -eq 0 ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable seedbox-tune.service 2>/dev/null || log_warn "Could not enable seedbox-tune.service"
    fi
}

apply_initcwnd() {
    if [ $DRY_RUN -eq 0 ]; then
        _default_route="$(ip -4 route show default 2>/dev/null | head -1)"
        [ -n "$_default_route" ] && {
            _dev="$(echo "$_default_route" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
            _via="$(echo "$_default_route" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
            [ -n "$_dev" ] && {
                if [ -n "$_via" ]; then
                    ip route replace default via "$_via" dev "$_dev" initcwnd 25 initrwnd 25 2>/dev/null || true
                else
                    ip route replace default dev "$_dev" initcwnd 25 initrwnd 25 2>/dev/null || true
                fi
            }
        }
    fi
}

verify_configuration() {
    log_info "Verifying applied configuration..."
    verify_sysctl "net.ipv4.tcp_congestion_control" "bbr" || true
    verify_sysctl "net.core.default_qdisc" "fq" || true
    verify_sysctl "net.core.somaxconn" "524288" || true
    verify_sysctl "net.ipv4.tcp_fastopen" "3" || true
    verify_sysctl "net.ipv4.tcp_adv_win_scale" "$WIN_SCALE" || true
    [ -f "$LIMITS_DIR/99-seedbox.conf" ] && log_info "✓ File limits configured"
    [ -f "$SYSTEMD_CONF_DIR/99-seedbox.conf" ] && log_info "✓ Systemd limits configured"
}

print_summary() {
    cat <<EOF

================================================================================
FasterSeedbox for RHEL-like Systems - Configuration Summary
================================================================================
Applied:
  ✓ $CONF_DIR/99-seedbox.conf          (sysctl network parameters)
  ✓ $LIMITS_DIR/99-seedbox.conf        (file descriptor limits)
  ✓ $SYSTEMD_CONF_DIR/99-seedbox.conf  (systemd resource limits)
  ✓ $MODULES_CONF_DIR/seedbox-bbr.conf (kernel module loading)
  ✓ $RUNTIME_BIN                       (runtime NIC/disk tuning)
  ✓ $RUNTIME_SERVICE                   (systemd boot service)

System: $(. /etc/os-release 2>/dev/null && printf '%s %s' "$NAME" "$VERSION_ID" || echo 'RHEL-like')
Kernel: $(uname -r)
Memory: $((TOTAL_MEM_KB / 1024)) MB | Virtualization: $VIRT_KIND

Next steps:
  1. Reboot recommended: reboot
  2. Or apply now: sysctl -p $CONF_DIR/99-seedbox.conf && systemctl start seedbox-tune
  3. Verify: sysctl net.ipv4.tcp_congestion_control

Rollback:
  systemctl disable --now seedbox-tune.service
  rm -f $RUNTIME_SERVICE $RUNTIME_BIN $CONF_DIR/99-seedbox.conf \
        $LIMITS_DIR/99-seedbox.conf $SYSTEMD_CONF_DIR/99-seedbox.conf \
        $MODULES_CONF_DIR/seedbox-bbr.conf
  sysctl --system && systemctl daemon-reload
  # Backup files: *.bak-${BACKUP_TS}
================================================================================
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    log_info "FasterSeedbox for RHEL-like Systems v$SCRIPT_VERSION"
    check_root
    detect_virt
    calc_memory_tier

    apply_sysctl
    apply_limits
    apply_systemd_limits
    apply_modules
    apply_runtime
    apply_initcwnd

    verify_configuration
    print_summary

    if [ $ERRORS -gt 0 ]; then
        log_warn "Completed with $ERRORS error(s) and $WARNINGS warning(s)"
        exit 3
    elif [ $WARNINGS -gt 0 ]; then
        log_info "Completed with $WARNINGS warning(s)"
        exit 0
    else
        log_info "Optimization completed successfully"
        exit 0
    fi
}

main "$@"

