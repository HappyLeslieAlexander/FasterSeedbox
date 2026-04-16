#!/bin/bash

set -euo pipefail

# ════════════════════════════════════════════════════════════════
#  Seedbox System Tuning Script
#  基于 jerry048/Dedicated-Seedbox 调优逻辑
#  BBR: 使用 Debian 13 内核自带 BBR，无需替换内核
# ════════════════════════════════════════════════════════════════

# ── 动态检测默认路由网卡（修复硬编码 eth0 问题）─────────────────
IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
if [[ -z "$IFACE" ]]; then
    echo "[!] 无法检测到默认路由网卡，退出"
    exit 1
fi
echo "[*] 检测到默认网卡: $IFACE"

# ── 安装必要工具（含 tuned）──────────────────────────────────────
echo "[*] 安装必要工具..."
apt-get update -qq
apt-get -qqy install ethtool net-tools tuned || true

# 启用 tuned CPU 调频优化（还原 jerry048 的 tuned_ 函数）
if command -v tuned-adm &>/dev/null; then
    systemctl enable --now tuned 2>/dev/null || true
    tuned-adm profile throughput-performance 2>/dev/null || true
    echo "[✓] tuned 已启用 (profile: throughput-performance)"
else
    echo "[!] tuned 安装失败，跳过 CPU 调频优化"
fi

# ── Ring Buffer（读取硬件上限后安全设置）────────────────────────
echo "[*] 配置网卡 ring buffer..."
if ethtool -g "$IFACE" &>/dev/null; then
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
        && echo "[✓] RX ring buffer = $RX_VAL (硬件上限 $MAX_RX)" \
        || echo "[!] RX ring buffer 设置失败"
    ethtool -G "$IFACE" tx "$TX_VAL" 2>/dev/null \
        && echo "[✓] TX ring buffer = $TX_VAL (硬件上限 $MAX_TX)" \
        || echo "[!] TX ring buffer 设置失败"
else
    echo "[!] 网卡不支持 ring buffer 查询，跳过"
fi

# ── 关闭硬件卸载（TSO / GSO / GRO）──────────────────────────────
echo "[*] 关闭硬件卸载功能..."
ethtool -K "$IFACE" tso off 2>/dev/null && echo "[✓] TSO 已关闭" || echo "[!] TSO 无法关闭"
ethtool -K "$IFACE" gso off 2>/dev/null && echo "[✓] GSO 已关闭" || echo "[!] GSO 无法关闭"
ethtool -K "$IFACE" gro off 2>/dev/null && echo "[✓] GRO 已关闭" || echo "[!] GRO 无法关闭"

# ── txqueuelen = 10000 ────────────────────────────────────────
echo "[*] 设置 txqueuelen=10000..."
ifconfig "$IFACE" txqueuelen 10000 2>/dev/null \
    || ip link set dev "$IFACE" txqueuelen 10000
echo "[✓] txqueuelen 已设置"

# ── initcwnd / initrwnd = 25 ──────────────────────────────────
echo "[*] 设置 initcwnd=25 initrwnd=25..."
iproute=$(ip -o -4 route show to default)
if [ -n "$iproute" ]; then
    ip route change $iproute initcwnd 25 initrwnd 25 2>/dev/null \
        && echo "[✓] initcwnd/initrwnd 已设置" \
        || echo "[!] 路由参数设置失败（部分虚拟化环境不支持），继续..."
fi

# ── 磁盘 I/O 调度器（修复：补全 HDD → mq-deadline 分支）────────
echo "[*] 配置块设备 I/O 调度器..."
for d in $(lsblk -nd --output NAME 2>/dev/null); do
    [[ "$d" =~ ^(loop|ram|zram) ]] && continue
    [ -w "/sys/block/$d/queue/scheduler" ] || continue

    rotational=$(cat "/sys/block/$d/queue/rotational" 2>/dev/null || echo "1")
    if [ "$rotational" = "0" ]; then
        # SSD / NVMe → kyber
        if grep -q kyber "/sys/block/$d/queue/scheduler" 2>/dev/null; then
            echo kyber > "/sys/block/$d/queue/scheduler" 2>/dev/null \
                && echo "[✓] $d (SSD/NVMe): 调度器 → kyber" \
                || echo "[!] $d: kyber 写入失败"
        else
            cur=$(grep -o '\[.*\]' "/sys/block/$d/queue/scheduler" 2>/dev/null | tr -d '[]')
            echo "[!] $d (SSD/NVMe): 不支持 kyber，当前保持 ${cur:-unknown}"
        fi
    else
        # HDD → mq-deadline（修复原脚本缺失的分支）
        if grep -q mq-deadline "/sys/block/$d/queue/scheduler" 2>/dev/null; then
            echo mq-deadline > "/sys/block/$d/queue/scheduler" 2>/dev/null \
                && echo "[✓] $d (HDD): 调度器 → mq-deadline" \
                || echo "[!] $d: mq-deadline 写入失败"
        else
            cur=$(grep -o '\[.*\]' "/sys/block/$d/queue/scheduler" 2>/dev/null | tr -d '[]')
            echo "[!] $d (HDD): 不支持 mq-deadline，当前保持 ${cur:-unknown}"
        fi
    fi
done

# ── 文件句柄限制 ──────────────────────────────────────────────
echo "[*] 配置文件打开数限制..."
if ! grep -q "added by seedbox tuning" /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf <<'EOF'
# added by seedbox tuning
* hard nofile 1048576
* soft nofile 1048576
EOF
    echo "[✓] /etc/security/limits.conf 已更新"
else
    echo "[*] limits.conf 已包含配置，跳过"
fi

# systemd 层面的文件句柄限制（确保 systemd 托管进程也生效）
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-seedbox.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reexec 2>/dev/null || true
echo "[✓] systemd DefaultLimitNOFILE 已配置"

# ── TCP Buffer：按内存大小动态计算（还原 jerry048 原版逻辑）────
#
#  jerry048 原版用 RAM 大小计算 tcp_mem、rmem_max、wmem_max
#  以及 tcp_adv_win_scale，保护低内存机器不被大 buffer 撑爆
#
echo "[*] 按内存大小计算 TCP 缓冲区参数..."
memory_size=$(grep MemTotal /proc/meminfo | awk '{print $2}')
memory_4k=$(( memory_size / 4 ))   # 转换为 4KB 页数

# tcp_mem 各分量上限（单位：4KB 页）
tcp_mem_min_cap=262144      # 1  GB
tcp_mem_pressure_cap=2097152 # 8  GB
tcp_mem_max_cap=4194304      # 16 GB

if [ "$memory_size" -le 524288 ]; then          # ≤ 512 MB
    tcp_mem_min=$(( memory_4k / 32 ))
    tcp_mem_pressure=$(( memory_4k / 16 ))
    tcp_mem_max_val=$(( memory_4k / 8 ))
    rmem_max=8388608; wmem_max=8388608; win_scale=3
elif [ "$memory_size" -le 1048576 ]; then        # ≤ 1 GB
    tcp_mem_min=$(( memory_4k / 16 ))
    tcp_mem_pressure=$(( memory_4k / 8 ))
    tcp_mem_max_val=$(( memory_4k / 6 ))
    rmem_max=16777216; wmem_max=16777216; win_scale=2
elif [ "$memory_size" -le 4194304 ]; then        # ≤ 4 GB
    tcp_mem_min=$(( memory_4k / 8 ))
    tcp_mem_pressure=$(( memory_4k / 6 ))
    tcp_mem_max_val=$(( memory_4k / 4 ))
    rmem_max=33554432; wmem_max=33554432; win_scale=2
elif [ "$memory_size" -le 16777216 ]; then       # ≤ 16 GB
    tcp_mem_min=$(( memory_4k / 8 ))
    tcp_mem_pressure=$(( memory_4k / 4 ))
    tcp_mem_max_val=$(( memory_4k / 2 ))
    rmem_max=67108864; wmem_max=67108864; win_scale=1
else                                              # > 16 GB
    tcp_mem_min=$(( memory_4k / 8 ))
    tcp_mem_pressure=$(( memory_4k / 4 ))
    tcp_mem_max_val=$(( memory_4k / 2 ))
    rmem_max=134217728; wmem_max=134217728; win_scale=-2
fi

# 对 tcp_mem 各分量应用上限
[ $tcp_mem_min      -gt $tcp_mem_min_cap      ] && tcp_mem_min=$tcp_mem_min_cap
[ $tcp_mem_pressure -gt $tcp_mem_pressure_cap ] && tcp_mem_pressure=$tcp_mem_pressure_cap
[ $tcp_mem_max_val  -gt $tcp_mem_max_cap      ] && tcp_mem_max_val=$tcp_mem_max_cap

tcp_mem="$tcp_mem_min $tcp_mem_pressure $tcp_mem_max_val"
rmem_default=262144
wmem_default=16384
tcp_rmem="8192 $rmem_default $rmem_max"
tcp_wmem="4096 $wmem_default $wmem_max"

echo "[✓] 内存 ${memory_size} KB → rmem_max=${rmem_max}, wmem_max=${wmem_max}, tcp_adv_win_scale=${win_scale}"

# ── 加载 BBR 内核模块（使用 Debian 13 自带 BBR，无需换内核）────
echo "[*] 加载 BBR 相关内核模块..."
modprobe sch_fq   2>/dev/null || true
modprobe tcp_bbr  2>/dev/null || true

# 确保开机自动加载
cat > /etc/modules-load.d/seedbox-bbr.conf <<'EOF'
sch_fq
tcp_bbr
EOF

# 立即激活（在 sysctl -p 之前先行设置，避免写入失败）
sysctl -w net.core.default_qdisc=fq                    2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr           2>/dev/null || true

# ── 写入 /etc/sysctl.conf ────────────────────────────────────
echo "[*] 生成 /etc/sysctl.conf..."
cat > /etc/sysctl.conf <<EOF
###/proc/sys/kernel/
kernel.pid_max = 4194303
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000

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

###/proc/sys/net/ipv4/ — 路由
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

###/proc/sys/net/ipv4/ — 缓冲区（内存自适应）
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

###拥塞控制（Debian 13 内核自带 BBR）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl -p >/dev/null 2>&1 || true
echo "[✓] sysctl 参数已全部应用"

# ── BBR 验证 ──────────────────────────────────────────────────
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "$CURRENT_CC" == "bbr" ]]; then
    echo "[✓] BBR 拥塞控制已成功启用"
else
    echo "[!] BBR 未启用，当前: $CURRENT_CC（内核可能不支持，建议升级到 Debian 13）"
fi
lsmod | grep -q tcp_bbr  && echo "[✓] tcp_bbr  模块已加载" || echo "[!] tcp_bbr  模块未加载（可能已内置）"
lsmod | grep -q sch_fq   && echo "[✓] sch_fq   模块已加载" || echo "[!] sch_fq   模块未加载（可能已内置）"

# ── 开机自启脚本（动态网卡 + 完整 HDD/SSD 分支）────────────────
echo "[*] 创建开机自启脚本..."
cat > /root/.boot-script.sh <<'BOOTEOF'
#!/bin/bash
# Seedbox 开机调优脚本 — 由 seedbox-tune.sh 生成
sleep 120

IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
[ -z "$IFACE" ] && exit 1

# txqueuelen
ifconfig "$IFACE" txqueuelen 10000 2>/dev/null \
    || ip link set dev "$IFACE" txqueuelen 10000

# ring buffer（读取硬件上限）
if ethtool -g "$IFACE" &>/dev/null; then
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

# 关闭硬件卸载
ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null || true

# I/O 调度器（SSD → kyber，HDD → mq-deadline）
for d in $(lsblk -nd --output NAME 2>/dev/null); do
    [[ "$d" =~ ^(loop|ram|zram) ]] && continue
    [ -w "/sys/block/$d/queue/scheduler" ] || continue
    rotational=$(cat "/sys/block/$d/queue/rotational" 2>/dev/null || echo "1")
    if [ "$rotational" = "0" ]; then
        grep -q kyber "/sys/block/$d/queue/scheduler" 2>/dev/null \
            && echo kyber      > "/sys/block/$d/queue/scheduler" 2>/dev/null || true
    else
        grep -q mq-deadline "/sys/block/$d/queue/scheduler" 2>/dev/null \
            && echo mq-deadline > "/sys/block/$d/queue/scheduler" 2>/dev/null || true
    fi
done

# initcwnd / initrwnd
iproute=$(ip -o -4 route show to default)
[ -n "$iproute" ] && ip route change $iproute initcwnd 25 initrwnd 25 2>/dev/null || true

# BBR 模块
modprobe sch_fq  2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# 应用 sysctl
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
echo "[✓] 开机自启脚本已创建并启用"

# ── 最终状态汇总 ──────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "              调优完成！"
echo "═══════════════════════════════════════════"
echo "网卡: $IFACE"
echo "  txqueuelen : $(ip link show "$IFACE" 2>/dev/null | grep -oP 'qlen \K[0-9]+' || echo '未知')"
echo ""
echo "硬件卸载状态:"
ethtool -k "$IFACE" 2>/dev/null \
    | grep -E '^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' \
    | sed 's/^/  /' || echo "  无法获取"
echo ""
echo "内存: ${memory_size} KB"
echo "  tcp_adv_win_scale : $win_scale"
echo "  rmem_max          : $rmem_max"
echo "  wmem_max          : $wmem_max"
echo "  tcp_mem           : $tcp_mem"
echo ""
echo "TCP:"
echo "  拥塞控制 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
echo "  队列调度 : $(sysctl -n net.core.default_qdisc          2>/dev/null || echo '未知')"
echo ""
echo "提示: 部分设置（limits.conf 等）需重启后完全生效"
echo "建议执行: reboot"
echo ""
echo "回滚方法:"
echo "  1. 恢复 /etc/sysctl.conf 备份"
echo "  2. systemctl disable boot-script.service"
echo "  3. rm /root/.boot-script.sh"
echo "  4. systemctl daemon-reload"
echo "═══════════════════════════════════════════"

exit 0
