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

    /// 网格容量(后续做成设置项,参照 LaunchOS 的 columns/rows)。
    static let columns = 7
    static let rows = 5
    static var capacity: Int { columns * rows }

    /// 展示用扁平列表(搜索用):已按布局排序、剔除隐藏、附加别名。
    @Published private(set) var items: [AppItem] = []
    /// 分页展示列表:每页最多 capacity 个。
    @Published private(set) var pages: [[AppItem]] = []

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

    /// 上次扫描结果(路径 → AppItem),供不重扫磁盘的快速重建(如拖拽移动)使用。
    private var scannedByPath: [String: AppItem] = [:]

    /// 扫描磁盘并与已存布局对账,然后刷新展示列表并落盘。
    func refresh() {
        let sources = layout.sources.filter(\.enabled).map(\.path)
        let scanned = AppScanner.scan(sources: sources)
        let byPath = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        scannedByPath = byPath

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

        // 3. 容量归一:超出每页容量的应用向后页溢出(只向前溢、不回填,保护空间记忆)
        normalizeCapacity()
        pruneTrailingEmptyPageGroups()

        // 4. 生成分页展示列表并落盘
        rebuildPages()
        save()
    }

    /// 把应用移动到指定 (页, 槽位)。slot 为"移除被拖应用后"目标页内的插入位置。
    /// toPage 超出现有页数时自动创建承接新页。移动后归一容量、重建展示并落盘。
    func moveApp(_ appID: String, toPage: Int, slot: Int) {
        guard let (newApps, newGroups) = Self.applyMove(apps: layout.apps,
                                                        groups: layout.groups,
                                                        appID: appID,
                                                        toPage: toPage,
                                                        slot: slot) else { return }
        layout.apps = newApps
        layout.groups = newGroups
        commitMutation()
    }

    /// 删除持久层中"尾部"的空页组(中间空页保留,尊重用户留白)。
    /// 不清理会导致幻影远页:新装应用会被追加到 max(page) 的空组,凭空多出空白页。
    private func pruneTrailingEmptyPageGroups() {
        var pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        while pageGroups.count > 1 {
            guard let last = pageGroups.last,
                  !layout.apps.contains(where: { $0.groupID == last.id }) else { break }
            layout.groups.removeAll { $0.id == last.id }
            pageGroups.removeLast()
        }
    }

    // MARK: - 文件夹操作

    /// 把 source 应用拖到 target 应用上 → 创建文件夹容纳两者。
    /// 文件夹占据 target 原来的槽位;返回新文件夹 id,失败返回 nil。
    @discardableResult
    func createFolder(dragging sourceID: String, onto targetID: String, name: String) -> String? {
        guard let (apps, groups, folderID) = Self.applyCreateFolder(
            apps: layout.apps, groups: layout.groups,
            sourceID: sourceID, targetID: targetID, name: name) else { return nil }
        layout.apps = apps
        layout.groups = groups
        commitMutation()
        return folderID
    }

    /// 把应用放入已有文件夹(拖到文件夹上,或右键"移动到")。
    func addToFolder(_ appID: String, folderID: String) {
        guard let (apps, groups) = Self.applyAddToFolder(
            apps: layout.apps, groups: layout.groups,
            appID: appID, folderID: folderID) else { return }
        layout.apps = apps
        layout.groups = groups
        commitMutation()
    }

    /// 重命名文件夹。
    func renameFolder(_ folderID: String, to name: String) {
        guard let idx = layout.groups.firstIndex(where: { $0.id == folderID && $0.isFolder })
        else { return }
        layout.groups[idx].name = name
        commitMutation()
    }

    /// 解散文件夹:成员回到文件夹所在页、原槽位附近。
    func dissolveFolder(_ folderID: String) {
        guard let (apps, groups) = Self.applyDissolveFolder(
            apps: layout.apps, groups: layout.groups, folderID: folderID) else { return }
        layout.apps = apps
        layout.groups = groups
        commitMutation()
    }

    /// 文件夹内容(按 order,含隐藏过滤)。非文件夹 id 返回空。
    func folderItems(_ folderID: String) -> [AppItem] {
        guard layout.groups.contains(where: { $0.id == folderID && $0.isFolder }) else { return [] }
        return layout.apps
            .filter { $0.groupID == folderID && !$0.hidden }
            .sorted { $0.order < $1.order }
            .compactMap { record -> AppItem? in
                guard var item = scannedByPath[record.id] else { return nil }
                item.alias = record.alias
                return item
            }
    }

    /// 归一 + 修剪 + 自动解散单应用文件夹 + 重建 + 落盘(所有变更操作的统一收尾)。
    private func commitMutation() {
        autoDissolveSingletonFolders()
        normalizeCapacity()
        pruneTrailingEmptyPageGroups()
        rebuildPages()
        save()
    }

    /// 文件夹仅剩一个(或零个)应用时自动解散(还原原生行为)。
    private func autoDissolveSingletonFolders() {
        for folder in layout.groups where folder.isFolder {
            let memberCount = layout.apps.filter { $0.groupID == folder.id }.count
            if memberCount <= 1,
               let (apps, groups) = Self.applyDissolveFolder(apps: layout.apps,
                                                             groups: layout.groups,
                                                             folderID: folder.id) {
                layout.apps = apps
                layout.groups = groups
            }
        }
    }

    /// 纯函数:创建文件夹。文件夹作为组占据 target 在页内的槽位(order 继承 target)。
    static func applyCreateFolder(apps: [AppRecord], groups: [GroupRecord],
                                  sourceID: String, targetID: String, name: String)
        -> (apps: [AppRecord], groups: [GroupRecord], folderID: String)? {
        var apps = apps
        var groups = groups
        guard sourceID != targetID,
              let sourceIdx = apps.firstIndex(where: { $0.id == sourceID }),
              let targetIdx = apps.firstIndex(where: { $0.id == targetID }) else { return nil }
        // target 必须在页面上(不能在别的文件夹里再嵌套建夹)
        guard let hostPage = groups.first(where: { $0.id == apps[targetIdx].groupID && !$0.isFolder })
        else { return nil }

        let folderID = "folder-" + UUID().uuidString
        let folder = GroupRecord(id: folderID, isFolder: true, name: name,
                                 page: hostPage.page, order: apps[targetIdx].order)
        groups.append(folder)

        let sourceGroupID = apps[sourceIdx].groupID
        apps[targetIdx].groupID = folderID
        apps[targetIdx].order = 0
        apps[sourceIdx].groupID = folderID
        apps[sourceIdx].order = 1

        compactOrders(&apps, groupID: hostPage.id)
        if sourceGroupID != hostPage.id {
            compactOrders(&apps, groupID: sourceGroupID)
        }
        return (apps, groups, folderID)
    }

    /// 纯函数:应用入夹(追加到文件夹末尾)。
    static func applyAddToFolder(apps: [AppRecord], groups: [GroupRecord],
                                 appID: String, folderID: String)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        var apps = apps
        guard groups.contains(where: { $0.id == folderID && $0.isFolder }),
              let idx = apps.firstIndex(where: { $0.id == appID }),
              apps[idx].groupID != folderID else { return nil }

        let sourceGroupID = apps[idx].groupID
        let nextOrder = (apps.filter { $0.groupID == folderID }.map(\.order).max() ?? -1) + 1
        apps[idx].groupID = folderID
        apps[idx].order = nextOrder
        compactOrders(&apps, groupID: sourceGroupID)
        return (apps, groups)
    }

    /// 纯函数:解散文件夹,成员插回文件夹所在页的原槽位处(保持相对顺序)。
    static func applyDissolveFolder(apps: [AppRecord], groups: [GroupRecord],
                                    folderID: String)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        var apps = apps
        var groups = groups
        guard let folder = groups.first(where: { $0.id == folderID && $0.isFolder }),
              let hostPage = groups.first(where: { !$0.isFolder && $0.page == folder.page })
        else { return nil }

        let members = apps.indices
            .filter { apps[$0].groupID == folderID }
            .sorted { apps[$0].order < apps[$1].order }

        // 宿主页成员按 order 排队,文件夹槽位处依次插入成员
        let pageMembers = apps.indices
            .filter { apps[$0].groupID == hostPage.id }
            .sorted { apps[$0].order < apps[$1].order }
        var finalOrder: [Int] = []
        var inserted = false
        for idx in pageMembers {
            if !inserted && apps[idx].order >= folder.order {
                finalOrder.append(contentsOf: members)
                inserted = true
            }
            finalOrder.append(idx)
        }
        if !inserted { finalOrder.append(contentsOf: members) }

        for (order, idx) in finalOrder.enumerated() {
            apps[idx].groupID = hostPage.id
            apps[idx].order = order
        }
        groups.removeAll { $0.id == folderID }
        return (apps, groups)
    }

    /// 组内 order 压实为 0..n。
    private static func compactOrders(_ apps: inout [AppRecord], groupID: String) {
        let indices = apps.indices
            .filter { apps[$0].groupID == groupID }
            .sorted { apps[$0].order < apps[$1].order }
        for (order, idx) in indices.enumerated() {
            apps[idx].order = order
        }
    }

    /// 纯函数版移动逻辑,便于独立测试。找不到应用时返回 nil。
    static func applyMove(apps: [AppRecord], groups: [GroupRecord],
                          appID: String, toPage: Int, slot: Int)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        var apps = apps
        var groups = groups
        guard let recordIndex = apps.firstIndex(where: { $0.id == appID }) else { return nil }

        var pageGroups = groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        guard !pageGroups.isEmpty, toPage >= 0 else { return nil }

        // 拖到最后一页之后:自动创建承接新页
        while toPage >= pageGroups.count {
            let nextPage = (pageGroups.map(\.page).max() ?? -1) + 1
            let newGroup = GroupRecord(id: "page-\(nextPage)", isFolder: false,
                                       name: nil, page: nextPage, order: nextPage)
            groups.append(newGroup)
            pageGroups.append(newGroup)
        }

        let target = pageGroups[toPage]
        let sourceGroupID = apps[recordIndex].groupID

        // 目标页现有成员(不含被拖应用),按 order 排列。
        // UI 传入的 slot 是"可见序"槽位:映射为全记录插入点,隐藏记录保持相对位置。
        let targetIndices = apps.indices
            .filter { apps[$0].groupID == target.id && $0 != recordIndex }
            .sorted { apps[$0].order < apps[$1].order }
        let visiblePositions = targetIndices.enumerated()
            .filter { !apps[$0.element].hidden }
            .map(\.offset)
        let visibleSlot = min(max(slot, 0), visiblePositions.count)
        let insertAt = visibleSlot < visiblePositions.count
            ? visiblePositions[visibleSlot]
            : targetIndices.count

        var finalOrder: [Int] = []
        for (i, idx) in targetIndices.enumerated() {
            if i == insertAt { finalOrder.append(recordIndex) }
            finalOrder.append(idx)
        }
        if finalOrder.count == targetIndices.count { finalOrder.append(recordIndex) }
        for (order, idx) in finalOrder.enumerated() {
            apps[idx].order = order
        }
        apps[recordIndex].groupID = target.id

        // 源页压实(跨页移动时)
        if sourceGroupID != target.id {
            let sourceIndices = apps.indices
                .filter { apps[$0].groupID == sourceGroupID }
                .sorted { apps[$0].order < apps[$1].order }
            for (i, idx) in sourceIndices.enumerated() {
                apps[idx].order = i
            }
        }
        return (apps, groups)
    }

    /// 从当前 layout + 上次扫描结果重建分页展示列表(不重扫磁盘、不落盘)。
    private func rebuildPages() {
        let pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        pages = pageGroups.map { pg in
            layout.apps
                .filter { $0.groupID == pg.id && !$0.hidden }
                .sorted { $0.order < $1.order }
                .compactMap { record -> AppItem? in
                    guard var item = scannedByPath[record.id] else { return nil }
                    item.alias = record.alias
                    return item
                }
        }
        // 去掉尾部空页(中间的空页保留,尊重用户留白)
        while pages.count > 1, pages.last?.isEmpty == true {
            pages.removeLast()
        }
        // items 含文件夹内的应用:搜索必须能找到收纳起来的应用
        let folderIDs = Set(layout.groups.filter(\.isFolder).map(\.id))
        let folderMembers = layout.apps
            .filter { folderIDs.contains($0.groupID) && !$0.hidden }
            .sorted { $0.order < $1.order }
            .compactMap { record -> AppItem? in
                guard var item = scannedByPath[record.id] else { return nil }
                item.alias = record.alias
                return item
            }
        items = pages.flatMap { $0 } + folderMembers
    }

    /// 每页最多 capacity 个;超出的按序搬到下一页开头,必要时自动建新页。
    private func normalizeCapacity() {
        var pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        guard !pageGroups.isEmpty else { return }

        var i = 0
        while i < pageGroups.count {
            let pg = pageGroups[i]
            let inPage = layout.apps.indices
                .filter { layout.apps[$0].groupID == pg.id }
                .sorted { layout.apps[$0].order < layout.apps[$1].order }

            if inPage.count > Self.capacity {
                let overflow = Array(inPage[Self.capacity...])

                // 找或建下一页
                let next: GroupRecord
                if i + 1 < pageGroups.count {
                    next = pageGroups[i + 1]
                } else {
                    next = GroupRecord(id: "page-\(pg.page + 1)", isFolder: false,
                                       name: nil, page: pg.page + 1, order: pg.page + 1)
                    layout.groups.append(next)
                    pageGroups.append(next)
                }

                // 下一页原有内容整体后移,溢出的插到开头(保持相对顺序)
                let shift = overflow.count
                for idx in layout.apps.indices where layout.apps[idx].groupID == next.id {
                    layout.apps[idx].order += shift
                }
                for (offset, idx) in overflow.enumerated() {
                    layout.apps[idx].groupID = next.id
                    layout.apps[idx].order = offset
                }
            }
            i += 1
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(layout).write(to: Self.fileURL, options: .atomic)
    }
}
