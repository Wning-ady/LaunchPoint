import AppKit

/// 应用级操作:添加到程序坞、简介信息、卸载(含残留清理)。
enum AppActions {

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
        let path = url.path
        let alreadyExists = apps.contains { entry in
            let stored = (((entry["tile-data"] as? [String: Any])?["file-data"]
                            as? [String: Any])?["_CFURLString"] as? String) ?? ""
            return stored == urlString || stored == path || stored == path + "/"
                || stored == urlString + "/"
        }
        guard !alreadyExists else { return false }

        // 与系统 Dock 相同的条目结构(_CFURLStringType 15 = file:// URL)
        apps.append(["tile-data": ["file-data": ["_CFURLString": urlString,
                                                 "_CFURLStringType": 15]]])
        CFPreferencesSetAppValue(key, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)

        // 重启 Dock 使配置生效
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
        return true
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
    /// 返回错误描述;nil = 成功。残留清理失败不阻断主流程。
    static func uninstall(appURL: URL, bundleID: String?) -> String? {
        do {
            try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
        } catch {
            return "无法移除应用:\(error.localizedDescription)"
        }
        for residual in residualPaths(bundleID: bundleID) {
            try? FileManager.default.trashItem(at: residual, resultingItemURL: nil)
        }
        return nil
    }
}
