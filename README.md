# Launchpad Clone

一个仿 LaunchOS / 原生启动台的 macOS 应用启动器,原生 Swift + SwiftUI 编写。

> 项目理念(与 LaunchOS 一致):不堆功能,专注打磨那些"消失时会立刻被察觉"的细节体验。

## 当前状态:v0.1 地基

- [x] 扫描系统与用户应用目录(`/Applications`、`/System/Applications`、`~/Applications` 等)
- [x] 全屏网格展示应用图标(自适应列数)
- [x] 实时搜索过滤(输入即搜)
- [x] 点击图标启动应用并隐藏窗口
- [x] 毛玻璃(ultraThinMaterial)背景

## 构建与运行

```bash
./build.sh
./launchpad
```

> 说明:本机 SwiftPM 清单库损坏,`build.sh` 直接用 `swiftc` 编译。
> 装完整版 Xcode 后可改用 `swift build`,或用 Xcode 打开 `Package.swift`。

## 路线图(按 LaunchOS 功能清单分阶段)

### 阶段 1 — 核心体验
- [ ] 全屏无边框窗口(真正的 Launchpad 式覆盖层)
- [ ] `Esc` 关闭 / 点击空白关闭
- [ ] 键盘导航(方向键高亮 + 回车打开)
- [ ] 搜索:拼音匹配、首字母匹配、缩写匹配

### 阶段 2 — 唤起方式
- [ ] 菜单栏图标唤起
- [ ] 自定义全局快捷键
- [ ] 接管 F4 键(需要辅助功能权限)
- [ ] 触发角唤起

### 阶段 3 — 分页与整理
- [ ] 横向分页 / 纵向滚动双模式
- [ ] 拖拽排序、拖拽跨页
- [ ] 文件夹(创建/合并/解散/重命名)
- [ ] 自定义排序模式持久化

### 阶段 4 — 深度打磨
- [ ] 触控板捏合手势唤起(跟手动画)
- [ ] 导入原生 Launchpad 布局
- [ ] 多显示器策略
- [ ] 布局备份与恢复
- [ ] 右键菜单(重命名/隐藏/在 Finder 显示/卸载)

## 项目结构

```
Sources/LaunchpadClone/
├── App.swift          # 应用入口与窗口配置
├── AppScanner.swift   # 扫描已安装应用
└── ContentView.swift  # 主界面:搜索框 + 图标网格
```
