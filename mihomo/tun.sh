#!/bin/bash
# ============================================================
# TUN 模式开关 —— 让代理接管全部流量（无需逐个 App 配代理）
#
# 原理：macOS 创建 utun 虚拟网卡并接管默认路由，必须 root 权限。
#       因此本脚本需要 sudo。这与沙箱无关，是 macOS 本身的限制。
#
# 用法: sudo ./tun.sh on        切换到 TUN 全局接管
#       sudo ./tun.sh off       关闭 TUN
#       sudo ./tun.sh status    查看当前状态
# ============================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config.yaml"
BAK="$DIR/.config.yaml.notun"
PIDFILE="$DIR/.mihomo.pid"

if [ "$(id -u)" != "0" ]; then
  echo "✗ 需要 root 权限：sudo $0 $*" >&2
  exit 1
fi

tun_block() {
  cat <<'EOF'

# ---------- TUN 模式（由 tun.sh 开启）----------
tun:
  enable: true
  stack: gvisor
  device: utun199
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
  mtu: 1500
EOF
}

case "${1:-status}" in
  on)
    if grep -qE '^tun:' "$CFG"; then
      echo "• TUN 已处于开启状态，无需重复操作"; exit 0
    fi
    [ -f "$BAK" ] || cp "$CFG" "$BAK"
    tun_block >> "$CFG"
    echo "✓ 已写入 TUN 配置"
    # 重启服务
    sudo -u "${SUDO_USER:-root}" "$DIR/mihomoctl.sh" restart 2>/dev/null || true
    sleep 2
    if ifconfig 2>/dev/null | grep -q "utun199"; then
      echo "✓ TUN 接口 utun199 已建立，全部流量正在走代理"
    else
      echo "! utun199 未出现，检查日志: $DIR/mihomo.log"
    fi
    ;;
  off)
    if [ -f "$BAK" ]; then
      cp "$BAK" "$CFG"; rm -f "$BAK"
      echo "✓ 已还原为无 TUN 配置"
    else
      echo "• 无备份可还原（可能本就未开启）"
    fi
    sudo -u "${SUDO_USER:-root}" "$DIR/mihomoctl.sh" restart 2>/dev/null || true
    ;;
  status)
    if grep -qE '^tun:' "$CFG" 2>/dev/null; then
      echo "配置: TUN 已开启"
    else
      echo "配置: TUN 未开启（当前为 7890 端口代理模式）"
    fi
    if ifconfig 2>/dev/null | grep -q utun199; then
      echo "接口: utun199 存在"
    else
      echo "接口: utun199 不存在"
    fi
    ;;
  *)
    sed -n '2,12p' "$0"; exit 1 ;;
esac
