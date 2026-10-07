#!/bin/bash
# ============================================================
# 把 mihomo 运行时装到 ~/.config/mihomo，并生成开机自启 LaunchAgent
#
# 用法: bash scripts/install-mihomo.sh
# 前置: 先跑 scripts/fetch-deps.sh 准备好内核与规则库
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/mihomo"
DST="$HOME/.config/mihomo"
LABEL="com.user.mihomo"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 必需文件检查
for f in mihomo config.yaml geoip.dat geosite.dat country.mmdb; do
  [ -e "$SRC/$f" ] || { echo "✗ 缺少 $SRC/${f}，请先运行: bash scripts/fetch-deps.sh"; exit 1; }
done

echo "=== 安装到 $DST ==="
mkdir -p "$DST/providers" "$HOME/Library/LaunchAgents" "$HOME/.local/bin"

# 脚本与配置
for f in mihomoctl.sh proxyctl.sh tun.sh verify_node.sh parse_sub.py subscription.py node_speed.py chain_proxy.py cert_probe.py nodes.py config.yaml; do
  [ -e "$SRC/$f" ] && cp -f "$SRC/$f" "$DST/$f"
done
# 内核与规则库
for f in mihomo geoip.dat geosite.dat country.mmdb; do
  cp -f "$SRC/$f" "$DST/$f"
done
# 密钥与订阅：优先用仓库里的；否则生成/占位，且不覆盖目标机已有文件
for f in .api-secret .sub-url; do
  if [ -s "$SRC/$f" ]; then
    cp -f "$SRC/$f" "$DST/$f"
  elif [ ! -s "$DST/$f" ]; then
    if [ "$f" = ".api-secret" ]; then
      python3 -c "import base64,os;print(base64.b64encode(os.urandom(24)).decode().replace('/','').replace('+','').replace('=','')[:24])" > "$DST/$f"
    else
      echo "https://example.com/subs/REPLACE_ME" > "$DST/$f"
    fi
  fi
  chmod 600 "$DST/$f"
done
[ -s "$SRC/providers/nodes.yaml" ] && cp -f "$SRC/providers/nodes.yaml" "$DST/providers/nodes.yaml" || true

chmod 755 "$DST/mihomo" "$DST"/*.sh "$DST"/nodes.py "$DST"/parse_sub.py
ln -sf "$DST/mihomo" "$HOME/.local/bin/mihomo"
echo "✓ 文件已就位"

echo
echo "=== 生成 LaunchAgent（开机自启代理内核）==="
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DST/mihomo</string>
    <string>-d</string><string>$DST</string>
    <string>-f</string><string>$DST/.run-config.yaml</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>$DST</string>
  <key>StandardOutPath</key><string>$DST/mihomo.log</string>
  <key>StandardErrorPath</key><string>$DST/mihomo.log</string>
</dict>
</plist>
EOF
echo "  → $PLIST"

cat <<EOF

=== 完成 ===
注意：LaunchAgent 依赖 .run-config.yaml（由 mihomoctl.sh start 生成）。
建议先用脚本启动一次，确认可用后再启用开机自启。

  cd $DST
  ./mihomoctl.sh sub '你的订阅链接'   # 单引号！URL 里常含 &
  ./mihomoctl.sh start
  ./mihomoctl.sh verify               # 验证出口 IP 是否真的切换
  ./proxyctl.sh on                    # 让浏览器也走代理

确认无误后启用开机自启：
  launchctl bootstrap gui/\$(id -u) "$PLIST"
EOF
