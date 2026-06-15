#!/bin/bash
# 编译并打包成 VoiceKey.app(菜单栏常驻 App)
set -e
cd "$(dirname "$0")"

echo "==> 编译 release..."
swift build -c release

APP="VoiceKey.app"
BIN=".build/release/VoiceKey"

echo "==> 组装 $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceKey"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> 代码签名(ad-hoc,带 entitlements)..."
codesign --force --deep --sign - \
  --entitlements VoiceKey.entitlements \
  "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"

echo "==> 完成:$(pwd)/$APP"
echo "    首次运行:open $APP  然后按住「右 Option」说话"
