#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/../SeafileDock.app"
MACOS="$APP/Contents/MacOS"
BIN="$MACOS/SeafileDock"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc -O -parse-as-library -swift-version 5 \
    -target arm64-apple-macosx13.0 \
    -o "$BIN" \
    "$ROOT"/src/AppMain.swift \
    "$ROOT"/src/Config.swift \
    "$ROOT"/src/SeafileAPI.swift \
    "$ROOT"/src/Store.swift \
    "$ROOT"/src/WidgetView.swift

echo "==> 组装 app bundle"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP"

echo "==> 完成: $APP"
codesign -dv "$APP" 2>&1 | head -6
