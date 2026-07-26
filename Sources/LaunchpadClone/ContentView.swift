import SwiftUI
import AppKit

/// 收集单元格尺寸(只取高度用于行距推算;水平几何用纯数学,不依赖测量)。
struct CellSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 文件夹面板在窗口坐标系中的 frame(拖出判定用)。
struct PanelFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct ContentView: View {
    let dismiss: () -> Void
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var store = LayoutStore.shared
    @FocusState private var searchFocused: Bool
    @GestureState private var pageSwipeOffset: CGFloat = 0

    // MARK: 网格几何常量(与 pageView 布局参数保持一致)
    private static let hPadding: CGFloat = 70
    private static let colSpacing: CGFloat = 16
    private static let rowSpacing: CGFloat = 26
    private static let gridTop: CGFloat = 20
    private static let edgeMargin: CGFloat = 48

    /// 拖拽落点:插到槽位之间,或落到某条目上(建夹/入夹)。
    enum DropTarget: Equatable {
        case insert(page: Int, slot: Int)
        case onto(page: Int, entryID: String)
    }

    /// 起拖时指针所在的格子(页 + 格序),用于"拿起放回"保护。
    private struct OriginCell: Equatable {
        let page: Int
        let cell: Int
    }

    // MARK: 拖拽排序状态(网格内:应用或文件夹图块)
    @State private var draggingEntry: PageEntry?
    @State private var dragLocation: CGPoint = .zero       // "pagingArea" 坐标
    @State private var previewPages: [[PageEntry]]?        // 拖拽中的预览布局
    @State private var dropTarget: DropTarget?
    @State private var dragOrigin: OriginCell?             // 起拖格
    @State private var hasLeftOrigin = false               // 指针是否已离开起拖格
    @State private var containerWidth: CGFloat = 0         // 分页容器宽度(即页宽)
    @State private var cellHeight: CGFloat = 120           // 单元格高度(测量,供行距推算)
    @State private var edgeFlipWork: DispatchWorkItem?
    @State private var pagingAreaFrame: CGRect = .zero     // 分页容器的窗口坐标 frame

    // MARK: 从文件夹面板拖出
    @State private var panelDragApp: AppItem?              // 面板内起拖的应用
    @State private var panelDragLocation: CGPoint = .zero  // 窗口坐标
    @State private var folderPanelHidden = false           // 拖出边界后面板隐去(视图保留,手势不断)
    @State private var panelFrame: CGRect = .zero          // 面板窗口坐标 frame

    private var draggingID: String? { draggingEntry?.id }

    // MARK: 重命名对话框状态
    @State private var renameTarget: AppItem?
    @State private var renameText = ""
    @State private var folderRenameID: String?
    @State private var folderRenameText = ""
    // MARK: 简介与卸载状态
    @State private var infoTarget: AppItem?
    @State private var uninstallTarget: AppItem?
    @State private var uninstallError: String?

    /// onto 模式下被悬停的条目(视觉放大提示)。
    private var ontoHighlightID: String? {
        if case .onto(_, let id) = dropTarget { return id }
        return nil
    }

    /// 分页与搜索结果共用固定列数:键盘导航需要确定的网格几何。
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.colSpacing),
              count: LayoutStore.columns)
    }

    /// 展示用页面:拖拽时用预览布局,并在末尾提供一个空承接页。
    private var displayPages: [[PageEntry]] {
        if let previewPages { return previewPages }
        var pages = store.pages
        if draggingEntry != nil { pages.append([]) }
        return pages
    }

    /// 搜索结果:前缀/词首/首字母/缩写/拼音多路匹配,按匹配度排序。
    private var filtered: [AppItem] {
        SearchEngine.rank(state.effectiveQuery, in: store.items)
    }

    var body: some View {
        ZStack {
            mainContent

            // 文件夹展开面板(盖在网格之上;拖出时隐去但视图保留,手势不断)
            if let folderID = state.openFolderID {
                folderOverlay(folderID)
                    .opacity(folderPanelHidden ? 0 : 1)
                    .allowsHitTesting(!folderPanelHidden)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            // 面板内拖动阶段的浮动图标(根层坐标 = 窗口坐标)
            if let app = panelDragApp, !folderPanelHidden {
                floatingIcon(.app(app))
                    .position(panelDragLocation)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.openFolderID)
    }

    private var mainContent: some View {
        VStack(spacing: 16) {
            searchField

            if state.effectiveQuery.isEmpty {
                pagedGrid
                pageDots
            } else {
                searchResults
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }   // 点击空白区域关闭(图标/搜索框/圆点会自行消费点击)
        .onAppear {
            store.refresh()
            focusSearch()
            // 预热搜索键(含 ICU 转换器首次初始化的约 40ms),挪出打字路径
            DispatchQueue.main.async {
                SearchEngine.prewarm(store.items)
            }
        }
        // 每次从菜单栏/快捷键重新唤起时:重新对账(捕捉新装/卸载)并聚焦搜索框
        .onReceive(NotificationCenter.default.publisher(for: .refocusSearch)) { _ in
            store.refresh()
            focusSearch()
        }
        // Esc/隐藏 终止拖拽:不落盘,布局弹回原状;同一次按住期间不得重新开始
        .onReceive(NotificationCenter.default.publisher(for: .cancelDrag)) { _ in
            AppState.shared.dragInhibited = true
            finishDrag()
        }
        // 页数变化时防止停留在已不存在的页
        .onChange(of: store.pages.count) { _, count in
            state.currentPage = min(state.currentPage, max(0, count - 1))
        }
        // 关闭文件夹后把焦点还给搜索框(改名可能夺走过焦点)
        .onChange(of: state.openFolderID) { _, id in
            if id == nil { focusSearch() }
        }
        .onChange(of: state.query) { old, new in
            // 拖拽中打字会切走分页视图、销毁手势:先取消拖拽防状态泄漏
            if AppState.shared.isDragging {
                AppState.shared.dragInhibited = true
                finishDrag()
            }
            // 有效查询变化时重置键盘高亮(结果集变了,旧高亮无意义);
            // 只比较去空白后的值:分页模式误触空格不应清掉高亮
            if old.trimmingCharacters(in: .whitespaces) != new.trimmingCharacters(in: .whitespaces) {
                state.highlightedAppID = nil
            }
        }
        // 布局变更后若展开的文件夹已不存在(被解散),自动收起
        .onReceive(store.objectWillChange) { _ in
            DispatchQueue.main.async {
                if let id = state.openFolderID, !store.isFolderID(id) {
                    state.openFolderID = nil
                }
            }
        }
        // 重命名应用对话框
        .alert("重命名应用", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("名称", text: $renameText)
            Button("确定") {
                if let app = renameTarget {
                    store.setAlias(app.id, alias: renameText)
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            Text("留空则恢复默认名称")
        }
        // 重命名文件夹对话框
        .alert("重命名文件夹", isPresented: Binding(
            get: { folderRenameID != nil },
            set: { if !$0 { folderRenameID = nil } })
        ) {
            TextField("名称", text: $folderRenameText)
            Button("确定") {
                if let id = folderRenameID {
                    store.renameFolder(id, to: folderRenameText)
                }
                folderRenameID = nil
            }
            Button("取消", role: .cancel) { folderRenameID = nil }
        }
        // 应用简介面板
        .sheet(item: $infoTarget) { app in
            AppInfoPanel(app: app)
        }
        // 卸载确认
        .alert("卸载“\(uninstallTarget?.displayName ?? "")”?", isPresented: Binding(
            get: { uninstallTarget != nil },
            set: { if !$0 { uninstallTarget = nil } })
        ) {
            Button("移到废纸篓", role: .destructive) {
                if let app = uninstallTarget {
                    AppActions.uninstall(
                        appURL: app.url,
                        bundleID: app.bundleID,
                        beforeFinderFallback: {
                            dismiss()   // Finder 的管理员认证弹窗不能被全屏层挡住
                        },
                        completion: { error in
                            if let error {
                                uninstallError = error
                                // 覆盖层可能已收起,重新唤起以展示错误
                                (NSApp.delegate as? AppDelegate)?.showOverlay()
                            } else {
                                store.refresh()
                            }
                        }
                    )
                }
                uninstallTarget = nil
            }
            Button("取消", role: .cancel) { uninstallTarget = nil }
        } message: {
            let residuals = AppActions.residualPaths(bundleID: uninstallTarget?.bundleID).count
            Text(residuals > 0
                 ? "应用本体与 \(residuals) 项残留数据(缓存、偏好设置等)将一并移到废纸篓,可随时恢复。"
                 : "应用将被移到废纸篓,可随时恢复。")
        }
        // 卸载失败提示
        .alert("卸载失败", isPresented: Binding(
            get: { uninstallError != nil },
            set: { if !$0 { uninstallError = nil } })
        ) {
            Button("好", role: .cancel) { uninstallError = nil }
        } message: {
            Text(uninstallError ?? "")
        }
    }

    // MARK: - 右键菜单

    /// 应用右键菜单(网格/搜索结果/文件夹面板通用)。
    @ViewBuilder
    private func appContextMenu(_ app: AppItem) -> some View {
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
            dismiss()   // 覆盖层在最顶层,不关掉会把 Finder 窗口完全挡住
        }
        Button("显示简介") {
            infoTarget = app
        }
        Button("添加到程序坞") {
            AppActions.addToDock(app.url)
        }
        Divider()
        // 排除:应用当前所在的文件夹(移入自己所在夹是无效操作)与正展开的文件夹
        let currentFolder = store.containingFolderID(of: app.id)
        let folders = store.allFolders().filter {
            $0.id != state.openFolderID && $0.id != currentFolder
        }
        if !folders.isEmpty {
            Menu("移动到文件夹") {
                ForEach(folders, id: \.id) { folder in
                    Button(folder.name) {
                        store.addToFolder(app.id, folderID: folder.id)
                    }
                }
            }
        }
        Button("重命名…") {
            renameText = app.displayName
            renameTarget = app
        }
        Divider()
        Button("隐藏") {
            store.setHidden(app.id, hidden: true)
        }
        // 系统应用受 SIP 保护不可卸载,不显示入口
        if !app.id.hasPrefix("/System/") {
            Divider()
            Button("卸载…") {
                uninstallTarget = app
            }
        }
    }

    /// 文件夹图块右键菜单。
    @ViewBuilder
    private func folderContextMenu(_ info: FolderInfo) -> some View {
        Button("重命名…") {
            folderRenameText = info.name
            folderRenameID = info.id
        }
        Divider()
        Button("解散文件夹") {
            store.dissolveFolder(info.id)
        }
    }

    /// 空白区域右键菜单。
    @ViewBuilder
    private var blankAreaMenu: some View {
        let hidden = store.hiddenApps()
        if !hidden.isEmpty {
            Menu("已隐藏的应用") {
                ForEach(hidden) { app in
                    Button(app.displayName) {
                        store.setHidden(app.id, hidden: false)
                        // 跳到应用回归的页面,给出可见反馈
                        if let page = store.displayPageIndex(ofApp: app.id) {
                            state.currentPage = min(page, max(0, store.pages.count - 1))
                        }
                    }
                }
            }
            Divider()
        }
        Button("完全退出") {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        TextField("搜索应用…", text: $state.query)
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 52)
            .onSubmit {
                // 搜索后按回车直接打开第一个结果(纯空白查询不触发)
                if !state.effectiveQuery.isEmpty, let first = filtered.first {
                    launch(first)
                }
            }
    }

    private func focusSearch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocused = true
        }
    }

    // MARK: - 分页网格(横向翻页 + 跟手拖拽 + 图标拖拽排序)

    private var pagedGrid: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(displayPages.indices, id: \.self) { pageIndex in
                        pageView(displayPages[pageIndex])
                            .frame(width: width, height: geo.size.height, alignment: .top)
                    }
                }
                // 拖拽位移实时叠加到页面偏移上,还原跟手感
                .offset(x: -CGFloat(state.currentPage) * width + pageSwipeOffset)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.currentPage)
                .gesture(pageSwipeGesture(width: width))

                // 跟随指针的浮动图标(拖拽中)
                if let entry = draggingEntry {
                    floatingIcon(entry)
                        .position(dragLocation)
                        .allowsHitTesting(false)
                        .zIndex(10)
                }
            }
            .coordinateSpace(name: "pagingArea")         // 指针/浮动图标用:静止坐标系
            .onAppear {
                containerWidth = width
                pagingAreaFrame = geo.frame(in: .global)
            }
            .onChange(of: geo.size.width) { _, w in
                containerWidth = w
                pagingAreaFrame = geo.frame(in: .global)
            }
            .onPreferenceChange(CellSizeKey.self) { size in
                if size.height > 0 { cellHeight = size.height }
            }
        }
        .clipped()
        // 空白区域右键菜单(挂在网格区,不覆盖页码圆点/搜索框;图标有自己的菜单)
        .contextMenu { blankAreaMenu }
    }

    private func pageSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($pageSwipeOffset) { value, offset, _ in
                offset = value.translation.width
            }
            .onEnded { value in
                // 按预测终点(含速度)决定翻页,轻甩也能翻
                let predicted = value.predictedEndTranslation.width
                if predicted < -width / 4 {
                    state.flipPage(1)
                } else if predicted > width / 4 {
                    state.flipPage(-1)
                }
            }
    }

    private func pageView(_ entries: [PageEntry]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: Self.rowSpacing) {
            ForEach(entries) { entry in
                entryCell(entry)
                    // onto 悬停:目标条目放大提示"松手即建夹/入夹"
                    .scaleEffect(ontoHighlightID == entry.id ? 1.12 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7),
                               value: ontoHighlightID == entry.id)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: CellSizeKey.self, value: g.size)
                        }
                    )
            }
        }
        .padding(.horizontal, Self.hPadding)
        .padding(.top, Self.gridTop)
    }

    @ViewBuilder
    private func entryCell(_ entry: PageEntry) -> some View {
        switch entry {
        case .app(let app):
            appCell(app)
                // 拖拽中的条目在预览槽位处半透明显示,作为落点指示
                .opacity(app.id == draggingID ? 0.35 : 1)
                .gesture(iconDragGesture(entry))
        case .folder(let info):
            folderCell(info)
                .opacity(info.id == draggingID ? 0.35 : 1)
                .gesture(iconDragGesture(entry))   // 文件夹图块同样可拖动排序
        }
    }

    // MARK: - 文件夹

    /// 文件夹图块:托盘 + 2×2 成员预览 + 名称。
    private func folderCell(_ info: FolderInfo) -> some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    if i < info.preview.count {
                        Image(nsImage: info.preview[i].icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Color.clear.frame(width: 24, height: 24)
                    }
                }
            }
            .padding(8)
            .frame(width: 72, height: 72)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            Text(info.name.isEmpty ? "未命名文件夹" : info.name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 100)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(info.id == state.highlightedAppID ? 0.14 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { state.openFolderID = info.id }
        .contextMenu { folderContextMenu(info) }
    }

    /// 文件夹展开面板:标题可点击改名,成员网格,点外部/Esc 关闭,可解散。
    private func folderOverlay(_ folderID: String) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { state.openFolderID = nil }   // 点击外部空白关闭

            VStack(spacing: 14) {
                FolderTitleField(folderID: folderID)

                // 成员多时可滚动,保证标题与解散按钮始终可达
                ScrollView {
                    let members = store.folderItems(folderID)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                             count: min(5, max(members.count, 1))),
                              spacing: 22) {
                        ForEach(members) { app in
                            appCell(app)
                                .opacity(app.id == panelDragApp?.id ? 0.35 : 1)
                                .gesture(panelDragGesture(app))   // 按住拖出文件夹
                        }
                    }
                    .padding(.horizontal, 34)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)

                Button("解散文件夹") {
                    store.dissolveFolder(folderID)
                    state.openFolderID = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
            }
            .padding(.top, 8)
            .frame(maxWidth: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: PanelFrameKey.self,
                                           value: g.frame(in: .global))
                }
            )
        }
        .onPreferenceChange(PanelFrameKey.self) { frame in
            if frame != .zero { panelFrame = frame }
        }
    }

    /// 从文件夹面板内拖出:指针越出面板边界 → 面板隐去(视图保留),转入网格拖拽管线。
    private func panelDragGesture(_ app: AppItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard !AppState.shared.dragInhibited else { return }
                if panelDragApp == nil {
                    panelDragApp = app
                    AppState.shared.isDragging = true
                }
                panelDragLocation = value.location

                if !folderPanelHidden {
                    // 仍在面板内:只跟随浮动图标
                    guard panelFrame != .zero, !panelFrame.contains(value.location) else { return }
                    // 越出边界:面板隐去,接入网格拖拽管线(跳过起拖格保护)
                    withAnimation(.easeOut(duration: 0.18)) { folderPanelHidden = true }
                    draggingEntry = .app(app)
                    dragOrigin = nil
                    hasLeftOrigin = true
                }
                dragLocation = CGPoint(x: value.location.x - pagingAreaFrame.minX,
                                       y: value.location.y - pagingAreaFrame.minY)
                evaluateDragTarget()
                handleEdgeHover()
            }
            .onEnded { _ in
                let didLeavePanel = folderPanelHidden
                if didLeavePanel {
                    commitDrag()                     // 含 finishDrag(清 panel 状态)
                    state.openFolderID = nil         // 拖出后关闭面板(可能已自动解散)
                } else {
                    // 未离开面板:无操作
                    AppState.shared.dragInhibited = false
                    panelDragApp = nil
                    AppState.shared.isDragging = false
                }
            }
    }

    /// 文件夹标题:点击即改名(还原 LaunchOS:点展开后的标题重命名)。
    /// 回车或面板关闭(点外部/Esc)都会提交,不丢输入。
    private struct FolderTitleField: View {
        let folderID: String
        @State private var name: String = ""
        @State private var original: String = ""
        @FocusState private var editing: Bool

        var body: some View {
            TextField("未命名文件夹", text: $name)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 18, weight: .medium))
                .focused($editing)
                .frame(maxWidth: 300)
                .padding(.top, 22)
                .onAppear {
                    name = LayoutStore.shared.folderName(folderID)
                    original = name
                }
                // 改名中把按键让给输入框(全局按键监听据此放行)
                .onChange(of: editing) { _, isEditing in
                    AppState.shared.folderTitleEditing = isEditing
                }
                .onSubmit { commit() }
                .onDisappear {
                    commit()
                    AppState.shared.folderTitleEditing = false
                }
        }

        private func commit() {
            guard name != original else { return }
            LayoutStore.shared.renameFolder(folderID, to: name)
            original = name
        }
    }

    // MARK: - 图标拖拽排序

    private func iconDragGesture(_ entry: PageEntry) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("pagingArea"))
            .onChanged { value in
                guard state.effectiveQuery.isEmpty,
                      state.openFolderID == nil else { return }   // 搜索态/文件夹展开不排序
                dragChanged(entry, value)
            }
            .onEnded { _ in
                commitDrag()
            }
    }

    private func dragChanged(_ entry: PageEntry, _ value: DragGesture.Value) {
        guard !AppState.shared.dragInhibited else { return }   // 本次按住已被 Esc 取消
        if draggingEntry == nil {
            draggingEntry = entry
            AppState.shared.isDragging = true
            hasLeftOrigin = false
            // 记录起拖格:指针未离开它之前不判定任何落点("拿起放回"必须是无操作)
            let xInPage = value.location.x   // 起拖时必然在当前可见页
            if let cell = cellIndex(xInPage: xInPage, y: value.location.y) {
                dragOrigin = OriginCell(page: state.currentPage, cell: cell)
            } else {
                dragOrigin = nil
            }
        }
        dragLocation = value.location
        evaluateDragTarget()
        handleEdgeHover()
    }

    /// 指针所在格序(不带中心区约束);出界返回 nil。
    private func cellIndex(xInPage: CGFloat, y: CGFloat) -> Int? {
        let cols = LayoutStore.columns
        let colWidth = (containerWidth - 2 * Self.hPadding
                        - CGFloat(cols - 1) * Self.colSpacing) / CGFloat(cols)
        let pitch = colWidth + Self.colSpacing
        let col = Int(floor((xInPage - Self.hPadding) / pitch))
        guard col >= 0, col < cols else { return nil }
        let rowPitch = cellHeight + Self.rowSpacing
        let row = Int(floor((y - Self.gridTop) / rowPitch))
        guard row >= 0, row < LayoutStore.rows else { return nil }
        return row * cols + col
    }

    /// 移除被拖条目后的基准布局(末尾带承接空页)。
    private func basePagesWithoutDragged(_ entry: PageEntry) -> [[PageEntry]] {
        var base = store.pages
        base.append([])
        for i in base.indices {
            base[i].removeAll { $0.id == entry.id }
        }
        return base
    }

    /// 由指针位置 + 当前页码推算落点(插入 / 建夹 / 入夹)并刷新预览。
    /// 纯数学推导,不依赖运行时测量的水平几何。文件夹图块只走插入,不参与建夹/入夹。
    private func evaluateDragTarget() {
        guard let entry = draggingEntry, containerWidth > 0 else { return }
        let width = containerWidth
        let contentX = dragLocation.x + CGFloat(state.currentPage) * width
        var pageIndex = Int(floor(contentX / width))
        pageIndex = min(max(pageIndex, 0), store.pages.count)   // 末尾允许承接新页
        let xInPage = contentX - CGFloat(pageIndex) * width

        // "拿起放回"保护:指针未离开起拖格之前不判定落点,松手即无操作
        if !hasLeftOrigin {
            let current = cellIndex(xInPage: xInPage, y: dragLocation.y)
                .map { OriginCell(page: pageIndex, cell: $0) }
            if let origin = dragOrigin, current == origin {
                return
            }
            hasLeftOrigin = true
        }

        let base = basePagesWithoutDragged(entry)

        // 悬停在某条目中心区 → 建夹(应用)或入夹(文件夹);仅应用可触发
        if case .app = entry,
           pageIndex < base.count,
           let hit = ontoHit(xInPage: xInPage, y: dragLocation.y, entries: base[pageIndex]) {
            setDropTarget(.onto(page: pageIndex, entryID: hit.id), entry: entry, base: base)
            return
        }

        let slot = insertionSlot(xInPage: xInPage, y: dragLocation.y)
        setDropTarget(.insert(page: pageIndex, slot: slot), entry: entry, base: base)
    }

    /// 指针是否悬停在条目的中心区(横向中央 56%、纵向中央 76%)。
    private func ontoHit(xInPage: CGFloat, y: CGFloat, entries: [PageEntry]) -> PageEntry? {
        let cols = LayoutStore.columns
        let colWidth = (containerWidth - 2 * Self.hPadding
                        - CGFloat(cols - 1) * Self.colSpacing) / CGFloat(cols)
        let pitch = colWidth + Self.colSpacing
        let xInGrid = xInPage - Self.hPadding
        let col = Int(floor(xInGrid / pitch))
        guard col >= 0, col < cols else { return nil }
        let fracX = xInGrid - CGFloat(col) * pitch
        guard fracX > colWidth * 0.22, fracX < colWidth * 0.78 else { return nil }

        let rowPitch = cellHeight + Self.rowSpacing
        let yInGrid = y - Self.gridTop
        let row = Int(floor(yInGrid / rowPitch))
        guard row >= 0, row < LayoutStore.rows else { return nil }
        let fracY = yInGrid - CGFloat(row) * rowPitch
        guard fracY > cellHeight * 0.12, fracY < cellHeight * 0.88 else { return nil }

        let index = row * cols + col
        return index < entries.count ? entries[index] : nil
    }

    /// 网格插入槽位:指针越过某格中心 → 插到其后。
    private func insertionSlot(xInPage: CGFloat, y: CGFloat) -> Int {
        let cols = LayoutStore.columns
        let colWidth = (containerWidth - 2 * Self.hPadding
                        - CGFloat(cols - 1) * Self.colSpacing) / CGFloat(cols)
        let pitch = colWidth + Self.colSpacing

        let xInGrid = xInPage - Self.hPadding
        var col = Int(floor((xInGrid - colWidth / 2) / pitch)) + 1
        col = min(max(col, 0), cols)

        let rowPitch = cellHeight + Self.rowSpacing
        var row = Int(floor((y - Self.gridTop) / rowPitch))
        row = min(max(row, 0), LayoutStore.rows - 1)

        return row * cols + col
    }

    /// 更新落点与预览。insert → 实时让位;onto → 收拢空位、目标放大。
    private func setDropTarget(_ target: DropTarget, entry: PageEntry, base: [[PageEntry]]) {
        guard target != dropTarget else { return }
        dropTarget = target

        var preview = base
        if case .insert(let page, let slot) = target {
            let p = min(page, preview.count - 1)
            let s = min(max(slot, 0), preview[p].count)
            preview[p].insert(entry, at: s)

            // 级联溢出:插入导致超容的页,把队尾挤到下一页开头(与落盘规则一致)
            var i = p
            while preview[i].count > LayoutStore.capacity {
                let spilled = preview[i].removeLast()
                if i + 1 >= preview.count { preview.append([]) }
                preview[i + 1].insert(spilled, at: 0)
                i += 1
            }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            previewPages = preview
        }
    }

    /// 拖到页面左右边缘悬停 0.45s → 自动翻页;指针不动也会连续翻页并刷新落点。
    private func handleEdgeHover() {
        let direction = edgeDirection()
        guard direction != 0 else {
            edgeFlipWork?.cancel()
            edgeFlipWork = nil
            return
        }
        guard edgeFlipWork == nil else { return }
        scheduleEdgeFlip(direction)
    }

    private func edgeDirection() -> Int {
        guard containerWidth > 0 else { return 0 }
        if dragLocation.x < Self.edgeMargin { return -1 }
        if dragLocation.x > containerWidth - Self.edgeMargin { return 1 }
        return 0
    }

    private func scheduleEdgeFlip(_ direction: Int) {
        let work = DispatchWorkItem {
            edgeFlipWork = nil
            guard draggingEntry != nil else { return }
            state.flipPage(direction)
            evaluateDragTarget()                 // 指针不动也要刷新落点预览
            let next = edgeDirection()
            if next != 0 { scheduleEdgeFlip(next) }   // 停在边缘 → 连续翻页
        }
        edgeFlipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func commitDrag() {
        AppState.shared.dragInhibited = false    // 一次按住结束
        if let entry = draggingEntry, let target = dropTarget {
            switch target {
            case .insert(let page, let slot):
                store.moveEntry(entry.id, toPage: page, slot: slot)
            case .onto(_, let targetID):
                // 只有拖应用才会产生 onto 落点(evaluateDragTarget 保证)
                if case .app(let app) = entry {
                    if store.isFolderID(targetID) {
                        store.addToFolder(app.id, folderID: targetID)
                    } else if targetID != app.id {
                        store.createFolder(dragging: app.id, onto: targetID, name: "未命名文件夹")
                    }
                }
            }
        }
        finishDrag()
    }

    /// 结束/取消拖拽:清空拖拽状态;未落盘的预览弹回真实布局;页码防越界(承接页可能消失)。
    private func finishDrag() {
        edgeFlipWork?.cancel()
        edgeFlipWork = nil
        draggingEntry = nil
        dropTarget = nil
        dragOrigin = nil
        hasLeftOrigin = false
        panelDragApp = nil
        folderPanelHidden = false
        AppState.shared.isDragging = false
        state.currentPage = min(state.currentPage, max(0, store.pages.count - 1))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            previewPages = nil
        }
    }

    @ViewBuilder
    private func floatingIcon(_ entry: PageEntry) -> some View {
        Group {
            switch entry {
            case .app(let app):
                VStack(spacing: 8) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text(app.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: 100)
                }
            case .folder(let info):
                VStack(spacing: 8) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                        GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(0..<4, id: \.self) { i in
                            if i < info.preview.count {
                                Image(nsImage: info.preview[i].icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                Color.clear.frame(width: 24, height: 24)
                            }
                        }
                    }
                    .padding(8)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    Text(info.name.isEmpty ? "未命名文件夹" : info.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: 100)
                }
            }
        }
        .scaleEffect(1.15)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    /// 单元格:普通视图 + TapGesture 启动。
    /// 不能用 Button:macOS 上 Button 的按压手势会把外层 DragGesture 的回调
    /// 全部推迟到松手时一次性爆发,实时拖拽彻底失效(已实测证实)。
    private func appCell(_ app: AppItem) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
            Text(app.displayName)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 100)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(
            // 键盘高亮:圆角浅底,与原生选中态一致
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(app.id == state.highlightedAppID ? 0.14 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { launch(app) }
        .contextMenu { appContextMenu(app) }
    }

    // MARK: - 页码圆点

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(displayPages.indices, id: \.self) { index in
                Circle()
                    .fill(index == state.currentPage
                          ? Color.primary.opacity(0.85)
                          : Color.primary.opacity(0.25))
                    .frame(width: 7, height: 7)
                    .contentShape(Circle().scale(2.2))   // 扩大点击热区
                    .onTapGesture {
                        state.highlightedAppID = nil     // 手动跳页,旧高亮失效
                        state.currentPage = index
                    }
            }
        }
        .padding(.bottom, 26)
    }

    // MARK: - 搜索结果(扁平网格)

    private var searchResults: some View {
        Group {
            if filtered.isEmpty {
                // 无结果时给出明确反馈,避免整片空白看起来像应用全部消失
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("未找到“\(state.effectiveQuery)”")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ScrollViewReader:键盘高亮移动时自动滚动到可见区域中央(功能清单要求)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 30) {
                            ForEach(filtered) { app in
                                appCell(app).id(app.id)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.bottom, 60)
                    }
                    .onChange(of: state.highlightedAppID) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func launch(_ app: AppItem) {
        NSWorkspace.shared.open(app.url)
        dismiss()
    }
}

/// 应用简介面板:图标、名称、版本、Bundle ID、大小、修改日期、位置。
struct AppInfoPanel: View {
    let app: AppItem
    @Environment(\.dismiss) private var dismissSheet
    @State private var sizeText = "计算中…"

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            Text(app.displayName)
                .font(.title3.weight(.semibold))
            if app.alias != nil {
                Text("原名:\(app.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 8) {
                infoRow("版本", AppActions.versionString(of: app.url) ?? "—")
                infoRow("Bundle ID", app.bundleID ?? "—")
                infoRow("大小", sizeText)
                infoRow("修改日期", AppActions.modifiedDate(of: app.url)
                    .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                infoRow("位置", app.url.deletingLastPathComponent().path)
            }

            Divider()

            HStack {
                Spacer()
                Button("关闭") { dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .task {
            // 目录遍历较慢,后台计算
            let bytes = await Task.detached(priority: .utility) {
                AppActions.size(of: app.url)
            }.value
            sizeText = AppActions.formatBytes(bytes)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
    }
}
