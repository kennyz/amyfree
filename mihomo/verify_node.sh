#!/bin/bash
# ============================================================
# 节点真实连通性验证
#
# 判据：必须证明「经代理的出口 IP ≠ 本机直连 IP」才算真正走通节点。
#      仅凭「某个网页能打开」不足以判断——国内站点直连也能打开。
#
# 用法: verify_node.sh [mixed-port] [api地址] [secret] [节点名] [期望国家代码]
# ============================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 按字节百分号编码（中文节点名等），与 Python urllib.parse.quote 一致
urlencode() {
  local LC_ALL=C text="$1" out="" char code hex i
  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    case "$char" in
      [A-Za-z0-9._~/-]) out+="$char" ;;
      *) printf -v code '%d' "'$char"; printf -v hex '%%%02X' $((code & 255)); out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}
PORT="${1:-7890}"; API="${2:-127.0.0.1:9090}"; SECRET="${3:-}"; NODE="${4:-}"; WANT="${5:-}"

# 提示语言：AMYFREE_LANG=en 输出英文，默认中文（菜单栏 App 按界面语言传入）
t() { if [ "${AMYFREE_LANG:-zh}" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
AUTH=()
[ -n "$SECRET" ] && AUTH=(-H "Authorization: Bearer $SECRET")

echo "==================== $(t '节点连通性硬验证' 'Node connectivity check') ===================="

# ---------- [1] 本机直连出口 IP ----------
echo "--- [1] $(t '本机直连出口 IP（不经代理）' 'Direct exit IP (no proxy)') ---"
LOCAL_IP="$(curl -sSL --max-time 12 "http://api.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')"
LOCAL_DESC="$(curl -sSL --max-time 12 "http://ip-api.com/line/?fields=query,country" 2>/dev/null | tr '\n' ' ')"
echo "    IP   = ${LOCAL_IP:-<$(t '获取失败' 'failed')>}"
echo "    $(t '归属' 'Location') = ${LOCAL_DESC:-<$(t '获取失败' 'failed')>}"

# ---------- [2] 经代理的出口 IP ----------
# 关键：必须 -L 跟随跳转。1.1.1.1 的 trace 会 301，不加 -L 会拿到空内容，
#       从而误判成「节点未生效」（这个坑实际踩过）。
echo "--- [2] $(t '经代理出口 IP' 'Exit IP via proxy') ---"
PROXY_IP=""; PROXY_DESC=""
for ep in "http://api.ip.sb/ip" "http://ipinfo.io/ip" "http://ip-api.com/line/?fields=query,country"; do
  out="$(curl -sSL --max-time 15 -x "http://127.0.0.1:$PORT" "$ep" 2>/dev/null | tr '\n' ' ')"
  ip="$(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$ip" ]; then
    PROXY_IP="$ip"; PROXY_DESC="$out"
    echo "    $(t '查询接口' 'Endpoint') = $ep"
    break
  fi
done
echo "    IP   = ${PROXY_IP:-<$(t '失败' 'failed')>}"
[ -n "$PROXY_DESC" ] && echo "    $(t '详情' 'Details') = $PROXY_DESC"

# ---------- [3] 判定 ----------
echo "--- [3] $(t '判定结论' 'Verdict') ---"
if [ -z "$PROXY_IP" ]; then
  echo "    $(t '✗ 无法经代理取得出口 IP —— 代理链路不通' '✗ Could not get an exit IP through the proxy: the proxy path is down')"
  echo "      $(t '（先确认内核在跑：./mihomoctl.sh status）' '(check the core is running: ./mihomoctl.sh status)')"
elif [ -n "$LOCAL_IP" ] && [ "$PROXY_IP" = "$LOCAL_IP" ]; then
  echo "    $(t "✗ 出口 IP 与本机相同（${LOCAL_IP}）—— 流量未走节点" "✗ Exit IP is the same as this machine (${LOCAL_IP}): traffic is not going through the node")"
else
  echo "    $(t "✓ 出口 IP = ${PROXY_IP}，本机 = ${LOCAL_IP:-?} —— 节点真实生效" "✓ Exit IP = ${PROXY_IP}, local = ${LOCAL_IP:-?}: the node is working")"
fi

# ---------- [4] 真实站点可达性 ----------
echo "--- [4] $(t '真实站点可达性（经代理）' 'Site reachability (via proxy)') ---"
for u in https://www.google.com https://github.com https://www.youtube.com https://www.gstatic.com/generate_204; do
  printf '    %-42s ' "$u"
  curl -sSL -o /dev/null -w "http=%{http_code} t=%{time_total}s\n" \
    --max-time 20 -x "http://127.0.0.1:$PORT" "$u" 2>&1 | tail -1
done

# ---------- [5] API 测速 ----------
if [ -n "$NODE" ]; then
  echo "--- [5] $(t 'API 节点测速' 'API latency test') (${NODE}) ---"
  # delay 接口的 url 参数必须 URL 编码，否则 mihomo 返回 400
  enc="$(urlencode "$NODE")"
  resp="$(curl -s "${AUTH[@]}" --max-time 30 \
    "http://$API/proxies/$enc/delay?timeout=15000&url=http%3A%2F%2Fapi.ip.sb%2Fip" 2>/dev/null)"
  echo "    $resp"
  case "$resp" in
    *'"delay"'*) : ;;
    *Unauthorized*) echo "    $(t '! 鉴权失败：检查 .api-secret 与运行时配置是否一致' '! Auth failed: check .api-secret matches the runtime config')" ;;
    *) echo "    $(t '! 测速未返回延迟（节点名或组名可能不正确）' '! No latency returned (the node or group name may be wrong)')" ;;
  esac
fi
echo "========================================================"
