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

# 用固定的开发者证书签名(Team ID 稳定),这样系统授权(辅助功能等)不会因每次重编译而失效。
# 没有该证书时回退到 ad-hoc(授权会每次失效)。
SIGN_ID="${VOICEKEY_SIGN_ID:-Apple Development: rgxinlin@163.com (KR8Y7J5UBL)}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "==> 代码签名(稳定证书:$SIGN_ID)..."
  codesign --force --deep --sign "$SIGN_ID" --entitlements VoiceKey.entitlements "$APP"
else
  echo "==> ⚠️ 未找到固定证书,回退 ad-hoc(授权会每次失效)..."
  codesign --force --deep --sign - --entitlements VoiceKey.entitlements "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"
fi

echo "==> 完成:$(pwd)/$APP"
codesign -dvv "$APP" 2>&1 | grep -E "TeamIdentifier|Authority=Apple" | head -2
