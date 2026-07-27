> **纯 AI 编写：LaunchPoint 的代码、界面、图标、文档与构建流程均由 AI 完整生成和实现。**

# LaunchPoint

LaunchPoint 是一款面向 macOS 的原生应用启动器，专注于快速唤起、流畅浏览、即时搜索与可持久化整理。

当前版本：`v0.13.0-beta.1`
系统要求：macOS 14 或更高版本
处理器：Apple Silicon `arm64` 或 Intel `x86_64`

[下载发行版](https://github.com/Wning-ady/LaunchPoint/releases) · [源代码](https://github.com/Wning-ady/LaunchPoint) · [问题反馈](https://github.com/Wning-ady/LaunchPoint/issues)

## 主要功能

- 全屏无边框应用网格，支持壁纸和系统毛玻璃背景。
- 横向分页与纵向连续滚动两种显示模式。
- 自适应行列、图标大小、横向间距和纵向间距。
- 图标与标签根据屏幕可用区域自动收敛，避免小屏幕越界。
- 应用名称、缩写和拼音即时搜索，并支持键盘导航。
- 鼠标、触控板、滚轮、方向键和页码圆点翻页。
- 应用拖拽排序、跨页移动、创建文件夹和文件夹改名。
- 应用隐藏、恢复、别名、简介、卸载和在 Finder 中显示。
- 空白区域右键菜单，以及应用和文件夹的独立右键菜单。
- 可移动设置面板，调整过程实时预览并防抖保存。
- 自定义全局快捷键、F4 开关、触发角和多显示器策略。
- 登录时启动、菜单栏入口、布局导入导出与应用来源管理。
- 应用内检查 GitHub Releases 更新，并自动匹配当前处理器的安装包。
- 后台扫描、图标缓存、搜索缓存和壁纸降采样。

## 视觉

LaunchPoint 使用统一的米白、炭黑和系统蓝配色。应用图标、设置面板、搜索框、选中状态和页码采用同一视觉语言，保持清晰、克制和易辨识。

## 安装

1. 按处理器下载 `LaunchPoint-v0.13.0-beta.1-arm64.dmg` 或 `LaunchPoint-v0.13.0-beta.1-x86_64.dmg`。
2. 打开镜像并将 `LaunchPoint.app` 拖入 `Applications`。
3. 首次启动时按照 macOS 提示确认打开。

当前测试包使用 ad-hoc 签名，尚未进行 Developer ID 签名和公证。

## 构建

```bash
./build.sh
```

构建产物：

```text
dist/LaunchPoint-arm64.app
dist/LaunchPoint-x86_64.app
dist/LaunchPoint-v0.13.0-beta.1-arm64.dmg
dist/LaunchPoint-v0.13.0-beta.1-x86_64.dmg
```

严格类型检查：

```bash
xcrun swiftc -warnings-as-errors -typecheck \
  Sources/LaunchPoint/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  -framework ServiceManagement
```

## 数据位置

布局数据保存在：

```text
~/Library/Application Support/LaunchPoint/layout.json
```

偏好设置使用 bundle identifier：

```text
com.waning.launchpoint
```

## 项目结构

```text
Sources/LaunchPoint/
├── AppTheme.swift       # 全局配色
├── AppScanner.swift     # 应用来源扫描
├── ContentView.swift    # 主界面与交互
├── KeyboardNav.swift    # 键盘导航
├── LayoutStore.swift    # 布局与持久化
├── SearchEngine.swift   # 搜索与排序
├── Settings.swift       # 设置界面与偏好
├── UpdateChecker.swift  # GitHub 发行版更新检测
└── main.swift           # 应用入口与系统集成

Resources/
├── AppIcon.svg
└── AppIcon.icns
```

## 开源

LaunchPoint 的源代码依据 [MIT License](LICENSE) 公开。欢迎通过 Issue 提交问题、建议和兼容性反馈。

## 当前限制

- 安装包尚未公证。
- 纵向滚动模式暂不支持图标拖拽重排。
- 多显示器、触控板惯性和大量应用场景仍在持续测试。
