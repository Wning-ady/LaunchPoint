import SwiftUI
import AppKit

struct ContentView: View {
    let dismiss: () -> Void
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var store = LayoutStore.shared
    @FocusState private var searchFocused: Bool
    @GestureState private var dragOffset: CGFloat = 0

    /// 分页与搜索结果共用固定列数:键盘导航需要确定的网格几何。
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: LayoutStore.columns)
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
        // 页数变化时防止停留在已不存在的页
        .onChange(of: store.pages.count) { _, count in
            state.currentPage = min(state.currentPage, max(0, count - 1))
        }
        // 有效查询变化时重置键盘高亮(结果集变了,旧高亮无意义);
        // 只比较去空白后的值:分页模式误触空格不应清掉高亮
        .onChange(of: state.query) { old, new in
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

    // MARK: - 分页网格(横向翻页 + 跟手拖拽)

    private var pagedGrid: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ForEach(store.pages.indices, id: \.self) { index in
                    pageView(store.pages[index])
                        .frame(width: width, height: geo.size.height, alignment: .top)
                }
            }
            // 拖拽位移实时叠加到页面偏移上,还原跟手感
            .offset(x: -CGFloat(state.currentPage) * width + dragOffset)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.currentPage)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .updating($dragOffset) { value, offset, _ in
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
            )
        }
        .clipped()
    }

    private func pageView(_ apps: [AppItem]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 26) {
            ForEach(apps) { app in
                appCell(app)
            }
        }
        .padding(.horizontal, 70)
        .padding(.top, 20)
    }

    private func appCell(_ app: AppItem) -> some View {
        Button {
            launch(app)
        } label: {
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
        }
        .buttonStyle(.plain)
    }

    // MARK: - 页码圆点

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(store.pages.indices, id: \.self) { index in
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
