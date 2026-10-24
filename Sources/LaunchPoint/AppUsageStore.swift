import Foundation

/// Local-only launch history used to rank equally matched search results.
/// The store intentionally keeps only a small bounded set of app paths.
final class AppUsageStore {
    static let shared = AppUsageStore()

    private struct Record: Codable {
        var launches: Int
        var lastUsed: Date
    }

    private static let defaultsKey = "AppUsageRecords"
    private static let maximumRecords = 256
    private let defaults: UserDefaults
    private var records: [String: Record]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    /// Record a successful launch request. The caller invokes this on the main
    /// thread alongside the existing launch action.
    func record(appID: String, now: Date = Date()) {
        var current = records[appID] ?? Record(launches: 0, lastUsed: now)
        current.launches = min(current.launches + 1, 10_000)
        current.lastUsed = now
        records[appID] = current
        pruneIfNeeded()
        save()
    }

    /// Return a small recency/frequency score for the requested app IDs.
    /// Scores are intentionally only used as a tie-breaker after text match
    /// quality, so a recent app cannot outrank a much better text match.
    func scores(for appIDs: [String], now: Date = Date()) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(appIDs.count)
        for id in appIDs {
            guard let record = records[id] else { continue }
            let ageHours = max(0, now.timeIntervalSince(record.lastUsed) / 3600)
            let recency = max(0, 1_000 - Int(ageHours * 20))
            let frequency = min(record.launches, 100) * 10
            result[id] = recency + frequency
        }
        return result
    }

    private func pruneIfNeeded() {
        guard records.count > Self.maximumRecords else { return }
        let overflow = records.count - Self.maximumRecords
        let staleIDs = records
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(overflow)
            .map(\.key)
        for id in staleIDs { records.removeValue(forKey: id) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
