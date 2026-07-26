import SwiftUI
import AppKit

struct ContentView: View {
    let dismiss: () -> Void
    @ObservedObject private var state = AppState.shared
    @State private var apps: [AppItem] = []
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 28)]

    private var filtered: [AppItem] {
        guard !state.query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(state.query) }
    }

    var body: some View {
        VStack(spacing: 24) {
            TextField("搜索应用…", text: $state.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 460)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 52)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 30) {
                    ForEach(filtered) { app in
                        Button {
                            launch(app)
                        } label: {
                            VStack(spacing: 8) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 72, height: 72)
                                Text(app.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 100)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }   // 点击空白区域关闭(图标与搜索框会自行消费点击)
        .onAppear {
            apps = AppScanner.scan()
            // 显示后自动聚焦搜索框:无需点击,输入即搜
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
    }

    private func launch(_ app: AppItem) {
        NSWorkspace.shared.open(app.url)
        dismiss()
    }
}
