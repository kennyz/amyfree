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
# 提示语言：AMYFREE_LANG=en 输出英文，默认中文（菜单栏 App 按界面语言传入）
t() { if [ "${AMYFREE_LANG:-zh}" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

if [ "$(id -u)" != "0" ]; then
  echo "$(t '✗ 需要 root 权限：' '✗ Root privileges required: ')sudo $0 $*" >&2
  exit 1
fi

# 内核需以 root 运行才能建立 TUN，但运行文件要留给目录所有者：
# App 以普通用户身份保存链式代理、分流和订阅时需要读写这些文件。
OWNER="$(stat -f %Su "$DIR")"
give_back() {
  local f
  for f in .run-config.yaml .mihomo.pid .config.yaml.notun config.yaml mihomo.log cache.db; do
    [ -e "$DIR/$f" ] && chown "$OWNER" "$DIR/$f"
  done
  return 0
}

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
      echo "$(t '• TUN 已处于开启状态，无需重复操作' '• TUN is already on')"; exit 0
    fi
    [ -f "$BAK" ] || cp "$CFG" "$BAK"
    tun_block >> "$CFG"
    echo "$(t '✓ 已写入 TUN 配置' '✓ TUN config written')"
    # 重启服务
    sudo -u "${SUDO_USER:-root}" env AMYFREE_LANG="${AMYFREE_LANG:-zh}" "$DIR/mihomoctl.sh" restart 2>/dev/null || true
    give_back
    sleep 2
    if ifconfig 2>/dev/null | grep -q "utun199"; then
      echo "$(t '✓ TUN 接口 utun199 已建立，全部流量正在走代理' '✓ TUN interface utun199 is up; all traffic goes through the proxy')"
    else
      echo "$(t '! utun199 未出现，检查日志' '! utun199 did not appear; check the log'): $DIR/mihomo.log"
    fi
    ;;
  off)
    if [ -f "$BAK" ]; then
      cp "$BAK" "$CFG"; rm -f "$BAK"
      echo "$(t '✓ 已还原为无 TUN 配置' '✓ Restored the non-TUN config')"
    else
      echo "$(t '• 无备份可还原（可能本就未开启）' '• No backup to restore (TUN was probably off)')"
    fi
    sudo -u "${SUDO_USER:-root}" env AMYFREE_LANG="${AMYFREE_LANG:-zh}" "$DIR/mihomoctl.sh" restart 2>/dev/null || true
    give_back
    ;;
  status)
    if grep -qE '^tun:' "$CFG" 2>/dev/null; then
      echo "$(t '配置: TUN 已开启' 'Config: TUN on')"
    else
      echo "$(t '配置: TUN 未开启（当前为 7890 端口代理模式）' 'Config: TUN off (port 7890 proxy mode)')"
    fi
    if ifconfig 2>/dev/null | grep -q utun199; then
      echo "$(t '接口: utun199 存在' 'Interface: utun199 present')"
    else
      echo "$(t '接口: utun199 不存在' 'Interface: utun199 absent')"
    fi
    ;;
  *)
    sed -n '2,12p' "$0"; exit 1 ;;
esac
