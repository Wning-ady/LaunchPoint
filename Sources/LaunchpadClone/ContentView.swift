import SwiftUI
import AppKit

struct ContentView: View {
    let dismiss: () -> Void
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var store = LayoutStore.shared
    @FocusState private var searchFocused: Bool
    @GestureState private var dragOffset: CGFloat = 0

    private let searchColumns = [GridItem(.adaptive(minimum: 110), spacing: 28)]
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: LayoutStore.columns)
    }

    /// 搜索结果:显示名(别名优先)与默认名双路匹配。
    private var filtered: [AppItem] {
        store.items.filter {
            $0.displayName.localizedCaseInsensitiveContains(state.query)
                || $0.name.localizedCaseInsensitiveContains(state.query)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            searchField

            if state.query.isEmpty {
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
                // 搜索后按回车直接打开第一个结果
                if !state.query.isEmpty, let first = filtered.first {
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
                    .onTapGesture { state.currentPage = index }
            }
        }
        .padding(.bottom, 26)
    }

    // MARK: - 搜索结果(扁平网格)

    private var searchResults: some View {
        ScrollView {
            LazyVGrid(columns: searchColumns, spacing: 30) {
                ForEach(filtered) { app in
                    appCell(app)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
    }

    private func launch(_ app: AppItem) {
        NSWorkspace.shared.open(app.url)
        dismiss()
    }
}
