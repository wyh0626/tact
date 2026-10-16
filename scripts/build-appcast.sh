#!/usr/bin/env bash
# Writes dist/appcast.xml for the DMG build-dmg.sh made: the feed Sparkle
# reads from the latest GitHub release, so every release uploads one. It
# names the version, where to download it, and the EdDSA signature made with
# the update key in this Mac's keychain (Sparkle's generate_keys). Markdown
# release notes, when given, show in the update window.
#   scripts/build-appcast.sh [release-notes.md]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/dist/Tact.app"
TOOLS="$REPO/app/.build/artifacts/sparkle/Sparkle/bin"
OUT="$REPO/dist/appcast.xml"
NOTES="${1:-}"
[ -x "$TOOLS/sign_update" ] || { echo "没找到 Sparkle 的工具，先运行 scripts/build-app.sh"; exit 1; }
[ -z "$NOTES" ] || [ -f "$NOTES" ] || { echo "没找到发布说明：$NOTES"; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MINIMUM="$(plist LSMinimumSystemVersion)"
FEED="$(plist SUFeedURL)"
PUBLIC_KEY="$(plist SUPublicEDKey)"
ARCH="$(lipo -archs "$APP/Contents/MacOS/Tact" | tr ' ' '-')"
DMG="$REPO/dist/Tact-$VERSION-$ARCH.dmg"
[ -f "$DMG" ] || { echo "没找到 ${DMG}，先运行 scripts/build-dmg.sh"; exit 1; }
# The feed is https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml.
RELEASES="${FEED%/latest/download/appcast.xml}"
[ "$RELEASES" != "$FEED" ] || { echo "SUFeedURL 不是 GitHub Release 的地址：$FEED"; exit 1; }

keychain_hint() {
  printf '%s\n' "$1" "Sparkle 的工具第一次读取钥匙串里的更新密钥时，macOS 要弹窗请你允许；在后台运行时弹不出来就会失败。" \
    "请在「终端」应用里运行 $0，弹窗时点「始终允许」。" >&2
  exit 1
}
# An update signed with any other key is refused by every installed copy.
KEYCHAIN_KEY="$("$TOOLS/generate_keys" -p)" || keychain_hint "读不到钥匙串里的更新密钥。"
[ "$KEYCHAIN_KEY" = "$PUBLIC_KEY" ] || { echo "钥匙串里的更新密钥和应用里的公钥（SUPublicEDKey）对不上，已安装的 Tact 会拒绝这个更新。"; exit 1; }
SIGNATURE="$("$TOOLS/sign_update" "$DMG")" || keychain_hint "签名更新包失败。"
[[ "$SIGNATURE" =~ ^sparkle:edSignature=\"[^\"]+\"\ length=\"[0-9]+\"$ ]] || { echo "sign_update 的输出看不懂：$SIGNATURE"; exit 1; }

DESCRIPTION=""
if [ -n "$NOTES" ]; then
  if grep -q ']]>' "$NOTES"; then echo "发布说明里不能有 ]]>"; exit 1; fi
  DESCRIPTION="      <description sparkle:format=\"markdown\"><![CDATA[
$(cat "$NOTES")
]]></description>"
fi
HARDWARE=""
[ "$ARCH" != "arm64" ] || HARDWARE="      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"

# Written from a variable, not a here-document: Homebrew's bash 5.3 passes a
# here-document through a pipe, and when macOS shrinks pipe buffers under load
# the write blocks for good.
FEED_XML="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">
  <channel>
    <title>Tact</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
$HARDWARE
      <sparkle:fullReleaseNotesLink>$RELEASES</sparkle:fullReleaseNotesLink>
$DESCRIPTION
      <enclosure url=\"$RELEASES/download/v$VERSION/$(basename "$DMG")\" $SIGNATURE type=\"application/octet-stream\"/>
    </item>
  </channel>
</rss>"
printf '%s\n' "$FEED_XML" > "$OUT"
xmllint --noout "$OUT"
printf '\n完成：%s（%s，build %s）\n和 DMG 一起上传到 GitHub Release v%s。\n' "$OUT" "$VERSION" "$BUILD" "$VERSION"
