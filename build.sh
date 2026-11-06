#!/bin/bash
# Build the Apple Silicon LaunchPoint app and DMG without SwiftPM.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="0.1.6"
BUILD="6"
MINIMUM_MACOS="14.0"
APP_NAME="LaunchPoint"
DIST_DIR="$PWD/dist"
STAGING_ROOT="$PWD/.dmg-staging"
ARCHITECTURES=("arm64")

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

# SwiftUI 的 @State 等属性包装器依赖 SwiftUIMacros 插件，该插件只随 Xcode 提供。
# 只安装 Command Line Tools 时编译会抛出一大堆宏展开错误，这里提前给出可执行的提示。
require_swiftui_macro_plugin() {
  local probe_dir
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/launchpoint-probe.XXXXXX")"
  cat > "$probe_dir/Probe.swift" <<'SWIFT'
import SwiftUI

struct Probe: View {
    @State private var value = 0
    var body: some View { Text("\(value)") }
}
SWIFT

  if ! xcrun swiftc -typecheck "$probe_dir/Probe.swift" > /dev/null 2>&1; then
    echo "无法编译 SwiftUI 代码：当前工具链缺少 SwiftUIMacros 插件。" >&2
    echo "当前 xcode-select 路径：$(xcode-select -p)" >&2
    echo "请安装 Xcode 后执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    rm -rf "$probe_dir"
    exit 1
  fi
  rm -rf "$probe_dir"
}

write_info_plist() {
  local app_dir="$1"
  local arch="$2"

  cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundleExecutable</key><string>${APP_NAME}</string>
<key>CFBundleIdentifier</key><string>com.waning.launchpoint</string>
<key>CFBundleName</key><string>${APP_NAME}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>LaunchPointReleaseVersion</key><string>${VERSION}</string>
<key>LSArchitecturePriority</key><array><string>${arch}</string></array>
<key>LSMinimumSystemVersion</key><string>${MINIMUM_MACOS}</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
}

build_architecture() {
  local arch="$1"
  local app_dir="$DIST_DIR/${APP_NAME}-${arch}.app"
  local staging_dir="$STAGING_ROOT/$arch"
  local dmg="$DIST_DIR/${APP_NAME}-v${VERSION}-${arch}.dmg"

  echo "Building ${APP_NAME} for ${arch}..."
  mkdir -p \
    "$app_dir/Contents/MacOS" \
    "$app_dir/Contents/Resources" \
    "$staging_dir"

  xcrun swiftc -O -target "${arch}-apple-macosx${MINIMUM_MACOS}" \
    Sources/LaunchPoint/*.swift \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework ServiceManagement \
    -o "$app_dir/Contents/MacOS/$APP_NAME"

  write_info_plist "$app_dir" "$arch"
  cp "$PWD/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
  chmod +x "$app_dir/Contents/MacOS/$APP_NAME"

  # Sign the completed bundle so the executable, plist, and resources are sealed together.
  codesign --force --deep --sign - "$app_dir"

  # Keep a friendly app name inside the disk image while the dist bundle remains
  # architecture-qualified for release automation.
  cp -R "$app_dir" "$staging_dir/$APP_NAME.app"
  ln -s /Applications "$staging_dir/Applications"
  hdiutil create \
    -volname "$APP_NAME $VERSION $arch" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg" >/dev/null

  echo "App: $app_dir"
  echo "DMG: $dmg"
}

require_swiftui_macro_plugin

rm -rf "$DIST_DIR" "$STAGING_ROOT"
mkdir -p "$DIST_DIR" "$STAGING_ROOT"

for arch in "${ARCHITECTURES[@]}"; do
  build_architecture "$arch"
done

echo "Apple Silicon build completed."
