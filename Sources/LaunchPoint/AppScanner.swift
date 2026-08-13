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

    /// Returns app bundles plus explicitly selected executables, sorted by name.
    static func scan(sources: [String] = defaultSearchDirs,
                     customPaths: [String] = []) -> [AppItem] {
        let fm = FileManager.default
        let workspace = NSWorkspace.shared
        var seen = Set<String>()
        var items: [AppItem] = []

        func appendItem(_ url: URL) {
            let normalizedURL = url.standardizedFileURL
            let fullPath = normalizedURL.path
            guard seen.insert(fullPath).inserted else { return }

            let name = localizedDisplayName(for: normalizedURL)
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
                        url: normalizedURL,
                        icon: icon,
                        bundleID: Bundle(url: normalizedURL)?.bundleIdentifier,
                        alias: nil)
            )
        }

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
                if isApplication {
                    enumerator.skipDescendants()
                    appendItem(url)
                    continue
                }

                // A few utility apps, including Adobe maintenance scripts, are
                // installed as executable files directly in /Applications.
                if url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL,
                   isLaunchable(url) {
                    appendItem(url)
                }
                if enumerator.level >= maximumSearchDepth {
                    enumerator.skipDescendants()
                }
            }
        }

        for path in customPaths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if isLaunchable(url) { appendItem(url) }
        }

        return items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Prefer the same localized name Finder shows for app bundles, then fall
    /// back through bundle metadata and finally the file name. This keeps
    /// built-in apps aligned with the current macOS language.
    private static func localizedDisplayName(for url: URL) -> String {
        let isApplication = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame

        func cleaned(_ rawName: String?) -> String? {
            guard var name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            if isApplication, name.lowercased().hasSuffix(".app") {
                name = String(name.dropLast(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return name.isEmpty ? nil : name
        }

        let finderName = cleaned(FileManager.default.displayName(atPath: url.path))
        guard isApplication else {
            return finderName ?? url.deletingPathExtension().lastPathComponent
        }

        let bundle = Bundle(url: url)
        let localizedInfo = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary
        let candidates = [
            finderName,
            cleaned(localizedInfo?["CFBundleDisplayName"] as? String),
            cleaned(localizedInfo?["CFBundleName"] as? String),
            cleaned(info?["CFBundleDisplayName"] as? String),
            cleaned(info?["CFBundleName"] as? String),
            cleaned(url.deletingPathExtension().lastPathComponent),
        ]
        return candidates.compactMap { $0 }.first
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func isLaunchable(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return FileManager.default.fileExists(atPath: url.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
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
