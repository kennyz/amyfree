#!/bin/bash
# Shared curl installer and signed in-app update helper. Requires only macOS tools.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
REPO='kennyz/amyfree'
REQUIREMENT='anchor apple generic and identifier "com.user.mihomo.menubar" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "FCX336J3XU"'
VERSION='' TARGET='' ARCHIVE='' EXPECTED='' STAGED='' WAIT_PID=''
STAGE_ONLY=false OPEN_APP=true WORK='' BACKUP='' INCOMING='' COMMITTED=false
die() { echo "Amyfree：$*" >&2; exit 1; }
usage() {
  echo '用法：bash install.sh [--version v1.4.0] [--target /路径/Amyfree.app] [--no-open]'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--target|--archive|--sha256|--staged|--wait-pid)
      [ "$#" -ge 2 ] || die "缺少参数：$1"
      case "$1" in
        --version) VERSION="$2";; --target) TARGET="$2";; --archive) ARCHIVE="$2";;
        --sha256) EXPECTED="$2";; --staged) STAGED="$2";; --wait-pid) WAIT_PID="$2";;
      esac
      shift 2;;
    --stage-only) STAGE_ONLY=true; shift;;
    --no-open) OPEN_APP=false; shift;;
    --help|-h) usage; exit 0;;
    *) die "未知参数：$1";;
  esac
done
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die '当前版本支持 Apple Silicon Mac。'
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$OS_MAJOR" -ge 13 ] || die '需要 macOS 13 或更新版本。'
valid_version() { [[ "$1" =~ ^v?[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]]; }
newer() {
  local left right i
  IFS=. read -r -a left <<< "${1#v}"
  IFS=. read -r -a right <<< "${2#v}"
  for i in 0 1 2; do
    if (( 10#${left[$i]} > 10#${right[$i]} )); then return 0; fi
    if (( 10#${left[$i]} < 10#${right[$i]} )); then return 1; fi
  done
  return 1
}
fetch() { curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 20 --max-time 900 --retry 3 "$1" -o "$2"; }
validate_app() {
  local app="$1" actual
  [ -d "$app" ] && [ ! -L "$app" ] || die '安装包中没有有效应用。'
  codesign --verify --deep --strict -R "=$REQUIREMENT" "$app" || die '签名校验失败，安装已取消。'
  actual="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
  [ "$actual" = "${VERSION#v}" ] || die '安装包版本不匹配。'
  [ -x "$app/Contents/MacOS/Amyfree" ] || die '应用缺少可执行文件。'
}
cleanup() {
  local result=$?
  trap - EXIT
  if [ "$COMMITTED" = false ] && [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
    [ ! -e "$TARGET" ] || rm -rf "$TARGET"
    mv "$BACKUP" "$TARGET" || echo "请从 $BACKUP 恢复应用。" >&2
  fi
  [ -z "$INCOMING" ] || [ ! -d "$INCOMING" ] || rm -rf "$INCOMING"
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
  if [ "$result" -ne 0 ]; then
    echo '安装未完成；订阅和设置未被修改。' >&2
    if [ -n "$WAIT_PID" ] && [ "$OPEN_APP" = true ]; then
      [ ! -d "$TARGET" ] || open "$TARGET" || true
      osascript -e 'display notification "更新未完成，原应用已保留。详情见 ~/Library/Logs/Amyfree-update.log。" with title "Amyfree"' || true
    fi
  fi
  exit "$result"
}
trap cleanup EXIT

if [ -n "$STAGED" ]; then
  # Only accept an owned staging directory created by this installer.
  [ -d "$STAGED" ] && [ ! -L "$STAGED" ] || die '更新暂存目录无效。'
  case "$(basename "$STAGED")" in amyfree-install.*) ;; *) die '更新暂存目录无效。';; esac
  [ "$(stat -f %u "$STAGED")" = "$(id -u)" ] || die '更新暂存目录不属于当前用户。'
  VERSION="$(cat "$STAGED/version")"
  valid_version "$VERSION" || die '版本号无效。'
  WORK="$(cd "$STAGED" && pwd -P)"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/amyfree-install.XXXXXX")"
  if [ "$STAGE_ONLY" = true ]; then echo "AMYFREE_WORK=$WORK"; fi
  if [ -z "$VERSION" ]; then
    echo '正在检查最新版本…' >&2
    fetch "https://api.github.com/repos/$REPO/releases/latest" "$WORK/release.json"
    VERSION="$(plutil -extract tag_name raw -o - "$WORK/release.json")"
  fi
  valid_version "$VERSION" || die '版本号无效。'
  VERSION="v${VERSION#v}"
  NAME="Amyfree-${VERSION#v}-macOS-arm64.zip"
  if [ -z "$ARCHIVE" ]; then
    BASE="https://github.com/$REPO/releases/download/$VERSION"
    fetch "$BASE/SHA256SUMS.txt" "$WORK/SHA256SUMS.txt"
    EXPECTED="$(awk -v name="$NAME" '$2 == name {print $1; count++} END {if(count != 1) exit 1}' "$WORK/SHA256SUMS.txt")" || die '缺少文件校验值。'
    echo "正在下载 Amyfree ${VERSION}…" >&2
    fetch "$BASE/$NAME" "$WORK/app.zip"
    ARCHIVE="$WORK/app.zip"
  fi
  [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || die 'SHA-256 校验值无效。'
  if [ "$STAGE_ONLY" = true ]; then echo 'AMYFREE_PHASE=verify'; fi
  [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$EXPECTED" ] || die '下载文件校验失败。'
  unzip -Z1 "$ARCHIVE" > "$WORK/entries.txt"
  awk 'BEGIN {bad=0} /^\// || /(^|\/)\.\.(\/|$)/ {bad=1} !/^(Amyfree\.app(\/|$)|__MACOSX\/)/ {bad=1} END {exit bad}' "$WORK/entries.txt" || die '压缩包包含非法路径。'
  # Inspect symbolic-link payloads before extraction, including links in metadata.
  unzip -Z -l "$ARCHIVE" | awk '$1 ~ /^l/ {line=$0; for(i=0;i<9;i++) sub(/^[^[:space:]]+[[:space:]]+/, "", line); print line}' > "$WORK/links.txt"
  while IFS= read -r link; do
    value="$(unzip -p "$ARCHIVE" "$link")"
    case "$value" in /*|../*|*/../*|*/..) die '安装包包含非法符号链接。';; esac
  done < "$WORK/links.txt"
  ditto -x -k "$ARCHIVE" "$WORK/unpacked"
  # Bundled Python uses only local, non-traversing symbolic links.
  while IFS= read -r link; do
    value="$(readlink "$link")"
    case "$value" in /*|../*|*/../*|*/..) die '安装包包含非法符号链接。';; esac
  done < <(find "$WORK/unpacked/Amyfree.app" -type l)
  echo "$VERSION" > "$WORK/version"
  if [ "$STAGE_ONLY" = true ]; then
    [ -f "${BASH_SOURCE[0]:-}" ] || die '暂存更新需要从应用内或本地脚本运行。'
    cp "${BASH_SOURCE[0]}" "$WORK/install.sh"
  fi
fi
validate_app "$WORK/unpacked/Amyfree.app"
if [ "$STAGE_ONLY" = true ]; then
  echo "AMYFREE_STAGED=$WORK"
  WORK='' # The signed-app updater owns this directory after a successful stage.
  exit 0
fi

if [ -z "$TARGET" ]; then
  if [ -d /Applications/Amyfree.app ]; then TARGET=/Applications/Amyfree.app
  elif [ -d "$HOME/Applications/Amyfree.app" ]; then TARGET="$HOME/Applications/Amyfree.app"
  elif [ -w /Applications ]; then TARGET=/Applications/Amyfree.app
  else TARGET="$HOME/Applications/Amyfree.app"; fi
fi
case "$TARGET" in /*/Amyfree.app) ;; *) die '安装目标必须是绝对路径并以 /Amyfree.app 结尾。';; esac
[ ! -L "$TARGET" ] || die '安装目标不能是符号链接。'
PARENT="$(dirname "$TARGET")"
mkdir -p "$PARENT"
PARENT="$(cd "$PARENT" && pwd -P)"
TARGET="$PARENT/Amyfree.app"
[ -w "$PARENT" ] || die '没有安装目录的写入权限，请将应用放入 ~/Applications 后重试。'
if [ -e "$TARGET" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TARGET/Contents/Info.plist")" = com.user.mihomo.menubar ] || die '目标位置存在其他应用。'
  CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"
  valid_version "$CURRENT" || die '已安装应用的版本号无效。'
  if newer "$CURRENT" "$VERSION"; then die '已安装较新版本，已取消降级。'; fi
fi
if [ -n "$WAIT_PID" ]; then
  [[ "$WAIT_PID" =~ ^[0-9]+$ ]] && [ "$WAIT_PID" -gt 1 ] || die '应用进程参数无效。'
  for ((i=0; i<60; i++)); do
    kill -0 "$WAIT_PID" 2>/dev/null || break
    sleep .5
  done
  if kill -0 "$WAIT_PID" 2>/dev/null; then die '应用未退出，请稍后重试。'; fi
fi
for pid in $(pgrep -x Amyfree || true); do
  command_path="$(ps -ww -p "$pid" -o comm= 2>/dev/null || true)"
  [ "$command_path" != "$TARGET/Contents/MacOS/Amyfree" ] || die '请先退出 Amyfree 后重试，或使用应用内更新。'
done
# Stage on the destination filesystem so each rename is atomic.
INCOMING="$(mktemp -d "$PARENT/.Amyfree-install.XXXXXX")"
ditto --noextattr --norsrc "$WORK/unpacked/Amyfree.app" "$INCOMING/Amyfree.app"
validate_app "$INCOMING/Amyfree.app"
if [ -d "$TARGET" ]; then
  BACKUP="$INCOMING/previous.app"
  mv "$TARGET" "$BACKUP"
fi
mv "$INCOMING/Amyfree.app" "$TARGET"
validate_app "$TARGET"
if [ "$OPEN_APP" = true ]; then
  open "$TARGET" || die '无法打开新版应用，正在恢复原版本。'
fi
COMMITTED=true
echo "Amyfree ${VERSION#v} 已安装：$TARGET"
echo '订阅和设置已保留。若 macOS 阻止首次打开，请在「隐私与安全性」中允许。'
