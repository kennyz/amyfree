#!/bin/bash
# ============================================================
# 在新机器上重建运行依赖（下载 mihomo 内核 + 规则库 + 配置文件）
#
# 为什么需要这个脚本：
#   GitHub 在部分国内网络不可达（本项目开发环境实测直接超时），
#   所以内核走 gh-proxy 镜像下载；规则库走 jsDelivr。
#
# 用法: bash scripts/fetch-deps.sh [目标目录]
#   默认目标目录 = 仓库里的 ./mihomo
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$REPO/mihomo}"

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.32}"
GH_MIRROR="${GH_MIRROR-https://gh-proxy.com/}"
GEODATA_BASE="${GEODATA_BASE:-https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release}"

# 按 CPU 架构选包
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ASSET="mihomo-darwin-arm64-go124-${MIHOMO_VERSION}.gz" ;;
  x86_64) ASSET="mihomo-darwin-amd64-compatible-${MIHOMO_VERSION}.gz" ;;
  *) echo "✗ 不支持的架构: ${ARCH}（本项目面向 macOS）"; exit 1 ;;
esac

echo "=== 目标目录: $DEST ==="
mkdir -p "$DEST/providers"

# ---------- 1. mihomo 内核 ----------
if [ -x "$DEST/mihomo" ] && "$DEST/mihomo" -v >/dev/null 2>&1; then
  echo "• mihomo 已存在，跳过（删除它可强制重下）"
else
  OFFICIAL_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ASSET}"
  URL="${GH_MIRROR}${OFFICIAL_URL}"
  echo "=== 下载 mihomo ${MIHOMO_VERSION} ($ARCH) ==="
  echo "  $URL"
  if ! curl -fL --connect-timeout 20 --max-time 300 --retry 3 -o "$DEST/mihomo.gz" "$URL"; then
    [ -n "$GH_MIRROR" ] || exit 1
    echo '镜像下载失败，尝试官方源…'
    curl -fL --connect-timeout 20 --max-time 300 --retry 3 -o "$DEST/mihomo.gz" "$OFFICIAL_URL"
  fi
  gunzip -c "$DEST/mihomo.gz" > "$DEST/.mihomo-download"
  chmod 755 "$DEST/.mihomo-download"
  "$DEST/.mihomo-download" -v >/dev/null 2>&1 || { echo '✗ 下载的内核无法运行，未替换现有文件。' >&2; exit 1; }
  mv -f "$DEST/.mihomo-download" "$DEST/mihomo"
  rm -f "$DEST/mihomo.gz"
  chmod 755 "$DEST/mihomo"
  echo "✓ 已解压 $(du -h "$DEST/mihomo" | cut -f1)"
fi

echo "--- 版本自检 ---"
"$DEST/mihomo" -v 2>&1 | head -1 || { echo "✗ 二进制无法运行"; exit 1; }
"$DEST/mihomo" -v 2>&1 | grep -q with_gvisor || echo "  ! 警告: 该版本不含 with_gvisor，TUN 模式不可用"

# ---------- 2. 规则库 ----------
echo
echo "=== 下载规则库（GeoIP / GeoSite / MMDB）==="
for f in geoip.dat geosite.dat country.mmdb; do
  if [ -s "$DEST/$f" ]; then
    echo "• $f 已存在，跳过"
    continue
  fi
  printf "  下载 %-14s " "$f"
  curl -fsSL --connect-timeout 20 --max-time 300 --retry 3 -o "$DEST/$f.part" "$GEODATA_BASE/$f" \
    -w "http=%{http_code} %{size_download} bytes\n"
  [ -s "$DEST/$f.part" ] || { echo "✗ 规则库 $f 为空。" >&2; exit 1; }
  mv -f "$DEST/$f.part" "$DEST/$f"
done

# ---------- 3. 配置文件 ----------
echo
echo "=== 配置文件 ==="
if [ -s "$DEST/config.yaml" ]; then
  echo "• config.yaml 已存在，不覆盖（模板见 mihomo/config.template.yaml）"
else
  cp "$REPO/mihomo/config.template.yaml" "$DEST/config.yaml"
  echo "✓ 已从模板生成 config.yaml"
fi

# ---------- 4. API 密钥 ----------
if [ -s "$DEST/.api-secret" ]; then
  echo "• .api-secret 已存在"
else
  # 避免把密钥打印到终端
  python3 -c "import base64,os;print(base64.b64encode(os.urandom(24)).decode().replace('/','').replace('+','').replace('=','')[:24])" > "$DEST/.api-secret"
  chmod 600 "$DEST/.api-secret"
  echo "✓ 已生成 .api-secret（24 位随机，未回显）"
fi

# ---------- 5. 订阅地址占位 ----------
if [ ! -s "$DEST/.sub-url" ]; then
  echo "https://example.com/subs/REPLACE_ME" > "$DEST/.sub-url"
  chmod 600 "$DEST/.sub-url"
  echo "✓ 已写入占位订阅地址，请替换为真实地址"
fi

echo
echo "=== 完成 ==="
ls -lh "$DEST" | awk '{print "  " $5 "\t" $9}' | grep -v "^\s*$"
cat <<EOF

下一步：
  1) 设置订阅地址：
       $DEST/mihomoctl.sh sub '你的订阅链接'
  2) 启动并验证：
       cd $DEST && ./mihomoctl.sh start && ./mihomoctl.sh verify
  3) 让浏览器也走代理：
       $DEST/proxyctl.sh on

若要装到 ~/.config/mihomo 并开机自启，见 scripts/install-mihomo.sh
EOF
