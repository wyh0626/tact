#!/usr/bin/env bash
# Builds dist/Tact.app: the menu bar app with the engine and
# style template inside, signed with the local signing identity when there is
# one (see scripts/create-signing-identity.sh) and ad hoc otherwise.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/dist/Tact.app"
VERSION="${TACT_VERSION:-0.2.0}"
BUILD_NUMBER="${TACT_BUILD:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="io.github.wyh0626.tact"
# TACT_SIGN_IDENTITY names another certificate; "-" forces an ad hoc signature.
IDENTITY="${TACT_SIGN_IDENTITY:-Tact Local Signing}"
# Sparkle reads updates from the latest GitHub release and installs only an
# archive signed with the private half of this key, which stays in the
# keychain of whoever publishes (scripts/build-appcast.sh).
UPDATE_FEED="https://github.com/wyh0626/tact/releases/latest/download/appcast.xml"
UPDATE_KEY="vOkDbkYbnfymA98LtOqOgVVX80TdWLKv3V9O0CraRZM="

step() { printf '\n→ %s\n' "$1"; }
WORK="$(mktemp -d)"
INSTALL_STARTED=false
APP_REPLACED=false
STAGED_ENGINE=""
TELEGRAM_DEST="$REPO/dist/plugins/telegram"
TELEGRAM_ZIP_DEST="$REPO/dist/plugins/telegram.zip"
TELEGRAM_REPLACED=false
TELEGRAM_ZIP_REPLACED=false
cleanup() {
  if [ "$INSTALL_STARTED" = true ]; then
    if [ "$APP_REPLACED" = true ]; then rm -rf "$DEST"; fi
    if [ -e "$WORK/previous-app" ]; then mv "$WORK/previous-app" "$DEST"; fi
    if [ "$TELEGRAM_REPLACED" = true ]; then rm -rf "$TELEGRAM_DEST"; fi
    if [ -e "$WORK/previous-telegram" ]; then mv "$WORK/previous-telegram" "$TELEGRAM_DEST"; fi
    if [ "$TELEGRAM_ZIP_REPLACED" = true ]; then rm -f "$TELEGRAM_ZIP_DEST"; fi
    if [ -e "$WORK/previous-telegram-zip" ]; then mv "$WORK/previous-telegram-zip" "$TELEGRAM_ZIP_DEST"; fi
  fi
  if [ -n "$STAGED_ENGINE" ]; then rm -f "$STAGED_ENGINE"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
# Assembled and signed here, then moved into dist/ only once everything
# succeeded, so a failed build never leaves a broken app behind.
APP="$WORK/Tact.app"

command -v go >/dev/null || { echo "需要 Go：brew install go"; exit 1; }
command -v swift >/dev/null || { echo "需要 Swift：xcode-select --install"; exit 1; }

step "编译引擎"
(cd "$REPO/engine" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$WORK/tactd" ./cmd/tactd)

step "Telegram 插件"
# A release build passes Tact's own API application in TACT_TELEGRAM_APP_ID
# and TACT_TELEGRAM_APP_HASH, so people only scan a QR code; they never go
# into the source. Without them, sign-in asks for the developer's own.
TELEGRAM_FLAGS="-s -w"
if [ -n "${TACT_TELEGRAM_APP_ID:-}" ] && [ -n "${TACT_TELEGRAM_APP_HASH:-}" ]; then
  TELEGRAM_FLAGS="$TELEGRAM_FLAGS -X main.builtinAppID=$TACT_TELEGRAM_APP_ID -X main.builtinAppHash=$TACT_TELEGRAM_APP_HASH"
fi
mkdir -p "$WORK/telegram"
(cd "$REPO/plugins/telegram" && GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -ldflags "$TELEGRAM_FLAGS" \
  -o "$WORK/telegram/tact-telegram" .)
cp "$REPO/plugins/telegram/manifest.json" "$REPO/plugins/telegram/README.md" "$WORK/telegram/"

step "本机模型运行时"
"$REPO/scripts/build-llama.sh"

step "编译应用"
(cd "$REPO/app" && swift build -c release)
BIN_DIR="$(cd "$REPO/app" && swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Tact"
SPARKLE_LICENSE="$REPO/app/.build/artifacts/sparkle/Sparkle/LICENSE"

step "组装"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/PluginSDK/template"
cp "$BIN" "$APP/Contents/MacOS/Tact"
# The debug map names every source file by its path on this Mac; a
# shipped app has no use for it.
strip -S "$APP/Contents/MacOS/Tact"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Tact"
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Its XPC services are for sandboxed apps only; Tact isn't one.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
cp "$WORK/tactd" "$APP/Contents/MacOS/tactd"
cp "$REPO/engine/bin/llama-server" "$APP/Contents/MacOS/llama-server"
cp "$REPO/engine/bin/llama.cpp-LICENSE" "$APP/Contents/Resources/llama.cpp-LICENSE"
cp "$REPO/style.example.md" "$APP/Contents/Resources/style.example.md"
cp "$REPO/style.example.en.md" "$APP/Contents/Resources/style.example.en.md"
cp "$REPO"/assets/menubar/TactMenuBarTemplate*.png "$APP/Contents/Resources/"
cp "$REPO/docs/ADAPTER.md" "$APP/Contents/Resources/PluginSDK/ADAPTER.md"
cp "$REPO/plugins/template/manifest.json" "$REPO/plugins/template/adapter.py" "$REPO/plugins/template/README.md" "$APP/Contents/Resources/PluginSDK/template/"

step "生成图标"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --export-icon "$WORK/icon-1024.png" --artwork "$REPO/assets/tact-icon-1024.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Tact</string>
  <key>CFBundleDisplayName</key><string>Tact</string>
  <key>CFBundleExecutable</key><string>Tact</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Tact contributors</string>
  <key>SUFeedURL</key><string>$UPDATE_FEED</string>
  <key>SUPublicEDKey</key><string>$UPDATE_KEY</string>
</dict>
</plist>
EOF

step "签名"
# macOS ties Accessibility and Screen Recording grants to the signature. An ad
# hoc signature changes with every build, so permissions must be granted
# again after each rebuild; a fixed identity keeps them.
if [ "$IDENTITY" != "-" ] && security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
  echo "  用证书「${IDENTITY}」签名"
else
  SIGN="-"
  echo "  没找到证书「${IDENTITY}」，改用临时签名：每次重新编译后都要重新授权。"
  echo "  运行 scripts/create-signing-identity.sh 创建一个固定证书可以避免。"
fi
# Apple's notary service needs the hardened runtime and a secure timestamp;
# only a Developer ID certificate is notarized, so only it gets them.
SIGN_FLAGS=(--force --sign "$SIGN")
case "$SIGN" in "Developer ID Application:"*) SIGN_FLAGS+=(--options runtime --timestamp) ;; esac
# Sparkle's helpers first, then the framework around them, each on its own:
# --deep would sign them all alike.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if ! codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID.engine" "$APP/Contents/MacOS/tactd" ||
   ! codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID.telegram" "$WORK/telegram/tact-telegram" ||
   ! codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID.llama" "$APP/Contents/MacOS/llama-server" ||
   ! codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate" ||
   ! codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app" ||
   ! codesign "${SIGN_FLAGS[@]}" "$SPARKLE" ||
   ! codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID" "$APP"; then
  cat >&2 <<MSG

签名失败，dist/ 里原来的应用没有改动。
codesign 第一次使用钥匙串里的证书时，macOS 要弹窗请你允许；在后台运行时弹不出来就会失败
（errSecInternalComponent）。请在「终端」应用里运行这个脚本，弹窗时输入登录密码并点「始终允许」。
只想先用临时签名打包：TACT_SIGN_IDENTITY=- $0
MSG
  exit 1
fi
codesign --verify --strict --deep "$APP"

mkdir -p "$(dirname "$DEST")" "$(dirname "$TELEGRAM_DEST")" "$REPO/engine/bin"
# The Telegram plugin is a separate, opt-in package; it is never an app
# resource. Resource forks, extended attributes and ACLs stay out of it.
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noacl "$WORK/telegram" "$WORK/telegram.zip"
# Stage beside the development binary so the final rename is atomic. A
# failed compile/sign/package leaves the old app and development engine intact.
STAGED_ENGINE="$(mktemp "$REPO/engine/bin/.tactd.XXXXXX")"
cp "$APP/Contents/MacOS/tactd" "$STAGED_ENGINE"
chmod 755 "$STAGED_ENGINE"
INSTALL_STARTED=true
if [ -e "$DEST" ]; then mv "$DEST" "$WORK/previous-app"; fi
mv "$APP" "$DEST"
APP_REPLACED=true
if [ -e "$TELEGRAM_DEST" ]; then mv "$TELEGRAM_DEST" "$WORK/previous-telegram"; fi
mv "$WORK/telegram" "$TELEGRAM_DEST"
TELEGRAM_REPLACED=true
if [ -e "$TELEGRAM_ZIP_DEST" ]; then mv "$TELEGRAM_ZIP_DEST" "$WORK/previous-telegram-zip"; fi
mv "$WORK/telegram.zip" "$TELEGRAM_ZIP_DEST"
TELEGRAM_ZIP_REPLACED=true
mv -f "$STAGED_ENGINE" "$REPO/engine/bin/tactd"
STAGED_ENGINE=""
INSTALL_STARTED=false
printf '\n完成：%s\n启动：open "%s"\nTelegram 插件（实验性，需主动导入）：%s\n' "$DEST" "$DEST" "$TELEGRAM_DEST"
