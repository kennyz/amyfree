#!/bin/bash
# ============================================================
# 更新规则库（GeoIP / GeoSite / MMDB）
#
# 为什么单独写：config.yaml 里 geo-auto-update 必须为 false
# （mihomo 自动更新走 GitHub，国内会卡死启动），所以更新要手动触发。
#
# 用法: bash scripts/refresh-geodata.sh [目标目录]
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$REPO/mihomo}"
BASE="${GEODATA_BASE:-https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release}"

[ -d "$DEST" ] || { echo "✗ 目录不存在: $DEST"; exit 1; }

echo "=== 备份现有规则库（失败可回滚）==="
TMP="$(mktemp -d)"
for f in geoip.dat geosite.dat country.mmdb; do
  [ -f "$DEST/$f" ] && cp "$DEST/$f" "$TMP/$f"
done
echo "  备份于 $TMP"

restore() {
  echo "! 更新失败，正在回滚…"
  for f in geoip.dat geosite.dat country.mmdb; do
    [ -f "$TMP/$f" ] && cp "$TMP/$f" "$DEST/$f"
  done
  echo "  已回滚"
}
trap restore ERR

echo
echo "=== 下载最新规则库 ==="
for f in geoip.dat geosite.dat country.mmdb; do
  printf "  %-14s " "$f"
  # 下到临时文件，校验非空且够大才替换，避免半截文件顶掉好文件
  curl -sSL --max-time 300 --retry 3 -o "$TMP/new.$f" "$BASE/$f" \
    -w "http=%{http_code} %{size_download} bytes\n"
  SIZE=$(wc -c < "$TMP/new.$f" | tr -d ' ')
  if [ "$SIZE" -lt 100000 ]; then
    echo "  ✗ $f 下载内容过小（$SIZE 字节），疑似失败"
    false
  fi
  cp "$TMP/new.$f" "$DEST/$f"
done

echo
trap - ERR
rm -rf "$TMP"
echo "=== 完成 ==="
ls -lh "$DEST"/geoip.dat "$DEST"/geosite.dat "$DEST"/country.mmdb | awk '{print "  " $5 "\t" $9}'
echo
echo "若内核正在运行，请重启以加载新规则库："
echo "  cd $DEST && ./mihomoctl.sh restart"
