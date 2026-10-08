#!/bin/bash
# ============================================================
# 安装菜单栏 App 到 ~/Applications 并启动
#
# 用法: bash scripts/install-menubar.sh
# 前置: 先跑 scripts/build-app.sh 生成 build/Amyfree.app
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Amyfree.app"
SRC="$REPO/build/$APP_NAME"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME"
LEGACY_DEST="$DEST_DIR/mihomo-menubar.app"
PREVIOUS_DEST="$DEST_DIR/MihomoMini.app"
REBRAND_DEST="$DEST_DIR/Mimio.app"
RESTORE_LOGIN=false
AGENT="$HOME/Library/LaunchAgents/com.user.mihomo.menubar.plist"

[ -d "$SRC" ] || { echo "✗ 未找到 ${SRC}，请先运行: bash scripts/build-app.sh"; exit 1; }

# A source-built app does not bundle the release runtime. Prepare all dependencies
# before stopping or replacing the existing application.
RUNTIME="${MIHOMO_HOME:-$HOME/.config/mihomo}"
bash "$REPO/scripts/install-source-runtime.sh" "$RUNTIME"

echo "=== 安装 $APP_NAME → $DEST ==="
mkdir -p "$DEST_DIR" "$HOME/Library/LaunchAgents"

# 名称迁移后重新登记登录项的路径，保留用户已开启的自启选择。
if [ -x "$REBRAND_DEST/Contents/MacOS/Mimio" ]; then
  OLD_LOGIN="$("$REBRAND_DEST/Contents/MacOS/Mimio" --login-status 2>/dev/null || true)"
  if [ "$OLD_LOGIN" = "enabled" ]; then
    "$REBRAND_DEST/Contents/MacOS/Mimio" --disable-login
    RESTORE_LOGIN=true
  fi
fi

# 覆盖安装前先停掉旧实例，否则 cp 可能因文件占用失败
pkill -f "$APP_NAME/Contents/MacOS/Amyfree" 2>/dev/null || true
pkill -f "$LEGACY_DEST/Contents/MacOS/mihomo-menubar" 2>/dev/null || true
pkill -f "$PREVIOUS_DEST/Contents/MacOS/MihomoMini" 2>/dev/null || true
pkill -f "$REBRAND_DEST/Contents/MacOS/Mimio" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto --noextattr --norsrc "$SRC" "$DEST"
# 更名后清理旧菜单栏 App，保留 ~/.config/mihomo 内的订阅与运行时。
if [ -d "$LEGACY_DEST" ]; then
  rm -rf "$LEGACY_DEST"
fi
if [ -d "$PREVIOUS_DEST" ]; then
  rm -rf "$PREVIOUS_DEST"
fi
if [ -d "$REBRAND_DEST" ]; then
  rm -rf "$REBRAND_DEST"
fi

# 去隔离属性，避免 Gatekeeper 拦截；再补一次 ad-hoc 签名
xattr -cr "$DEST"
codesign --force --deep --sign - "$DEST"
codesign --verify --strict "$DEST"
echo "✓ 已安装"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
if [ "$RESTORE_LOGIN" = "true" ]; then
  "$DEST/Contents/MacOS/Amyfree" --enable-login
fi

# 旧版本安装脚本曾自动写入自启 plist；新版本由 SMAppService 按用户选择管理。
if [ -f "$AGENT" ]; then
  if launchctl print "gui/$(id -u)/com.user.mihomo.menubar" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/com.user.mihomo.menubar"
  fi
  rm -f "$AGENT"
  echo "✓ 已迁移旧菜单栏自启记录，今后通过 App 菜单设置"
fi

echo
echo "=== 启动 ==="
open "$DEST" --args "$@" 2>/dev/null && echo "✓ 已启动，请看菜单栏盾牌图标" || {
  nohup "$DEST/Contents/MacOS/Amyfree" "$@" >/dev/null 2>&1 &
  echo "  已后台启动"
}

cat <<'EOF'

=== 完成 ===
菜单栏图标显示「开启」/「关闭」表示代理内核运行状态。

常用操作：
  · 启用代理    → 启动内核 + 自动接管系统代理（浏览器即可用）
  · 系统代理     → 只开关系统代理，不动内核
  · 修改订阅地址 → 支持 base64 原始链接订阅，失败会自动回滚
  · 切换节点     → 列出所有节点与延迟，点击即切
  · 分流设置     → 国内直连、广告拦截、网站与 IP 规则，保存后生效
  · 节点测速     → 每 30 秒自动检测，支持手工下载测速
  · 链式代理     → 设置入口 → 出口的两跳链路
  · 关于 Amyfree → 查看应用版本和内核版本
  · TUN 全局接管 → 需管理员密码，接管所有 App 流量

开机自启（可选）：
  在 Amyfree 菜单点击「开机自启（Amyfree）」，应用会读取 macOS 的实际登记状态。
EOF
