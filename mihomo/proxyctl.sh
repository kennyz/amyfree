#!/bin/bash
# ============================================================
# 系统代理开关 —— 让浏览器等所有 App 自动走 mihomo
#
# 背景：mihomo 只监听 127.0.0.1:7890，不会自动改系统设置。
#       不开 TUN 也不设系统代理的话，浏览器是直连的，等于没用代理。
#
# 用法: ./proxyctl.sh on|off|status|refresh
#   on      把活跃网卡的 HTTP/HTTPS/SOCKS 代理指向 127.0.0.1:7890
#   off     关闭（只关自己开过的那些服务）
#   status  查看当前状态
# ============================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ ! -x "$DIR/python3" ] || export PATH="$DIR:$PATH"
# 状态文件优先放脚本目录；该目录不可写时（受限沙箱等）退回临时目录
STATE="$DIR/.proxy-state"
if [ ! -w "$DIR" ]; then
  STATE="${TMPDIR:-/tmp}/mihomo-proxy-state.$(id -u)"
fi
PROXY_HOST="127.0.0.1"
PROXY_PORT="7890"
SOCKS_PORT="7890"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

# 找到「有 IPv4 地址且处于活跃状态」的网络服务（即真正的出口网卡）
active_services() {
  # 设备名 -> 服务名 映射
  local order
  order="$(networksetup -listnetworkserviceorder 2>/dev/null)"
  python3 - "$order" <<'PY'
import re, subprocess, sys
order = sys.argv[1]
# 解析形如: (1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en1)
pairs = re.findall(r'\(\d+\)\s+(.+?)\n\(Hardware Port: .*?, Device: (\w+)\)', order)
active = []
for svc, dev in pairs:
    svc = svc.strip()
    try:
        out = subprocess.run(['/sbin/ifconfig', dev], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        continue
    # 有 inet（IPv4）且 UP 且 不是 169.254 自分配
    if re.search(r'\binet (\d+\.\d+\.\d+\.\d+)', out) and 'UP' in out.split('\n')[0]:
        ip = re.search(r'\binet (\d+\.\d+\.\d+\.\d+)', out).group(1)
        if not ip.startswith('169.254.'):
            active.append(svc)
for s in active:
    print(s)
PY
}

set_one() {
  local svc="$1" on="$2"
  if [ "$on" = "on" ]; then
    networksetup -setwebproxy        "$svc" "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null
    networksetup -setsecurewebproxy  "$svc" "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null
    networksetup -setsocksfirewallproxy "$svc" "$PROXY_HOST" "$SOCKS_PORT" 2>/dev/null
    networksetup -setproxybypassdomains "$svc" \
      "localhost" "127.0.0.1" "::1" "*.local" "169.254/16" "192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12" 2>/dev/null
  else
    networksetup -setwebproxystate        "$svc" off 2>/dev/null
    networksetup -setsecurewebproxystate  "$svc" off 2>/dev/null
    networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
  fi
}

case "${1:-status}" in
  on)
    svcs="$(active_services)"
    if [ -z "$svcs" ]; then red "✗ 未找到活跃网络服务"; exit 1; fi
    : > "$STATE"
    while IFS= read -r svc; do
      [ -z "$svc" ] && continue
      set_one "$svc" on
      echo "$svc" >> "$STATE"
      echo "  → $svc"
    done <<< "$svcs"
    grn "✓ 系统代理已开启（指向 ${PROXY_HOST}:${PROXY_PORT}）"
    # 回读校验，避免"设了但没生效"
    sleep 1
    if networksetup -getwebproxy "$(head -1 "$STATE")" 2>/dev/null | grep -q "Enabled: Yes"; then
      grn "✓ 回读校验通过"
    else
      red "✗ 回读校验失败——设置未生效"
      exit 1
    fi
    ;;
  off)
    if [ -f "$STATE" ]; then
      while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        set_one "$svc" off
        echo "  ← $svc"
      done < "$STATE"
      rm -f "$STATE"
    else
      # 没有记录时，兜底关闭所有服务的代理
      while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        set_one "$svc" off
      done <<< "$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')"
    fi
    grn "✓ 系统代理已关闭"
    ;;
  status)
    local_any=0
    while IFS= read -r svc; do
      [ -z "$svc" ] && continue
      wh="$(networksetup -getwebproxy "$svc" 2>/dev/null | head -1)"
      case "$wh" in
        *"Enabled: Yes"*) echo "  $svc: 开"; local_any=1 ;;
        *) echo "  $svc: 关" ;;
      esac
    done <<< "$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')"
    [ "$local_any" = "1" ] && grn "→ 系统代理处于开启状态" || ylw "→ 系统代理全部关闭"
    ;;
  refresh)
    # 网络切换后重新应用到当前活跃服务
    [ -f "$STATE" ] || { ylw "• 系统代理未开启，无需刷新"; exit 0; }
    "$0" off >/dev/null; "$0" on
    ;;
  *)
    sed -n '2,13p' "$0"; exit 1 ;;
esac
