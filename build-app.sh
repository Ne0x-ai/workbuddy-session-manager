#!/bin/bash
# 构建并打包成可直接双击运行的 .app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="WorkBuddy 会话管理"
BUNDLE="build/${APP_NAME}.app"
BINARY="WorkBuddySessionManager"

echo "▸ 编译 release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BINARY}"
[ -x "$BIN_PATH" ] || { echo "找不到可执行文件：$BIN_PATH"; exit 1; }

echo "▸ 组装 bundle"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "$BIN_PATH" "${BUNDLE}/Contents/MacOS/${BINARY}"

# 图标从 1024 母版现场生成，换设计稿后重跑本脚本即可
if [ -f Resources/AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "${BUNDLE}/Contents/Resources/AppIcon.icns"
fi

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>            <string>${BINARY}</string>
    <key>CFBundleIdentifier</key>            <string>dev.local.wb.sessionmanager</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "▸ 临时签名（允许本机运行）"
codesign --force --sign - --timestamp=none "$BUNDLE" 2>/dev/null \
  || echo "  签名跳过，不影响本机使用"

echo "✓ 完成：$BUNDLE"
echo "  运行：open \"$BUNDLE\""
