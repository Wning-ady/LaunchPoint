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
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
    private static let maximumSearchDepth = 5
    private static let iconDisplaySize = NSSize(width: 160, height: 160)

    private struct IconDescriptor {
        let cacheKey: NSString
        let resourceURL: URL?
    }

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
            let descriptor = iconDescriptor(for: normalizedURL)
            let icon: NSImage
            if let cached = iconCache.object(forKey: descriptor.cacheKey) {
                icon = cached
            } else {
                let loaded = descriptor.resourceURL.flatMap(NSImage.init(contentsOf:))
                    ?? workspace.icon(forFile: fullPath)
                icon = (loaded.copy() as? NSImage) ?? loaded
                icon.size = iconDisplaySize
                iconCache.setObject(icon, forKey: descriptor.cacheKey)
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

    /// Build a cache key from the files that can change during an in-place update.
    /// A path-only cache otherwise keeps the old/generic icon forever after reinstalling.
    private static func iconDescriptor(for url: URL) -> IconDescriptor {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return IconDescriptor(cacheKey: fileFingerprint([url]), resourceURL: nil)
        }

        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contents.appendingPathComponent("Info.plist")
        let resourcesURL = contents.appendingPathComponent("Resources", isDirectory: true)
        let info = infoDictionary(at: infoURL)
        let iconURL = applicationIconURL(
            appURL: url,
            resourcesURL: resourcesURL,
            info: info
        )
        let executableURL = (info?["CFBundleExecutable"] as? String).map {
            contents.appendingPathComponent("MacOS", isDirectory: true).appendingPathComponent($0)
        }
        let assetsURL = resourcesURL.appendingPathComponent("Assets.car")
        let fingerprinted = [url, infoURL, resourcesURL, executableURL, iconURL, assetsURL]
            .compactMap { $0 }
        return IconDescriptor(
            cacheKey: fileFingerprint(fingerprinted),
            resourceURL: iconURL
        )
    }

    private static func infoDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    /// Prefer the app's declared icon resource. If a package declares a missing
    /// extension (for example .png while only the same-name .icns exists), try
    /// the sibling resource before falling back to NSWorkspace's generic icon.
    private static func applicationIconURL(appURL: URL,
                                           resourcesURL: URL,
                                           info: [String: Any]?) -> URL? {
        var declaredNames: [String] = []
        for key in ["CFBundleIconFile", "CFBundleIconName"] {
            if let value = info?[key] as? String { declaredNames.append(value) }
        }
        declaredNames.append(contentsOf: info?["CFBundleIconFiles"] as? [String] ?? [])
        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            declaredNames.append(contentsOf: primary["CFBundleIconFiles"] as? [String] ?? [])
        }

        var candidates: [URL] = []
        for rawName in declaredNames {
            let name = (rawName as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let declared = resourcesURL.appendingPathComponent(name)
            candidates.append(declared)
            if declared.pathExtension.isEmpty {
                candidates.append(declared.appendingPathExtension("icns"))
                candidates.append(declared.appendingPathExtension("png"))
            } else {
                let base = declared.deletingPathExtension()
                candidates.append(base.appendingPathExtension("icns"))
                candidates.append(base.appendingPathExtension("png"))
            }
        }
        if let existing = firstReadableImage(in: candidates) { return existing }

        guard let resources = try? FileManager.default.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let icnsFiles = resources.filter {
            $0.pathExtension.caseInsensitiveCompare("icns") == .orderedSame
        }
        if icnsFiles.count == 1 { return icnsFiles[0] }

        let preferredBaseNames = Set([
            "appicon",
            "icon",
            appURL.deletingPathExtension().lastPathComponent.lowercased(),
            (info?["CFBundleExecutable"] as? String)?.lowercased() ?? "",
        ])
        return icnsFiles.first {
            preferredBaseNames.contains($0.deletingPathExtension().lastPathComponent.lowercased())
        }
    }

    private static func firstReadableImage(in candidates: [URL]) -> URL? {
        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return FileManager.default.isReadableFile(atPath: path)
                && NSImage(contentsOf: candidate) != nil
        }
    }

    private static func fileFingerprint(_ urls: [URL]) -> NSString {
        var components: [String] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            components.append(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                components.append("missing")
                continue
            }
            let modified = (attributes[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? 0
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            components.append("\(modified):\(size)")
        }
        return components.joined(separator: "|") as NSString
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
