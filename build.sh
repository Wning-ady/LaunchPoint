#!/bin/bash
# 直接用 swiftc 编译（绕过本机损坏的 SwiftPM）。
# 装了完整版 Xcode 后，也可以改用: swift build / 用 Xcode 打开 Package.swift。
set -e
cd "$(dirname "$0")"
echo "编译中…"
swiftc -O Sources/LaunchpadClone/*.swift -o launchpad
echo "完成 → ./launchpad"
echo "运行: ./launchpad"
