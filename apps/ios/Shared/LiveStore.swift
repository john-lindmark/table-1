import Foundation

/// The last known live state, shared through the App Group so widgets render instantly and offline.
enum LiveStore {
    private static let defaults = UserDefaults(suiteName: T1Shared.appGroup)
    private static let key = "live.snapshots.v1"
    private static let fetchedKey = "live.fetchedAt"

    static func load() -> [LiveSnapshot] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LiveSnapshot].self, from: data)) ?? []
    }

    /// Returns true when something actually changed (callers skip widget reloads otherwise).
    @discardableResult
    static func save(_ snapshots: [LiveSnapshot], fetched: Bool = true) -> Bool {
        if fetched { defaults?.set(Date().timeIntervalSince1970, forKey: fetchedKey) }
        let old = load()
        guard old != snapshots, let data = try? JSONEncoder().encode(snapshots) else { return false }
        defaults?.set(data, forKey: key)
        return true
    }

    static var fetchedAt: Date? {
        guard let t = defaults?.double(forKey: fetchedKey), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func isStale(maxAge: TimeInterval) -> Bool {
        guard let f = fetchedAt else { return true }
        return Date().timeIntervalSince(f) > maxAge
    }

    /// The seat to feature: a live match first, then anything else in progress.
    static func featured(_ snapshots: [LiveSnapshot]) -> LiveSnapshot? {
        snapshots.first { $0.state.isPlaying } ?? snapshots.first { $0.state.phase != "complete" } ?? snapshots.first
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
        defaults?.removeObject(forKey: fetchedKey)
    }
}
