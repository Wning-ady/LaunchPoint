import AppKit
import Foundation

// MARK: - 持久化模型

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

/// 组:页面与文件夹的统一抽象。
/// 文件夹通过 page + order 占据某页的一个槽位,与应用共享同一 order 序列。
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
    var customApps: [String]

    private enum CodingKeys: String, CodingKey {
        case version, groups, apps, sources, customApps
    }

    init(version: Int, groups: [GroupRecord], apps: [AppRecord],
         sources: [SourceRecord], customApps: [String] = []) {
        self.version = version
        self.groups = groups
        self.apps = apps
        self.sources = sources
        self.customApps = customApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        groups = try container.decode([GroupRecord].self, forKey: .groups)
        apps = try container.decode([AppRecord].self, forKey: .apps)
        sources = try container.decodeIfPresent([SourceRecord].self, forKey: .sources)
            ?? AppScanner.defaultSearchDirs.map { SourceRecord(path: $0, enabled: true) }
        customApps = try container.decodeIfPresent([String].self, forKey: .customApps) ?? []
    }

    static func initial() -> Layout {
        Layout(version: 1,
               groups: [GroupRecord(id: "page-0", isFolder: false, name: nil, page: 0, order: 0)],
               apps: [],
               sources: AppScanner.defaultSearchDirs.map { SourceRecord(path: $0, enabled: true) },
               customApps: [])
    }
}

enum LayoutBackupError: LocalizedError {
    case unsupportedVersion(Int)
    case missingPage

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "不支持的布局备份版本（\(version)）。"
        case .missingPage: return "布局备份缺少页面数据。"
        }
    }
}

// MARK: - 展示模型

/// 文件夹图块信息。
struct FolderInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let preview: [AppItem]    // 封面小图标(最多 4 个)
    let count: Int

    static func == (lhs: FolderInfo, rhs: FolderInfo) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.count == rhs.count
            && lhs.preview.map(\.id) == rhs.preview.map(\.id)
    }
}

/// 页面上的一个条目:应用或文件夹图块。
enum PageEntry: Identifiable {
    case app(AppItem)
    case folder(FolderInfo)

    var id: String {
        switch self {
        case .app(let a): return a.id
        case .folder(let f): return f.id
        }
    }
}

// MARK: - 存取与对账

/// 布局仓库:磁盘扫描结果与持久化布局的对账中心。
/// 保证:已有条目保持自定义顺序,新装的追加到末尾,卸载的自动移除。
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()

    /// 网格容量(设置面板可调;启动时由 Settings 注入,避免此处依赖设置层)。
    static var columns = 7
    static var rows = 5
    static var capacity: Int { columns * rows }

    /// 展示用扁平应用列表(搜索用,含文件夹内应用)。
    @Published private(set) var items: [AppItem] = []
    /// 分页展示列表:应用与文件夹图块混排,每页最多 capacity 个条目。
    @Published private(set) var pages: [[PageEntry]] = []
    /// 应用目录正在后台扫描。旧页面会继续显示，只用轻量状态给用户反馈。
    @Published private(set) var isRefreshing = false

    private var layout: Layout

    /// 上次扫描结果(路径 → AppItem),供不重扫磁盘的快速重建(如拖拽移动)使用。
    private var scannedByPath: [String: AppItem] = [:]
    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var refreshRequest: ScanRequest?
    private var pendingRefresh: (generation: Int, request: ScanRequest)?
    private var pendingSave: DispatchWorkItem?
    private let scanQueue = DispatchQueue(label: "LaunchPoint.application-scan",
                                          qos: .userInitiated)

    private struct ScanRequest: Equatable {
        let sources: [String]
        let customApps: [String]
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("LaunchPoint", isDirectory: true)
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
        refreshAsync()
    }

    /// 后台扫描应用目录，避免启动台首次出现时阻塞主线程。
    func refreshAsync() {
        let request = ScanRequest(sources: layout.sources.filter(\.enabled).map(\.path),
                                  customApps: layout.customApps)

        // 多个唤起通知可能在数百毫秒内连续到达。同一来源扫描正在进行时
        // 直接复用它，来源变更则只保留最后一次请求，避免并发解码全部应用图标。
        if refreshInFlight {
            guard request != refreshRequest else { return }
            refreshGeneration &+= 1
            pendingRefresh = (refreshGeneration, request)
            isRefreshing = true
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        startAsyncRefresh(generation: generation, request: request)
    }

    private func startAsyncRefresh(generation: Int, request: ScanRequest) {
        refreshInFlight = true
        refreshRequest = request
        isRefreshing = true
        scanQueue.async { [weak self] in
            let scanned = AppScanner.scan(sources: request.sources,
                                          customPaths: request.customApps)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.refreshGeneration == generation {
                    // 扫描目录暂时不可读时保留旧布局，避免权限或磁盘短暂异常
                    // 把整个启动台错误清空。
                    let hasExistingApps = !self.layout.apps.isEmpty
                    if !scanned.isEmpty || !hasExistingApps {
                        self.reconcile(scanned)
                    }
                }
                self.refreshInFlight = false
                self.refreshRequest = nil
                if let pending = self.pendingRefresh {
                    self.pendingRefresh = nil
                    self.startAsyncRefresh(generation: pending.generation,
                                           request: pending.request)
                } else {
                    self.isRefreshing = false
                }
            }
        }
    }

    private func reconcile(_ scanned: [AppItem]) {
        let byPath = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        scannedByPath = byPath

        // 1. 移除已卸载的应用
        let manualIDs = Set(layout.customApps)
        layout.apps.removeAll { byPath[$0.id] == nil && !manualIDs.contains($0.id) }

        // 1.5. Refresh metadata for already-known apps. Aliases remain intact,
        // while default names can follow the current system language.
        for index in layout.apps.indices {
            guard let item = byPath[layout.apps[index].id] else { continue }
            layout.apps[index].name = item.name
            layout.apps[index].bundleID = item.bundleID
        }

        // 2. 新安装的应用追加到最后一页队尾(首次运行 = 全部按扫描的字母序录入)
        let known = Set(layout.apps.map(\.id))
        if let lastPage = layout.groups.filter({ !$0.isFolder }).max(by: { $0.page < $1.page }) {
            var nextOrder = (Self.entityList(apps: layout.apps, groups: layout.groups,
                                             pageID: lastPage.id, page: lastPage.page)
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

        commitMutation()
    }

    // MARK: - 拖拽移动

    /// 把条目(应用或文件夹图块)移动到指定 (页, 槽位)。
    /// slot 为"移除被拖条目后"目标页内可见条目的插入位置;toPage 越界时自动创建承接新页。
    func moveEntry(_ entryID: String, toPage: Int, slot: Int) {
        guard let (newApps, newGroups) = Self.applyMoveEntity(apps: layout.apps,
                                                              groups: layout.groups,
                                                              entityID: entryID,
                                                              toPage: toPage,
                                                              slot: slot) else { return }
        layout.apps = newApps
        layout.groups = newGroups
        commitMutation()
    }

    /// Move an entry immediately before or after a visible target. Resolving the
    /// target directly in the persisted entity list keeps the visible marker and
    /// committed anchor identical even when a saved app is temporarily unscannable.
    func moveEntry(_ entryID: String, relativeTo targetID: String, after: Bool) {
        guard let (newApps, newGroups) = Self.applyMoveEntity(apps: layout.apps,
                                                              groups: layout.groups,
                                                              entityID: entryID,
                                                              relativeTo: targetID,
                                                              after: after) else { return }
        layout.apps = newApps
        layout.groups = newGroups
        commitMutation()
    }

    /// 将持久化布局对齐到拖拽预览中的可见顺序。
    /// 预览基于可见条目构建，直接使用相邻条目作为锚点可以避免隐藏项或
    /// 空页面导致“动画落点”和松手后的最终位置出现偏移。
    func moveEntryToMatchPreview(_ entryID: String, preview: [[PageEntry]]) {
        for page in preview {
            guard let sourceIndex = page.firstIndex(where: { $0.id == entryID }) else { continue }
            if sourceIndex + 1 < page.count {
                moveEntry(entryID, relativeTo: page[sourceIndex + 1].id, after: false)
            } else if sourceIndex > 0 {
                moveEntry(entryID, relativeTo: page[sourceIndex - 1].id, after: true)
            } else {
                let pageIndex = preview.firstIndex(where: { $0.contains(where: { $0.id == entryID }) }) ?? 0
                moveEntry(entryID, toPage: pageIndex, slot: 0)
            }
            return
        }
    }

    // MARK: - 文件夹操作

    /// id 是否是文件夹。
    func isFolderID(_ id: String) -> Bool {
        layout.groups.contains { $0.id == id && $0.isFolder }
    }

    /// 文件夹名。
    func folderName(_ folderID: String) -> String {
        layout.groups.first { $0.id == folderID }?.name ?? ""
    }

    /// 把 source 应用拖到 target 应用上 → 创建文件夹容纳两者。
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

    /// 把应用放入已有文件夹。
    func addToFolder(_ appID: String, folderID: String) {
        guard let (apps, groups) = Self.applyAddToFolder(
            apps: layout.apps, groups: layout.groups,
            appID: appID, folderID: folderID) else { return }
        layout.apps = apps
        layout.groups = groups
        commitMutation()
    }

    /// 隐藏 / 取消隐藏应用。
    func setHidden(_ appID: String, hidden: Bool) {
        guard let idx = layout.apps.firstIndex(where: { $0.id == appID }) else { return }
        layout.apps[idx].hidden = hidden
        commitMutation()
    }

    /// 设置应用别名(重命名);空串 = 恢复默认名。
    func setAlias(_ appID: String, alias: String?) {
        guard let idx = layout.apps.firstIndex(where: { $0.id == appID }) else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespaces)
        layout.apps[idx].alias = (trimmed?.isEmpty ?? true) ? nil : trimmed
        commitMutation()
    }

    /// 已隐藏的应用(按显示名排序),供"找回"入口。
    func hiddenApps() -> [AppItem] {
        layout.apps.filter(\.hidden)
            .compactMap { record -> AppItem? in
                guard var item = scannedByPath[record.id] else { return nil }
                item.alias = record.alias
                return item
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// 应用当前所在的文件夹 id(不在文件夹里返回 nil)。
    func containingFolderID(of appID: String) -> String? {
        guard let record = layout.apps.first(where: { $0.id == appID }) else { return nil }
        return layout.groups.first { $0.id == record.groupID && $0.isFolder }?.id
    }

    /// 应用所在的展示页序(在文件夹里则取文件夹所在页),供"取消隐藏后跳页"。
    func displayPageIndex(ofApp appID: String) -> Int? {
        guard let record = layout.apps.first(where: { $0.id == appID }) else { return nil }
        let pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        if let index = pageGroups.firstIndex(where: { $0.id == record.groupID }) { return index }
        if let folder = layout.groups.first(where: { $0.id == record.groupID && $0.isFolder }) {
            return pageGroups.firstIndex { $0.page == folder.page }
        }
        return nil
    }

    /// 所有文件夹 (id, 显示名),按页/槽位排序,供"移动到文件夹"菜单。
    func allFolders() -> [(id: String, name: String)] {
        layout.groups.filter(\.isFolder)
            .sorted { ($0.page, $0.order) < ($1.page, $1.order) }
            .map { ($0.id, ($0.name?.isEmpty == false) ? $0.name! : "未命名文件夹") }
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

    /// 文件夹内容(按 order,剔除隐藏)。非文件夹 id 返回空。
    func folderItems(_ folderID: String) -> [AppItem] {
        guard isFolderID(folderID) else { return [] }
        return layout.apps
            .filter { $0.groupID == folderID && !$0.hidden }
            .sorted { $0.order < $1.order }
            .compactMap { record -> AppItem? in
                guard var item = scannedByPath[record.id] else { return nil }
                item.alias = record.alias
                return item
            }
    }

    /// 网格行列数变化后重排(超容溢出、重建展示、落盘)。
    func gridConfigChanged() {
        reflowPagesForGrid()
        commitMutation()
    }

    /// 网格容量变化属于用户明确发起的整体几何调整。按当前跨页顺序重新分块，
    /// 这样增大行数时后一页的项目也会补回当前页，而不是看起来“行数没生效”。
    private func reflowPagesForGrid() {
        var pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        guard let first = pageGroups.first else { return }

        let entities = pageGroups.flatMap {
            Self.entityList(apps: layout.apps, groups: layout.groups,
                            pageID: $0.id, page: $0.page)
        }
        let requiredCount = max(1, Int(ceil(Double(entities.count) / Double(Self.capacity))))

        while pageGroups.count < requiredCount {
            let nextPage = (pageGroups.last?.page ?? first.page) + 1
            var candidate = "page-\(nextPage)"
            var suffix = 2
            while layout.groups.contains(where: { $0.id == candidate }) {
                candidate = "page-\(nextPage)-\(suffix)"
                suffix += 1
            }
            let page = GroupRecord(id: candidate, isFolder: false, name: nil,
                                   page: nextPage, order: nextPage)
            layout.groups.append(page)
            pageGroups.append(page)
        }

        let targets = Array(pageGroups.prefix(requiredCount))
        for (index, entity) in entities.enumerated() {
            let target = targets[index / Self.capacity]
            assign(entity, pageID: target.id, page: target.page,
                   order: index % Self.capacity)
        }

        let targetIDs = Set(targets.map(\.id))
        layout.groups.removeAll { !$0.isFolder && !targetIDs.contains($0.id) }
    }

    /// 当前应用来源，按设置中的顺序返回。
    func sourceRecords() -> [SourceRecord] {
        layout.sources
    }

    /// 启用或停用一个应用来源，并立即重新扫描。
    func setSourceEnabled(_ path: String, enabled: Bool) {
        guard let index = layout.sources.firstIndex(where: { $0.path == path }) else { return }
        layout.sources[index].enabled = enabled
        save()
        refreshAsync()
    }

    /// 添加自定义应用来源。重复路径不会重复写入。
    func addSource(path: String) {
        guard !path.isEmpty, !layout.sources.contains(where: { $0.path == path }) else { return }
        layout.sources.append(SourceRecord(path: path, enabled: true))
        save()
        refreshAsync()
    }

    /// 删除自定义应用来源。默认来源也允许移除，便于用户精简扫描范围。
    func removeSource(path: String) {
        layout.sources.removeAll { $0.path == path }
        save()
        refreshAsync()
    }

    /// Manually selected app bundles and executable files remain discoverable
    /// even when they live outside configured scan folders.
    func customAppPaths() -> [String] {
        layout.customApps
    }

    @discardableResult
    func addCustomApp(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        guard AppScanner.isLaunchable(URL(fileURLWithPath: normalized)),
              !layout.customApps.contains(normalized) else { return false }
        layout.customApps.append(normalized)
        save()
        refreshAsync()
        return true
    }

    func removeCustomApp(path: String) {
        layout.customApps.removeAll { $0 == path }
        save()
        refreshAsync()
    }

    /// 保持当前顺序，把所有页面级条目压实到连续槽位，消除页面之间的空洞。
    func fillEmptySlots() {
        let pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        guard let firstPage = pageGroups.first else { return }
        let entities = pageGroups.flatMap {
            Self.entityList(apps: layout.apps, groups: layout.groups,
                            pageID: $0.id, page: $0.page)
        }
        for (order, entity) in entities.enumerated() {
            assign(entity, pageID: firstPage.id, page: firstPage.page, order: order)
        }
        commitMutation()
    }

    /// 按显示名重排所有页面级条目(应用+文件夹图块),从第一页起连续排列,
    /// 超容由容量归一自动分页。文件夹内部顺序不动。
    func arrangeAllByName() {
        let pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        guard let firstPage = pageGroups.first else { return }

        var entities = pageGroups.flatMap {
            Self.entityList(apps: layout.apps, groups: layout.groups,
                            pageID: $0.id, page: $0.page)
        }

        func displayName(_ entity: LayoutEntity) -> String {
            switch entity.ref {
            case .app(let id):
                guard let record = layout.apps.first(where: { $0.id == id }) else { return "" }
                if let alias = record.alias, !alias.isEmpty { return alias }
                return record.name
            case .folder(let id):
                return layout.groups.first { $0.id == id }?.name ?? ""
            }
        }

        entities.sort {
            displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending
        }
        // 全部排入第一页,交给容量归一按页瀑布式切分
        for (order, entity) in entities.enumerated() {
            assign(entity, pageID: firstPage.id, page: firstPage.page, order: order)
        }
        commitMutation()
    }

    /// 导出完整布局。应用本体不包含在备份中，恢复时会按当前机器重新扫描对账。
    func backupData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(layout)
    }

    /// 恢复布局并立即与当前机器的应用目录对账。
    func restoreBackup(_ data: Data) throws {
        let restored = try JSONDecoder().decode(Layout.self, from: data)
        guard restored.version == Layout.initial().version else {
            throw LayoutBackupError.unsupportedVersion(restored.version)
        }
        guard restored.groups.contains(where: { !$0.isFolder }) else {
            throw LayoutBackupError.missingPage
        }
        layout = restored
        save()
        refreshAsync()
    }

    // MARK: - 变更收尾

    /// 自动解散单应用文件夹 + 容量归一 + 修剪空尾页 + 重建展示 + 落盘。
    private func commitMutation() {
        autoDissolveSingletonFolders()
        normalizeCapacity()
        pruneTrailingEmptyPageGroups()
        rebuildPages()
        save()
    }

    /// 文件夹仅剩一个(或零个)可见应用时自动解散(还原原生行为)。
    /// 按可见成员计数:隐藏成员不该撑住一个看起来空了的"幽灵文件夹"。
    private func autoDissolveSingletonFolders() {
        for folder in layout.groups where folder.isFolder {
            let memberCount = layout.apps
                .filter { $0.groupID == folder.id && !$0.hidden }.count
            if memberCount <= 1,
               let (apps, groups) = Self.applyDissolveFolder(apps: layout.apps,
                                                             groups: layout.groups,
                                                             folderID: folder.id) {
                layout.apps = apps
                layout.groups = groups
            }
        }
    }

    /// 每页最多 capacity 个条目(应用+文件夹);超出的整体搬到下一页开头,必要时自动建新页。
    private func normalizeCapacity() {
        var pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        guard !pageGroups.isEmpty else { return }

        var i = 0
        while i < pageGroups.count {
            let pg = pageGroups[i]
            let entities = Self.entityList(apps: layout.apps, groups: layout.groups,
                                           pageID: pg.id, page: pg.page)
            if entities.count > Self.capacity {
                let overflow = Array(entities[Self.capacity...])

                let next: GroupRecord
                if i + 1 < pageGroups.count {
                    next = pageGroups[i + 1]
                } else {
                    let nextPage = pg.page + 1
                    next = GroupRecord(id: "page-\(nextPage)", isFolder: false,
                                       name: nil, page: nextPage, order: nextPage)
                    layout.groups.append(next)
                    pageGroups.append(next)
                }

                // 下一页现有条目整体后移,溢出条目插到开头(保持相对顺序)
                let existing = Self.entityList(apps: layout.apps, groups: layout.groups,
                                               pageID: next.id, page: next.page)
                var order = 0
                for entity in overflow {
                    assign(entity, pageID: next.id, page: next.page, order: order)
                    order += 1
                }
                for entity in existing {
                    assign(entity, pageID: next.id, page: next.page, order: order)
                    order += 1
                }
            }
            i += 1
        }
    }

    /// 把实体安置到指定页与槽位。
    private func assign(_ entity: LayoutEntity, pageID: String, page: Int, order: Int) {
        switch entity.ref {
        case .app(let id):
            if let idx = layout.apps.firstIndex(where: { $0.id == id }) {
                layout.apps[idx].groupID = pageID
                layout.apps[idx].order = order
            }
        case .folder(let id):
            if let idx = layout.groups.firstIndex(where: { $0.id == id }) {
                layout.groups[idx].page = page
                layout.groups[idx].order = order
            }
        }
    }

    /// 删除持久层中"尾部"的空页组(中间空页保留,尊重用户留白)。
    private func pruneTrailingEmptyPageGroups() {
        var pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        while pageGroups.count > 1 {
            guard let last = pageGroups.last,
                  Self.entityList(apps: layout.apps, groups: layout.groups,
                                  pageID: last.id, page: last.page).isEmpty else { break }
            layout.groups.removeAll { $0.id == last.id }
            pageGroups.removeLast()
        }
    }

    /// 从当前 layout + 上次扫描结果重建分页展示列表(不重扫磁盘、不落盘)。
    private func rebuildPages() {
        // 页面重建会在 Stepper、拖拽和扫描完成后频繁发生。先建立索引和
        // 文件夹成员表，避免每个槽位再次对 apps/groups 做 first(where:)/filter。
        let recordsByID = Dictionary(uniqueKeysWithValues: layout.apps.map { ($0.id, $0) })
        let groupsByID = Dictionary(uniqueKeysWithValues: layout.groups.map { ($0.id, $0) })
        var entitiesByPage: [String: [LayoutEntity]] = [:]
        for record in layout.apps {
            entitiesByPage[record.groupID, default: []].append(
                LayoutEntity(ref: .app(record.id), order: record.order, hidden: record.hidden))
        }
        for group in layout.groups where group.isFolder {
            entitiesByPage[pageGroupID(forPage: group.page), default: []]
                .append(LayoutEntity(ref: .folder(group.id), order: group.order, hidden: false))
        }

        var membersByFolder: [String: [AppItem]] = [:]
        for record in layout.apps {
            guard !record.hidden,
                  let folder = groupsByID[record.groupID], folder.isFolder,
                  var item = scannedByPath[record.id] else { continue }
            item.alias = record.alias
            membersByFolder[folder.id, default: []].append(item)
        }
        for key in membersByFolder.keys {
            membersByFolder[key]?.sort {
                (recordsByID[$0.id]?.order ?? 0) < (recordsByID[$1.id]?.order ?? 0)
            }
        }

        let pageGroups = layout.groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        pages = pageGroups.map { pg in
            let entities = entitiesByPage[pg.id, default: []].sorted { $0.order < $1.order }
            return entities.compactMap { entity -> PageEntry? in
                switch entity.ref {
                case .app(let id):
                    guard let record = recordsByID[id], !record.hidden,
                          var item = scannedByPath[id] else { return nil }
                    item.alias = record.alias
                    return .app(item)
                case .folder(let id):
                    guard let folder = groupsByID[id] else { return nil }
                    let members = membersByFolder[id, default: []]
                    return .folder(FolderInfo(id: id,
                                              name: folder.name ?? "",
                                              preview: Array(members.prefix(4)),
                                              count: members.count))
                }
            }
        }
        while pages.count > 1, pages.last?.isEmpty == true {
            pages.removeLast()
        }

        // items 含文件夹内应用:搜索必须能找到收纳起来的应用
        var flat: [AppItem] = []
        for page in pages {
            for entry in page {
                switch entry {
                case .app(let a): flat.append(a)
                case .folder(let f): flat.append(contentsOf: membersByFolder[f.id, default: []])
                }
            }
        }
        items = flat
    }

    /// 文件夹记录用 page 值挂在页面组上；这里将其转换为当前页面组 id。
    /// 旧布局的页面 id 始终遵循 page-N，其他布局仍由下面的回退查找兼容。
    private func pageGroupID(forPage page: Int) -> String {
        let expected = "page-\(page)"
        if layout.groups.contains(where: { !$0.isFolder && $0.id == expected }) { return expected }
        return layout.groups.first(where: { !$0.isFolder && $0.page == page })?.id ?? expected
    }

    private func save() {
        // 行列 Stepper 和拖拽预览会在很短时间内连续触发布局变更。
        // 合并磁盘写入，避免主线程反复 JSON 编码造成设置面板掉帧。
        pendingSave?.cancel()
        let layout = layout
        let destination = Self.fileURL
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(layout).write(to: destination, options: .atomic)
        }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    // MARK: - 纯函数层(可独立测试)

    /// 页内实体引用:应用(按 id)或文件夹(按 id)。
    struct LayoutEntity {
        enum Ref { case app(String); case folder(String) }
        let ref: Ref
        let order: Int
        let hidden: Bool

        var id: String {
            switch ref {
            case .app(let id), .folder(let id): return id
            }
        }
    }

    /// 页内实体列表(应用 + 文件夹共享同一 order 序列),按 order 排序。
    static func entityList(apps: [AppRecord], groups: [GroupRecord],
                           pageID: String, page: Int) -> [LayoutEntity] {
        var out: [LayoutEntity] = []
        for record in apps where record.groupID == pageID {
            out.append(LayoutEntity(ref: .app(record.id), order: record.order,
                                    hidden: record.hidden))
        }
        for group in groups where group.isFolder && group.page == page {
            out.append(LayoutEntity(ref: .folder(group.id), order: group.order, hidden: false))
        }
        return out.sorted { $0.order < $1.order }
    }

    /// 按实体列表重新编号(应用写 order,文件夹写 page+order)。
    private static func renumber(_ entities: [LayoutEntity],
                                 pageID: String, page: Int,
                                 apps: inout [AppRecord], groups: inout [GroupRecord]) {
        for (order, entity) in entities.enumerated() {
            switch entity.ref {
            case .app(let id):
                if let idx = apps.firstIndex(where: { $0.id == id }) {
                    apps[idx].groupID = pageID
                    apps[idx].order = order
                }
            case .folder(let id):
                if let idx = groups.firstIndex(where: { $0.id == id }) {
                    groups[idx].page = page
                    groups[idx].order = order
                }
            }
        }
    }

    /// 纯函数:把应用移到 (页, 可见槽位)。保留旧名以兼容既有测试。
    static func applyMove(apps: [AppRecord], groups: [GroupRecord],
                          appID: String, toPage: Int, slot: Int)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        applyMoveEntity(apps: apps, groups: groups, entityID: appID, toPage: toPage, slot: slot)
    }

    /// 纯函数:把实体(应用或文件夹图块)移到 (页, 可见槽位)。
    /// slot 按"可见条目"计数(隐藏应用保持相对位置);文件夹不可放入文件夹。
    static func applyMoveEntity(apps: [AppRecord], groups: [GroupRecord],
                                entityID: String, toPage: Int, slot: Int)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        var apps = apps
        var groups = groups

        let isFolder = groups.contains { $0.id == entityID && $0.isFolder }
        let appIndex = apps.firstIndex { $0.id == entityID }
        guard isFolder || appIndex != nil else { return nil }

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

        // 源信息(用于事后压实)
        var sourceGroupID: String?          // 应用的来源组(页或文件夹)
        var sourceHostPage: GroupRecord?    // 文件夹的原宿主页
        if isFolder {
            let folderPage = groups.first { $0.id == entityID }!.page
            sourceHostPage = pageGroups.first { $0.page == folderPage }
        } else {
            sourceGroupID = apps[appIndex!].groupID
        }

        // 目标页实体(不含被拖实体),可见槽位 → 全列表插入点
        var targetEntities = entityList(apps: apps, groups: groups,
                                        pageID: target.id, page: target.page)
            .filter { $0.id != entityID }
        let visiblePositions = targetEntities.enumerated()
            .filter { !$0.element.hidden }
            .map(\.offset)
        let visibleSlot = min(max(slot, 0), visiblePositions.count)
        let insertAt = visibleSlot < visiblePositions.count
            ? visiblePositions[visibleSlot]
            : targetEntities.count

        let moved = LayoutEntity(ref: isFolder ? .folder(entityID) : .app(entityID),
                                 order: 0,
                                 hidden: isFolder ? false : apps[appIndex!].hidden)
        targetEntities.insert(moved, at: insertAt)
        renumber(targetEntities, pageID: target.id, page: target.page,
                 apps: &apps, groups: &groups)

        // 源侧压实(renumber 已把实体移走,重新取列表自然不含它)
        if isFolder {
            if let sp = sourceHostPage, sp.id != target.id {
                let remaining = entityList(apps: apps, groups: groups,
                                           pageID: sp.id, page: sp.page)
                renumber(remaining, pageID: sp.id, page: sp.page, apps: &apps, groups: &groups)
            }
        } else if let sourceGroupID, sourceGroupID != target.id {
            if let sp = pageGroups.first(where: { $0.id == sourceGroupID }) {
                let remaining = entityList(apps: apps, groups: groups,
                                           pageID: sp.id, page: sp.page)
                renumber(remaining, pageID: sp.id, page: sp.page, apps: &apps, groups: &groups)
            } else {
                // 源是文件夹:成员 order 压实(拖出文件夹的路径)
                compactFolderMembers(&apps, folderID: sourceGroupID)
            }
        }
        return (apps, groups)
    }

    /// Pure function: move an entity directly before/after another persisted
    /// entity. Unlike a numeric visible slot, this cannot drift when `pages`
    /// omits an app whose bundle is temporarily unavailable during scanning.
    static func applyMoveEntity(apps: [AppRecord], groups: [GroupRecord],
                                entityID: String, relativeTo targetID: String, after: Bool)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        guard entityID != targetID else { return nil }
        var apps = apps
        var groups = groups

        let isFolder = groups.contains { $0.id == entityID && $0.isFolder }
        let appIndex = apps.firstIndex { $0.id == entityID }
        guard isFolder || appIndex != nil else { return nil }

        let pageGroups = groups.filter { !$0.isFolder }.sorted { $0.page < $1.page }
        let targetPage: GroupRecord?
        if let folder = groups.first(where: { $0.id == targetID && $0.isFolder }) {
            targetPage = pageGroups.first { $0.page == folder.page }
        } else if let targetApp = apps.first(where: { $0.id == targetID }) {
            targetPage = pageGroups.first { $0.id == targetApp.groupID }
        } else {
            targetPage = nil
        }
        guard let targetPage else { return nil }

        var sourceGroupID: String?
        var sourceHostPage: GroupRecord?
        if isFolder {
            let folderPage = groups.first { $0.id == entityID }!.page
            sourceHostPage = pageGroups.first { $0.page == folderPage }
        } else {
            sourceGroupID = apps[appIndex!].groupID
        }

        var targetEntities = entityList(apps: apps, groups: groups,
                                        pageID: targetPage.id, page: targetPage.page)
            .filter { $0.id != entityID }
        guard let targetIndex = targetEntities.firstIndex(where: { $0.id == targetID }) else {
            return nil
        }
        let moved = LayoutEntity(ref: isFolder ? .folder(entityID) : .app(entityID),
                                 order: 0,
                                 hidden: isFolder ? false : apps[appIndex!].hidden)
        targetEntities.insert(moved, at: targetIndex + (after ? 1 : 0))
        renumber(targetEntities, pageID: targetPage.id, page: targetPage.page,
                 apps: &apps, groups: &groups)

        if isFolder {
            if let sourceHostPage, sourceHostPage.id != targetPage.id {
                let remaining = entityList(apps: apps, groups: groups,
                                           pageID: sourceHostPage.id, page: sourceHostPage.page)
                renumber(remaining, pageID: sourceHostPage.id, page: sourceHostPage.page,
                         apps: &apps, groups: &groups)
            }
        } else if let sourceGroupID, sourceGroupID != targetPage.id {
            if let sourcePage = pageGroups.first(where: { $0.id == sourceGroupID }) {
                let remaining = entityList(apps: apps, groups: groups,
                                           pageID: sourcePage.id, page: sourcePage.page)
                renumber(remaining, pageID: sourcePage.id, page: sourcePage.page,
                         apps: &apps, groups: &groups)
            } else {
                compactFolderMembers(&apps, folderID: sourceGroupID)
            }
        }
        return (apps, groups)
    }

    /// 文件夹成员 order 压实为 0..n。
    private static func compactFolderMembers(_ apps: inout [AppRecord], folderID: String) {
        let members = apps.indices
            .filter { apps[$0].groupID == folderID }
            .sorted { apps[$0].order < apps[$1].order }
        for (order, idx) in members.enumerated() {
            apps[idx].order = order
        }
    }

    /// 纯函数:创建文件夹。文件夹占据 target 在页内的槽位,target 在前 source 在后。
    static func applyCreateFolder(apps: [AppRecord], groups: [GroupRecord],
                                  sourceID: String, targetID: String, name: String)
        -> (apps: [AppRecord], groups: [GroupRecord], folderID: String)? {
        var apps = apps
        var groups = groups
        guard sourceID != targetID,
              let sourceIdx = apps.firstIndex(where: { $0.id == sourceID }),
              let targetIdx = apps.firstIndex(where: { $0.id == targetID }) else { return nil }
        // target 必须在页面上(文件夹内不可再嵌套建夹)
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

        // 宿主页与源组重新编号
        let hostEntities = entityList(apps: apps, groups: groups,
                                      pageID: hostPage.id, page: hostPage.page)
        renumber(hostEntities, pageID: hostPage.id, page: hostPage.page,
                 apps: &apps, groups: &groups)
        if sourceGroupID != hostPage.id {
            if let sp = groups.first(where: { $0.id == sourceGroupID && !$0.isFolder }) {
                let sourceEntities = entityList(apps: apps, groups: groups,
                                                pageID: sp.id, page: sp.page)
                renumber(sourceEntities, pageID: sp.id, page: sp.page,
                         apps: &apps, groups: &groups)
            } else {
                compactFolderMembers(&apps, folderID: sourceGroupID)  // 从别的文件夹拖出
            }
        }
        return (apps, groups, folderID)
    }

    /// 纯函数:应用入夹(追加到文件夹末尾)。
    static func applyAddToFolder(apps: [AppRecord], groups: [GroupRecord],
                                 appID: String, folderID: String)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        var apps = apps
        var groups = groups
        guard groups.contains(where: { $0.id == folderID && $0.isFolder }),
              let idx = apps.firstIndex(where: { $0.id == appID }),
              apps[idx].groupID != folderID else { return nil }

        let sourceGroupID = apps[idx].groupID
        let nextOrder = (apps.filter { $0.groupID == folderID }.map(\.order).max() ?? -1) + 1
        apps[idx].groupID = folderID
        apps[idx].order = nextOrder

        if let sp = groups.first(where: { $0.id == sourceGroupID && !$0.isFolder }) {
            let sourceEntities = entityList(apps: apps, groups: groups,
                                            pageID: sp.id, page: sp.page)
            renumber(sourceEntities, pageID: sp.id, page: sp.page, apps: &apps, groups: &groups)
        } else {
            compactFolderMembers(&apps, folderID: sourceGroupID)  // 夹到夹的移动
        }
        return (apps, groups)
    }

    /// 纯函数:解散文件夹,成员在文件夹槽位处依次插回宿主页(保持相对顺序)。
    static func applyDissolveFolder(apps: [AppRecord], groups: [GroupRecord],
                                    folderID: String)
        -> (apps: [AppRecord], groups: [GroupRecord])? {
        var apps = apps
        var groups = groups
        guard let folder = groups.first(where: { $0.id == folderID && $0.isFolder }),
              let hostPage = groups.first(where: { !$0.isFolder && $0.page == folder.page })
        else { return nil }

        let members = apps.filter { $0.groupID == folderID }
            .sorted { $0.order < $1.order }
            .map { LayoutEntity(ref: .app($0.id), order: 0, hidden: $0.hidden) }

        var entities = entityList(apps: apps, groups: groups,
                                  pageID: hostPage.id, page: hostPage.page)
        let position = entities.firstIndex { $0.id == folderID } ?? entities.count
        if position < entities.count { entities.remove(at: position) }
        entities.insert(contentsOf: members, at: min(position, entities.count))

        groups.removeAll { $0.id == folderID }
        renumber(entities, pageID: hostPage.id, page: hostPage.page,
                 apps: &apps, groups: &groups)
        return (apps, groups)
    }
}
