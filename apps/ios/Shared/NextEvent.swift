import Foundation
import Supabase

/// The Next event widget's data (contract/widgets-2026-10-22.md): the slice of `events_home` it needs, the pick
/// rule and the time text. Pure parts are tested in WidgetLogicTests.
struct NextEventItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var status: String
    var bucket: String          // live | upcoming | past
    var organizing: Bool
    var playing: Bool
    var venueName: String?
    var startsAt: String?
    var numberOfRounds: Int
    var currentRound: Int
    var players: Int
    var formatLabel: String?
    var format: String

    var label: String { formatLabel ?? format.capitalized }
    var startDate: Date? { startsAt.flatMap(NextEvent.parseDate) }
    var isLive: Bool { bucket == "live" }
    func deepLink(src: String) -> URL { URL(string: "table1://event/\(id)?src=\(src)")! }
}

struct NextEventData: Codable, Equatable {
    var events: [NextEventItem] = []
    var invites = 0
    var fetchedAt: Double = 0
}

enum NextEvent {
    /// What to show, best first: a live event, then the soonest upcoming with a start time, then upcoming ones with none
    /// (in the server's order). Cancelled and past never show.
    static func pick(_ events: [NextEventItem]) -> [NextEventItem] {
        let shown = events.filter { $0.status != "cancelled" && $0.bucket != "past" }
        let live = shown.filter(\.isLive)
        let upcoming = shown.filter { !$0.isLive }
        let dated = upcoming.filter { $0.startDate != nil }.sorted { $0.startDate! < $1.startDate! }
        let undated = upcoming.filter { $0.startDate == nil }
        return live + dated + undated
    }

    /// `Live · R2/4`, `Starting now`, `In 2h 10m` (within 12 h), else `Fri 6:30 PM` / `Oct 30, 6:30 PM`, or `Not scheduled`.
    static func timeText(_ e: NextEventItem, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if e.isLive { return "Live · R\(max(e.currentRound, 1))/\(e.numberOfRounds)" }
        guard let start = e.startDate else { return "Not scheduled" }
        let seconds = start.timeIntervalSince(now)
        if seconds <= 60 { return "Starting now" }
        if seconds < 12 * 3600 {
            let minutes = Int((seconds / 60).rounded(.up))
            return minutes < 60 ? "In \(minutes)m" : "In \(minutes / 60)h \(minutes % 60)m"
        }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(seconds < 6 * 86400 ? "EEEjmm" : "MMMdjmm")
        return f.string(from: start)
    }

    /// Reload 1 min after the next start time passes, every 30 min while one is within 12 h, else every 3 h.
    static func nextReload(_ shown: [NextEventItem], now: Date = .now) -> Date {
        let soon = shown.compactMap(\.startDate).filter { $0 > now }.min()
        if let soon, soon.timeIntervalSince(now) < 12 * 3600 {
            return min(soon.addingTimeInterval(60), now.addingTimeInterval(30 * 60))
        }
        if shown.contains(where: \.isLive) { return now.addingTimeInterval(30 * 60) }
        return now.addingTimeInterval(3 * 3600)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// The last `events_home` seen, shared through the App Group: the app writes it whenever the Events tab loads, the
/// widget refreshes it at most every 15 minutes.
enum NextEventStore {
    private static let defaults = UserDefaults(suiteName: T1Shared.appGroup)
    private static let key = "next.events.v1"

    static func load() -> NextEventData? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NextEventData.self, from: data)
    }

    /// Returns true when what the widget shows changed.
    @discardableResult
    static func save(events: [NextEventItem], invites: Int, now: Date = .now) -> Bool {
        let old = load()
        let new = NextEventData(events: events, invites: invites, fetchedAt: now.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(new) else { return false }
        defaults?.set(data, forKey: key)
        return old?.events != events || old?.invites != invites
    }

    static func isStale(maxAge: TimeInterval) -> Bool {
        guard let f = load()?.fetchedAt, f > 0 else { return true }
        return Date().timeIntervalSince1970 - f > maxAge
    }

    static func clear() { defaults?.removeObject(forKey: key) }

    /// The widget's own refresh: the same RPC the Events tab calls.
    static func fetch() async throws -> NextEventData {
        struct Invite: Decodable {}
        struct Home: Decodable { var events: [NextEventItem]; var invites: [Invite] }
        let home: Home = try await T1Shared.client
            .rpc("events_home", params: ["p_include_demo": AnyJSON.bool(BuildFlavor.isTest)]).execute().value
        save(events: home.events, invites: home.invites.count)
        return load() ?? NextEventData(events: home.events, invites: home.invites.count)
    }
}
