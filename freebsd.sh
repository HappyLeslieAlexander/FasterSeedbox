#!/bin/sh
# ════════════════════════════════════════════════════════════════
#  Seedbox 系统调优脚本 — FreeBSD
#
#  参数侧的语义对应自 jerry048/Dedicated-Seedbox 的
#  seedbox_installation.sh，使用 FreeBSD 原生机制实现等价调优：
#    • powerd          ≈ Linux tuned (CPU 调频)
#    • login.conf      ≈ Linux limits.conf
#    • loader.conf     ≈ Linux modules-load.d + 部分 sysctl 早期参数
#    • rc.conf 持久化  ≈ Linux systemd unit
#
#  BBR 在 FreeBSD 是 TCP stack（非 CC 算法），需 tcp_bbr.ko + tcp_rack.ko
#  FreeBSD 14.1+ / 15 GENERIC 内核已自带这两个模块，可直接 kldload
#  FreeBSD 14.0 及更早需 WITH_EXTRA_TCP_STACKS=1 + TCPHPTS 自编内核
#  本脚本：能加载就用 BBR；否则回退到 cubic / htcp 拥塞控制
# ════════════════════════════════════════════════════════════════

set -eu

# ── 前置检查 ─────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] 需 root 权限运行"
    exit 1
fi

# ── 备份现有配置 ─────────────────────────────────────────────
TS=$(date +%Y%m%d-%H%M%S)
echo "[*] 备份现有配置 (后缀 .bak-${TS})"
for f in /etc/sysctl.conf /boot/loader.conf /etc/rc.conf /etc/login.conf; do
    if [ -f "$f" ]; then
        cp -p "$f" "${f}.bak-${TS}"
        echo "    ${f} -> ${f}.bak-${TS}"
    fi
done

# ── 默认网卡 ─────────────────────────────────────────────────
IFACE=$(route -n get -inet default 2>/dev/null | awk '/interface:/{print $2; exit}')
if [ -z "${IFACE:-}" ]; then
    echo "[!] 未找到默认路由网卡，退出"
    exit 1
fi
echo "[*] 默认网卡: $IFACE"

# ── 物理内存（KB） ───────────────────────────────────────────
MEM_BYTES=$(sysctl -n hw.physmem)
MEM_KB=$((MEM_BYTES / 1024))
echo "[*] 物理内存: $((MEM_KB / 1024)) MB"

# ── 按内存分级计算 TCP buffer（对齐 jerry048 的分档） ────────
# FreeBSD 不需要 tcp_adv_win_scale；这里只取 rmem_max / wmem_max
if   [ "$MEM_KB" -le 524288 ];   then    # ≤ 512 MB
    rmem_max=8388608;   wmem_max=8388608
elif [ "$MEM_KB" -le 1048576 ];  then    # ≤ 1 GB
    rmem_max=16777216;  wmem_max=16777216
elif [ "$MEM_KB" -le 4194304 ];  then    # ≤ 4 GB
    rmem_max=33554432;  wmem_max=33554432
elif [ "$MEM_KB" -le 16777216 ]; then    # ≤ 16 GB
    rmem_max=67108864;  wmem_max=67108864
else                                     # > 16 GB
    rmem_max=134217728; wmem_max=134217728
fi

# FreeBSD 要求 kern.ipc.maxsockbuf ≥ max(rmem,wmem) * 2
if [ "$rmem_max" -ge "$wmem_max" ]; then
    maxsockbuf=$((rmem_max * 2))
else
    maxsockbuf=$((wmem_max * 2))
fi

echo "[✓] rmem_max=$rmem_max  wmem_max=$wmem_max  maxsockbuf=$maxsockbuf"

# ── 关闭硬件 offload (runtime) ───────────────────────────────
# FreeBSD 上 TSO / LRO 与 BPF / pf / 高吞吐场景常有兼容性问题，
# 关闭后由 TCP stack 自身做分段；TXCSUM/RXCSUM 仍保留以减小 CPU 负担
echo "[*] 关闭网卡硬件 offload (TSO / LRO / VLAN_HWTSO)..."
for opt in -tso -lro -vlanhwtso; do
    ifconfig "$IFACE" $opt 2>/dev/null || true
done
echo "[✓] runtime offload 已关闭（持久化项见 rc.conf）"

# ── 加载 TCP RACK / BBR 模块 ─────────────────────────────────
# FreeBSD 14.1+ / 15 GENERIC 内核自带 tcp_rack.ko 与 tcp_bbr.ko，
# kldload 应直接成功；失败一般意味着旧版 FreeBSD 或自定义精简内核
BBR_OK=0
echo "[*] 加载 TCP RACK / BBR 模块..."
if kldload tcp_rack 2>/dev/null || kldstat -q -m tcp_rack; then
    echo "[✓] tcp_rack 已加载"
    if kldload tcp_bbr 2>/dev/null || kldstat -q -m tcp_bbr; then
        echo "[✓] tcp_bbr 已加载"
        BBR_OK=1
    else
        echo "[!] tcp_bbr 加载失败（可能为 FreeBSD 14.0 及更早，或自定义内核未含此模块）"
    fi
else
    echo "[!] tcp_rack 加载失败（可能为 FreeBSD 14.0 及更早，或自定义内核未含此模块）"
fi

# ── 选择 TCP stack / 拥塞控制 ────────────────────────────────
if [ "$BBR_OK" -eq 1 ]; then
    sysctl net.inet.tcp.functions_default=bbr >/dev/null 2>&1 || true
    TCP_STACK_CFG='net.inet.tcp.functions_default=bbr'
    echo "[✓] 默认 TCP stack 已切换到 bbr"
else
    # 回退方案：默认 stack + HTCP 拥塞控制（高 BDP 链路下表现优于 cubic）
    kldload cc_htcp 2>/dev/null || true
    if sysctl -n net.inet.tcp.cc.available 2>/dev/null | grep -q htcp; then
        sysctl net.inet.tcp.cc.algorithm=htcp >/dev/null 2>&1 || true
        TCP_STACK_CFG='net.inet.tcp.cc.algorithm=htcp'
        echo "[!] 回退方案：默认 stack + htcp 拥塞控制"
    else
        TCP_STACK_CFG='# 未能启用 bbr/htcp，保留默认 cubic'
        echo "[!] htcp 不可用，保留默认 cubic"
    fi
    cat <<'HINT'
    ┌─ 旧版 FreeBSD 启用 BBR 的方法（仅当上面 kldload 失败时需要）─┐
    │ 1) cd /usr/src/sys/amd64/conf                                │
    │    cp GENERIC BBR                                            │
    │ 2) 编辑 BBR 文件，追加：                                     │
    │      ident         BBR                                       │
    │      makeoptions   WITH_EXTRA_TCP_STACKS=1                   │
    │      options       TCPHPTS                                   │
    │      options       RATELIMIT                                 │
    │ 3) 编译并安装：                                              │
    │      cd /usr/src                                             │
    │      make -j$(sysctl -n hw.ncpu) KERNCONF=BBR buildkernel    │
    │      make KERNCONF=BBR installkernel                         │
    │      shutdown -r now                                         │
    │ 4) 重启后再跑一次本脚本即可启用 BBR                          │
    └──────────────────────────────────────────────────────────────┘
HINT
fi

# ── /boot/loader.conf.d/seedbox.conf ─────────────────────────
# loader tunables 必须在内核启动早期生效，单独放在 conf.d 便于回滚
echo "[*] 写入 /boot/loader.conf.d/seedbox.conf"
mkdir -p /boot/loader.conf.d
cat > /boot/loader.conf.d/seedbox.conf <<EOF
# Seedbox tuning — loader tunables (生效需 reboot)
# 由调优脚本生成 @ ${TS}

# TCP stack 模块（FreeBSD 14.1+ / 15 默认包含；旧版需自编内核）
tcp_rack_load="YES"
tcp_bbr_load="YES"

# HTCP 拥塞控制（BBR 不可用时的备选）
cc_htcp_load="YES"

# 文件句柄上限（早期就应可用）
kern.maxfiles="1048576"
kern.maxfilesperproc="524288"

# 接口发送队列长度（≈ Linux txqueuelen）
net.link.ifqmaxlen="10240"

# 网络中断 / 软中断队列缓冲
net.isr.defaultqlimit="4096"
net.isr.maxqlimit="20480"

# 启用 MSI-X（多数现代网卡默认开启）
hw.pci.enable_msix="1"

# —— NIC 驱动 ring buffer 上限示例（按实际网卡解开注释） ——
# Intel igc:      hw.igc.rxd="4096"   hw.igc.txd="4096"
# Intel em/igb:   hw.igb.rxd="4096"   hw.igb.txd="4096"
# Intel ix (10G): hw.ix.rxd="4096"    hw.ix.txd="4096"
# Mellanox mlx5:  hw.mlx5en.rx_queue_size="4096"
# Virtio:         hw.vtnet.rx_process_limit="4096"
EOF

# ── /etc/sysctl.conf ─────────────────────────────────────────
# runtime sysctl，开机时 service sysctl 自动加载
echo "[*] 写入 /etc/sysctl.conf"
cat > /etc/sysctl.conf <<EOF
# Seedbox tuning — FreeBSD runtime sysctls
# 由调优脚本生成 @ ${TS}

# —— 文件句柄 ————————————————
kern.maxfiles=1048576
kern.maxfilesperproc=524288

# —— socket / 连接队列 ————————
kern.ipc.maxsockbuf=${maxsockbuf}
kern.ipc.somaxconn=524288
kern.ipc.soacceptqueue=524288

# —— 网络缓冲 ————————————————
net.inet.tcp.sendbuf_max=${wmem_max}
net.inet.tcp.recvbuf_max=${rmem_max}
net.inet.tcp.sendbuf_auto=1
net.inet.tcp.recvbuf_auto=1
net.inet.tcp.sendbuf_inc=16384
net.inet.tcp.recvbuf_inc=524288
net.inet.tcp.sendspace=262144
net.inet.tcp.recvspace=262144

# —— TCP 行为 ————————————————
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

# —— 超时 / keepalive ————————
net.inet.tcp.msl=5000
net.inet.tcp.keepidle=7200000
net.inet.tcp.keepintvl=60000
net.inet.tcp.keepcnt=15
net.inet.tcp.finwait2_timeout=5000
net.inet.tcp.fast_finwait2_recycle=1
net.inet.tcp.maxtcptw=10240

# —— IP 层 ————————————————
net.inet.ip.portrange.first=1024
net.inet.ip.portrange.last=65535
net.inet.ip.intr_queue_maxlen=100000
net.route.netisr_maxqlen=4096

# —— VM / dirty（对应 Linux vm.dirty_*） ————
vm.swap_enabled=1
vfs.hirunningspace=67108864
vfs.lorunningspace=33554432

# —— 拥塞控制 / TCP stack ——————
${TCP_STACK_CFG}
EOF

# 立即应用 sysctl
service sysctl restart >/dev/null 2>&1 || \
    /etc/rc.d/sysctl reload >/dev/null 2>&1 || true
echo "[✓] sysctl 已应用"

# ── /etc/login.conf：seedbox 用户 class ───────────────────────
# 对应 Linux limits.conf；FreeBSD 不支持通配符，需为目标用户分配 class
echo "[*] 配置 /etc/login.conf"
if ! grep -q '^seedbox:' /etc/login.conf 2>/dev/null; then
    cat >> /etc/login.conf <<'EOF'

# --- added by seedbox tuning ---
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
    cap_mkdb /etc/login.conf
    echo "[✓] login class 'seedbox' 已添加"
    echo "    将用户加入此 class:  pw usermod <user> -L seedbox"
else
    echo "[*] 'seedbox' class 已存在，跳过"
fi

# ── /etc/rc.conf 持久化 ──────────────────────────────────────
echo "[*] 更新 /etc/rc.conf"

# 开机自动 kldload 模块（检查已有值，避免重复追加）
if [ "$BBR_OK" -eq 1 ]; then
    CUR_KLD=$(sysrc -n kld_list 2>/dev/null || true)
    case " $CUR_KLD " in
        *" tcp_rack "*) ;;   # 已包含，跳过
        *) sysrc -f /etc/rc.conf kld_list+=" tcp_rack tcp_bbr" >/dev/null ;;
    esac
fi

# powerd ≈ Linux tuned 的 throughput-performance profile
sysrc -f /etc/rc.conf powerd_enable="YES" >/dev/null
sysrc -f /etc/rc.conf powerd_flags="-a hiadaptive -b hiadaptive -n hiadaptive" >/dev/null

# 启动 powerd：根据当前运行状态选择 start / restart
if service powerd status >/dev/null 2>&1; then
    service powerd restart >/dev/null 2>&1 || true
    echo "[✓] powerd 已重启"
else
    service powerd start   >/dev/null 2>&1 || true
    echo "[✓] powerd 已启动"
fi

# 在现有 ifconfig_<IFACE> 行尾追加 -tso -lro -vlanhwtso（持久化 offload 关闭）
IFCFG_KEY="ifconfig_${IFACE}"
if sysrc -qn "$IFCFG_KEY" >/dev/null 2>&1; then
    CUR=$(sysrc -n "$IFCFG_KEY")
    case " $CUR " in
        *" -tso "*) ;;
        *) sysrc -f /etc/rc.conf "${IFCFG_KEY}=${CUR} -tso -lro -vlanhwtso" >/dev/null ;;
    esac
else
    echo "[!] rc.conf 中未发现 ${IFCFG_KEY}，请手动追加 offload 关闭项："
    echo "      sysrc ${IFCFG_KEY}+=\" -tso -lro -vlanhwtso\""
fi

# ── /usr/local/etc/rc.d/seedbox_tune：开机自启脚本 ───────────
# 兜底：DHCP 等场景下 ifconfig 行可能被覆盖，启动时再次关闭 offload
echo "[*] 创建开机自启 rc.d 脚本"
cat > /usr/local/etc/rc.d/seedbox_tune <<'BOOTEOF'
#!/bin/sh
#
# PROVIDE: seedbox_tune
# REQUIRE: NETWORKING FILESYSTEMS sysctl
# KEYWORD: nojail
#
# Enable with: sysrc seedbox_tune_enable=YES

. /etc/rc.subr

name="seedbox_tune"
rcvar="seedbox_tune_enable"
start_cmd="seedbox_tune_start"
stop_cmd=":"

seedbox_tune_start()
{
    # 关闭硬件 offload（rc.conf 已持久化，这里兜底防被 DHCP 等流程覆盖）
    IFACE=$(route -n get -inet default 2>/dev/null | \
            awk '/interface:/{print $2; exit}')
    [ -n "$IFACE" ] && {
        ifconfig "$IFACE" -tso -lro -vlanhwtso 2>/dev/null || true
    }

    # 若 tcp_bbr 已通过 kld_list 加载，再次确认默认 stack 为 bbr
    if sysctl -n net.inet.tcp.functions_available 2>/dev/null | \
            grep -q bbr; then
        sysctl net.inet.tcp.functions_default=bbr >/dev/null 2>&1 || true
    fi
}

load_rc_config $name
: ${seedbox_tune_enable:=NO}
run_rc_command "$1"
BOOTEOF
chmod +x /usr/local/etc/rc.d/seedbox_tune
sysrc -f /etc/rc.conf seedbox_tune_enable="YES" >/dev/null
echo "[✓] /usr/local/etc/rc.d/seedbox_tune 已就位并启用"

# ── 状态汇总 ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "              调优完成"
echo "═══════════════════════════════════════════"
echo " 网卡          : $IFACE"
echo " 物理内存      : ${MEM_KB} KB ($((MEM_KB / 1024)) MB)"
echo " rmem_max      : $rmem_max"
echo " wmem_max      : $wmem_max"
echo " maxsockbuf    : $maxsockbuf"
echo " TCP stack     : $(sysctl -n net.inet.tcp.functions_default 2>/dev/null || echo '?')"
echo " CC algorithm  : $(sysctl -n net.inet.tcp.cc.algorithm     2>/dev/null || echo '?')"
echo ""
echo " 硬件 offload 当前状态:"
ifconfig "$IFACE" | grep -E 'options=|capabilities=' | sed 's/^/    /'
echo ""
echo " 备份后缀      : .bak-${TS}"
echo ""
echo " 提示:"
echo "  • /boot/loader.conf.d/seedbox.conf 需 reboot 才能全部生效"
echo "  • login.conf 的 seedbox class 只对该 class 下的用户生效:"
echo "      pw usermod <你的用户名> -L seedbox"
if [ "$BBR_OK" -ne 1 ]; then
    echo "  • BBR 未启用：tcp_bbr 模块无法加载"
    echo "    若运行 FreeBSD 14.0 及更早，按上面 HINT 重编内核后再次运行本脚本"
fi
echo ""
echo " 回滚步骤:"
echo "   cp /etc/sysctl.conf.bak-${TS}  /etc/sysctl.conf"
echo "   cp /boot/loader.conf.bak-${TS} /boot/loader.conf 2>/dev/null || true"
echo "   cp /etc/rc.conf.bak-${TS}      /etc/rc.conf"
echo "   cp /etc/login.conf.bak-${TS}   /etc/login.conf && cap_mkdb /etc/login.conf"
echo "   rm /boot/loader.conf.d/seedbox.conf"
echo "   rm /usr/local/etc/rc.d/seedbox_tune"
echo "   reboot"
echo "═══════════════════════════════════════════"
