#!/usr/bin/env bash
# Packs dist/Tact.app into dist/Tact-<version>-<arch>.dmg for download: the
# app beside a link to Applications, to drag across. Signed with a Developer
# ID certificate and given a notarytool keychain profile (TACT_NOTARY_PROFILE),
# the DMG is notarized and stapled, so it opens without Gatekeeper's warning.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/dist/Tact.app"
[ -d "$APP" ] || { echo "没找到 $APP，先运行 scripts/build-app.sh"; exit 1; }
codesign --verify --strict --deep "$APP"

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
ARCH="$(lipo -archs "$APP/Contents/MacOS/Tact" | tr ' ' '-')"
DMG="$REPO/dist/Tact-$VERSION-$ARCH.dmg"
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/Tact"
/usr/bin/ditto "$APP" "$WORK/Tact/Tact.app"
ln -s /Applications "$WORK/Tact/Applications"
rm -f "$DMG"
hdiutil create -volname "Tact" -srcfolder "$WORK/Tact" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

case "$SIGNER" in
"Developer ID Application:"*)
  codesign --force --sign "$SIGNER" --timestamp "$DMG"
  if [ -n "${TACT_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$TACT_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  else
    echo "已用「$SIGNER」签名，但没有设置 TACT_NOTARY_PROFILE，DMG 没有公证。"
  fi
  ;;
*)
  cat <<MSG
注意：应用不是用 Developer ID 签名的（${SIGNER:-临时签名}）。下载的人第一次打开会被拦下，
要到「系统设置 → 隐私与安全性」点「仍要打开」；每次更新版本都要重新授予辅助功能和屏幕录制权限。
发布给别人用的版本建议用临时签名打包，不要带上本机证书：TACT_SIGN_IDENTITY=- scripts/build-app.sh
MSG
  ;;
esac

printf '\n完成：%s（%s）\nSHA-256：%s\n' "$DMG" "$(du -h "$DMG" | cut -f1)" "$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
