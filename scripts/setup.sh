#!/usr/bin/env bash
# Builds the engine and the macOS app, and creates ~/.tact on first run.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/.tact"

step() { printf '\n→ %s\n' "$1"; }

command -v go >/dev/null || { echo "需要 Go 1.24+：brew install go"; exit 1; }
command -v swift >/dev/null || { echo "需要 Swift：xcode-select --install"; exit 1; }

step "准备 $STATE"
mkdir -p "$STATE"
chmod 700 "$STATE"
if [ -f "$STATE/config.json" ]; then
  echo "  已有 config.json，保持不动"
else
  # "|" is used as the sed delimiter because it is unlikely in a repo path.
  sed "s|__REPO__|$REPO|g" "$REPO/config.example.json" > "$STATE/config.json"
  chmod 600 "$STATE/config.json"
  echo "  已写入 config.json（未导入聊天工具插件）"
fi
if [ -f "$STATE/style.md" ]; then
  echo "  已有 style.md，保持不动"
else
  cp "$REPO/style.example.md" "$STATE/style.md"
  echo "  已写入 style.md"
fi

step "打包 macOS 应用"
"$REPO/scripts/build-app.sh"

cat <<EOF

完成。接下来：
  1. 打开应用，跟着引导授权、选模型：open "$REPO/dist/Tact.app"
  2. 想让权限在重新打包后保留，运行一次：$REPO/scripts/create-signing-identity.sh
  3. 在终端里查看平台注册（可选，不执行插件）：$REPO/engine/bin/tactd platforms
EOF
