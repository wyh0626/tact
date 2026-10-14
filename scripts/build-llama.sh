#!/usr/bin/env bash
# Builds llama-server, the runtime behind Tact's built-in local models, from a
# pinned llama.cpp release into engine/bin/. Metal shaders are compiled when
# the server starts, so the Command Line Tools are enough; no Xcode needed.
# The source is fetched once into .cache/ and checked against the pinned
# commit; a matching build is reused.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TAG="v0.6.0"
COMMIT="d81235049384534c167caea52b85a694f6103d14"
# Names the tag and the build options below; a change to either rebuilds.
BUILD_ID="$TAG static metal-embedded no-ssl prefix-map"
SRC="$REPO/.cache/llama.cpp-$TAG"
OUT="$REPO/engine/bin/llama-server"

if [ -x "$OUT" ] && [ "$(cat "$OUT.version" 2>/dev/null)" = "$BUILD_ID" ]; then
  echo "  llama-server $TAG 已编译，直接使用"
  exit 0
fi
command -v cmake >/dev/null || { echo "需要 cmake：brew install cmake"; exit 1; }
command -v git >/dev/null || { echo "需要 git：xcode-select --install"; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC.partial"
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC.partial"
  mv "$SRC.partial" "$SRC"
fi
actual="$(git -C "$SRC" rev-parse HEAD)"
if [ "$actual" != "$COMMIT" ]; then
  echo "llama.cpp $TAG 的提交是 $actual，和固定的 $COMMIT 不一致，停止编译" >&2
  exit 1
fi

# Static, so the app carries one self-contained binary; no native CPU tuning,
# so it runs on any Apple silicon Mac; no OpenSSL, which would tie it to a
# Homebrew install: it only ever serves plain HTTP on loopback, and Tact
# downloads the models itself.
# Source paths in asserts and logs name the checkout, not this Mac's folders.
PREFIX_MAP="-ffile-prefix-map=$SRC=llama.cpp"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP" -DCMAKE_OBJC_FLAGS="$PREFIX_MAP" \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON >/dev/null
cmake --build "$SRC/build" --target llama-server --config Release -j "$(sysctl -n hw.ncpu)" >/dev/null
mkdir -p "$(dirname "$OUT")"
cp "$SRC/build/bin/llama-server" "$OUT.partial"
mv "$OUT.partial" "$OUT"
echo "$BUILD_ID" > "$OUT.version"
# Only the system's frameworks and libraries: anything else would be missing
# on another Mac.
if otool -L "$OUT" | tail -n +2 | grep -v -E "^\s+(/System/Library/|/usr/lib/)"; then
  echo "llama-server 链接了系统以外的库，不能随应用分发" >&2
  rm -f "$OUT" "$OUT.version"
  exit 1
fi
cp "$SRC/LICENSE" "$REPO/engine/bin/llama.cpp-LICENSE"
echo "  已编译 llama-server $TAG"
