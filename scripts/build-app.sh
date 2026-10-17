#!/bin/bash
# ============================================================
# 编译并打包菜单栏 App（Rust + objc2，无需 Xcode 工程）
#
# 用法: bash scripts/build-app.sh
# 产物: build/Amyfree.app
#
# 菜单栏在 app-rs/（Rust）；尚未迁移的窗口仍在 app/*.swift，
# 由 app-rs/build.rs 调用 swiftc 编译成静态库链接进同一个可执行文件。
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
command -v cargo >/dev/null 2>&1 || { echo "✗ 未找到 cargo。请安装 Rust：https://rustup.rs"; exit 1; }
cargo build --release --quiet --manifest-path "$REPO/Cargo.toml" -p amyfree-app
cp "$REPO/target/release/Amyfree" "$OUT/Amyfree"
echo "✓ 编译完成: $(du -h "$OUT/Amyfree" | cut -f1)"

echo
echo "=== 编译运行组件 amyfree-helper（Rust） ==="
cargo build --release --quiet --manifest-path "$REPO/Cargo.toml" -p amyfree-core --bin amyfree-helper
cp "$REPO/target/release/amyfree-helper" "$OUT/amyfree-helper"
echo "✓ amyfree-helper: $(du -h "$OUT/amyfree-helper" | cut -f1)"

echo
echo "=== 打包 .app ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Amyfree" "$APP/Contents/MacOS/"
cp "$OUT/amyfree-helper" "$APP/Contents/MacOS/"
cp "$APP_SRC/Info.plist" "$APP/Contents/"
cp "$REPO/scripts/install.sh" "$APP/Contents/Resources/install.sh"
chmod +x "$APP/Contents/MacOS/Amyfree" "$APP/Contents/MacOS/amyfree-helper"

echo "=== 生成应用图标 ==="
# 图标与菜单栏共用 app/CatGlyph.swift；多文件编译时入口须命名为 main.swift
mkdir -p "$STAGING/icon"
cp "$REPO/scripts/generate-icon.swift" "$STAGING/icon/main.swift"
swiftc "$STAGING/icon/main.swift" "$APP_SRC/CatGlyph.swift" -o "$STAGING/icon/generate-icon" \
  -module-cache-path "$CACHE" -target arm64-apple-macosx13.0 -framework AppKit
"$STAGING/icon/generate-icon" "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名：本机运行足够，且避免 Gatekeeper 直接拦掉
xattr -cr "$APP"
# 先签内嵌的可执行组件，再签整个应用
codesign --force --sign - "$APP/Contents/MacOS/amyfree-helper"
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
