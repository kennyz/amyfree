#!/bin/bash
# ============================================================
# 编译并打包菜单栏 App（无需 Xcode 工程，直接 swiftc）
#
# 用法: bash scripts/build-app.sh
# 产物: build/Amyfree.app
#
# 为什么不用 Xcode：这是纯 AppKit 单文件程序，swiftc 足够，
# 且避免维护 .xcodeproj。若你更喜欢 Xcode，可自行新建工程
# 并加入 app/main.swift。
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$REPO/app"
OUT="$REPO/build"
# 工作区可能位于 iCloud；File Provider 会自动写回 FinderInfo，导致签名失败。
# 在本机临时目录完成打包和签名，再复制最终产物。
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/mimio-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Amyfree.app"

echo "=== 环境检查 ==="
command -v swiftc >/dev/null 2>&1 || { echo "✗ 未找到 swiftc。请安装 Xcode 或 Command Line Tools：
  xcode-select --install"; exit 1; }
echo "  swiftc: $(swiftc --version 2>&1 | head -1)"

# 注意：swiftc 默认把模块缓存写到 ~/Library/Developer，在受限环境下可能失败，
# 所以显式指定到临时目录。
CACHE="${TMPDIR:-/tmp}/mihomo-swift-cache"
# OUT 目录必须先存在，否则 swiftc 链接阶段报 ld: open() failed errno=2
mkdir -p "$CACHE" "$OUT"

echo
echo "=== 编译 ==="
swiftc -O "$APP_SRC"/*.swift -o "$OUT/Amyfree" \
  -module-cache-path "$CACHE" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework ServiceManagement
echo "✓ 编译完成: $(du -h "$OUT/Amyfree" | cut -f1)"

echo
echo "=== 打包 .app ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Amyfree" "$APP/Contents/MacOS/"
cp "$APP_SRC/Info.plist" "$APP/Contents/"
chmod +x "$APP/Contents/MacOS/Amyfree"

echo "=== 生成应用图标 ==="
swift -module-cache-path "$CACHE" "$REPO/scripts/generate-icon.swift" "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名：本机运行足够，且避免 Gatekeeper 直接拦掉
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
echo "✓ 签名有效 (ad-hoc)"
rm -rf "$OUT/Amyfree.app"
ditto --noextattr --norsrc "$APP" "$OUT/Amyfree.app"
APP="$OUT/Amyfree.app"

echo
echo "=== 完成 ==="
echo "  产物: $APP"
echo
echo "本地调试（不改动 ~/.config）："
echo "  1) 先把依赖准备好:  bash scripts/fetch-deps.sh"
echo "  2) 用环境变量指向仓库目录后再启动:"
echo "       MIHOMO_HOME=$REPO/mihomo $APP/Contents/MacOS/Amyfree"
echo
echo "正式安装到 ~/Applications:  bash scripts/install-menubar.sh"
