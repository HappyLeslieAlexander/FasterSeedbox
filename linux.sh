#!/bin/sh
# ════════════════════════════════════════════════════════════════
#  Seedbox 系统调优脚本 — Linux
#
#  参数与分级逻辑严格对齐 jerry048/Dedicated-Seedbox 的
#  seedbox_installation.sh，仅在以下方面做工程加固：
#    • Ring buffer 按 NIC 硬件上限取较小值，避免对低规格网卡设置失败
#    • Disk scheduler 在内核未编入 kyber / mq-deadline 时给出回退提示
#    • limits.conf 通配条目额外补 root，配合 systemd DefaultLimitNOFILE
#    • 内核 6.6+ 跳过已被 EEVDF 移除的 sched_*_granularity_ns 参数
#
#  适用：Debian 12 / 13、Ubuntu 22.04 / 24.04 等带内核自带 BBR 的发行版
# ════════════════════════════════════════════════════════════════

# 不开启 -e：本脚本是"尽力而为"的调优性质，单步失败应让后续步骤继续
set -u

# ── 前置检查 ─────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { echo "[!] 需 root 权限运行"; exit 1; }

# 解析内核主次版本号为 100*主+次（如 6.12 → 612），用于参数兼容性判断
KERNEL_VER=$(uname -r | awk -F. '{printf "%d", $1*100+$2}')

# 虚拟化检测：决定是否禁用 NIC 硬件卸载
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q; then
    IS_VIRT=1
    VIRT_KIND=$(systemd-detect-virt 2>/dev/null || echo "unknown")
else
    IS_VIRT=0
    VIRT_KIND="none"
fi

# 默认路由所在网卡（动态获取，不假设 eth0 / ens / enp 等命名）
IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
if [ -z "$IFACE" ]; then
    echo "[!] 未找到默认路由网卡，退出"
    exit 1
fi

echo "[*] 网卡: $IFACE   虚拟化: $VIRT_KIND   内核: $(uname -r)"

# ── 备份现有配置 ─────────────────────────────────────────────
TS=$(date +%Y%m%d-%H%M%S)
echo "[*] 备份现有配置 (后缀 .bak-${TS})"
for f in /etc/sysctl.conf /etc/security/limits.conf; do
    if [ -f "$f" ]; then
        cp -p "$f" "${f}.bak-${TS}"
        echo "    ${f} -> ${f}.bak-${TS}"
    fi
done

# ── 安装依赖 ─────────────────────────────────────────────────
echo "[*] 更新软件源并安装依赖..."
apt-get update -qq          || echo "[!] apt-get update 失败，使用本地缓存继续"
apt-get -qqy install ethtool net-tools tuned \
                            || echo "[!] 部分依赖安装失败，继续后续步骤"

# ── tuned ────────────────────────────────────────────────────
# 与 jerry048 一致：仅安装并启用 tuned，不强制 profile；
# tuned 会按虚拟化状态自动选择（物理机 throughput-performance、虚拟机 virtual-guest）
if command -v tuned-adm >/dev/null 2>&1; then
    systemctl enable --now tuned 2>/dev/null || true
    CUR_PROFILE=$(tuned-adm active 2>/dev/null \
        | awk -F': ' '/Current active profile/{print $2}')
    echo "[✓] tuned 已启用 (auto profile: ${CUR_PROFILE:-unknown})"
else
    echo "[!] tuned 不可用，跳过 CPU 调频优化"
fi

# ── Ring Buffer ──────────────────────────────────────────────
# 目标值 RX=1024 / TX=2048（与 jerry048 一致），但先读取硬件上限取 min，
# 这样在硬件最大值低于目标的低端 NIC（如部分虚拟机 e1000）上不会写入失败
echo "[*] 配置网卡 ring buffer..."
if ethtool -g "$IFACE" >/dev/null 2>&1; then
    MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null \
        | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' \
        | awk '/^RX:/{print $2; exit}')
    MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null \
        | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' \
        | awk '/^TX:/{print $2; exit}')
    MAX_RX=${MAX_RX:-256}
    MAX_TX=${MAX_TX:-256}
    RX_VAL=$(( MAX_RX >= 1024 ? 1024 : MAX_RX ))
    TX_VAL=$(( MAX_TX >= 2048 ? 2048 : MAX_TX ))
    ethtool -G "$IFACE" rx "$RX_VAL" 2>/dev/null \
        && echo "[✓] RX = $RX_VAL  (硬件上限 $MAX_RX)" \
        || echo "[!] RX ring buffer 写入失败"
    ethtool -G "$IFACE" tx "$TX_VAL" 2>/dev/null \
        && echo "[✓] TX = $TX_VAL  (硬件上限 $MAX_TX)" \
        || echo "[!] TX ring buffer 写入失败"
else
    echo "[!] 网卡不支持 ring buffer 查询，跳过"
fi

# ── NIC 硬件卸载 (TSO / GSO / GRO) ──────────────────────────
# 与 jerry048 行为一致：仅在虚拟化环境下关闭。
# 物理 NIC 上 TSO/GSO/GRO 是性能利好；虚拟网卡（virtio、vmxnet3 等）
# 的 offload 实现常存在 stall / 丢包问题，关闭可规避
if [ "$IS_VIRT" -eq 1 ]; then
    echo "[*] 虚拟化环境，关闭 NIC 硬件卸载..."
    ethtool -K "$IFACE" tso off 2>/dev/null && echo "[✓] TSO off" || echo "[!] TSO 未能关闭"
    ethtool -K "$IFACE" gso off 2>/dev/null && echo "[✓] GSO off" || echo "[!] GSO 未能关闭"
    ethtool -K "$IFACE" gro off 2>/dev/null && echo "[✓] GRO off" || echo "[!] GRO 未能关闭"
else
    echo "[*] 物理机环境，保留 NIC 硬件卸载（性能更优）"
fi

# ── txqueuelen ───────────────────────────────────────────────
echo "[*] 设置 txqueuelen=10000..."
if ifconfig "$IFACE" txqueuelen 10000 2>/dev/null; then
    echo "[✓] txqueuelen 已设置 (ifconfig)"
elif ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null; then
    echo "[✓] txqueuelen 已设置 (ip link)"
else
    echo "[!] txqueuelen 设置失败"
fi

# ── 初始拥塞 / 接收窗口 ─────────────────────────────────────
echo "[*] 设置 initcwnd=25 initrwnd=25..."
iproute=$(ip -o -4 route show to default 2>/dev/null | head -n 1 || true)
if [ -n "$iproute" ]; then
    ip route change $iproute initcwnd 25 initrwnd 25 2>/dev/null \
        && echo "[✓] initcwnd / initrwnd 已设置" \
        || echo "[!] 路由参数未生效（部分虚拟化平台受限），继续"
else
    echo "[!] 无默认路由信息，跳过"
fi

# ── 块设备 I/O 调度器 ───────────────────────────────────────
# 旋转介质 (HDD) → mq-deadline；非旋转 (SSD/NVMe) → kyber
echo "[*] 配置块设备 I/O 调度器..."
for d in $(lsblk -nd --output NAME 2>/dev/null); do
    case "$d" in loop*|ram*|zram*) continue ;; esac
    [ -w "/sys/block/$d/queue/scheduler" ] || continue

    rotational=$(cat "/sys/block/$d/queue/rotational" 2>/dev/null || echo "1")
    if [ "$rotational" = "0" ]; then
        # SSD / NVMe → kyber
        if grep -q kyber "/sys/block/$d/queue/scheduler" 2>/dev/null; then
            echo kyber > "/sys/block/$d/queue/scheduler" 2>/dev/null \
                && echo "[✓] $d (SSD/NVMe) → kyber" \
                || echo "[!] $d: kyber 写入失败"
        else
            cur=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "/sys/block/$d/queue/scheduler" 2>/dev/null)
            echo "[!] $d (SSD/NVMe): 内核未编译 kyber，保持 ${cur:-unknown}"
        fi
    else
        # HDD → mq-deadline
        if grep -q mq-deadline "/sys/block/$d/queue/scheduler" 2>/dev/null; then
            echo mq-deadline > "/sys/block/$d/queue/scheduler" 2>/dev/null \
                && echo "[✓] $d (HDD) → mq-deadline" \
                || echo "[!] $d: mq-deadline 写入失败"
        else
            cur=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "/sys/block/$d/queue/scheduler" 2>/dev/null)
            echo "[!] $d (HDD): 内核未编译 mq-deadline，保持 ${cur:-unknown}"
        fi
    fi
done

# ── 文件描述符上限 ──────────────────────────────────────────
# limits.conf 的 * 通配符不覆盖 root，需单独写一行；
# systemd 托管的服务不读 limits.conf，需通过 system.conf.d 兜底
echo "[*] 配置文件描述符上限..."
if ! grep -q "added by seedbox tuning" /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf <<'EOF'
# added by seedbox tuning
* hard nofile 1048576
* soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
EOF
    echo "[✓] /etc/security/limits.conf 已更新（包含 root 显式条目）"
else
    echo "[*] limits.conf 已存在配置块，跳过"
fi

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-seedbox.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reexec 2>/dev/null || true
echo "[✓] systemd DefaultLimitNOFILE 已配置"

# ── 按物理内存计算 TCP 缓冲区参数 ───────────────────────────
# 完全对齐 jerry048：分 5 档（≤512MB / ≤1GB / ≤4GB / ≤16GB / >16GB），
# tcp_mem 三个分量分别有 1GB / 8GB / 16GB 上限 cap
echo "[*] 计算 TCP 缓冲区参数..."
memory_size=$(grep MemTotal /proc/meminfo | awk '{print $2}')
memory_4k=$(( memory_size / 4 ))   # 转换为 4KB 页数

tcp_mem_min_cap=262144       # 1  GB (= 262144 * 4KB)
tcp_mem_pressure_cap=2097152 # 8  GB
tcp_mem_max_cap=4194304      # 16 GB

if   [ "$memory_size" -le 524288 ];   then    # ≤ 512 MB
    tcp_mem_min=$(( memory_4k / 32 ))
    tcp_mem_pressure=$(( memory_4k / 16 ))
    tcp_mem_max_val=$(( memory_4k / 8 ))
    rmem_max=8388608;   wmem_max=8388608;   win_scale=3
elif [ "$memory_size" -le 1048576 ];  then    # ≤ 1 GB
    tcp_mem_min=$(( memory_4k / 16 ))
    tcp_mem_pressure=$(( memory_4k / 8 ))
    tcp_mem_max_val=$(( memory_4k / 6 ))
    rmem_max=16777216;  wmem_max=16777216;  win_scale=2
elif [ "$memory_size" -le 4194304 ];  then    # ≤ 4 GB
    tcp_mem_min=$(( memory_4k / 8 ))
    tcp_mem_pressure=$(( memory_4k / 6 ))
    tcp_mem_max_val=$(( memory_4k / 4 ))
    rmem_max=33554432;  wmem_max=33554432;  win_scale=2
elif [ "$memory_size" -le 16777216 ]; then    # ≤ 16 GB
    tcp_mem_min=$(( memory_4k / 8 ))
    tcp_mem_pressure=$(( memory_4k / 4 ))
    tcp_mem_max_val=$(( memory_4k / 2 ))
    rmem_max=67108864;  wmem_max=67108864;  win_scale=1
else                                          # > 16 GB
    tcp_mem_min=$(( memory_4k / 8 ))
    tcp_mem_pressure=$(( memory_4k / 4 ))
    tcp_mem_max_val=$(( memory_4k / 2 ))
    rmem_max=134217728; wmem_max=134217728; win_scale=-2
fi

# 应用 tcp_mem 各分量的硬上限
[ $tcp_mem_min      -gt $tcp_mem_min_cap      ] && tcp_mem_min=$tcp_mem_min_cap
[ $tcp_mem_pressure -gt $tcp_mem_pressure_cap ] && tcp_mem_pressure=$tcp_mem_pressure_cap
[ $tcp_mem_max_val  -gt $tcp_mem_max_cap      ] && tcp_mem_max_val=$tcp_mem_max_cap

tcp_mem="$tcp_mem_min $tcp_mem_pressure $tcp_mem_max_val"
rmem_default=262144
wmem_default=16384
tcp_rmem="8192 $rmem_default $rmem_max"
tcp_wmem="4096 $wmem_default $wmem_max"

echo "[✓] 内存 ${memory_size} KB → rmem_max=${rmem_max}  wmem_max=${wmem_max}  tcp_adv_win_scale=${win_scale}"

# ── EEVDF 调度器在内核 6.6+ 移除了部分 sysctl ────────────────
# sched_min_granularity_ns / sched_wakeup_granularity_ns 在新内核下属于
# unknown key，写入会被 sysctl -p 报错。按内核版本动态决定是否输出
if [ "$KERNEL_VER" -ge 606 ]; then
    SCHED_GRAN_BLOCK="# kernel.sched_min_granularity_ns / sched_wakeup_granularity_ns
# 在 Linux 6.6+ EEVDF 调度器下已移除，本机内核 $(uname -r) 跳过"
else
    SCHED_GRAN_BLOCK="kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000"
fi

# ── 加载 BBR 内核模块 ──────────────────────────────────────
# Debian 12+ / Ubuntu 22.04+ 等主流发行版内核已自带 BBR，无需替换
echo "[*] 加载 BBR 相关内核模块..."
modprobe sch_fq  2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# 持久化模块加载
cat > /etc/modules-load.d/seedbox-bbr.conf <<'EOF'
sch_fq
tcp_bbr
EOF

# 立即激活 BBR：在 sysctl -p 之前先 set，避免 conf 文件的写入顺序影响生效
sysctl -w net.core.default_qdisc=fq           >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

# ── 写入 /etc/sysctl.conf ───────────────────────────────────
echo "[*] 写入 /etc/sysctl.conf..."
cat > /etc/sysctl.conf <<EOF
###/proc/sys/kernel/
kernel.pid_max = 4194303
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
${SCHED_GRAN_BLOCK}

###/proc/sys/fs/
fs.file-max = 1048576
fs.nr_open = 1048576

###/proc/sys/vm/
vm.dirty_background_ratio = 5
vm.dirty_ratio = 30
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 100
vm.swappiness = 10

###/proc/sys/net/core/
net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 100000
net.core.rmem_default = $rmem_default
net.core.rmem_max = $rmem_max
net.core.wmem_default = $wmem_default
net.core.wmem_max = $wmem_max
net.core.optmem_max = 4194304
net.core.somaxconn = 524288

###/proc/sys/net/ipv4/ — 路由 / IP
net.ipv4.route.mtu_expires = 1800
net.ipv4.route.min_adv_mss = 536
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.neigh.default.unres_qlen_bytes = 16777216

###/proc/sys/net/ipv4/ — TCP 连接队列
net.ipv4.tcp_max_syn_backlog = 524288
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 10240

###/proc/sys/net/ipv4/ — MTU 探测
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1460
net.ipv4.tcp_min_snd_mss = 536

###/proc/sys/net/ipv4/ — SACK / 重传
net.ipv4.tcp_sack = 1
net.ipv4.tcp_comp_sack_delay_ns = 250000
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_ecn = 0

###/proc/sys/net/ipv4/ — 缓冲区（按内存自适应）
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = $win_scale
net.ipv4.tcp_wmem = $tcp_wmem

###/proc/sys/net/ipv4/ — 乱序容忍
net.ipv4.tcp_reordering = 10
net.ipv4.tcp_max_reordering = 600

###/proc/sys/net/ipv4/ — 重试 / Keepalive
net.ipv4.tcp_synack_retries = 10
net.ipv4.tcp_syn_retries = 7
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_probes = 15
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_orphan_retries = 2

###/proc/sys/net/ipv4/ — 行为调整
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

###拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl -p >/dev/null 2>&1 || true
echo "[✓] sysctl 已加载"

# ── BBR 验证 ────────────────────────────────────────────────
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [ "$CURRENT_CC" = "bbr" ]; then
    echo "[✓] BBR 拥塞控制已启用"
else
    echo "[!] BBR 未启用，当前: $CURRENT_CC （内核可能不支持）"
fi
lsmod | grep -q tcp_bbr && echo "[✓] tcp_bbr 模块已加载" || echo "[!] tcp_bbr 模块未加载（可能已编入内核）"
lsmod | grep -q sch_fq  && echo "[✓] sch_fq  模块已加载" || echo "[!] sch_fq  模块未加载（可能已编入内核）"

# ── 开机自启脚本 ────────────────────────────────────────────
# Ring buffer / txqueuelen / NIC offload 等设置在重启后会被驱动重置，
# 通过 systemd 服务在每次启动时重新应用
echo "[*] 创建开机自启脚本..."
cat > /root/.boot-script.sh <<'BOOTEOF'
#!/bin/sh
# Seedbox 开机调优脚本 — 由主调优脚本生成
sleep 120

IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
[ -z "$IFACE" ] && exit 1

# 虚拟化检测：决定是否禁用 NIC offload
IS_VIRT=0
command -v systemd-detect-virt >/dev/null 2>&1 \
    && systemd-detect-virt -q && IS_VIRT=1

# txqueuelen
ifconfig "$IFACE" txqueuelen 10000 2>/dev/null \
    || ip link set dev "$IFACE" txqueuelen 10000

# Ring buffer：按硬件上限取较小值
if ethtool -g "$IFACE" >/dev/null 2>&1; then
    MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null \
        | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' \
        | awk '/^RX:/{print $2; exit}')
    MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null \
        | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' \
        | awk '/^TX:/{print $2; exit}')
    MAX_RX=${MAX_RX:-256}; MAX_TX=${MAX_TX:-256}
    RX_VAL=$(( MAX_RX >= 1024 ? 1024 : MAX_RX ))
    TX_VAL=$(( MAX_TX >= 2048 ? 2048 : MAX_TX ))
    ethtool -G "$IFACE" rx "$RX_VAL" 2>/dev/null || true
    ethtool -G "$IFACE" tx "$TX_VAL" 2>/dev/null || true
fi

# NIC 硬件卸载：仅虚拟化环境关闭
if [ "$IS_VIRT" -eq 1 ]; then
    ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null || true
fi

# I/O 调度器
for d in $(lsblk -nd --output NAME 2>/dev/null); do
    case "$d" in loop*|ram*|zram*) continue ;; esac
    [ -w "/sys/block/$d/queue/scheduler" ] || continue
    rotational=$(cat "/sys/block/$d/queue/rotational" 2>/dev/null || echo "1")
    if [ "$rotational" = "0" ]; then
        grep -q kyber "/sys/block/$d/queue/scheduler" 2>/dev/null \
            && echo kyber       > "/sys/block/$d/queue/scheduler" 2>/dev/null || true
    else
        grep -q mq-deadline "/sys/block/$d/queue/scheduler" 2>/dev/null \
            && echo mq-deadline > "/sys/block/$d/queue/scheduler" 2>/dev/null || true
    fi
done

# initcwnd / initrwnd
iproute=$(ip -o -4 route show to default 2>/dev/null | head -n 1 || true)
[ -n "$iproute" ] && ip route change $iproute initcwnd 25 initrwnd 25 2>/dev/null || true

# BBR 模块
modprobe sch_fq  2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# 重新加载所有 sysctl 片段（涵盖 /etc/sysctl.conf 与 /etc/sysctl.d/*.conf）
sysctl --system >/dev/null 2>&1 || true
BOOTEOF

chmod +x /root/.boot-script.sh

cat > /etc/systemd/system/boot-script.service <<'EOF'
[Unit]
Description=Seedbox Boot Tuning Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/.boot-script.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload  2>/dev/null || true
systemctl enable boot-script.service 2>/dev/null || true
echo "[✓] 开机自启脚本已就位"

# ── 状态汇总 ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "              调优完成"
echo "═══════════════════════════════════════════"
echo "环境       : $VIRT_KIND  /  内核 $(uname -r)"
echo "网卡       : $IFACE"
echo "  txqueuelen : $(ip link show "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="qlen"){print $(i+1);exit}}' || echo '未知')"
echo ""
if [ "$IS_VIRT" -eq 1 ]; then
    echo "硬件卸载（虚拟化环境，已关闭）:"
else
    echo "硬件卸载（物理机环境，已保留）:"
fi
ethtool -k "$IFACE" 2>/dev/null \
    | grep -E '^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' \
    | sed 's/^/  /' || echo "  无法获取"
echo ""
echo "内存 ${memory_size} KB:"
echo "  tcp_adv_win_scale : $win_scale"
echo "  rmem_max          : $rmem_max"
echo "  wmem_max          : $wmem_max"
echo "  tcp_mem           : $tcp_mem"
echo ""
echo "TCP:"
echo "  拥塞控制 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
echo "  队列调度 : $(sysctl -n net.core.default_qdisc          2>/dev/null || echo '未知')"
echo ""
echo "提示: limits.conf / systemd 文件描述符上限需重启后完全生效"
echo "备份后缀: .bak-${TS}"
echo "建议: reboot"
echo ""
echo "回滚步骤:"
echo "  1. cp /etc/sysctl.conf.bak-${TS} /etc/sysctl.conf"
echo "  2. cp /etc/security/limits.conf.bak-${TS} /etc/security/limits.conf"
echo "  3. systemctl disable boot-script.service"
echo "  4. rm /root/.boot-script.sh /etc/systemd/system/boot-script.service"
echo "  5. rm /etc/modules-load.d/seedbox-bbr.conf"
echo "  6. rm /etc/systemd/system.conf.d/99-seedbox.conf"
echo "  7. systemctl daemon-reload && systemctl daemon-reexec"
echo "═══════════════════════════════════════════"

exit 0
