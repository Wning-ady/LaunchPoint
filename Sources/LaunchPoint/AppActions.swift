import AppKit

/// 应用级操作:添加到程序坞、简介信息、卸载(含残留清理)。
enum AppActions {

    /// Opens app bundles normally. Standalone executable files are handed to
    /// Terminal so shell scripts retain an interactive session for output and
    /// privilege prompts instead of being treated as documents by Finder.
    static func launch(_ url: URL) {
        if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            NSWorkspace.shared.open(url)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", "--", url.path]
        try? task.run()
    }

    // MARK: - 添加到程序坞

    /// 把应用加入 Dock 的 persistent-apps 并重启 Dock 生效。
    /// 已在坞中则不重复添加。返回是否实际添加。
    @discardableResult
    static func addToDock(_ url: URL) -> Bool {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString

        var apps = (CFPreferencesCopyAppValue(key, domain) as? [[String: Any]]) ?? []

        // 与系统一致:目录型 file:// URL(带尾斜杠),实测 Dock 存的即此格式
        let urlString = URL(fileURLWithPath: url.path, isDirectory: true).absoluteString
        let targetPath = normalizedPath(url.path)
        let alreadyExists = apps.contains { entryPath($0) == targetPath }
        guard !alreadyExists else { return false }

        // 与系统 Dock 相同的条目结构(_CFURLStringType 15 = file:// URL)
        apps.append(["tile-data": ["file-data": ["_CFURLString": urlString,
                                                 "_CFURLStringType": 15]]])
        CFPreferencesSetAppValue(key, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        restartDock()
        return true
    }

    /// 从程序坞移除应用条目(卸载后清理)。返回是否实际移除。
    @discardableResult
    static func removeFromDock(_ url: URL) -> Bool {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        guard let apps = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else {
            return false
        }
        let targetPath = normalizedPath(url.path)
        let remaining = apps.filter { entryPath($0) != targetPath }
        guard remaining.count != apps.count else { return false }

        CFPreferencesSetAppValue(key, remaining as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        restartDock()
        return true
    }

    /// 解析 Dock 条目里的应用路径(_CFURLString 可能是 file:// URL 或纯路径,可能带尾斜杠/编码)。
    private static func entryPath(_ entry: [String: Any]) -> String {
        let stored = (((entry["tile-data"] as? [String: Any])?["file-data"]
                        as? [String: Any])?["_CFURLString"] as? String) ?? ""
        if stored.hasPrefix("file://"), let parsed = URL(string: stored) {
            return normalizedPath(parsed.path)
        }
        return normalizedPath(stored)
    }

    /// 去掉尾斜杠的规范路径。
    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// 重启 Dock 使配置生效。
    private static func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }

    // MARK: - 简介信息

    /// 版本字符串,如 "2.1.0 (345)"。
    static func versionString(of url: URL) -> String? {
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (version, build) {
        case let (v?, b?) where v != b: return "\(v) (\(b))"
        case let (v?, _): return v
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// 修改日期。
    static func modifiedDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 目录占用大小(字节)。遍历较慢,务必在后台线程调用。
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey,
                                                                          .fileAllocatedSizeKey],
                                             options: [],
                                             errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                            .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 卸载

    /// 应用的用户级残留数据路径。严格按 bundleID 精确匹配,宁缺毋滥。
    static func residualPaths(bundleID: String?) -> [URL] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let candidates = [
            "Application Support/\(bundleID)",
            "Caches/\(bundleID)",
            "Preferences/\(bundleID).plist",
            "Logs/\(bundleID)",
            "Saved Application State/\(bundleID).savedState",
            "HTTPStorages/\(bundleID)",
            "WebKit/\(bundleID)",
            "Containers/\(bundleID)",
        ].map { library.appendingPathComponent($0) }
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 卸载:应用本体与残留数据全部移入废纸篓(可从废纸篓恢复)。
    /// 直接搬移权限不足时(root 所有 / App 管理保护),退回让 Finder 代为删除——
    /// Finder 有 App 管理权限,必要时会弹它自己的管理员认证。
    /// 后台执行;`beforeFinderFallback` 在退回 Finder 前于主线程调用(用于收起全屏覆盖层,
    /// 否则 Finder 的认证弹窗会被挡住);`completion` 主线程回调,参数为错误描述(nil = 成功)。
    static func uninstall(appURL: URL, bundleID: String?,
                          beforeFinderFallback: @escaping () -> Void,
                          completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorMessage: String?
            do {
                try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
            } catch {
                DispatchQueue.main.sync { beforeFinderFallback() }
                if !finderTrash(appURL) {
                    errorMessage = """
                    无法移除“\(appURL.deletingPathExtension().lastPathComponent)”:权限不足,\
                    且 Finder 代删被拒或被取消。
                    可在 Finder 中手动将其移到废纸篓;若从未弹出过授权窗口,\
                    请在 系统设置 → 隐私与安全性 → 自动化 中允许本应用控制 Finder 后重试。
                    """
                }
            }
            if errorMessage == nil {
                for residual in residualPaths(bundleID: bundleID) {
                    try? FileManager.default.trashItem(at: residual, resultingItemURL: nil)
                }
                // 程序坞里若还挂着该应用,一并移除(否则留下"在废纸篓中"的死图标)
                removeFromDock(appURL)
            }
            DispatchQueue.main.async { completion(errorMessage) }
        }
    }

    /// 让 Finder 把文件移到废纸篓(经 osascript 子进程,避免阻塞主线程;
    /// 首次调用会触发系统"控制 Finder"授权询问)。
    private static func finderTrash(_ url: URL) -> Bool {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return false }
        // Finder 返回成功后确认文件确实已不在原位
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
