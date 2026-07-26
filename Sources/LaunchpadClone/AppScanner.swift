import AppKit

/// A single launchable application discovered on disk.
struct AppItem: Identifiable {
    let id: String          // absolute path, also used for de-duplication
    let name: String        // display name without the ".app" suffix
    let url: URL
    let icon: NSImage
}

/// Scans the standard macOS application directories for installed apps.
enum AppScanner {
    private static let searchDirs: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        (("~/Applications") as NSString).expandingTildeInPath,
    ]

    /// Returns every `.app` found in the search directories, sorted by name.
    static func scan() -> [AppItem] {
        let fm = FileManager.default
        let workspace = NSWorkspace.shared
        var seen = Set<String>()
        var items: [AppItem] = []

        for dir in searchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let fullPath = dir + "/" + entry
                guard seen.insert(fullPath).inserted else { continue }
                let name = String(entry.dropLast(4))
                let icon = workspace.icon(forFile: fullPath)
                icon.size = NSSize(width: 72, height: 72)
                items.append(
                    AppItem(id: fullPath,
                            name: name,
                            url: URL(fileURLWithPath: fullPath),
                            icon: icon)
                )
            }
        }

        return items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
