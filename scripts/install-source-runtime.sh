#!/bin/bash
# Prepare the runtime for a locally compiled app, without enabling a LaunchAgent.
set -euo pipefail
umask 077
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/mihomo"
DEST="${1:-${MIHOMO_HOME:-$HOME/.config/mihomo}}"
NEED_DEPS=false
for file in mihomo geoip.dat geosite.dat country.mmdb; do
  if [ ! -s "$SRC/$file" ] && [ ! -s "$DEST/$file" ]; then NEED_DEPS=true; fi
done
CORE="$SRC/mihomo"
[ -s "$CORE" ] || CORE="$DEST/mihomo"
if ! "$CORE" -v >/dev/null 2>&1; then NEED_DEPS=true; fi
if [ "$NEED_DEPS" = true ]; then
  echo '=== 首次源码安装：准备 mihomo 内核和规则库 ==='
  bash "$REPO/scripts/fetch-deps.sh"
fi
mkdir -p "$DEST/providers"
for file in mihomoctl.sh proxyctl.sh tun.sh verify_node.sh parse_sub.py subscription.py node_speed.py chain_proxy.py cert_probe.py nodes.py geodata_update.py config.template.yaml; do
  temporary="$(mktemp "$DEST/.amyfree-copy.XXXXXX")"
  cp "$SRC/$file" "$temporary"
  case "$file" in *.sh|*.py) chmod 755 "$temporary";; *) chmod 644 "$temporary";; esac
  mv -f "$temporary" "$DEST/$file"
done
cp "$REPO/scripts/refresh-geodata.sh" "$DEST/refresh-geodata.sh"
chmod 755 "$DEST/refresh-geodata.sh"
for file in mihomo geoip.dat geosite.dat country.mmdb; do
  # Preserve custom rule databases already in use.
  if [ "$file" != mihomo ] && [ -s "$DEST/$file" ]; then continue; fi
  if [ -s "$SRC/$file" ]; then
    temporary="$(mktemp "$DEST/.amyfree-copy.XXXXXX")"
    cp "$SRC/$file" "$temporary"
    if [ "$file" = mihomo ]; then chmod 755 "$temporary"; else chmod 644 "$temporary"; fi
    mv -f "$temporary" "$DEST/$file"
  fi
done
if [ ! -e "$DEST/config.yaml" ]; then
  # Install the template, never an accidental developer's private configuration.
  cp "$SRC/config.template.yaml" "$DEST/config.yaml"
  chmod 600 "$DEST/config.yaml"
fi
if [ ! -s "$DEST/.api-secret" ]; then
  openssl rand -hex 32 > "$DEST/.api-secret"
  chmod 600 "$DEST/.api-secret"
fi
# A prior Release installation may have left a launcher pointing into the old app.
# Source builds use the Command Line Tools Python, so remove only our own launcher.
if [ -f "$DEST/python3" ] && grep -q '^export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1$' "$DEST/python3"; then
  rm -f "$DEST/python3"
fi
# Do not install a placeholder subscription; a fresh app asks the user to import one.
[ -x "$DEST/mihomo" ] || { echo '✗ mihomo 内核未安装。' >&2; exit 1; }
"$DEST/mihomo" -v >/dev/null 2>&1 || { echo '✗ mihomo 内核无法运行，请重新拉取依赖后安装。' >&2; exit 1; }
echo "✓ 内核、规则库和运行脚本已就位：$DEST"
echo '✓ 已有订阅、密钥和配置保持不变；未开启额外的内核自启服务。'
