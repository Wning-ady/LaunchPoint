#!/bin/bash
# 直接用 swiftc 编译（绕过本机损坏的 SwiftPM）。
# 装了完整版 Xcode 后，也可以改用: swift build / 用 Xcode 打开 Package.swift。
set -e
cd "$(dirname "$0")"
VERSION="0.13.0"
BUILD="1"
ARCH="arm64"
APP_NAME="LaunchpadClone"
APP_DIR="$PWD/dist/$APP_NAME.app"
DMG="$PWD/dist/${APP_NAME}-v${VERSION}-beta.1-${ARCH}.dmg"
STAGING="$PWD/.dmg-staging"

echo "编译中…"
rm -rf "$PWD/dist" "$STAGING"
mkdir -p "$PWD/dist" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$STAGING"
swiftc -O -target "$ARCH-apple-macosx14.0" Sources/LaunchpadClone/*.swift \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>LaunchpadClone</string>
<key>CFBundleExecutable</key><string>LaunchpadClone</string>
<key>CFBundleIdentifier</key><string>com.waning.launchpadclone</string>
<key>CFBundleName</key><string>LaunchpadClone</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "完成 → $APP_DIR"
echo "DMG → $DMG"
echo "运行: open '$APP_DIR'"
