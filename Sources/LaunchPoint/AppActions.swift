import AppKit
import Security

/// 应用级操作:添加到程序坞、简介信息、卸载(含残留清理)。
enum AppActions {

    /// Opens app bundles normally. Standalone executable files are handed to
    /// Terminal so shell scripts retain an interactive session for output and
    /// privilege prompts instead of being treated as documents by Finder.
    static func launch(_ url: URL) {
        if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: configuration,
                                               completionHandler: nil)
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
    static func removeFromDock(_ url: URL, bundleID: String? = nil) -> Bool {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        guard let apps = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else {
            return false
        }
        let targetPath = normalizedPath(url.path)
        let remaining = apps.filter { entry in
            let matchesPath = entryPath(entry) == targetPath
            let matchesBundleID = bundleID.map { id in entryBundleIdentifier(entry) == id } ?? false
            return !matchesPath && !matchesBundleID
        }
        guard remaining.count != apps.count else { return false }

        CFPreferencesSetAppValue(key, remaining as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        restartDock(waitForExit: true)
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

    private static func entryBundleIdentifier(_ entry: [String: Any]) -> String? {
        (((entry["tile-data"] as? [String: Any])?["bundle-identifier"]) as? String)
    }

    /// 去掉尾斜杠的规范路径。
    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// 重启 Dock 使配置生效。
    private static func restartDock(waitForExit: Bool = false) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        if waitForExit { task.waitUntilExit() }
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

    private struct UninstallMetadata {
        var bundleIDs = Set<String>()
        var groupContainerIDs = Set<String>()
        var iCloudContainerIDs = Set<String>()
        var appNames = Set<String>()
        var processNames = Set<String>()
    }

    /// 返回应用及其内嵌扩展的用户级关联数据。卸载前读取签名权限，才能识别
    /// Widget/Share Extension、App Group 与 iCloud 容器；应用包被移走后这些信息就丢失了。
    static func residualPaths(appURL: URL? = nil, bundleID: String?) -> [URL] {
        let metadata = uninstallMetadata(appURL: appURL, fallbackBundleID: bundleID)
        return residualPaths(metadata: metadata)
    }

    /// Use the metadata snapshot captured before the app bundle is moved. A
    /// sandbox container or helper can be recreated briefly while the app is
    /// quitting, so later cleanup passes must not depend on the bundle still
    /// being present at its original path.
    private static func residualPaths(metadata: UninstallMetadata) -> [URL] {
        guard !metadata.bundleIDs.isEmpty || !metadata.appNames.isEmpty else { return [] }

        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let systemLibrary = URL(fileURLWithPath: "/Library", isDirectory: true)
        var candidates = Set<URL>()

        func add(_ relativePath: String) {
            candidates.insert(library.appendingPathComponent(relativePath).standardizedFileURL)
        }

        func addSystem(_ relativePath: String) {
            candidates.insert(systemLibrary.appendingPathComponent(relativePath).standardizedFileURL)
        }

        for identifier in metadata.bundleIDs where isSafePathComponent(identifier) {
            [
                "Application Support/\(identifier)",
                "Caches/\(identifier)",
                "Preferences/\(identifier).plist",
                "Logs/\(identifier)",
                "Saved Application State/\(identifier).savedState",
                "HTTPStorages/\(identifier)",
                "WebKit/\(identifier)",
                "Containers/\(identifier)",
                "Application Scripts/\(identifier)",
                "Cookies/\(identifier).binarycookies",
                "LaunchAgents/\(identifier).plist",
            ].forEach(add)

            // Privileged helpers and system launch services live outside the
            // user's Library. Only exact identifier paths are considered.
            [
                "Application Support/\(identifier)",
                "LaunchAgents/\(identifier).plist",
                "LaunchDaemons/\(identifier).plist",
                "PrivilegedHelperTools/\(identifier)",
            ].forEach(addSystem)

            // Helpers, widgets and older versions sometimes leave descendants
            // such as com.vendor.App.helper even when that nested bundle is no
            // longer shipped. Match only the complete bundle ID boundary so a
            // similarly named sibling app (for example App2) is not selected.
            for root in [
                "Application Support", "Caches", "Preferences", "Logs",
                "Saved Application State", "HTTPStorages", "WebKit",
                "Containers", "Application Scripts", "Cookies",
                "LaunchAgents", "SyncedPreferences",
            ] {
                addChildren(
                    of: library.appendingPathComponent(root, isDirectory: true),
                    to: &candidates
                ) { artifactName($0, matchesBundleID: identifier) }
            }
            for root in [
                "Application Support", "Caches", "Preferences", "Logs",
                "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools",
            ] {
                addChildren(
                    of: systemLibrary.appendingPathComponent(root, isDirectory: true),
                    to: &candidates
                ) { artifactName($0, matchesBundleID: identifier) }
            }

            // cfprefsd may create a host-specific preference alongside the main plist.
            let byHost = library.appendingPathComponent("Preferences/ByHost", isDirectory: true)
            addChildren(of: byHost, to: &candidates) { name in
                let lowered = name.lowercased()
                return lowered.hasPrefix(identifier.lowercased() + ".")
                    && lowered.hasSuffix(".plist")
            }
        }

        // A small number of non-sandboxed apps use their product name instead of bundle ID.
        for name in metadata.appNames where isSafePathComponent(name) && name.count >= 3 {
            [
                "Application Support/\(name)",
                "Caches/\(name)",
                "Preferences/\(name).plist",
                "Logs/\(name)",
                "HTTPStorages/\(name)",
                "WebKit/\(name)",
                "Saved Application State/\(name).savedState",
                "LaunchAgents/\(name).plist",
            ].forEach(add)

            [
                "Application Support/\(name)",
                "LaunchAgents/\(name).plist",
                "LaunchDaemons/\(name).plist",
                "PrivilegedHelperTools/\(name)",
            ].forEach(addSystem)

            let diagnosticReports = library.appendingPathComponent(
                "Logs/DiagnosticReports", isDirectory: true
            )
            addChildren(of: diagnosticReports, to: &candidates) { artifact in
                let lowered = artifact.lowercased()
                let loweredName = name.lowercased()
                return lowered.hasPrefix(loweredName + "_")
                    || lowered.hasPrefix(loweredName + "-")
            }

            let crashReporter = library.appendingPathComponent(
                "Application Support/CrashReporter", isDirectory: true
            )
            addChildren(of: crashReporter, to: &candidates) { artifact in
                let lowered = artifact.lowercased()
                let loweredName = name.lowercased()
                return lowered.hasPrefix(loweredName + "_")
                    || lowered.hasPrefix(loweredName + ".")
            }
        }

        for identifier in metadata.groupContainerIDs where isSafePathComponent(identifier) {
            add("Group Containers/\(identifier)")
            add("Application Scripts/\(identifier)")
        }
        for identifier in metadata.iCloudContainerIDs where isSafePathComponent(identifier) {
            let directoryName = identifier.replacingOccurrences(of: ".", with: "~")
            add("Mobile Documents/\(directoryName)")
        }

        // Some older/ad-hoc signed apps do not expose entitlements through Security.framework.
        // Exact bundle-ID suffix matching recovers their App Group/iCloud paths without broad scans.
        for identifier in metadata.bundleIDs {
            let loweredID = identifier.lowercased()
            let groupRoot = library.appendingPathComponent("Group Containers", isDirectory: true)
            addChildren(of: groupRoot, to: &candidates) { name in
                name.lowercased().hasSuffix("." + loweredID)
            }
            let scriptsRoot = library.appendingPathComponent("Application Scripts", isDirectory: true)
            addChildren(of: scriptsRoot, to: &candidates) { name in
                let lowered = name.lowercased()
                return lowered == loweredID || lowered.hasSuffix("." + loweredID)
            }
            let cloudSuffix = "~" + loweredID.replacingOccurrences(of: ".", with: "~")
            let mobileDocuments = library.appendingPathComponent("Mobile Documents", isDirectory: true)
            addChildren(of: mobileDocuments, to: &candidates) { name in
                name.lowercased().hasSuffix(cloudSuffix)
            }
        }

        return candidates
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func uninstallMetadata(appURL: URL?, fallbackBundleID: String?) -> UninstallMetadata {
        var metadata = UninstallMetadata()
        if let fallbackBundleID, !fallbackBundleID.isEmpty {
            metadata.bundleIDs.insert(fallbackBundleID)
        }
        guard let appURL,
              appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return metadata
        }

        var bundleURLs = [appURL]
        if let enumerator = FileManager.default.enumerator(
            at: appURL.appendingPathComponent("Contents", isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) {
            while let url = enumerator.nextObject() as? URL {
                let ext = url.pathExtension.lowercased()
                if ext == "app" || ext == "appex" || ext == "xpc" {
                    bundleURLs.append(url)
                    enumerator.skipDescendants()
                }
            }
        }

        for url in bundleURLs {
            if let bundle = Bundle(url: url) {
                if let identifier = bundle.bundleIdentifier, !identifier.isEmpty {
                    metadata.bundleIDs.insert(identifier)
                }
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = bundle.object(forInfoDictionaryKey: key) as? String,
                       !name.isEmpty {
                        metadata.appNames.insert(name)
                    }
                }
                if url.standardizedFileURL == appURL.standardizedFileURL,
                   let executable = bundle.executableURL?.lastPathComponent,
                   !executable.isEmpty {
                    metadata.processNames.insert(executable)
                    metadata.processNames.insert(
                        URL(fileURLWithPath: executable).deletingPathExtension().lastPathComponent
                    )
                }
            }
            if url.standardizedFileURL == appURL.standardizedFileURL {
                let bundleName = url.deletingPathExtension().lastPathComponent
                if !bundleName.isEmpty { metadata.processNames.insert(bundleName) }
            }
            collectContainerIdentifiers(from: signingEntitlements(at: url), into: &metadata)
        }
        metadata.appNames.insert(appURL.deletingPathExtension().lastPathComponent)
        return metadata
    }

    private static func signingEntitlements(at url: URL) -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return [:] }
        var signingInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &signingInfo) == errSecSuccess,
              let dictionary = signingInfo as? [String: Any] else { return [:] }
        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }

    private static func collectContainerIdentifiers(from entitlements: [String: Any],
                                                    into metadata: inout UninstallMetadata) {
        let groupKeys = ["com.apple.security.application-groups"]
        let cloudKeys = [
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.ubiquity-container-identifiers",
        ]
        for key in groupKeys {
            for identifier in entitlements[key] as? [String] ?? [] where !identifier.isEmpty {
                metadata.groupContainerIDs.insert(identifier)
            }
        }
        for key in cloudKeys {
            for identifier in entitlements[key] as? [String] ?? [] where !identifier.isEmpty {
                metadata.iCloudContainerIDs.insert(identifier)
            }
        }
    }

    private static func addChildren(of directory: URL, to candidates: inout Set<URL>,
                                    matching predicate: (String) -> Bool) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for child in children where predicate(child.lastPathComponent) {
            candidates.insert(child.standardizedFileURL)
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains(":")
    }

    private static func artifactName(_ name: String, matchesBundleID identifier: String) -> Bool {
        let lowered = name.lowercased()
        let loweredID = identifier.lowercased()
        return lowered == loweredID
            || lowered.hasPrefix(loweredID + ".")
            || lowered.hasPrefix(loweredID + "_")
            || lowered.hasPrefix(loweredID + "-")
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
            // 必须在移走 app 之前保存扩展和容器信息，否则 Bundle/签名已不可读取。
            let metadata = uninstallMetadata(appURL: appURL, fallbackBundleID: bundleID)
            let failedToQuit = terminateRunningApplications(
                appURL: appURL,
                bundleIDs: metadata.bundleIDs,
                processNames: metadata.processNames
            )
            if !failedToQuit.isEmpty {
                let names = failedToQuit.joined(separator: "、")
                DispatchQueue.main.async {
                    completion("无法退出正在运行的 \(names)，因此尚未删除应用。请保存工作后再试。")
                }
                return
            }

            var finderWasPrepared = false
            func moveToTrash(_ url: URL) -> Bool {
                unloadLaunchServiceIfNeeded(at: url)
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                    let removed = !FileManager.default.fileExists(atPath: url.path)
                    if removed, url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                        unregisterApplication(at: url)
                        if let resultingURL { unregisterApplication(at: resultingURL as URL) }
                    }
                    return removed
                } catch {
                    if !finderWasPrepared {
                        DispatchQueue.main.sync { beforeFinderFallback() }
                        finderWasPrepared = true
                    }
                    let removed = finderTrash(url)
                    if removed, url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                        unregisterApplication(at: url)
                    }
                    return removed
                }
            }

            guard moveToTrash(appURL) else {
                let errorMessage = """
                无法移除“\(appURL.deletingPathExtension().lastPathComponent)”:权限不足,\
                且 Finder 代删被拒或被取消。
                可在 Finder 中手动将其移到废纸篓;若从未弹出过授权窗口,\
                请在 系统设置 → 隐私与安全性 → 自动化 中允许本应用控制 Finder 后重试。
                """
                DispatchQueue.main.async { completion(errorMessage) }
                return
            }

            // A sandboxed app can recreate its container while its last process
            // is winding down. Re-scan from the saved metadata until two
            // consecutive passes are clean, instead of reporting success after
            // a single move that may immediately be undone by containermanagerd.
            var failedResiduals = Set<URL>()
            var relaunchedApps = Set<String>()
            var consecutiveCleanPasses = 0
            for pass in 0..<5 {
                let stillRunning = terminateRunningApplications(
                    appURL: appURL,
                    bundleIDs: metadata.bundleIDs,
                    processNames: metadata.processNames
                )
                relaunchedApps.formUnion(stillRunning)

                let currentResiduals = residualPaths(metadata: metadata)
                if currentResiduals.isEmpty && stillRunning.isEmpty {
                    consecutiveCleanPasses += 1
                } else {
                    consecutiveCleanPasses = 0
                    for residual in currentResiduals {
                        if !moveToTrash(residual) { failedResiduals.insert(residual) }
                    }
                }

                if consecutiveCleanPasses >= 2 { break }
                if pass < 4 { Thread.sleep(forTimeInterval: 0.45) }
            }

            // Only report paths that still exist. A protected path may fail on
            // the first pass, then succeed through Finder on a later pass.
            failedResiduals = Set(failedResiduals.filter {
                FileManager.default.fileExists(atPath: $0.path)
            })
            failedResiduals.formUnion(residualPaths(metadata: metadata))

            // 固定图标与正在运行时产生的临时图标都要刷新。
            if !removeFromDock(appURL, bundleID: bundleID) { restartDock(waitForExit: true) }

            let errorMessage: String?
            if failedResiduals.isEmpty && relaunchedApps.isEmpty {
                errorMessage = nil
            } else {
                var details: [String] = ["应用本体已移到废纸篓，但卸载未完全结束。"]
                if !relaunchedApps.isEmpty {
                    details.append("仍无法退出：\(relaunchedApps.sorted().joined(separator: "、"))")
                }
                if !failedResiduals.isEmpty {
                    let sortedResiduals = failedResiduals.sorted {
                        $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                    }
                    let shown = sortedResiduals.prefix(5).map(\.path).joined(separator: "\n")
                    let omitted = failedResiduals.count > 5
                        ? "\n另有 \(failedResiduals.count - 5) 项"
                        : ""
                    details.append("以下关联文件未能移除：\n\(shown)\(omitted)")
                }
                details.append("请检查 Finder 自动化或“完全磁盘访问权限”后重试。")
                errorMessage = details.joined(separator: "\n")
            }
            DispatchQueue.main.async { completion(errorMessage) }
        }
    }

    /// 先请求正常退出，给应用保存状态的机会；超时后强制退出。
    /// 当前进程被排除，LaunchPoint 自卸载仍由安装路径监视器安全收尾。
    private static func terminateRunningApplications(appURL: URL,
                                                     bundleIDs: Set<String>,
                                                     processNames: Set<String>) -> [String] {
        let targetPath = appURL.standardizedFileURL.path
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let running: [NSRunningApplication] = DispatchQueue.main.sync {
            NSWorkspace.shared.runningApplications.filter { application in
                guard application.processIdentifier != currentPID else { return false }
                if let localizedName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   processNames.contains(where: { $0.caseInsensitiveCompare(localizedName) == .orderedSame }) {
                    return true
                }
                if let identifier = application.bundleIdentifier,
                   bundleIDs.contains(identifier) { return true }
                guard let runningURL = application.bundleURL?.standardizedFileURL else { return false }
                let path = runningURL.path
                if path == targetPath || path.hasPrefix(targetPath + "/") { return true }
                return false
            }
        }
        guard !running.isEmpty else { return [] }

        for application in running { application.terminate() }
        waitForTermination(of: running, timeout: 2.5)
        let remaining = running.filter { !$0.isTerminated }
        for application in remaining { application.forceTerminate() }
        waitForTermination(of: remaining, timeout: 1.5)
        return remaining.filter { !$0.isTerminated }.map {
            $0.localizedName ?? $0.bundleIdentifier ?? "目标应用"
        }
    }

    /// Unload a matching launch service before its plist/binary is trashed.
    /// This prevents launchd from immediately respawning a helper after the
    /// main application is removed.
    private static func unloadLaunchServiceIfNeeded(at url: URL) {
        let path = url.standardizedFileURL.path
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(where: {
            $0 == "LaunchAgents" || $0 == "LaunchDaemons"
        }) else { return }

        let domain: String
        if components[index] == "LaunchAgents" {
            domain = "gui/\(getuid())"
        } else {
            domain = "system"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", domain, path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    /// Remove both the original and trashed bundle records from LaunchServices.
    /// Otherwise a menu-bar app can remain launchable from a stale Dock/login
    /// item and recreate the container that was just removed.
    private static func unregisterApplication(at url: URL) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = ["-u", url.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    private static func waitForTermination(of applications: [NSRunningApplication], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
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
