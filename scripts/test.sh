#!/bin/sh
# Runs every test suite: Go engine, Telegram plugin, Swift app. Keeps going
# after a failing suite so the summary shows all of them.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
status=0

echo "→ Go 引擎"
(cd "$ROOT/engine" && go vet ./... && go test -race ./...) || status=1

echo "→ Telegram 插件"
(cd "$ROOT/plugins/telegram" && GOTOOLCHAIN=local go vet ./... && GOTOOLCHAIN=local go test -race ./...) || status=1

echo "→ Swift 应用"
# With only the Command Line Tools installed, swift-testing lives outside the
# default search paths.
CLT=/Library/Developer/CommandLineTools/Library/Developer
set --
if [ -d "$CLT/Frameworks/Testing.framework" ]; then
  set -- -Xswiftc -F -Xswiftc "$CLT/Frameworks" -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib"
fi
(cd "$ROOT/app" && swift test "$@") || status=1

if [ $status -eq 0 ]; then echo "全部通过"; else echo "有测试失败"; fi
exit $status
