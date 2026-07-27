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

        for dir in sources {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let fullPath = dir + "/" + entry
                guard seen.insert(fullPath).inserted else { continue }
                let name = String(entry.dropLast(4))
                let url = URL(fileURLWithPath: fullPath)
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
}
