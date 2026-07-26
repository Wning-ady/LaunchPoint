# LaunchOS 2.2.0 实现调研

> 调研对象:本机安装的 LaunchOS Beta 2.2.0 (404),bundle ID `app.remixdesign.LaunchOS`。
> 方式:只观察公开可见的包结构、链接框架、偏好设置与数据库 schema,不反编译、不复制任何代码或素材。

## 一、总体架构

| 维度 | LaunchOS 的选择 | 我们的现状 |
|---|---|---|
| 应用形态 | `LSUIElement = true`(菜单栏应用,不占 Dock) | ✅ 相同(accessory 模式) |
| UI 框架 | AppKit + SwiftUI 混合 | ✅ 相同 |
| 全局快捷键 | Carbon API(sindresorhus/KeyboardShortcuts 库) | ✅ 相同(Carbon 直调) |
| 默认快捷键 | `⌥空格`(keyCode 49 + optionKey 2048) | ✅ 完全一致 |
| 布局存储 | CoreData → SQLite(`~/Library/Application Support/LaunchOS/LaunchOS.sqlite`) | 未做 |
| 自动更新 | Sparkle 框架 | 不需要 |
| 网络 | Alamofire(更新/检查) | 不需要 |
| 开机自启 | ServiceManagement 登录项 | 未做 |
| 沙盒 | ❌ 非沙盒(entitlements 为空)——纯净卸载等功能需要 | 一致(无沙盒) |
| 应用信息读取 | Finder automation(AppleEvents 权限) | 我们直接扫目录,更简单 |
| 本地化 | 20+ 种语言 `.lproj` | 未做 |
| 细节音效 | `MoveToTrash.aif`(卸载音效) | — |

**验证了我们的技术路线:菜单栏常驻 + Carbon 快捷键 + AppKit/SwiftUI 混合,和 LaunchOS 本尊完全一致,连默认快捷键都撞车了(⌥空格)。**

## 二、数据模型(SQLite schema,三张表)

### AppEntity(应用)
```
hidden      是否隐藏
order       组内排序
group       所属组(外键 → GroupEntity)
alias       用户自定义别名(重命名功能)
bundleID / bundleName / name / version / build
url         应用路径
id          唯一标识
```

### GroupEntity(组 = 页面 或 文件夹,统一抽象!)
```
isFolder    0 = 页面,1 = 文件夹
order       排序
page        所在页码
name        文件夹名
```
**关键设计:页面和文件夹是同一种实体。** 应用属于组,组要么是页要么是文件夹。这个抽象让"拖拽跨页""文件夹合并""解散回原位"都变成同一套 order/group 操作。

### SourceEntity(自定义应用来源目录)
```
enabled     是否启用
type        来源类型
path        目录路径
```
对应"扩展应用来源"功能(外置硬盘、自定义目录)。

## 三、设置项设计(defaults 键值,即功能开关清单)

```
AppIcon = 4              # 图标风格(九宫格/小火箭等多款)
BackgroundType = 0       # 背景模式(壁纸/玻璃)
GlassMaterial = 1        # 玻璃材质强度
DisplayMode = 0          # 全屏 / 小窗模式
ViewMode = 1             # 横向分页 / 纵向滚动
SortBy = 0               # 排序模式(自定义/名称/添加时间/最后打开)
columns = 10, rows = 7   # 网格行列数(用户可调)
EnableF4Shortcut = 1     # 接管 F4 键(独立开关)
KeyboardShortcuts_launchApp = {keyCode:49, mod:2048}  # ⌥空格
LaunchShowOn = 2         # 多显示器策略(主屏/活跃屏/鼠标所在屏)
LastHiddenTime           # 上次关闭时间(用于"延迟后回到主界面")
```

## 四、对我们路线图的启示

1. **布局持久化尽早做**:先定 `App / Group(页=文件夹) / Source` 三实体模型,后面所有拖拽、分页、文件夹功能都长在它上面。用 SQLite 或 JSON 均可,起步 JSON 更简单。
2. **行列数做成设置**(columns/rows),图标尺寸由可视区域反推 —— 而不是固定图标大小。
3. **F4 是独立开关**,和自定义快捷键并存,不互斥。
4. **`LastHiddenTime`** 是实现"自定义延迟后自动回主界面"的钥匙,记录关闭时间即可。
5. **多显示器策略只有三个选项**(主屏/活跃屏/鼠标屏),不用过度设计。
6. **别名(alias)存在 AppEntity 上**,搜索时"当前显示名/默认名/别名"三路匹配。

## 五、官方 v2 重构复盘的教训

> 来源:[LaunchOS V2 重构博客(中文)](https://launchosapp.com/blog/zh/launchos-v2-rebuild/)

**核心结论:LaunchOS v1 用 SwiftUI 做核心交互,v2 推倒重来把启动台核心体验下沉到了 AppKit。**

v1 遇到的 SwiftUI 瓶颈(恰好都在"跟手感"上):
- 页面拖拽/触控板滑动的跟手性、分页动画流畅性难以打磨
- 动画节奏不够可控;高频状态变化带来额外开销
- 内存与视图生命周期不可预测;老旧设备(Intel)上尤其吃力
- "开发一个功能不难,难的是让它在少数老旧设备上也足够流畅稳定"

v2 用 AppKit 的代价与收获:
- SwiftUI 几行代码的动画,AppKit 要几十行(起止时机、中间插值、用户打断恢复、拖拽防抖动)
- 换来:120Hz/240Hz 稳定帧率、更低运行开销、拖拽到 Dock 等 v1 难以实现的功能
- 反向妥协:macOS 26 新视觉(液态玻璃)优先给 SwiftUI,AppKit 侧只能"尽量接近"

### 对我们的启示

1. **不必现在就恐慌**:我们的规模(个人项目、现代 Mac)远没到 v1 的瓶颈,SwiftUI 开发速度优势更重要。
2. **但要留后路**——两条已就位的防线:
   - 数据层(LayoutStore)与 UI 完全解耦,换渲染层不动数据;
   - 外壳已是 AppKit(NSWindow/事件监听),SwiftUI 只是 contentView,可逐块替换。
3. **分页翻页是最高危区**:做横向分页时,若 SwiftUI 跟手感不达标,单独把"分页容器"换成 NSScrollView/CALayer 实现,其余保持 SwiftUI。
4. 优先级参考本尊:先把"跟手"做对(拖拽位移实时更新、按完成进度决定去留),再谈功能数量。
