import AppKit

/// A single launchable application discovered on disk.
struct AppItem: Identifiable {
    let id: String          // absolute path, also used for de-duplication
    let name: String        // display name without the ".app" suffix
    let url: URL
    let icon: NSImage
    let bundleID: String?
    var alias: String?      // 用户自定义别名(来自布局存储)

    /// 界面显示名:有别名用别名,否则用默认名。
    var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        return name
    }
}

/// Scans application directories for installed apps.
enum AppScanner {
    private static let iconCache = NSCache<NSString, NSImage>()
    private static let maximumSearchDepth = 5

    static let defaultSearchDirs: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        (("~/Applications") as NSString).expandingTildeInPath,
    ]

    /// Returns every `.app` found in the given source directories, sorted by name.
    static func scan(sources: [String] = defaultSearchDirs) -> [AppItem] {
        let fm = FileManager.default
        let workspace = NSWorkspace.shared
        var seen = Set<String>()
        var items: [AppItem] = []

        for dir in compactSearchRoots(sources) {
            let rootURL = URL(fileURLWithPath: dir, isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let isApplication = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                guard isApplication else {
                    if enumerator.level >= maximumSearchDepth {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                enumerator.skipDescendants()

                let fullPath = url.standardizedFileURL.path
                guard seen.insert(fullPath).inserted else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let cacheKey = fullPath as NSString
                let icon: NSImage
                if let cached = iconCache.object(forKey: cacheKey) {
                    icon = cached
                } else {
                    icon = workspace.icon(forFile: fullPath)
                    icon.size = NSSize(width: 160, height: 160)
                    iconCache.setObject(icon, forKey: cacheKey)
                }
                items.append(
                    AppItem(id: fullPath,
                            name: name,
                            url: url,
                            icon: icon,
                            bundleID: Bundle(url: url)?.bundleIdentifier,
                            alias: nil)
                )
            }
        }

        return items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Drop duplicate roots and roots already covered by an enabled parent.
    /// This keeps recursive scanning cheap when both /Applications and one of
    /// its subdirectories are present in an older saved source list.
    private static func compactSearchRoots(_ sources: [String]) -> [String] {
        let roots = Set(sources.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                isDirectory: true).standardizedFileURL.path
        }).sorted { lhs, rhs in
            if lhs.count == rhs.count { return lhs < rhs }
            return lhs.count < rhs.count
        }

        var result: [String] = []
        for root in roots {
            let covered = result.contains { parent in
                root == parent || root.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
            }
            if !covered { result.append(root) }
        }
        return result
    }
}
