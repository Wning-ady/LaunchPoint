import Combine
import AppKit
import Foundation

struct UpdateRelease: Equatable, Sendable {
    struct Asset: Equatable, Sendable {
        let name: String
        let downloadURL: URL
    }

    let tagName: String
    let releaseURL: URL
    let releaseNotes: String?
    let isPrerelease: Bool
    let assets: [Asset]

    var version: String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func preferredDMG(for architecture: UpdateArchitecture = .current) -> Asset? {
        let diskImages = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard !diskImages.isEmpty else { return nil }

        let architectureMarkers: [String]
        switch architecture {
        case .arm64:
            architectureMarkers = ["arm64", "aarch64", "apple-silicon", "apple_silicon"]
        case .x86_64:
            architectureMarkers = ["x86_64", "x64", "amd64", "intel"]
        case .unknown:
            architectureMarkers = []
        }

        if let exactMatch = diskImages.first(where: { asset in
            let name = asset.name.lowercased()
            return architectureMarkers.contains(where: name.contains)
        }) {
            return exactMatch
        }

        if let universal = diskImages.first(where: { asset in
            let name = asset.name.lowercased()
            return name.contains("universal") || name.contains("universal2")
        }) {
            return universal
        }

        return diskImages.count == 1 ? diskImages[0] : nil
    }
}

enum UpdateArchitecture: String, Sendable {
    case arm64
    case x86_64
    case unknown

    static var current: UpdateArchitecture {
#if arch(arm64)
        .arm64
#elseif arch(x86_64)
        .x86_64
#else
        .unknown
#endif
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(version: String)
        case installing(version: String)
        case upToDate(latestVersion: String)
        case updateAvailable(UpdateRelease)
        case failed(message: String)
    }

    nonisolated static let repositoryURL = URL(string: "https://github.com/Wning-ady/LaunchPoint")!
    nonisolated static let releasesURL = URL(string: "https://api.github.com/repos/Wning-ady/LaunchPoint/releases?per_page=20")!

    @Published private(set) var state: State = .idle

    let currentVersion: String
    private let endpoint: URL
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var generation = 0

    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "LaunchPointReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0",
        endpoint: URL = UpdateChecker.releasesURL
    ) {
        self.currentVersion = currentVersion
        self.endpoint = endpoint
    }

    var availableRelease: UpdateRelease? {
        guard case .updateAvailable(let release) = state else { return nil }
        return release
    }

    var preferredDownloadURL: URL? {
        availableRelease?.preferredDMG()?.downloadURL
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        case .idle, .upToDate, .updateAvailable, .failed:
            return false
        }
    }

    func checkForUpdates() {
        checkTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let endpoint = endpoint
        let currentVersion = currentVersion

        state = .checking
        checkTask = Task { [weak self] in
            do {
                let releases = try await Self.fetchReleases(from: endpoint)
                try Task.checkCancellation()
                guard let self, requestGeneration == self.generation else { return }
                self.apply(releases: releases, currentVersion: currentVersion)
            } catch is CancellationError {
                return
            } catch {
                guard let self, requestGeneration == self.generation else { return }
                self.state = .failed(message: Self.userFacingMessage(for: error))
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableRelease else { return }
        install(release)
    }

    private func install(_ release: UpdateRelease) {
        installTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        state = .downloading(version: release.version)

        installTask = Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try await Self.prepareInstall(for: release)
                }.value
                try Task.checkCancellation()
                guard let self, requestGeneration == self.generation else { return }
                self.state = .installing(version: release.version)
                try Self.launchInstaller(prepared)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    NSApp.terminate(nil)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, requestGeneration == self.generation else { return }
                self.state = .failed(message: Self.userFacingMessage(for: error))
            }
        }
    }

    func cancel() {
        if case .installing = state { return }
        generation &+= 1
        checkTask?.cancel()
        installTask?.cancel()
        checkTask = nil
        installTask = nil
        if case .checking = state {
            state = .idle
        } else if case .downloading = state {
            state = .idle
        }
    }

    private func apply(releases: [GitHubRelease], currentVersion: String) {
        let candidates = releases.compactMap { release -> (SemanticVersion, UpdateRelease)? in
            guard !release.draft,
                  let version = SemanticVersion(release.tagName),
                  let releaseURL = URL(string: release.htmlURL) else {
                return nil
            }

            let assets = release.assets.compactMap { asset -> UpdateRelease.Asset? in
                guard let downloadURL = URL(string: asset.downloadURL) else { return nil }
                return UpdateRelease.Asset(name: asset.name, downloadURL: downloadURL)
            }
            let updateRelease = UpdateRelease(
                tagName: release.tagName,
                releaseURL: releaseURL,
                releaseNotes: release.body,
                isPrerelease: release.prerelease,
                assets: assets
            )
            return (version, updateRelease)
        }

        guard let latest = candidates.max(by: { $0.0 < $1.0 }) else {
            state = .failed(message: "发行版中还没有可用的版本。")
            return
        }

        guard let installed = SemanticVersion(currentVersion) else {
            state = .failed(message: "当前版本号格式不受支持：\(currentVersion)")
            return
        }

        if latest.0 > installed {
            state = .updateAvailable(latest.1)
        } else {
            state = .upToDate(latestVersion: latest.1.version)
        }
    }

    private nonisolated static func fetchReleases(from endpoint: URL) async throws -> [GitHubRelease] {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LaunchPoint-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "网络未连接，请稍后重试。"
            case .timedOut:
                return "检查更新超时，请稍后重试。"
            default:
                return "检查更新失败：\(urlError.localizedDescription)"
            }
        }
        if let checkError = error as? UpdateCheckError {
            switch checkError {
            case .invalidResponse:
                return "更新服务器返回了无效响应。"
            case .httpStatus(let status):
                return "检查更新失败（HTTP \(status)）。"
            }
        }
        if let installError = error as? UpdateInstallError {
            return installError.localizedDescription
        }
        return "检查更新失败：\(error.localizedDescription)"
    }

    private nonisolated static func prepareInstall(for release: UpdateRelease) async throws -> PreparedInstall {
        guard let asset = release.preferredDMG() else {
            throw UpdateInstallError.missingCompatibleDMG
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "LaunchPointUpdate-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            var request = URLRequest(url: asset.downloadURL)
            request.timeoutInterval = 60
            request.setValue("LaunchPoint-Updater", forHTTPHeaderField: "User-Agent")
            let (downloadedURL, response) = try await URLSession.shared.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw UpdateInstallError.downloadFailed
            }

            let dmgURL = tempDir.appendingPathComponent(asset.name)
            if fm.fileExists(atPath: dmgURL.path) {
                try fm.removeItem(at: dmgURL)
            }
            try fm.moveItem(at: downloadedURL, to: dmgURL)

            let mountPoint = try mountDiskImage(dmgURL)
            let sourceApp = try findLaunchPointApp(in: mountPoint)
            let expectedBundleID = Bundle.main.bundleIdentifier ?? "com.waning.launchpoint"
            guard Bundle(url: sourceApp)?.bundleIdentifier == expectedBundleID else {
                throw UpdateInstallError.invalidBundle
            }

            return PreparedInstall(sourceApp: sourceApp,
                                   targetApp: installTargetURL(),
                                   mountPoint: mountPoint,
                                   temporaryDirectory: tempDir,
                                   currentPID: ProcessInfo.processInfo.processIdentifier)
        } catch {
            try? fm.removeItem(at: tempDir)
            throw error
        }
    }

    private nonisolated static func installTargetURL() -> URL {
        let currentBundle = Bundle.main.bundleURL.standardizedFileURL
        if currentBundle.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
           !currentBundle.path.hasPrefix("/Volumes/") {
            return currentBundle
        }
        return URL(fileURLWithPath: "/Applications/LaunchPoint.app", isDirectory: true)
    }

    private nonisolated static func mountDiskImage(_ dmgURL: URL) throws -> URL {
        let output = try runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        )
        guard let plist = try PropertyListSerialization.propertyList(
            from: output.standardOutput,
            options: [],
            format: nil
        ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateInstallError.mountFailed
        }
        for entity in entities {
            if let mountPath = entity["mount-point"] as? String, !mountPath.isEmpty {
                return URL(fileURLWithPath: mountPath, isDirectory: true)
            }
        }
        throw UpdateInstallError.mountFailed
    }

    private nonisolated static func findLaunchPointApp(in mountPoint: URL) throws -> URL {
        let direct = mountPoint.appendingPathComponent("LaunchPoint.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        guard let enumerator = FileManager.default.enumerator(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw UpdateInstallError.missingAppInDMG
        }

        for case let url as URL in enumerator {
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
            if url.deletingPathExtension().lastPathComponent == "LaunchPoint" {
                return url
            }
        }
        throw UpdateInstallError.missingAppInDMG
    }

    private nonisolated static func launchInstaller(_ install: PreparedInstall) throws {
        let script = """
        target="$1"
        source="$2"
        mount="$3"
        temp="$4"
        oldpid="$5"
        while /bin/kill -0 "$oldpid" 2>/dev/null; do
          /bin/sleep 0.1
        done
        backup="${target}.previous"
        /bin/rm -rf "$backup"
        backup_moved=0
        if [ -d "$target" ]; then
          if /bin/mv "$target" "$backup"; then
            backup_moved=1
          fi
        fi
        if /usr/bin/ditto "$source" "$target"; then
          /usr/bin/xattr -dr com.apple.quarantine "$target" >/dev/null 2>&1 || true
          /bin/rm -rf "$backup"
          /usr/bin/open "$target"
          status=0
        else
          status=$?
          /bin/rm -rf "$target"
          if [ "$backup_moved" -eq 1 ]; then
            /bin/mv "$backup" "$target"
          fi
          if [ -d "$target" ]; then
            /usr/bin/open "$target"
          fi
        fi
        /usr/bin/hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
        /bin/rm -rf "$temp"
        exit "$status"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            script,
            "launchpoint-updater",
            install.targetApp.path,
            install.sourceApp.path,
            install.mountPoint.path,
            install.temporaryDirectory.path,
            "\(install.currentPID)",
        ]
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.installerLaunchFailed
        }
    }

    @discardableResult
    private nonisolated static func runProcess(executable: String,
                                               arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.processFailed(executable)
        }
        process.waitUntilExit()
        let output = ProcessOutput(
            standardOutput: stdout.fileHandleForReading.readDataToEndOfFile(),
            standardError: stderr.fileHandleForReading.readDataToEndOfFile()
        )
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.processFailed(executable)
        }
        return output
    }
}

private struct PreparedInstall: Sendable {
    let sourceApp: URL
    let targetApp: URL
    let mountPoint: URL
    let temporaryDirectory: URL
    let currentPID: pid_t
}

private struct ProcessOutput: Sendable {
    let standardOutput: Data
    let standardError: Data
}

private struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let downloadURL: String

        private enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case draft
        case prerelease
        case assets
    }
}

private enum UpdateCheckError: Error {
    case invalidResponse
    case httpStatus(Int)
}

private enum UpdateInstallError: LocalizedError {
    case missingCompatibleDMG
    case downloadFailed
    case mountFailed
    case missingAppInDMG
    case invalidBundle
    case installerLaunchFailed
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCompatibleDMG:
            return "这个发行版没有匹配当前 Mac 架构的 DMG。"
        case .downloadFailed:
            return "下载更新包失败，请稍后重试。"
        case .mountFailed:
            return "无法挂载更新包 DMG。"
        case .missingAppInDMG:
            return "更新包里没有找到 LaunchPoint.app。"
        case .invalidBundle:
            return "更新包不是有效的 LaunchPoint 应用。"
        case .installerLaunchFailed:
            return "无法启动自动安装进程。"
        case .processFailed(let executable):
            return "\(URL(fileURLWithPath: executable).lastPathComponent) 执行失败。"
        }
    }
}

private struct SemanticVersion: Comparable, Sendable {
    private let components: [Int]
    private let prerelease: [Identifier]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])

        let versionParts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericParts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numericParts.isEmpty,
              numericParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let parsedComponents = numericParts.compactMap { Int($0) }
        guard parsedComponents.count == numericParts.count else { return nil }

        let parsedPrerelease: [Identifier]
        if versionParts.count == 2 {
            let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            parsedPrerelease = identifiers.map { Identifier(String($0)) }
        } else {
            parsedPrerelease = []
        }

        components = parsedComponents
        prerelease = parsedPrerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }

        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left != right { return left < right }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private enum Identifier: Comparable, Sendable {
        case numeric(Int)
        case text(String)

        init(_ value: String) {
            if let number = Int(value), value.allSatisfy(\.isNumber) {
                self = .numeric(number)
            } else {
                self = .text(value.lowercased())
            }
        }

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs, rhs) {
            case (.numeric(let left), .numeric(let right)):
                return left < right
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case (.text(let left), .text(let right)):
                return left < right
            }
        }
    }
}
