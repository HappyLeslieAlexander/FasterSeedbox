#!/bin/bash

set -euo pipefail

IFACE="eth0"

echo "[*] 安装必要工具..."
apt-get update -qq
apt-get -qqy install ethtool net-tools || true

echo "[*] 配置网卡 ring buffer 和硬件卸载..."

if ethtool -g "$IFACE" &>/dev/null; then
  MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | awk '/^RX:/{print $2; exit}')
  MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | awk '/^TX:/{print $2; exit}')
  
  MAX_RX=${MAX_RX:-256}
  MAX_TX=${MAX_TX:-256}
  
  TARGET_RX=1024
  TARGET_TX=2048
  
  if [ "$MAX_RX" -ge "$TARGET_RX" ]; then
    RX_VAL=$TARGET_RX
  else
    RX_VAL=$MAX_RX
  fi
  
  if [ "$MAX_TX" -ge "$TARGET_TX" ]; then
    TX_VAL=$TARGET_TX
  else
    TX_VAL=$MAX_TX
  fi
  
  echo "[*] 设置 ring buffer: rx=$RX_VAL (硬件最大=$MAX_RX), tx=$TX_VAL (硬件最大=$MAX_TX)"
  
  if ethtool -G "$IFACE" rx "$RX_VAL" 2>/dev/null; then
    echo "[✓] RX ring buffer 设置成功"
  else
    echo "[!] RX ring buffer 设置失败，使用默认值"
  fi
  
  if ethtool -G "$IFACE" tx "$TX_VAL" 2>/dev/null; then
    echo "[✓] TX ring buffer 设置成功"
  else
    echo "[!] TX ring buffer 设置失败，使用默认值"
  fi
else
  echo "[!] 无法读取 ring buffer 信息，跳过设置"
fi

echo "[*] 尝试关闭硬件卸载功能..."
ethtool -K "$IFACE" tso off 2>/dev/null && echo "[✓] TSO 已关闭" || echo "[!] TSO 无法关闭"
ethtool -K "$IFACE" gso off 2>/dev/null && echo "[✓] GSO 已关闭" || echo "[!] GSO 无法关闭"
ethtool -K "$IFACE" gro off 2>/dev/null && echo "[✓] GRO 已关闭" || echo "[!] GRO 无法关闭"

echo "[*] 设置 txqueuelen=10000..."
if command -v ifconfig >/dev/null 2>&1; then
  ifconfig "$IFACE" txqueuelen 10000 2>/dev/null || ip link set dev "$IFACE" txqueuelen 10000
else
  ip link set dev "$IFACE" txqueuelen 10000
fi
echo "[✓] txqueuelen 已设置"

echo "[*] 尝试为默认路由设置 initcwnd=25 initrwnd=25..."
iproute="$(ip -o -4 route show to default | sed -n 's/^[[:space:]]*//;p')" || true
if [ -n "$iproute" ]; then
  if ip route replace $iproute initcwnd 25 initrwnd 25 2>/dev/null; then
    echo "[✓] 默认路由参数已设置"
  else
    echo "[!] 路由参数设置失败（可能不支持），继续..."
  fi
fi

echo "[*] 配置块设备 I/O 调度器..."
for d in $(lsblk -nd --output NAME 2>/dev/null); do
  [[ "$d" =~ ^loop ]] && continue
  [[ "$d" =~ ^ram ]] && continue
  [[ "$d" =~ ^zram ]] && continue
  
  if [ -w "/sys/block/$d/queue/scheduler" ]; then
    if grep -q kyber "/sys/block/$d/queue/scheduler" 2>/dev/null; then
      if echo kyber > "/sys/block/$d/queue/scheduler" 2>/dev/null; then
        echo "[✓] $d: kyber 调度器已启用"
      fi
    else
      CURRENT=$(cat "/sys/block/$d/queue/scheduler" 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
      echo "[!] $d: 不支持 kyber，当前使用 $CURRENT"
    fi
  fi
done

echo "[*] 配置文件打开数限制..."
if ! grep -q "added by seedbox tuning" /etc/security/limits.conf 2>/dev/null; then
  cat >> /etc/security/limits.conf <<'EOF'

* hard nofile 1048576
* soft nofile 1048576
EOF
  echo "[✓] limits.conf 已更新"
else
  echo "[*] limits.conf 已包含配置，跳过"
fi

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-seedbox.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reexec 2>/dev/null || true
echo "[✓] systemd 文件限制已配置"

echo "[*] 生成 sysctl 配置..."
memsize=$(grep MemTotal /proc/meminfo | awk '{print $2}') || memsize=0
if [ "$memsize" -gt 16000000 ]; then
  tcp_mem='262144 1572864 2097152'
elif [ "$memsize" -gt 8000000 ]; then
  tcp_mem='262144 524288 1048576'
elif [ "$memsize" -gt 4000000 ]; then
  tcp_mem='32768 65536 65536'
else
  tcp_mem='32768 32768 32768'
fi

nic_speed=$(ethtool "$IFACE" 2>/dev/null | awk '/Speed:/ {print $2}' | grep -o '[0-9]*' | head -1)
nic_speed=${nic_speed:-0}

if [ "$nic_speed" -ge 10000 ]; then
  rmem_default=33554432
  rmem_max=67108864
  wmem_default=67108864
  wmem_max=134217728
  tcp_rmem='4194304 33554432 67108864'
  tcp_wmem='4194304 67108864 134217728'
  echo "[*] 检测到 10G+ 网卡，使用高性能缓冲区配置"
else
  rmem_default=16777216
  rmem_max=33554432
  wmem_default=16777216
  wmem_max=33554432
  tcp_rmem='4194304 16777216 33554432'
  tcp_wmem='4194304 16777216 33554432'
  echo "[*] 使用标准缓冲区配置"
fi

cat > /etc/sysctl.conf <<EOF
kernel.pid_max = 4194303
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000

fs.file-max = 1048576
fs.nr_open = 1048576

vm.dirty_background_ratio = 5
vm.dirty_ratio = 30
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 100
vm.swappiness = 10

net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 100000
net.core.rmem_default = $rmem_default
net.core.rmem_max = $rmem_max
net.core.wmem_default = $wmem_default
net.core.wmem_max = $wmem_max
net.core.optmem_max = 4194304

net.ipv4.route.mtu_expires = 1800
net.ipv4.route.min_adv_mss = 536
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.neigh.default.unres_qlen_bytes = 16777216

net.core.somaxconn = 500000
net.ipv4.tcp_max_syn_backlog = 500000
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 10000
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1460
net.ipv4.tcp_min_snd_mss = 536
net.ipv4.tcp_sack = 1
net.ipv4.tcp_comp_sack_delay_ns = 2500000
net.ipv4.tcp_comp_sack_nr = 10
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_wmem = $tcp_wmem
net.ipv4.tcp_reordering = 10
net.ipv4.tcp_max_reordering = 600
net.ipv4.tcp_synack_retries = 10
net.ipv4.tcp_syn_retries = 7
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_probes = 15
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_orphan_retries = 2
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
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

echo "[*] 配置 TCP BBR 拥塞控制..."
modprobe sch_fq 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

cat > /etc/modules-load.d/seedbox-bbr.conf <<'EOF'
sch_fq
tcp_bbr
EOF

sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true

echo "[*] 应用所有 sysctl 配置..."
sysctl -p >/dev/null 2>&1 || true

echo "[*] 验证 BBR 状态..."
AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [[ "$CURRENT_CC" == "bbr" ]]; then
  echo "[✓] BBR 拥塞控制已成功启用"
else
  echo "[!] BBR 未启用，当前使用: $CURRENT_CC"
fi

if lsmod | grep -q tcp_bbr 2>/dev/null; then
  echo "[✓] tcp_bbr 模块已加载"
elif grep -q tcp_bbr /proc/net/tcp_available_congestion_control 2>/dev/null; then
  echo "[✓] tcp_bbr 已内置在内核中"
fi

if lsmod | grep -q sch_fq 2>/dev/null; then
  echo "[✓] sch_fq 模块已加载"
fi

echo "[*] 创建开机自启脚本..."

cat > /root/.boot-script.sh <<EOF
#!/bin/bash
sleep 120s

ifconfig $IFACE txqueuelen 10000 2>/dev/null || ip link set dev $IFACE txqueuelen 10000

if ethtool -g $IFACE &>/dev/null; then
  MAX_RX=\$(ethtool -g $IFACE 2>/dev/null | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | awk '/^RX:/{print \$2; exit}')
  MAX_TX=\$(ethtool -g $IFACE 2>/dev/null | sed -n '/Pre-set maximums:/,/Current hardware settings:/p' | awk '/^TX:/{print \$2; exit}')
  MAX_RX=\${MAX_RX:-256}
  MAX_TX=\${MAX_TX:-256}
  
  RX_VAL=\$((MAX_RX >= 1024 ? 1024 : MAX_RX))
  TX_VAL=\$((MAX_TX >= 2048 ? 2048 : MAX_TX))
  
  ethtool -G $IFACE rx "\$RX_VAL" 2>/dev/null || true
  ethtool -G $IFACE tx "\$TX_VAL" 2>/dev/null || true
fi

ethtool -K $IFACE tso off gso off gro off 2>/dev/null || true

for d in \$(lsblk -nd --output NAME 2>/dev/null); do
  [[ "\$d" =~ ^(loop|ram|zram) ]] && continue
  if [ -w "/sys/block/\$d/queue/scheduler" ] && grep -q kyber "/sys/block/\$d/queue/scheduler" 2>/dev/null; then
    echo kyber > "/sys/block/\$d/queue/scheduler" 2>/dev/null || true
  fi
done

sysctl --system >/dev/null 2>&1 || true
EOF

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

systemctl daemon-reload 2>/dev/null || true
systemctl enable boot-script.service 2>/dev/null || true
echo "[✓] 开机自启脚本已创建并启用"

echo ""
echo "========================================="
echo "           调优完成！"
echo "========================================="
echo ""

echo "网卡配置 ($IFACE):"
TXQL=$(ip link show "$IFACE" 2>/dev/null | grep -oP 'qlen \K[0-9]+' || echo "未知")
echo "  - txqueuelen: $TXQL"

echo ""
echo "硬件卸载状态:"
ethtool -k "$IFACE" 2>/dev/null | grep -E '^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' | sed 's/^/  - /' || echo "  无法获取"

echo ""
echo "网络缓冲区:"
echo "  - rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo '未知')"
echo "  - wmem_max: $(sysctl -n net.core.wmem_max 2>/dev/null || echo '未知')"

echo ""
echo "TCP 配置:"
echo "  - 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
echo "  - 队列调度: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"

echo ""
echo "========================================="
echo "重要提示:"
echo "  - 部分设置需要重启后完全生效"
echo "  - 建议现在重启系统: reboot"
echo ""
echo "回滚方法:"
echo "  - 恢复 /etc/sysctl.conf 备份"
echo "  - 删除 /etc/systemd/system/boot-script.service"
echo "  - 删除 /root/.boot-script.sh"
echo "  - systemctl daemon-reload"
echo "========================================="

exit 0
