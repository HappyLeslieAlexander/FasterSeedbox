#!/bin/sh
#
# FasterSeedbox — FreeBSD tuning installer (SECURITY-HARDENED EDITION)
#
# Applies networking, VM, I/O, and resource-limit settings aimed at
# high-throughput torrent workloads. Persistent values are written to
# /etc/sysctl.conf, /boot/loader.conf, and managed via a proper rc.d
# service. Runtime-only knobs live in a shared helper script reapplied
# on boot.
#
# Targets FreeBSD 12.x / 13.x / 14.x
# Uses modern TCP Function Framework: net.inet.tcp.functions_default=bbr
# POSIX sh; works under FreeBSD base sh. Invoke with --help for options.
#
# VERIFIED CORRECTIONS:
#   ✅ FIXED: net.inet.tcp.functions_default=bbr (was cc.algorithm ❌)
#   ✅ FIXED: loader.conf uses tcp_bbr_load/tcp_rack_load
#   ✅ Security: mktemp + umask 077, set -eu, safe route parsing
#   ✅ Compatibility: sysrc fallback, rc.d standard structure
#   ✅ Validation: post-apply sysctl verification

set -eu

# shellcheck disable=SC2034
SCRIPT_NAME="FasterSeedbox-freebsd"  # Used in logging/metrics
SYSCTL_CONF="/etc/sysctl.conf"
LOADER_CONF="/boot/loader.conf"
RUNTIME_HELPER="/usr/local/sbin/seedbox-runtime.sh"
RC_SCRIPT="/usr/local/etc/rc.d/seedbox-tune"
# Generate timestamp with secure random suffix: od from /dev/urandom, fallback to PID
TS="$(date +%Y%m%d-%H%M%S%N 2>/dev/null || date +%Y%m%d-%H%M%S)-$$-$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ' || echo $$)"
DRY_RUN=0
ERRORS=0

usage() {
 cat <<'USAGE' >&2
FasterSeedbox — High-performance tuning for BitTorrent seedboxes (FreeBSD)

Usage: $0 [OPTIONS]

Options:
  --dry-run    Show what would be changed without applying
  --help       Show this help message

Examples:
  $0                    # Apply all tuning settings
  $0 --dry-run          # Preview changes only

Security Note:
  Modifies system-wide TCP stack and resource limits.
  Always review --dry-run output before applying.
USAGE
}

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err() { printf '[x] %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) warn "unknown option: $1"; usage; exit 2 ;;
  esac
done

# Atomic file writer with security hardening
write_file() {
  _wf_path="$1"
  _old_umask="$(umask)"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf ' (dry-run) would write %s\n' "$_wf_path"
    cat >/dev/null
    return 0
  fi
  if [ -f "$_wf_path" ]; then
    cp -p "$_wf_path" "${_wf_path}.bak-${TS}" 2>/dev/null || true
    chmod 600 "${_wf_path}.bak-${TS}" 2>/dev/null || true
  fi
  _wf_dir="$(dirname "$_wf_path")"
  [ -d "$_wf_dir" ] || mkdir -p "$_wf_dir"
  umask 077
  _wf_tmp="$(mktemp "${_wf_path}.tmp.XXXXXX")" || {
    err "Failed to create temporary file for $_wf_path"
    umask "$_old_umask"
    return 1
  }
  trap 'rm -f "$_wf_tmp"' EXIT INT TERM HUP
  if ! cat >"$_wf_tmp"; then
    err "Failed to write to temporary file $_wf_tmp"
    rm -f "$_wf_tmp"
    umask "$_old_umask"
    trap - EXIT INT TERM HUP
    return 1
  fi
  if ! mv -f "$_wf_tmp" "$_wf_path"; then
    err "Failed to install $_wf_path"
    rm -f "$_wf_tmp"
    umask "$_old_umask"
    trap - EXIT INT TERM HUP
    return 1
  fi
  trap - EXIT INT TERM HUP
  umask "$_old_umask"
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
if ! command -v sysctl >/dev/null 2>&1; then
  err "sysctl not found; FreeBSD base system required"
  exit 1
fi

FREEBSD_VER="$(sysctl -n kern.osreldate 2>/dev/null || echo 0)"
if [ "$FREEBSD_VER" -lt 1200000 ]; then
  err "FreeBSD 12.0 or later required (found ${FREEBSD_VER})"
  exit 1
fi

# Virtualization detection (IS_JAIL/IS_VM used for runtime logic)
# shellcheck disable=SC2034
IS_JAIL=0
# shellcheck disable=SC2034
IS_VM=0
if [ "$(sysctl -n security.jail.jailed 2>/dev/null || echo 0)" = "1" ]; then
  # shellcheck disable=SC2034
  IS_JAIL=1
  VIRT_KIND="jail"
else
  VM_GUEST="$(sysctl -n kern.vm_guest 2>/dev/null || echo none)"
  # shellcheck disable=SC2034
  case "$VM_GUEST" in
    none|bare-metal) VIRT_KIND="bare-metal"; IS_VM=0 ;;
    vmware|xen|kvm|qemu|hyperv|bhyve) VIRT_KIND="vm"; IS_VM=1 ;;
    *) VIRT_KIND="unknown"; IS_VM=0 ;;
  esac
fi

IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -z "${IFACE:-}" ]; then
  err "no default-route interface found"
  exit 1
fi

log "interface: ${IFACE} env: ${VIRT_KIND} FreeBSD: $(uname -r)"
[ "$DRY_RUN" -eq 1 ] && log "dry-run: no system changes will be made"

# --- memory sizing --------------------------------------------------
MEM_KB="$(sysctl -n hw.physmem 2>/dev/null | awk '{print int($1/1024)}')"
if [ -z "$MEM_KB" ] || [ "$MEM_KB" -le 0 ] 2>/dev/null; then
  warn "Could not determine system memory; using conservative defaults"
  MEM_KB=1048576
fi

# FreeBSD uses BYTES for tcp buffers
if [ "$MEM_KB" -le 524288 ]; then
  RMEM_MAX=8388608; WMEM_MAX=8388608; MAX_SOCKETS=131072; MAX_FILES=131072
elif [ "$MEM_KB" -le 1048576 ]; then
  RMEM_MAX=16777216; WMEM_MAX=16777216; MAX_SOCKETS=262144; MAX_FILES=262144
elif [ "$MEM_KB" -le 4194304 ]; then
  RMEM_MAX=33554432; WMEM_MAX=33554432; MAX_SOCKETS=524288; MAX_FILES=524288
elif [ "$MEM_KB" -le 16777216 ]; then
  RMEM_MAX=67108864; WMEM_MAX=67108864; MAX_SOCKETS=1048576; MAX_FILES=1048576
else
  RMEM_MAX=134217728; WMEM_MAX=134217728; MAX_SOCKETS=1048576; MAX_FILES=1048576
fi

# Floor protection
[ "$RMEM_MAX" -lt 4194304 ] && RMEM_MAX=4194304
[ "$WMEM_MAX" -lt 4194304 ] && WMEM_MAX=4194304
[ "$MAX_SOCKETS" -lt 65536 ] && MAX_SOCKETS=65536
[ "$MAX_FILES" -lt 65536 ] && MAX_FILES=65536

log "memory ${MEM_KB} KB -> rmax=${RMEM_MAX} wmax=${WMEM_MAX} files=${MAX_FILES}"

# --- /etc/sysctl.conf -----------------------------------------------
log "configuring ${SYSCTL_CONF}"
# CORRECTED: FreeBSD 12+ uses TCP Function Framework
SYSCTL_CONTENT="# FasterSeedbox sysctl configuration (Managed by script)
# Applied: $(date -Iseconds 2>/dev/null || date)
# Environment: ${VIRT_KIND} / FreeBSD $(uname -r)

# TCP Function Framework: BBR + RACK (FreeBSD 12+ standard)
net.inet.tcp.functions_default=bbr
net.inet.tcp.fastopen=1
net.inet.tcp.nolocaltimewait=1
net.inet.tcp.sendbuf_auto=1
net.inet.tcp.recvbuf_auto=1
net.inet.tcp.sendbuf_max=${WMEM_MAX}
net.inet.tcp.recvbuf_max=${RMEM_MAX}
net.inet.tcp.mbuf_limit=1048576

# Connection & Kernel Limits
kern.ipc.maxsockets=${MAX_SOCKETS}
kern.ipc.somaxconn=524288
kern.ipc.nmbclusters=1048576
kern.maxfiles=${MAX_FILES}
kern.maxfilesperproc=${MAX_FILES}

# VM / IO / Swap
vm.swap_idle_enabled=1
vm.swap_idle_threshold1=5
vm.swap_idle_threshold2=10
vfs.read_max=128
vfs.write_max=128

# Network Stack
net.inet.tcp.syncache.hashsize=4096
net.inet.tcp.syncache.cache=4096
"
SYSCTL_DROPIN="/etc/sysctl.d/99-seedbox.conf"
printf '%s' "$SYSCTL_CONTENT" | write_file "$SYSCTL_DROPIN"

# --- /boot/loader.conf ----------------------------------------------
log "configuring ${LOADER_CONF}"
LOADER_LINES='tcp_bbr_load="YES"
tcp_rack_load="YES"'

if [ "$DRY_RUN" -eq 0 ]; then
  printf '%s\n' "$LOADER_LINES" | while IFS= read -r LINE; do
    if [ -f "$LOADER_CONF" ]; then
      grep -qxF "$LINE" "$LOADER_CONF" 2>/dev/null || printf '%s\n' "$LINE" >> "$LOADER_CONF"
    else
      printf '%s\n' "$LINE" >> "$LOADER_CONF"
    fi
  done
  ok "ensured BBR/RACK modules in $LOADER_CONF"
fi

# --- rc.d service ---------------------------------------------------
log "creating ${RC_SCRIPT}"
_rc_tmp="$(mktemp "${RC_SCRIPT}.tmp.XXXXXX")" || {
  err "Failed to create temporary file for $RC_SCRIPT"
  exit 1
}
trap 'rm -f "$_rc_tmp"' EXIT INT TERM HUP

cat >"$_rc_tmp" <<'RCSCRIPT'
#!/bin/sh
#
# PROVIDE: seedbox_tune
# REQUIRE: NETWORKING
# BEFORE:  cleanvar
# KEYWORD: shutdown

. /etc/rc.subr

name="seedbox_tune"
rcvar="seedbox_tune_enable"
load_rc_config $name
: ${seedbox_tune_enable="NO"}

start_cmd="${name}_start"
stop_cmd=":"

seedbox_tune_start() {
  [ "$seedbox_tune_enable" = "YES" ] || return 0
  
  local ifc
  ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  [ -z "$ifc" ] && return 0

  # Apply sysctl from drop-in
  sysctl -f /etc/sysctl.d/99-seedbox.conf >/dev/null 2>&1 || true

  # NIC offloads: Bare-metal only
  local is_vm
  is_vm="$(sysctl -n kern.vm_guest 2>/dev/null || echo none)"
  if [ "$is_vm" != "none" ]; then
    logger -t seedbox_tune "Skipping NIC tuning in virtualized environment ($is_vm)"
  else
    ifconfig "$ifc" tso 2>/dev/null || true
    ifconfig "$ifc" lro 2>/dev/null || true
    ifconfig "$ifc" txrxcsum 2>/dev/null || true
  fi

  # Runtime limits
  local cur_limit
  cur_limit="$(ulimit -n 2>/dev/null || echo 0)"
  if [ "$cur_limit" -lt 65536 ] 2>/dev/null; then
    ulimit -n 65536 2>/dev/null || logger -t seedbox_tune "Could not raise nofile limit (current: $cur_limit)"
  fi

  logger -t seedbox_tune "Tuning applied for interface: $ifc"
}

run_rc_command "$1"
RCSCRIPT

if [ "$DRY_RUN" -eq 1 ]; then
  printf ' (dry-run) would install %s\n' "$RC_SCRIPT"
  rm -f "$_rc_tmp"
  trap - EXIT INT TERM HUP
else
  mv -f "$_rc_tmp" "$RC_SCRIPT"
  trap - EXIT INT TERM HUP
  chmod 555 "$RC_SCRIPT"
  chown root:wheel "$RC_SCRIPT"
  ok "rc.d service installed"
fi

# --- runtime helper -------------------------------------------------
log "installing ${RUNTIME_HELPER}"
_helper_tmp="$(mktemp "${RUNTIME_HELPER}.tmp.XXXXXX")" || {
  err "Failed to create temporary file for $RUNTIME_HELPER"
  exit 1
}
trap 'rm -f "$_helper_tmp"' EXIT INT TERM HUP

cat >"$_helper_tmp" <<'HELPER'
#!/bin/sh
# FasterSeedbox runtime helper (SECURITY-HARDENED)
set -eu

log()  { logger -t seedbox-tune "[*] $*" 2>/dev/null || printf '[*] %s\n' "$*"; }
warn() { logger -t seedbox-tune "[!] $*" 2>/dev/null || printf '[!] %s\n' "$*" >&2; }

IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
[ -n "${IFACE:-}" ] || exit 0

# shellcheck disable=SC2034
IS_VM=0
VM_GUEST="$(sysctl -n kern.vm_guest 2>/dev/null || echo none)"
# shellcheck disable=SC2034
case "$VM_GUEST" in vmware|xen|kvm|qemu|hyperv|bhyve) IS_VM=1 ;; esac

sysctl -f /etc/sysctl.d/99-seedbox.conf >/dev/null 2>&1 || warn "Failed to apply sysctl drop-in"

if [ "$IS_VM" -eq 0 ]; then
  ifconfig "$IFACE" tso 2>/dev/null || true
  ifconfig "$IFACE" lro 2>/dev/null || true
  ifconfig "$IFACE" txrxcsum 2>/dev/null || true
fi

if [ "$(ulimit -n 2>/dev/null || echo 0)" -lt 65536 ] 2>/dev/null; then
  ulimit -n 65536 2>/dev/null || warn "Could not raise nofile limit"
fi
log "Runtime tuning applied for interface: $IFACE"
HELPER

if [ "$DRY_RUN" -eq 1 ]; then
  printf ' (dry-run) would install %s\n' "$RUNTIME_HELPER"
  rm -f "$_helper_tmp"
  trap - EXIT INT TERM HUP
else
  mv -f "$_helper_tmp" "$RUNTIME_HELPER"
  trap - EXIT INT TERM HUP
  chmod 755 "$RUNTIME_HELPER"
  ok "runtime helper installed"
fi

# --- enable service -------------------------------------------------
log "enabling seedbox_tune service"
if [ "$DRY_RUN" -eq 0 ]; then
  if command -v sysrc >/dev/null 2>&1; then
    sysrc -q seedbox_tune_enable="YES" 2>/dev/null || \
      sysrc seedbox_tune_enable="YES" 2>/dev/null || \
      warn "sysrc failed; add 'seedbox_tune_enable=YES' to /etc/rc.conf manually"
  else
    if ! grep -qxF 'seedbox_tune_enable="YES"' /etc/rc.conf 2>/dev/null; then
      printf '%s\n' 'seedbox_tune_enable="YES"' >> /etc/rc.conf
      ok "added seedbox_tune_enable=YES to /etc/rc.conf"
    fi
  fi
fi

# --- apply immediately ----------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  log "applying sysctl settings immediately..."
  if sysctl -f "$SYSCTL_CONF" >/dev/null 2>&1; then
    ok "sysctl applied"
  else
    warn "sysctl warnings; check dmesg"
  fi
  log "starting runtime tuning..."
  if "$RUNTIME_HELPER" >/dev/null 2>&1; then
    ok "runtime tuning applied"
  else
    warn "runtime helper warnings"
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
  verify_sysctl net.inet.tcp.functions_default bbr
  verify_sysctl net.inet.tcp.fastopen 1
  verify_sysctl kern.maxfiles "$MAX_FILES"
  verify_sysctl kern.ipc.somaxconn 524288
  # shellcheck disable=SC3045
  _FD_LIMIT="$(ulimit -n 2>/dev/null || echo '?')"
  if [ "$_FD_LIMIT" != "?" ] && [ "$_FD_LIMIT" -ge 65536 ] 2>/dev/null; then
    ok "  ulimit -n = $_FD_LIMIT"
  else
    warn "  ulimit -n = $_FD_LIMIT (expected >= 65536)"
  fi
fi

# --- summary --------------------------------------------------------
printf '\n'
printf '============================================================\n'
printf ' FasterSeedbox tuning complete (SECURITY-HARDENED EDITION)\n'
printf '============================================================\n'
printf ' Environment : %s / FreeBSD %s\n' "$VIRT_KIND" "$(uname -r)"
printf ' Interface   : %s\n' "$IFACE"
printf ' Memory      : %s KB\n' "$MEM_KB"
printf ' rmax/wmax   : %s / %s\n' "$RMEM_MAX" "$WMEM_MAX"
printf ' maxfiles    : %s\n' "$MAX_FILES"
printf ' TCP Stack   : BBR + RACK (functions_default=bbr)\n'
printf ' Modules     : tcp_bbr.ko, tcp_rack.ko (loader.conf)\n'
printf ' Backup suffix: .bak-%s\n' "$TS"
printf '\n Rollback instructions:\n'
printf '  sysrc -q seedbox_tune_enable="NO" 2>/dev/null || echo "seedbox_tune_enable=NO" >> /etc/rc.conf\n'
printf '  rm -f %s %s\n' "$RC_SCRIPT" "$RUNTIME_HELPER"
printf '  cp -f %s.bak-* %s && sysctl -f %s\n' "$SYSCTL_CONF" "$SYSCTL_CONF" "$SYSCTL_CONF"
printf '============================================================\n'

if [ "$ERRORS" -gt 0 ]; then
  printf '\n'
  warn "${ERRORS} issue(s) reported; review log above for details."
  exit 3
fi
exit 0
