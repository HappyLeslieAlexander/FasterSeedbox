#!/bin/sh
#
# FasterSeedbox — FreeBSD tuning installer.
#
# Sets up the BBR TCP stack (with HTCP as a fallback), memory-tiered
# socket buffers, a 'seedbox' login class, and a small rc.d service
# that re-applies runtime-only knobs on each boot. Persistent values
# are written to a loader.conf.d drop-in, /etc/sysctl.conf and via
# sysrc into /etc/rc.conf.
#
# Tested on FreeBSD 13.x and 14.x. On FreeBSD 14.1+ the RACK / BBR
# modules ship with GENERIC and load unconditionally; on 14.0 and
# older a custom kernel built with WITH_EXTRA_TCP_STACKS=1 is
# required for BBR (the script falls back to HTCP otherwise).
#
# POSIX sh. Invoke with --help for options.
#

set -u

SCRIPT_NAME="FasterSeedbox-freebsd"
TUNE_SYSCTL="/etc/sysctl.conf"
TUNE_LOADER="/boot/loader.conf.d/seedbox.conf"
TUNE_LOGIN="/etc/login.conf"
TUNE_RCCONF="/etc/rc.conf"
TUNE_RCSCRIPT="/usr/local/etc/rc.d/seedbox_tune"
TS="$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
OFFLOAD_MODE="virt"
ERRORS=0

usage() {
    cat <<EOF
${SCRIPT_NAME}

Usage: $0 [--dry-run] [--offload=virt|always|never] [--help]

  --dry-run         Show every file that would be written or modified,
                    but do not touch the system.
  --offload=MODE    When to disable NIC TSO / LRO / VLAN-HWTSO:
                      virt    - only under a detected hypervisor
                                (default; virtio and vmxnet3 offloads
                                 are historically buggy)
                      always  - disable on every interface
                      never   - leave offloads alone
  --help            Print this message and exit.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)        DRY_RUN=1 ;;
        --offload=*)      OFFLOAD_MODE="${arg#*=}" ;;
        --help|-h)        usage; exit 0 ;;
        *)                printf 'Unknown option: %s\n\n' "$arg" >&2
                          usage >&2; exit 2 ;;
    esac
done

case "$OFFLOAD_MODE" in
    virt|always|never) ;;
    *) printf 'Invalid --offload value: %s\n' "$OFFLOAD_MODE" >&2
       exit 2 ;;
esac

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
# already present (idempotent). Also honors DRY_RUN.
append_once() {
    _ao_path="$1"; _ao_marker="$2"
    if [ -f "$_ao_path" ] \
         && grep -Fq "$_ao_marker" "$_ao_path" 2>/dev/null; then
        log "${_ao_path} already contains '${_ao_marker}', skipping"
        cat >/dev/null
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    (dry-run) would append block marked '\''%s'\'' to %s\n' \
               "$_ao_marker" "$_ao_path"
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

if [ "$(uname -s)" != "FreeBSD" ]; then
    err "this script targets FreeBSD"
    exit 1
fi

IFACE="$(route -n get -inet default 2>/dev/null \
         | awk '/interface:/{print $2; exit}')"
if [ -z "${IFACE}" ]; then
    err "no default-route interface found"
    exit 1
fi

# kern.vm_guest is 'none' on bare metal and e.g. 'kvm', 'vmware',
# 'xen' under a hypervisor. Used to decide --offload=virt behavior.
VIRT_KIND="$(sysctl -n kern.vm_guest 2>/dev/null || echo none)"
IS_VIRT=0
if [ -n "$VIRT_KIND" ] && [ "$VIRT_KIND" != "none" ]; then
    IS_VIRT=1
fi

log "interface: ${IFACE}   virt: ${VIRT_KIND}   system: $(uname -sr)"
[ "$DRY_RUN" -eq 1 ] && log "dry-run: no system changes will be made"

# --- memory-tiered buffer sizing ------------------------------------
# Five tiers mirror the Linux installer. FreeBSD has no adv_win_scale
# equivalent, so we only derive rmem / wmem caps and maxsockbuf.

MEM_BYTES="$(sysctl -n hw.physmem)"
MEM_KB=$((MEM_BYTES / 1024))

if   [ "$MEM_KB" -le 524288 ]; then
    RMEM_MAX=8388608;   WMEM_MAX=8388608
elif [ "$MEM_KB" -le 1048576 ]; then
    RMEM_MAX=16777216;  WMEM_MAX=16777216
elif [ "$MEM_KB" -le 4194304 ]; then
    RMEM_MAX=33554432;  WMEM_MAX=33554432
elif [ "$MEM_KB" -le 16777216 ]; then
    RMEM_MAX=67108864;  WMEM_MAX=67108864
else
    RMEM_MAX=134217728; WMEM_MAX=134217728
fi

# kern.ipc.maxsockbuf must be at least twice the larger of send/recv.
# Since the tiers above set rmem == wmem, either direction works; we
# keep the max() form in case a future tier breaks that symmetry.
if [ "$RMEM_MAX" -ge "$WMEM_MAX" ]; then
    MAXSOCKBUF=$((RMEM_MAX * 2))
else
    MAXSOCKBUF=$((WMEM_MAX * 2))
fi

log "memory $((MEM_KB / 1024)) MB -> rmem=${RMEM_MAX} wmem=${WMEM_MAX} maxsockbuf=${MAXSOCKBUF}"

# --- TCP stack selection -------------------------------------------
# Attempt BBR first (requires tcp_rack.ko + tcp_bbr.ko). If the
# kernel does not ship these, try HTCP as a better-than-cubic
# fallback for high-BDP links. Leave the kernel default in place if
# neither is available.

BBR_OK=0
HTCP_OK=0

if [ "$DRY_RUN" -eq 0 ]; then
    if kldload tcp_rack 2>/dev/null || kldstat -q -m tcp_rack; then
        if kldload tcp_bbr 2>/dev/null || kldstat -q -m tcp_bbr; then
            BBR_OK=1
        fi
    fi
    kldload cc_htcp 2>/dev/null || kldstat -q -m cc_htcp || true
    if sysctl -n net.inet.tcp.cc.available 2>/dev/null \
         | tr ' ' '\n' | grep -qx htcp; then
        HTCP_OK=1
    fi
fi

if [ "$BBR_OK" -eq 1 ]; then
    TCP_STACK_LINE="net.inet.tcp.functions_default=bbr"
    if [ "$DRY_RUN" -eq 0 ]; then
        sysctl net.inet.tcp.functions_default=bbr >/dev/null 2>&1 || true
    fi
    ok "TCP stack: BBR enabled"
elif [ "$HTCP_OK" -eq 1 ]; then
    TCP_STACK_LINE="net.inet.tcp.cc.algorithm=htcp"
    if [ "$DRY_RUN" -eq 0 ]; then
        sysctl net.inet.tcp.cc.algorithm=htcp >/dev/null 2>&1 || true
    fi
    warn "TCP stack: fallback to HTCP (BBR module unavailable)"
else
    TCP_STACK_LINE="# BBR/HTCP unavailable, kernel default (cubic) in use"
    warn "TCP stack: keeping kernel default (cubic)"
    if [ "$DRY_RUN" -eq 0 ]; then
        cat <<'HINT'
    To enable BBR on FreeBSD 14.0 or older:
      1. cd /usr/src/sys/amd64/conf && cp GENERIC BBR
      2. Append to the BBR file:
           ident        BBR
           makeoptions  WITH_EXTRA_TCP_STACKS=1
           options      TCPHPTS
           options      RATELIMIT
      3. cd /usr/src \
         && make -j"$(sysctl -n hw.ncpu)" KERNCONF=BBR buildkernel \
         && make KERNCONF=BBR installkernel
      4. Reboot, then re-run this installer.
HINT
    fi
fi

# --- offload policy ------------------------------------------------

APPLY_OFFLOAD=0
case "$OFFLOAD_MODE" in
    always) APPLY_OFFLOAD=1 ;;
    virt)   [ "$IS_VIRT" -eq 1 ] && APPLY_OFFLOAD=1 ;;
    never)  APPLY_OFFLOAD=0 ;;
esac

if [ "$APPLY_OFFLOAD" -eq 1 ]; then
    log "disabling NIC offloads on ${IFACE} (tso/lro/vlanhwtso)"
    if [ "$DRY_RUN" -eq 0 ]; then
        for opt in -tso -lro -vlanhwtso; do
            ifconfig "$IFACE" "$opt" 2>/dev/null || true
        done
    fi
else
    log "NIC offloads left intact (--offload=${OFFLOAD_MODE}, virt=${IS_VIRT})"
fi

# --- loader.conf drop-in -------------------------------------------
# Loader tunables are read at early boot and cannot be changed at
# runtime. Anything settable by sysctl(8) is kept out of this file
# to avoid silent duplication.

log "writing ${TUNE_LOADER}"
write_file "$TUNE_LOADER" <<EOF
# FasterSeedbox loader tunables, generated ${TS}
# Do not edit by hand; overwritten by the installer.

# TCP stack modules (bundled with GENERIC on FreeBSD 14.1+).
tcp_rack_load="YES"
tcp_bbr_load="YES"

# HTCP congestion control (used only when BBR is unavailable).
cc_htcp_load="YES"

# Interface send-queue length (the FreeBSD analogue of txqueuelen).
net.link.ifqmaxlen="10240"

# Netisr input queues.
net.isr.defaultqlimit="4096"
net.isr.maxqlimit="20480"

# Prefer MSI-X over legacy pin interrupts.
hw.pci.enable_msix="1"

# Per-driver ring-buffer tunables. These are loader-only; uncomment
# the line matching your NIC. Values shown are safe defaults for
# 1 GbE and 10 GbE adapters of the respective families.
# hw.igc.rxd="4096"    hw.igc.txd="4096"     # Intel I225/I226
# hw.igb.rxd="4096"    hw.igb.txd="4096"     # Intel 82576 / I350
# hw.ix.rxd="4096"     hw.ix.txd="4096"      # Intel ixgbe (10 GbE)
# hw.mlx5en.rx_queue_size="4096"              # Mellanox mlx5
# hw.vtnet.rx_process_limit="4096"            # VirtIO net
EOF

# --- sysctl.conf ---------------------------------------------------

log "writing ${TUNE_SYSCTL}"
write_file "$TUNE_SYSCTL" <<EOF
# FasterSeedbox runtime sysctls, generated ${TS}
# Do not edit by hand; overwritten by the installer.

# File descriptors.
kern.maxfiles=1048576
kern.maxfilesperproc=524288

# Socket and accept queues.
kern.ipc.maxsockbuf=${MAXSOCKBUF}
kern.ipc.somaxconn=524288
kern.ipc.soacceptqueue=524288

# Send/receive buffer auto-tuning bounded by per-socket maxima.
net.inet.tcp.sendbuf_max=${WMEM_MAX}
net.inet.tcp.recvbuf_max=${RMEM_MAX}
net.inet.tcp.sendbuf_auto=1
net.inet.tcp.recvbuf_auto=1
net.inet.tcp.sendbuf_inc=16384
net.inet.tcp.recvbuf_inc=524288
net.inet.tcp.sendspace=262144
net.inet.tcp.recvspace=262144

# TCP behavior.
net.inet.tcp.rfc1323=1
net.inet.tcp.sack.enable=1
net.inet.tcp.rfc6675_pipe=1
net.inet.tcp.mssdflt=1460
net.inet.tcp.minmss=536
net.inet.tcp.path_mtu_discovery=1
net.inet.tcp.initcwnd_segments=25
net.inet.tcp.ecn.enable=0
net.inet.tcp.abc_l_var=2
net.inet.tcp.nolocaltimewait=1
net.inet.tcp.tolerate_missing_ts=1
net.inet.tcp.syncookies=1

# Timers and keepalive (values in milliseconds).
net.inet.tcp.msl=5000
net.inet.tcp.keepidle=7200000
net.inet.tcp.keepintvl=60000
net.inet.tcp.keepcnt=15
net.inet.tcp.finwait2_timeout=5000
net.inet.tcp.fast_finwait2_recycle=1
net.inet.tcp.maxtcptw=10240

# IP layer / routing.
net.inet.ip.portrange.first=1024
net.inet.ip.portrange.last=65535
net.inet.ip.intr_queue_maxlen=100000
net.route.netisr_maxqlen=4096

# Buffer-cache write-back bounds (FreeBSD analogues of Linux
# vm.dirty_*).
vm.swap_enabled=1
vfs.hirunningspace=67108864
vfs.lorunningspace=33554432

# TCP stack / congestion control (chosen above by feature detect).
${TCP_STACK_LINE}
EOF

if [ "$DRY_RUN" -eq 0 ]; then
    service sysctl restart >/dev/null 2>&1 \
        || /etc/rc.d/sysctl reload >/dev/null 2>&1 \
        || true
fi
ok "sysctl applied"

# --- login.conf seedbox class --------------------------------------
# FreeBSD has no login-class wildcard; operators assign the class
# to the torrent user with:   pw usermod <user> -L seedbox

log "adding 'seedbox' login class to ${TUNE_LOGIN}"
append_once "$TUNE_LOGIN" '^seedbox:' <<'EOF'

# --- FasterSeedbox login class ---
seedbox:\
    :openfiles=1048576:\
    :maxproc=unlimited:\
    :memorylocked=unlimited:\
    :memoryuse=unlimited:\
    :stacksize=unlimited:\
    :datasize=unlimited:\
    :coredumpsize=unlimited:\
    :tc=default:
EOF

if [ "$DRY_RUN" -eq 0 ] \
     && grep -q '^seedbox:' "$TUNE_LOGIN" 2>/dev/null; then
    cap_mkdb "$TUNE_LOGIN"
    ok "login class ready; assign it with: pw usermod <user> -L seedbox"
fi

# --- rc.conf persistence -------------------------------------------

log "updating ${TUNE_RCCONF}"
if [ "$DRY_RUN" -eq 0 ]; then
    cp -p "$TUNE_RCCONF" "${TUNE_RCCONF}.bak-${TS}" 2>/dev/null || true

    # Persist BBR/RACK module loading through kld_list (skip if the
    # entry is already present).
    if [ "$BBR_OK" -eq 1 ]; then
        CUR_KLD="$(sysrc -qn kld_list 2>/dev/null || true)"
        case " ${CUR_KLD} " in
            *" tcp_rack "*) ;;
            *) sysrc -f "$TUNE_RCCONF" \
                     kld_list+=" tcp_rack tcp_bbr" >/dev/null ;;
        esac
    fi

    # powerd serves the same role as tuned on Linux: keep CPU
    # frequency adaptive but biased toward performance.
    sysrc -f "$TUNE_RCCONF" powerd_enable="YES" >/dev/null
    sysrc -f "$TUNE_RCCONF" \
          powerd_flags="-a hiadaptive -b hiadaptive -n hiadaptive" \
          >/dev/null

    if service powerd status >/dev/null 2>&1; then
        service powerd restart >/dev/null 2>&1 || true
    else
        service powerd start   >/dev/null 2>&1 || true
    fi

    # Persist offload flags on ifconfig_<iface> only when the user
    # asked for it (--offload=always or =virt on a VM).
    if [ "$APPLY_OFFLOAD" -eq 1 ]; then
        IFCFG_KEY="ifconfig_${IFACE}"
        CUR_IFCFG="$(sysrc -qn "$IFCFG_KEY" 2>/dev/null || true)"
        if [ -n "$CUR_IFCFG" ]; then
            case " ${CUR_IFCFG} " in
                *" -tso "*) ;;
                *) sysrc -f "$TUNE_RCCONF" \
                         "${IFCFG_KEY}=${CUR_IFCFG} -tso -lro -vlanhwtso" \
                         >/dev/null ;;
            esac
        else
            warn "${IFCFG_KEY} not set in rc.conf"
            warn "  add manually: sysrc ${IFCFG_KEY}+=\" -tso -lro -vlanhwtso\""
        fi
    fi
fi

# --- rc.d boot script ----------------------------------------------
# A minimal rcng service that confirms the default TCP stack and
# (optionally) re-disables offloads that DHCP or a link flap may
# have re-enabled. Controlled by seedbox_tune_enable / _offload in
# rc.conf.

log "installing ${TUNE_RCSCRIPT}"
write_file "$TUNE_RCSCRIPT" <<'RCSCRIPT'
#!/bin/sh
#
# PROVIDE: seedbox_tune
# REQUIRE: NETWORKING FILESYSTEMS sysctl
# KEYWORD: nojail
#
# Enable:  sysrc seedbox_tune_enable="YES"
# Offload: sysrc seedbox_tune_offload="YES"    # disable tso/lro/vlanhwtso
#

. /etc/rc.subr

name="seedbox_tune"
rcvar="seedbox_tune_enable"
start_cmd="seedbox_tune_start"
stop_cmd=":"

seedbox_tune_start()
{
    IFACE=$(route -n get -inet default 2>/dev/null \
            | awk '/interface:/{print $2; exit}')

    if [ -n "${seedbox_tune_offload:-}" ] && [ -n "${IFACE:-}" ]; then
        ifconfig "$IFACE" -tso -lro -vlanhwtso 2>/dev/null || true
    fi

    # Confirm the default stack when BBR is advertised (grep -qx
    # matches an exact line to avoid partial matches like 'bbrv2').
    if sysctl -n net.inet.tcp.functions_available 2>/dev/null \
         | tr ' ' '\n' | grep -qx bbr; then
        sysctl net.inet.tcp.functions_default=bbr \
            >/dev/null 2>&1 || true
    fi
}

load_rc_config $name
: "${seedbox_tune_enable:=NO}"
: "${seedbox_tune_offload:=}"
run_rc_command "$1"
RCSCRIPT

if [ "$DRY_RUN" -eq 0 ]; then
    chmod +x "$TUNE_RCSCRIPT"
    sysrc -f "$TUNE_RCCONF" seedbox_tune_enable="YES" >/dev/null
    if [ "$APPLY_OFFLOAD" -eq 1 ]; then
        sysrc -f "$TUNE_RCCONF" seedbox_tune_offload="YES" >/dev/null
    else
        sysrc -f "$TUNE_RCCONF" seedbox_tune_offload="" >/dev/null
    fi
fi
ok "rc.d service installed and enabled"

# --- verification --------------------------------------------------

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
    verify_sysctl kern.ipc.somaxconn 524288
    verify_sysctl kern.ipc.maxsockbuf "$MAXSOCKBUF"
    if [ "$BBR_OK" -eq 1 ]; then
        verify_sysctl net.inet.tcp.functions_default bbr
    fi
fi

# --- summary -------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf '                 FasterSeedbox tuning complete\n'
printf '============================================================\n'
printf ' Interface     : %s\n' "$IFACE"
printf ' Memory        : %s KB (%s MB)\n' "$MEM_KB" "$((MEM_KB / 1024))"
printf ' rmem_max      : %s\n' "$RMEM_MAX"
printf ' wmem_max      : %s\n' "$WMEM_MAX"
printf ' maxsockbuf    : %s\n' "$MAXSOCKBUF"
if [ "$DRY_RUN" -eq 0 ]; then
    printf ' TCP stack     : %s\n' \
        "$(sysctl -n net.inet.tcp.functions_default 2>/dev/null || echo '?')"
    printf ' CC algorithm  : %s\n' \
        "$(sysctl -n net.inet.tcp.cc.algorithm 2>/dev/null || echo '?')"
fi
printf ' Offload mode  : %s (applied=%d)\n' "$OFFLOAD_MODE" "$APPLY_OFFLOAD"
printf ' Backup suffix : .bak-%s\n' "$TS"

printf '\n Files managed by this run:\n'
printf '   %s\n' "$TUNE_LOADER"
printf '   %s\n' "$TUNE_SYSCTL"
printf '   %s   (seedbox class appended)\n' "$TUNE_LOGIN"
printf '   %s   (sysrc edits)\n' "$TUNE_RCCONF"
printf '   %s\n' "$TUNE_RCSCRIPT"

printf '\n Notes:\n'
printf '   * loader.conf tunables require reboot to take full effect.\n'
printf '   * Assign the login class:  pw usermod <user> -L seedbox\n'
if [ "$BBR_OK" -ne 1 ]; then
    printf '   * BBR not loaded. On FreeBSD 14.0 or older, rebuild the\n'
    printf '     kernel with WITH_EXTRA_TCP_STACKS=1 (see HINT above).\n'
fi

printf '\n Rollback:\n'
printf '   cp %s.bak-%s %s\n'     "$TUNE_SYSCTL" "$TS" "$TUNE_SYSCTL"
printf '   cp %s.bak-%s %s\n'     "$TUNE_RCCONF" "$TS" "$TUNE_RCCONF"
printf '   cp %s.bak-%s %s && cap_mkdb %s\n' \
       "$TUNE_LOGIN" "$TS" "$TUNE_LOGIN" "$TUNE_LOGIN"
printf '   rm -f %s %s\n'         "$TUNE_LOADER" "$TUNE_RCSCRIPT"
printf '   service sysctl reload && reboot\n'
printf '============================================================\n'

if [ "$ERRORS" -gt 0 ]; then
    printf '\n'
    warn "${ERRORS} issue(s) reported; review log above."
    exit 3
fi

exit 0
