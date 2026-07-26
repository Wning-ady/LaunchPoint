import AppKit
import Foundation

// MARK: - 持久化模型(参照 LaunchOS 的三实体设计,见 docs/launchos-research.md)

/// 应用记录:属于某个组(页面或文件夹),组内有序。
struct AppRecord: Codable {
    var id: String            // 应用完整路径,亦作唯一标识
    var bundleID: String?
    var name: String          // 默认显示名
    var alias: String?        // 用户自定义别名(重命名功能)
    var hidden: Bool
    var groupID: String       // 所属组
    var order: Int            // 组内顺序
}

/// 组:页面与文件夹的统一抽象(LaunchOS 的关键设计)。
struct GroupRecord: Codable {
    var id: String
    var isFolder: Bool        // false = 页面,true = 文件夹
    var name: String?         // 文件夹名(页面为 nil)
    var page: Int             // 页面自身页码;文件夹 = 所在页码
    var order: Int            // 文件夹在页内的槽位(页面 = 页码)
}

/// 应用来源目录(支持后续扩展外置硬盘、自定义目录)。
struct SourceRecord: Codable {
    var path: String
    var enabled: Bool
}

struct Layout: Codable {
    var version: Int
    var groups: [GroupRecord]
    var apps: [AppRecord]
    var sources: [SourceRecord]

    static func initial() -> Layout {
        Layout(version: 1,
               groups: [GroupRecord(id: "page-0", isFolder: false, name: nil, page: 0, order: 0)],
               apps: [],
               sources: AppScanner.defaultSearchDirs.map { SourceRecord(path: $0, enabled: true) })
    }
}

// MARK: - 存取与对账

/// 布局仓库:磁盘扫描结果与持久化布局的对账中心。
/// 保证:已有应用保持自定义顺序,新装的追加到末尾,卸载的自动移除。
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()

    /// 展示用列表:已按布局排序、剔除隐藏、附加别名。
    @Published private(set) var items: [AppItem] = []

    private var layout: Layout

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("LaunchpadClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(Layout.self, from: data) {
            layout = decoded
        } else {
            layout = .initial()
        }
    }

    /// 扫描磁盘并与已存布局对账,然后刷新展示列表并落盘。
    func refresh() {
        let sources = layout.sources.filter(\.enabled).map(\.path)
        let scanned = AppScanner.scan(sources: sources)
        let byPath = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

        // 1. 移除已卸载的应用
        layout.apps.removeAll { byPath[$0.id] == nil }

        // 2. 新安装的应用追加到最后一页队尾(首次运行 = 全部按扫描的字母序录入)
        let known = Set(layout.apps.map(\.id))
        if let lastPage = layout.groups.filter({ !$0.isFolder }).max(by: { $0.page < $1.page }) {
            var nextOrder = (layout.apps.filter { $0.groupID == lastPage.id }
                                        .map(\.order).max() ?? -1) + 1
            for item in scanned where !known.contains(item.id) {
                layout.apps.append(AppRecord(id: item.id,
                                             bundleID: item.bundleID,
                                             name: item.name,
                                             alias: nil,
                                             hidden: false,
                                             groupID: lastPage.id,
                                             order: nextOrder))
                nextOrder += 1
            }
        }

        // 3. 生成展示列表:按 (组页码, 组槽位, 组内顺序) 排列,剔除隐藏
        let position = Dictionary(uniqueKeysWithValues: layout.groups.map { ($0.id, ($0.page, $0.order)) })
        items = layout.apps
            .filter { !$0.hidden }
            .sorted { a, b in
                let ga = position[a.groupID] ?? (0, 0)
                let gb = position[b.groupID] ?? (0, 0)
                if ga != gb { return ga < gb }
                return a.order < b.order
            }
            .compactMap { record in
                guard var item = byPath[record.id] else { return nil }
                item.alias = record.alias
                return item
            }

        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(layout).write(to: Self.fileURL, options: .atomic)
    }
}
