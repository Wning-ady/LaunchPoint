import SwiftUI
import AppKit

struct ContentView: View {
    @State private var apps: [AppItem] = []
    @State private var query: String = ""

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 28)]

    private var filtered: [AppItem] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 24) {
            TextField("搜索应用…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 460)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 36)

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
                .padding(.horizontal, 44)
                .padding(.bottom, 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .onAppear { apps = AppScanner.scan() }
    }

    private func launch(_ app: AppItem) {
        NSWorkspace.shared.open(app.url)
        NSApp.hide(nil)
    }
}
