import SwiftUI
import AppKit

/// 网格槽位标识:第 page 页第 slot 格。
struct SlotKey: Hashable {
    let page: Int
    let slot: Int
}

/// 收集单元格尺寸(只取高度用于行距推算;水平几何用纯数学,不依赖测量)。
struct CellSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
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

    // MARK: 拖拽排序状态
    @State private var draggingApp: AppItem?
    @State private var dragLocation: CGPoint = .zero       // "pagingArea" 坐标
    @State private var previewPages: [[AppItem]]?          // 拖拽中的预览布局
    @State private var previewTarget: SlotKey?
    @State private var containerWidth: CGFloat = 0         // 分页容器宽度(即页宽)
    @State private var cellHeight: CGFloat = 120           // 单元格高度(测量,供行距推算)
    @State private var edgeFlipWork: DispatchWorkItem?

    /// 分页与搜索结果共用固定列数:键盘导航需要确定的网格几何。
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.colSpacing),
              count: LayoutStore.columns)
    }

    /// 展示用页面:拖拽时用预览布局,并在末尾提供一个空承接页。
    private var displayPages: [[AppItem]] {
        if let previewPages { return previewPages }
        var pages = store.pages
        if draggingApp != nil { pages.append([]) }
        return pages
    }

    /// 搜索结果:前缀/词首/首字母/缩写/拼音多路匹配,按匹配度排序。
    private var filtered: [AppItem] {
        SearchEngine.rank(state.effectiveQuery, in: store.items)
    }

    var body: some View {
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
                        pageView(displayPages[pageIndex], pageIndex: pageIndex)
                            .frame(width: width, height: geo.size.height, alignment: .top)
                    }
                }
                // 拖拽位移实时叠加到页面偏移上,还原跟手感
                .offset(x: -CGFloat(state.currentPage) * width + pageSwipeOffset)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.currentPage)
                .gesture(pageSwipeGesture(width: width))

                // 跟随指针的浮动图标(拖拽中)
                if let app = draggingApp {
                    floatingIcon(app)
                        .position(dragLocation)
                        .allowsHitTesting(false)
                        .zIndex(10)
                }
            }
            .coordinateSpace(name: "pagingArea")         // 指针/浮动图标用:静止坐标系
            .onAppear { containerWidth = width }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
            .onPreferenceChange(CellSizeKey.self) { size in
                if size.height > 0 { cellHeight = size.height }
            }
        }
        .clipped()
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

    private func pageView(_ apps: [AppItem], pageIndex: Int) -> some View {
        LazyVGrid(columns: gridColumns, spacing: Self.rowSpacing) {
            ForEach(apps) { app in
                appCell(app)
                    // 拖拽中的应用在预览槽位处半透明显示,作为落点指示
                    .opacity(app.id == draggingApp?.id ? 0.35 : 1)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: CellSizeKey.self, value: g.size)
                        }
                    )
                    .gesture(iconDragGesture(app))
            }
        }
        .padding(.horizontal, Self.hPadding)
        .padding(.top, Self.gridTop)
    }

    // MARK: - 图标拖拽排序

    private func iconDragGesture(_ app: AppItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("pagingArea"))
            .onChanged { value in
                guard state.effectiveQuery.isEmpty else { return }   // 搜索态不排序
                dragChanged(app, value)
            }
            .onEnded { _ in
                commitDrag()
            }
    }

    private func dragChanged(_ app: AppItem, _ value: DragGesture.Value) {
        guard !AppState.shared.dragInhibited else { return }   // 本次按住已被 Esc 取消
        if draggingApp == nil {
            draggingApp = app
            AppState.shared.isDragging = true
        }
        dragLocation = value.location
        evaluateDragTarget()
        handleEdgeHover()
    }

    /// 由指针位置(pagingArea 坐标)+ 当前页码推算落点并刷新预览。
    /// 纯数学推导,不依赖运行时测量的水平几何,翻页动画/空页都不影响正确性。
    private func evaluateDragTarget() {
        guard let app = draggingApp, containerWidth > 0 else { return }
        let width = containerWidth
        let contentX = dragLocation.x + CGFloat(state.currentPage) * width
        var pageIndex = Int(floor(contentX / width))
        pageIndex = min(max(pageIndex, 0), store.pages.count)   // 末尾允许承接新页
        let xInPage = contentX - CGFloat(pageIndex) * width
        let slot = insertionSlot(xInPage: xInPage, y: dragLocation.y)
        let target = SlotKey(page: pageIndex, slot: slot)
        if target != previewTarget {
            updatePreview(app: app, target: target)
        }
    }

    /// 网格插入槽位:列宽由容器宽度与固定边距推出;行距由测得的单元格高度推出。
    /// 指针越过某格中心 → 插到其后。
    private func insertionSlot(xInPage: CGFloat, y: CGFloat) -> Int {
        let cols = LayoutStore.columns
        let colWidth = (containerWidth - 2 * Self.hPadding
                        - CGFloat(cols - 1) * Self.colSpacing) / CGFloat(cols)
        let pitch = colWidth + Self.colSpacing

        let xInGrid = xInPage - Self.hPadding
        // 已越过多少个格心 = 行内插入位
        var col = Int(floor((xInGrid - colWidth / 2) / pitch)) + 1
        col = min(max(col, 0), cols)

        let rowPitch = cellHeight + Self.rowSpacing
        var row = Int(floor((y - Self.gridTop) / rowPitch))
        row = min(max(row, 0), LayoutStore.rows - 1)

        return row * cols + col
    }

    /// 生成预览布局:被拖应用移除后插入目标槽位;超容的页向后级联溢出(与落盘规则一致)。
    private func updatePreview(app: AppItem, target: SlotKey) {
        var base = store.pages
        base.append([])   // 承接新页
        for i in base.indices {
            base[i].removeAll { $0.id == app.id }
        }
        let p = min(target.page, base.count - 1)
        let s = min(max(target.slot, 0), base[p].count)
        base[p].insert(app, at: s)

        // 级联溢出:插入导致超容的页,把队尾挤到下一页开头(与 normalizeCapacity 行为一致)
        var i = p
        while base[i].count > LayoutStore.capacity {
            let spilled = base[i].removeLast()
            if i + 1 >= base.count { base.append([]) }
            base[i + 1].insert(spilled, at: 0)
            i += 1
        }

        previewTarget = SlotKey(page: p, slot: s)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            previewPages = base
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
            guard draggingApp != nil else { return }
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
        if let app = draggingApp, let target = previewTarget {
            store.moveApp(app.id, toPage: target.page, slot: target.slot)
        }
        finishDrag()
    }

    /// 结束/取消拖拽:清空拖拽状态;未落盘的预览弹回真实布局;页码防越界(承接页可能消失)。
    private func finishDrag() {
        edgeFlipWork?.cancel()
        edgeFlipWork = nil
        draggingApp = nil
        previewTarget = nil
        AppState.shared.isDragging = false
        state.currentPage = min(state.currentPage, max(0, store.pages.count - 1))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            previewPages = nil
        }
    }

    private func floatingIcon(_ app: AppItem) -> some View {
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
