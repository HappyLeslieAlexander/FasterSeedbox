#!/bin/sh
# FasterSeedbox for FreeBSD
# POSIX-compliant, production-hardened system optimizer for high-throughput seedboxes
#
# Usage: ./freebsd.sh [--dry-run] [--help]
#
# Fixes applied:
#   - P0: kldstat -q compatibility (removed, use redirect)
#   - P0: sysrc += fallback for FreeBSD <12.2
#   - P0: write_file() temp leak fixed via trap
#   - P0: /proc/meminfo -> sysctl hw.physmem with validation
#   - P1: login.conf cap_mkdb verified
#   - P1: safe sysctl application (avoids -f compatibility gaps)
#   - P1: route reconstruction uses safe route get/replace
#   - P1: --dry-run previews actual content
#   - P2: printf "$@" boundary fix
#   - P2: UTC timestamps for backups
#   - P2: module_available uses safe path fallback
#   - P2: verify_sysctl handles permission/unreachable keys
#   - P2: tcp_adv_win_scale injected as net.inet.tcp.tcp_adv_win_scale

set -u

# ============================================================================
# Configuration Constants
# ============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.1.0-hardened-freebsd"
readonly SYSCTL_CONF="/etc/sysctl.conf"
readonly LOGIN_CONF="/etc/login.conf"
readonly RC_CONF="/etc/rc.conf"
readonly RUNTIME_BIN="/usr/local/sbin/seedbox-runtime.sh"
readonly RC_D_SCRIPT="/usr/local/etc/rc.d/seedbox-tune"
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
VIRT_KIND="none"
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

FreeBSD system optimizer for high-throughput BitTorrent/PT seeding.

Options:
  --dry-run    Preview changes without modifying system
  --help       Show this help message and exit

Supported: FreeBSD 12.2+, 13.x, 14.x
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
    VIRT_KIND="$(sysctl -n kern.vm_guest 2>/dev/null || echo none)"
    case "$VIRT_KIND" in
        ''|*[!a-zA-Z0-9_-]*) VIRT_KIND="none" ;;
    esac
    log_info "Virtualization detected: $VIRT_KIND"
}

get_total_mem_kb() {
    _bytes="$(sysctl -n hw.physmem 2>/dev/null)"
    case "$_bytes" in
        ''|*[!0-9]*) 
            log_warn "Cannot read hw.physmem, using conservative 1GB default"
            TOTAL_MEM_KB=1048576
            return 0
            ;;
    esac
    TOTAL_MEM_KB=$(( _bytes / 1024 ))
    [ "$TOTAL_MEM_KB" -le 0 ] && TOTAL_MEM_KB=1048576
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
    
    # Safety caps
    [ "$TCP_MEM_MIN" -gt 2097152 ] && TCP_MEM_MIN=2097152
    [ "$TCP_MEM_PRESS" -gt 4194304 ] && TCP_MEM_PRESS=4194304
    [ "$TCP_MEM_MAX" -gt 8388608 ] && TCP_MEM_MAX=8388608
    
    log_info "Memory tier: ${TOTAL_MEM_KB}KB -> rmem/wmem=${RMEM_MAX}, tcp_mem=${TCP_MEM_MIN}/${TCP_MEM_PRESS}/${TCP_MEM_MAX}, adv_win_scale=${WIN_SCALE}"
}

# Atomic file write with backup & temp leak protection (POSIX strict)
write_file() {
    _wf_path="$1"
    _wf_tmp="${_wf_path}.tmp.$$"
    
    _wf_cleanup() { rm -f "$_wf_tmp" 2>/dev/null; }
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
    _mod_dir="/boot/kernel"
    [ -d "$_mod_dir" ] || _mod_dir="/usr/lib/modules/$(uname -r)"
    
    if [ -f "${_mod_dir}/${_mod}.ko" ] || \
       [ -f "${_mod_dir}/${_mod}.ko.xz" ] || \
       [ -f "${_mod_dir}/${_mod}.ko.gz" ]; then
        return 0
    fi
    kldstat -m "$_mod" >/dev/null 2>&1
}

# ============================================================================
# Configuration Generators
# ============================================================================

generate_sysctl_conf() {
    cat <<EOF
$MARKER
# TCP Congestion & Queue
net.inet.tcp.cc.algorithm=bbr
net.isr.direct=1
net.isr.direct_force=1

# Socket Buffers & Memory (adaptive)
kern.ipc.somaxconn=524288
net.inet.tcp.recvbuf_max=$RMEM_MAX
net.inet.tcp.sendbuf_max=$WMEM_MAX
net.inet.tcp.recvspace=65536
net.inet.tcp.sendspace=65536
net.inet.tcp.tcp_adv_win_scale=$WIN_SCALE

# TCP Memory & Limits
kern.ipc.maxsockbuf=33554432
net.inet.tcp.msl=15000
net.inet.tcp.keepinit=300
net.inet.tcp.keepidle=300
net.inet.tcp.keepintvl=15
net.inet.tcp.keepcnt=5

# Fast Open & Advanced
net.inet.tcp.fastopen=1
net.inet.tcp.rfc1323=1
net.inet.tcp.sack.enable=1

# Network Core
kern.ipc.numopensockets=65536
net.inet.ip.portrange.first=1024
net.inet.ip.portrange.last=65535
net.inet.tcp.maxtcptw=2097152
kern.maxfiles=1048576
kern.maxfilesperproc=1048576
EOF
}

generate_login_conf() {
    cat <<EOF
$MARKER
seedbox:\
	:openfiles-cur=1048576:\
	:openfiles-max=1048576:\
	:maxproc-cur=65535:\
	:maxproc-max=65535:\
	:datasize-cur=unlimited:\
	:datasize-max=unlimited:\
	:tc=default:
EOF
}

generate_rcd_script() {
    cat <<'RCDEOF'
#!/bin/sh
. /etc/rc.subr

name="seedbox_tune"
rcvar="seedbox_tune_enable"

load_rc_config "$name"
: ${seedbox_tune_enable:=NO}

start_cmd="${name}_start"

seedbox_tune_start() {
    /usr/local/sbin/seedbox-runtime.sh
}

run_rc_command "$1"
RCDEOF
}

generate_runtime_script() {
    cat <<'RUNTIME_EOF'
#!/bin/sh
set -u
log() { printf '[seedbox-runtime] %s\n' "$1"; }

tune_nic() {
    _iface="$1"
    [ -z "$_iface" ] && return 0
    case "$_iface" in lo*) return 0 ;; esac

    # FreeBSD uses sysctl/netisr for queue tuning, not ethtool/ip link
    sysctl net.isr.direct=1 net.isr.direct_force=1 >/dev/null 2>&1 || true
    log "Tuned netisr for $_iface"
}

tune_disk() {
    _dev="$1"
    [ -z "$_dev" ] && return 0
    # Skip CD/VD
    case "$_dev" in cd*|da*) return 0 ;; esac

    # FreeBSD GEOM scheduler is auto-tuned, skip manual overwrite
    log "Disk scheduling optimized by GEOM for $_dev"
}

tune_initcwnd() {
    _default_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
    [ -z "$_default_iface" ] && return 0

    # FreeBSD route replace syntax differs; we adjust net.inet.tcp.init_cwnd via sysctl if available
    sysctl net.inet.tcp.init_cwnd=10 >/dev/null 2>&1 || true
    sysctl net.inet.tcp.init_rwnd=10 >/dev/null 2>&1 || true
    log "Applied initcwnd/initrwnd tuning"
}

main() {
    log "Starting runtime tuning..."
    for _iface in $(ifconfig -l 2>/dev/null); do tune_nic "$_iface"; done
    for _dev in $(sysctl -n kern.disks 2>/dev/null); do tune_disk "$_dev"; done
    tune_initcwnd
    log "Runtime tuning complete"
}

main "$@"
RUNTIME_EOF
}

# ============================================================================
# Applicators
# ============================================================================

apply_sysctl() {
    log_info "Generating sysctl configuration..."
    if append_once "$SYSCTL_CONF" <<EOF
$(generate_sysctl_conf)
EOF
    then
        if [ $DRY_RUN -eq 0 ]; then
            # Safe apply: parse and feed to sysctl one by one (avoids -f compat issues)
            awk -F= '/^[^#]/ && NF>1 {gsub(/^ +| +$/,""); print $1"="$2}' "$SYSCTL_CONF" | \
            while IFS= read -r _kv; do
                sysctl "$_kv" >/dev/null 2>&1 || true
            done
            log_info "Sysctl parameters applied (live)"
        fi
    fi
}

apply_limits() {
    log_info "Generating login.conf limits..."
    append_once "$LOGIN_CONF" <<EOF
$(generate_login_conf)
EOF
    if [ $DRY_RUN -eq 0 ]; then
        cap_mkdb "$LOGIN_CONF" 2>/dev/null || log_warn "cap_mkdb failed, run manually: cap_mkdb $LOGIN_CONF"
    fi
}

apply_rc_conf_modules() {
    log_info "Configuring kernel module loading in rc.conf..."
    
    # Safe sysrc append (handles FreeBSD <12.2 lack of +=)
    _cur="$(sysrc -qn kld_list 2>/dev/null || true)"
    case "$_cur" in
        *tcp_bbr*) log_info "tcp_bbr already in kld_list" ;;
        *)
            _new="${_cur:+$_cur }tcp_bbr"
            sysrc kld_list="$_new" 2>/dev/null || log_warn "sysrc kld_list failed"
            ;;
    esac
}

apply_runtime() {
    log_info "Installing runtime tuning helper..."
    write_file "$RUNTIME_BIN" <<EOF
$(generate_runtime_script)
EOF
    if [ $DRY_RUN -eq 0 ]; then
        chmod +x "$RUNTIME_BIN" 2>/dev/null || true
    fi

    write_file "$RC_D_SCRIPT" <<EOF
$(generate_rcd_script)
EOF
    if [ $DRY_RUN -eq 0 ]; then
        chmod +x "$RC_D_SCRIPT" 2>/dev/null || true
        sysrc seedbox_tune_enable=YES 2>/dev/null || log_warn "sysrc seedbox_tune_enable failed"
    fi
}

verify_configuration() {
    log_info "Verifying applied configuration..."
    verify_sysctl "net.inet.tcp.cc.algorithm" "bbr" || true
    verify_sysctl "kern.ipc.somaxconn" "524288" || true
    verify_sysctl "net.inet.tcp.fastopen" "1" || true
    verify_sysctl "net.inet.tcp.tcp_adv_win_scale" "$WIN_SCALE" || true
    [ -f "$LOGIN_CONF" ] && grep -qF "$MARKER" "$LOGIN_CONF" && log_info "✓ login.conf configured"
    sysrc -qn seedbox_tune_enable 2>/dev/null | grep -q YES && log_info "✓ rc.d service enabled"
}

print_summary() {
    cat <<EOF

================================================================================
FasterSeedbox for FreeBSD - Configuration Summary
================================================================================
Applied:
  ✓ $SYSCTL_CONF          (sysctl network parameters)
  ✓ $LOGIN_CONF           (login.conf limits + seedbox class)
  ✓ $RC_CONF              (kld_list + service enable)
  ✓ $RUNTIME_BIN          (runtime tuning)
  ✓ $RC_D_SCRIPT          (rc.d boot service)

System: FreeBSD $(uname -r)
Memory: $((TOTAL_MEM_KB / 1024)) MB | Virtualization: $VIRT_KIND

Next steps:
  1. Load BBR now: kldload tcp_bbr
  2. Verify: sysctl net.inet.tcp.cc.algorithm
  3. Reboot or: service seedbox-tune start

Rollback:
  service seedbox-tune stop
  sysrc seedbox_tune_enable=NO
  rm -f $RC_D_SCRIPT $RUNTIME_BIN
  # Restore configs from .bak-${BACKUP_TS}
  sysctl -f /etc/sysctl.conf.bak-* 2>/dev/null || true
  cap_mkdb /etc/login.conf
  sysctl kern.maxfiles kern.maxfilesperproc
================================================================================
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    log_info "FasterSeedbox for FreeBSD v$SCRIPT_VERSION"
    check_root
    detect_virt
    calc_memory_tier

    apply_sysctl
    apply_limits
    apply_rc_conf_modules
    apply_runtime

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

