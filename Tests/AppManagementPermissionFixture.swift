import AppKit
import Security
import SQLite3

final class AppDelegate: NSObject, NSApplicationDelegate {
    func dismissOverlay() {}
    func showOverlay() {}
}

@main
struct AppManagementPermissionFixture {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("TCC.db")
        let codeURL = URL(fileURLWithPath: "/usr/bin/true")
        var code: SecStaticCode?
        precondition(SecStaticCodeCreateWithPath(codeURL as CFURL, [], &code) == errSecSuccess)
        var requirement: SecRequirement?
        precondition(SecCodeCopyDesignatedRequirement(code!, [], &requirement) == errSecSuccess)
        var requirementData: CFData?
        precondition(SecRequirementCopyData(requirement!, [], &requirementData) == errSecSuccess)
        let data = requirementData! as Data
        var database: OpaquePointer?
        precondition(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func execute(_ sql: String) {
            precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        execute("CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, csreq BLOB)")
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(database, "INSERT INTO access VALUES ('kTCCServiceSystemPolicyAppBundles', 'fixture', 0, 2, ?)", -1, &statement, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient)
        }
        precondition(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        func status(client: String = "fixture", code: URL? = nil) -> PermissionAccessStatus? {
            PermissionGuide.appManagementRecord(databaseURL: url, client: client,
                                                clientType: 0, codeURL: code ?? codeURL)
        }
        precondition(status() == .enabled, "Matching signed authorization was not detected")
        precondition(status(client: "unrelated") == nil, "Unrelated authorization leaked into status")
        precondition(status(code: URL(fileURLWithPath: "/usr/bin/false")) == .unknown,
                     "A different code signature inherited authorization")
        execute("UPDATE access SET auth_value = 0")
        precondition(status() == .disabled)
        execute("UPDATE access SET auth_value = 3")
        precondition(status() == .unknown, "Unexpected authorization value was treated as allowed")
        execute("UPDATE access SET auth_value = 2, csreq = X'0001'")
        precondition(status() == .unknown, "Invalid signing requirement was trusted")
        execute("UPDATE access SET csreq = NULL")
        precondition(status() == .unknown)
        execute("DROP TABLE access")
        precondition(status() == nil, "Schema change must fail gracefully")
        let missing = root.appendingPathComponent("missing.db")
        precondition(PermissionGuide.appManagementRecord(databaseURL: missing, client: "fixture",
                                                         clientType: 0, codeURL: codeURL) == nil)
        precondition(!FileManager.default.fileExists(atPath: missing.path), "Read-only probe created a database")
        let probe = root.appendingPathComponent("probe.plist")
        let contents = Data("unchanged application metadata".utf8)
        try contents.write(to: probe)
        let before = try FileManager.default.attributesOfItem(atPath: probe.path)
        precondition(PermissionGuide.probeWriteAccess(at: probe) == .enabled)
        let after = try FileManager.default.attributesOfItem(atPath: probe.path)
        let remainingContents = try Data(contentsOf: probe)
        precondition(remainingContents == contents, "Capability probe changed file contents")
        precondition(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        precondition(before[.posixPermissions] as? Int == after[.posixPermissions] as? Int)
        let link = root.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: probe)
        precondition(PermissionGuide.probeWriteAccess(at: link) == .unknown)
        let missingProbe = root.appendingPathComponent("missing.plist")
        precondition(PermissionGuide.probeWriteAccess(at: missingProbe) == .unknown)
        precondition(!FileManager.default.fileExists(atPath: missingProbe.path))
        precondition(PermissionGuide.writeAccessStatus(openError: EPERM) == .disabled)
        precondition(PermissionGuide.writeAccessStatus(openError: EACCES) == .unknown)
        print("PASS non-mutating-access-probe symlink-rejected missing-not-created")
        print("PASS app-management allowed/denied/signature-mismatch/unrelated/missing/schema-change/read-only")
    }
}
