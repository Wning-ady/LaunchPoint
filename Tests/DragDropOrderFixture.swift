import AppKit
import Foundation

/// Standalone regression fixture. Compile it together with AppScanner.swift and
/// LayoutStore.swift so drag ordering can be verified without launching the UI.
@main
struct DragDropOrderFixture {
    static func main() throws {
        let pageID = "page-0"
        let groups = [
            GroupRecord(id: pageID, isFolder: false, name: nil, page: 0, order: 0),
        ]
        let names = ["闲鱼", "ListenNow", "Cockpit Tools", "全能解压"]
        let apps = names.enumerated().map { index, name in
            AppRecord(id: name,
                      bundleID: nil,
                      name: name,
                      alias: nil,
                      hidden: false,
                      groupID: pageID,
                      order: index)
        }

        // The marker shown in the reported reproduction is immediately before
        // Cockpit Tools. After removing the dragged item, that anchor is slot 2.
        let displayedAnchorSlot = 2
        let committed = try requireMove(
            LayoutStore.applyMoveEntity(apps: apps,
                                        groups: groups,
                                        entityID: "全能解压",
                                        toPage: 0,
                                        slot: displayedAnchorSlot)
        )
        let committedOrder = orderedNames(committed.apps, pageID: pageID)
        try require(committedOrder == ["闲鱼", "ListenNow", "全能解压", "Cockpit Tools"],
                    "Displayed anchor committed as \(committedOrder)")

        // A release-time recalculation that silently changes the anchor to
        // immediately before ListenNow reproduces the user's one-slot-early result.
        let shiftedRelease = try requireMove(
            LayoutStore.applyMoveEntity(apps: apps,
                                        groups: groups,
                                        entityID: "全能解压",
                                        toPage: 0,
                                        slot: 1)
        )
        let shiftedOrder = orderedNames(shiftedRelease.apps, pageID: pageID)
        try require(shiftedOrder == ["闲鱼", "全能解压", "ListenNow", "Cockpit Tools"],
                    "Shifted release did not reproduce the reported order: \(shiftedOrder)")

        // Persisted but currently unscannable apps are absent from the rendered
        // PageEntry list. A visible slot therefore under-counts the persisted list.
        let ghost = AppRecord(id: "missing-on-disk",
                              bundleID: nil,
                              name: "Missing",
                              alias: nil,
                              hidden: false,
                              groupID: pageID,
                              order: 0)
        let appsWithMissingRecord = [ghost] + apps.enumerated().map { index, app in
            var app = app
            app.order = index + 1
            return app
        }
        let anchored = try requireMove(
            LayoutStore.applyMoveEntity(apps: appsWithMissingRecord,
                                        groups: groups,
                                        entityID: "全能解压",
                                        relativeTo: "Cockpit Tools",
                                        after: false)
        )
        let anchoredVisibleOrder = orderedNames(anchored.apps, pageID: pageID)
            .filter { $0 != "Missing" }
        try require(anchoredVisibleOrder == ["闲鱼", "ListenNow", "全能解压", "Cockpit Tools"],
                    "Persisted invisible record shifted anchored drop: \(anchoredVisibleOrder)")

        print("PASS displayed-marker=before:Cockpit Tools direct-anchor=true invisible-record-safe=true")
    }

    private static func requireMove(
        _ value: (apps: [AppRecord], groups: [GroupRecord])?
    ) throws -> (apps: [AppRecord], groups: [GroupRecord]) {
        guard let value else { throw FixtureError("Move unexpectedly failed") }
        return value
    }

    private static func orderedNames(_ apps: [AppRecord], pageID: String) -> [String] {
        apps.filter { $0.groupID == pageID && !$0.hidden }
            .sorted { $0.order < $1.order }
            .map(\.name)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw FixtureError(message) }
    }

    private struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
