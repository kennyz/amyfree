#!/bin/bash
# ============================================================
# mihomo 服务管理脚本 —— 订阅 / 命令行模式
#   用法: ./mihomoctl.sh {start|stop|restart|status|log|test|sub URL|nodes|use 组 节点|env}
#
# 流程：拉取订阅 → parse_sub.py 转成 Clash 格式 → 写入 providers/nodes.yaml
#       → 启动 mihomo（以 type: file provider 加载）
# ============================================================
set -uo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ ! -x "$DIR/python3" ] || export PATH="$DIR:$PATH"
BIN="$DIR/mihomo"
CFG="$DIR/config.yaml"
SUB_FILE="$DIR/.sub-url"
NODES_FILE="$DIR/providers/nodes.yaml"
PIDFILE="$DIR/.mihomo.pid"
LOGFILE="$DIR/mihomo.log"
APICTL="127.0.0.1:9090"
SECRET_FILE="$DIR/.api-secret"
AUTH=()
[ -s "$SECRET_FILE" ] && AUTH=(-H "Authorization: Bearer $(cat "$SECRET_FILE")")

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

need_sub() {
  if [ ! -s "$SUB_FILE" ]; then
    red "✗ 还没有设置订阅地址。"
    echo "   执行: $0 sub '你的订阅链接'"
    return 1
  fi
  return 0
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  local p; p="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# 拉取订阅并转换成 mihomo 可读的 Clash 格式
refresh_nodes() {
  python3 "$DIR/subscription.py" fetch
}

start() {
  if is_running; then ylw "• 已在运行 (pid $(cat "$PIDFILE"))"; return 0; fi
  need_sub || return 1
  # 没有节点文件就先拉一次
  if [ ! -s "$NODES_FILE" ]; then
    refresh_nodes || return 1
  fi
  # 同步 API secret 到 config（脚本用占位符 __API_SECRET__）
  if [ -s "$SECRET_FILE" ]; then
    awk -v s="$(cat "$SECRET_FILE")" '{gsub(/__API_SECRET__/, s); print}' "$CFG" > "$DIR/.run-config.yaml"
  else
    cp "$CFG" "$DIR/.run-config.yaml"
  fi
  chmod 600 "$DIR/.run-config.yaml"

  # 启动前检查端口占用。若不检查，被占用的实例会起来但完全不工作
  # （API 返回 401、代理不生效），非常难排查——这个坑实际遇到过。
  local busy=""
  for pt in 7890 9090; do
    if lsof -nP -iTCP:"$pt" -sTCP:LISTEN >/dev/null 2>&1; then
      busy="$busy $pt"
    fi
  done
  if [ -n "$busy" ]; then
    red "✗ 端口被占用:$busy"
    echo "  可能是另一个 mihomo 实例在运行："
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ":(7890|9090) " | sed 's/^/    /'
    echo
    echo "  处理方式："
    echo "    · 停掉旧实例：$0 stop      （或检查 ~/.config/mihomo 是否也在跑）"
    echo "    · 或用其它端口：修改 config.yaml 的 mixed-port / external-controller"
    return 1
  fi

  : > "$LOGFILE"
  chmod 600 "$LOGFILE"
  # 独立会话避免命令/父进程退出时，后台内核被一起回收。
  if ! python3 - "$BIN" "$DIR" "$LOGFILE" "$PIDFILE" <<'PY_START'
import subprocess, sys
binary, directory, logfile, pidfile = sys.argv[1:]
process = None
try:
    with open(logfile, 'ab') as log:
        process = subprocess.Popen([binary, '-d', directory, '-f', directory + '/.run-config.yaml'],
                                   cwd=directory, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    with open(pidfile, 'w') as file:
        file.write(str(process.pid))
except Exception:
    if process is not None:
        process.terminate()
    sys.exit(1)
PY_START
  then
    red "✗ 无法创建后台内核进程"
    return 1
  fi
  sleep 4
  if is_running; then
    grn "✓ 已启动 (pid $(cat "$PIDFILE"))"
    echo "  HTTP/SOCKS5 代理: http://127.0.0.1:7890"
    echo "  控制面板 API    : http://$APICTL"
  else
    red "✗ 启动失败，日志尾部："; tail -15 "$LOGFILE"; rm -f "$PIDFILE"; return 1
  fi
}

stop() {
  if ! is_running; then ylw "• 未在运行"; rm -f "$PIDFILE" "$DIR/.run-config.yaml"; return 0; fi
  local p; p="$(cat "$PIDFILE")"
  kill "$p" 2>/dev/null
  for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.3; done
  kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  rm -f "$PIDFILE" "$DIR/.run-config.yaml"
  grn "✓ 已停止"
}

status() {
  if is_running; then
    grn "✓ 运行中 (pid $(cat "$PIDFILE"))"
    curl -s "${AUTH[@]}" --max-time 3 "http://$APICTL/version" 2>/dev/null | head -c 200; echo
  else
    red "✗ 未运行"
  fi
  echo "--- 端口监听 ---"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ":(7890|9090|1053) " || echo "(无)"
}

reload_sub() {
  need_sub || return 1
  refresh_nodes || return 1
  is_running && stop >/dev/null
  start
}

test_sub() {
  if [ -n "${1:-}" ]; then
    python3 "$DIR/subscription.py" test "$1"
  else
    python3 "$DIR/subscription.py" test
  fi
}

nodes() {
  is_running || { red "✗ 服务未运行"; return 1; }
  python3 "$DIR/nodes.py" "nodes" "$APICTL" "$(cat "$SECRET_FILE" 2>/dev/null)"
}

use_group() {
  local group="$1" node="$2"
  [ -z "$group" ] && { red "用法: $0 use <组名> <节点名>"; return 1; }
  curl -s "${AUTH[@]}" -X PUT --max-time 5 -H "Content-Type: application/json" \
    -d "{\"name\":\"$node\"}" "http://$APICTL/proxies/$group" >/dev/null 2>&1 \
    && grn "✓ 已把 [$group] 切换到 $node" || red "✗ 切换失败"
}

# 验证节点是否真实生效（出口 IP 必须变化）
verify() {
  is_running || { red "✗ 服务未运行"; return 1; }
  bash "$DIR/verify_node.sh" 7890 "$APICTL" "$(cat "$SECRET_FILE" 2>/dev/null)" "手动选择"
}

env_out() {
  cat <<'EOF'
# ---- 把下面内容加入 ~/.zshrc，让终端与 GUI 应用走代理 ----
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
export all_proxy=socks5://127.0.0.1:7890
export no_proxy="localhost,127.0.0.1,::1,*.local,192.168.0.0/16,10.0.0.0/8"
EOF
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  log)     tail -n "${2:-40}" "$LOGFILE" ;;
  test)    test_sub "${2:-}" ;;
  refresh) python3 "$DIR/subscription.py" update ;;
  verify)  verify ;;
  sub)
    if [ -z "${2:-}" ]; then
      if [ -s "$SUB_FILE" ]; then echo "当前订阅: $(cat "$SUB_FILE")"; else red "尚未设置订阅"; fi
    else
      case "$2" in
        http://*|https://*) ;;
        *) red "✗ 订阅地址必须以 http:// 或 https:// 开头"; exit 1 ;;
      esac
      python3 "$DIR/subscription.py" save "$2"
    fi ;;
  nodes)   nodes ;;
  use)     use_group "${2:-}" "${3:-}" ;;
  env)     env_out ;;
  *) sed -n '3,6p' "$0"; exit 1 ;;
esac
