#!/bin/bash
# Build a self-contained, Developer ID signed Apple Silicon distribution.
# Optional: NOTARY_PROFILE=<Keychain profile> bash scripts/build-release.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$REPO/build/release-deps"
OUT="$REPO/build/release"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/amyfree-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$REPO/app/Info.plist")"
IDENTITY="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo 'A Developer ID Application signing identity is required.' >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo 'Build this release on Apple Silicon.' >&2; exit 1; }
mkdir -p "$DEPS" "$OUT"

download() {
  local url="$1" target="$2"
  if [ ! -s "$target" ]; then
    curl -fLsS --retry 3 --max-time 600 "$url" -o "$target.part"
    mv "$target.part" "$target"
  fi
}
verify() {
  local target="$1" expected="$2" actual
  actual="$(shasum -a 256 "$target" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { echo "Checksum mismatch: $target" >&2; exit 1; }
}

echo '=== Download and verify public dependencies ==='
download 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-darwin-arm64-go124-v1.19.32.gz' "$DEPS/mihomo.gz"
verify "$DEPS/mihomo.gz" 3105fa21ce5195b456a13d57cde2f61dbdac7d04e9cf74b922d63064546c4d01
download 'https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.13.16%2B20261003-aarch64-apple-darwin-install_only.tar.gz' "$DEPS/python.tar.gz"
verify "$DEPS/python.tar.gz" d8975d7df4f08f7b1c7aafcdfacbddcec3d366415f2c1a72b2466b6850815933
RULES='https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/426f62e175218c1f1d0c909188fbff1746f88042'
for file in geoip.dat geosite.dat country.mmdb; do
  download "$RULES/$file" "$DEPS/$file"
  download "$RULES/$file.sha256sum" "$DEPS/$file.sha256sum"
  verify "$DEPS/$file" "$(awk '{print $1}' "$DEPS/$file.sha256sum")"
done
download 'https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.32/LICENSE' "$DEPS/mihomo-LICENSE.txt"
download 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/master/README.md' "$DEPS/rule-data-README.md"
download 'https://codeload.github.com/MetaCubeX/mihomo/tar.gz/refs/tags/v1.19.32' "$OUT/mihomo-v1.19.32-source.tar.gz"

bash "$REPO/scripts/build-app.sh"
APP="$STAGING/Amyfree.app"
ditto --noextattr --norsrc "$REPO/build/Amyfree.app" "$APP"
RUNTIME="$APP/Contents/Resources/runtime"
PYTHON="$APP/Contents/Resources/Python"
mkdir -p "$RUNTIME" "$APP/Contents/Resources/licenses"
# Use an allowlist so user configuration and credentials can never enter the bundle.
for file in mihomoctl.sh proxyctl.sh tun.sh verify_node.sh parse_sub.py subscription.py node_speed.py chain_proxy.py cert_probe.py nodes.py geodata_update.py config.template.yaml; do
  cp "$REPO/mihomo/$file" "$RUNTIME/$file"
done
cp "$REPO/scripts/refresh-geodata.sh" "$RUNTIME/refresh-geodata.sh"
for file in geoip.dat geosite.dat country.mmdb; do cp "$DEPS/$file" "$RUNTIME/$file"; done
gunzip -c "$DEPS/mihomo.gz" > "$APP/Contents/MacOS/mihomo"
chmod 755 "$APP/Contents/MacOS/mihomo" "$RUNTIME"/*.sh
tar -xzf "$DEPS/python.tar.gz" -C "$STAGING"
mv "$STAGING/python" "$PYTHON"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON/bin/python3" -m pip install --disable-pip-version-check --no-compile --only-binary=:all: 'PyYAML==6.0.3' 'certifi==2026.7.22'
cp "$REPO/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cp "$DEPS/mihomo-LICENSE.txt" "$DEPS/rule-data-README.md" "$APP/Contents/Resources/licenses/"
# Remove rebuild-only static libraries and generated caches before sealing.
find "$PYTHON" -name '*.a' -delete
find "$PYTHON" -type d -name __pycache__ -prune -exec rm -rf {} +
xattr -cr "$APP"

echo '=== Sign nested Mach-O components, then the application ==='
python3 - "$APP" "$IDENTITY" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
magic = {bytes.fromhex(s) for s in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
paths = []
for p in root.rglob('*'):
    if not p.is_file() or p.is_symlink(): continue
    if p == root / 'Contents/MacOS/Amyfree': continue  # Signed with its outer app bundle.
    with p.open('rb') as f:
        if f.read(4) in magic: paths.append(p)
for p in sorted(paths, key=lambda x: len(x.parts), reverse=True):
    result = subprocess.run(['codesign','--force','--sign',sys.argv[2],'--timestamp','--options','runtime',str(p)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f'Signing {p}: {result.stderr}')
print(f'Signed {len(paths)} Mach-O components.')
PY
codesign --force --sign "$IDENTITY" --timestamp --options runtime "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$OUT/Amyfree-$VERSION-macOS-arm64.zip"
DMG="$OUT/Amyfree-$VERSION-macOS-arm64.dmg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$STAGING/notarize.zip"
  xcrun notarytool submit "$STAGING/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT/notarization.json"
  python3 - "$OUT/notarization.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted': raise SystemExit('Apple notarization was not accepted; see notarization.json.')
PY
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  echo 'notarized' > "$OUT/signing-status.txt"
else
  echo 'developer-id-signed; not notarized' > "$OUT/signing-status.txt"
fi
if [ -d "$OUT/Amyfree.app" ]; then
  python3 - "$OUT/Amyfree.app" <<'PY_REMOVE'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1])
if p.name != 'Amyfree.app' or p.parent.name != 'release': raise SystemExit('Unexpected output path')
shutil.rmtree(p)
PY_REMOVE
fi
ditto --noextattr --norsrc "$APP" "$OUT/Amyfree.app"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
mkdir -p "$STAGING/disk"
ditto --noextattr --norsrc "$APP" "$STAGING/disk/Amyfree.app"
ln -s /Applications "$STAGING/disk/Applications"
cp "$REPO/README.md" "$STAGING/disk/使用说明.md"
hdiutil create -volname "Amyfree $VERSION" -srcfolder "$STAGING/disk" -format UDZO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT/dmg-notarization.json"
  python3 - "$OUT/dmg-notarization.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted': raise SystemExit('DMG notarization was not accepted.')
PY
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
(cd "$OUT" && shasum -a 256 "Amyfree-$VERSION-macOS-arm64.dmg" "Amyfree-$VERSION-macOS-arm64.zip" mihomo-v1.19.32-source.tar.gz > SHA256SUMS.txt)
echo "Release artifacts: $OUT"
cat "$OUT/signing-status.txt"
