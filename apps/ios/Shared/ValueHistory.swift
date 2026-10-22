import Foundation
import Supabase

/// The Collection value widget's history (contract/widgets-2026-10-22.md): one point per day, the last value seen that
/// day, 30 days kept, per account. Recorded by the app whenever its Library summary changes and by the widget's own
/// refresh. Pure parts are tested in WidgetLogicTests.
struct ValuePoint: Codable, Hashable {
    var day: String     // yyyy-MM-dd, local
    var usd: Double
}

struct ValueRecord: Codable, Equatable {
    var userId: String
    var points: [ValuePoint] = []
    var cards = 0
    var copies = 0
    var fetchedAt: Double = 0

    var current: Double? { points.last?.usd }

    /// Change from the latest point at least `days` old (or the oldest earlier day, if history is shorter) to today.
    /// Nil until there are two days.
    func change(days: Int = 7, now: Date = .now, calendar: Calendar = .current) -> (usd: Double, days: Int)? {
        guard let last = points.last, points.count >= 2 else { return nil }
        let cutoff = ValueHistory.day(calendar.date(byAdding: .day, value: -days, to: now) ?? now, calendar)
        let base = points.last(where: { $0.day <= cutoff }) ?? points.first!
        guard base.day != last.day,
              let from = ValueHistory.date(base.day, calendar), let to = ValueHistory.date(last.day, calendar) else { return nil }
        let span = calendar.dateComponents([.day], from: from, to: to).day ?? days
        return (last.usd - base.usd, max(1, span))
    }
}

enum ValueHistory {
    static let keepDays = 30

    /// Adds or replaces today's point. A different account starts a fresh record. Returns true when anything changed.
    @discardableResult
    static func record(_ rec: inout ValueRecord?, userId: String, usd: Double, cards: Int, copies: Int,
                       now: Date = .now, calendar: Calendar = .current) -> Bool {
        let before = rec
        var r = (rec?.userId == userId ? rec : nil) ?? ValueRecord(userId: userId)
        let today = day(now, calendar)
        let rounded = (usd * 100).rounded() / 100
        if r.points.last?.day == today { r.points[r.points.count - 1].usd = rounded } else { r.points.append(ValuePoint(day: today, usd: rounded)) }
        let oldest = day(calendar.date(byAdding: .day, value: -(keepDays - 1), to: now) ?? now, calendar)
        r.points.removeAll { $0.day < oldest }
        r.cards = cards
        r.copies = copies
        r.fetchedAt = before?.fetchedAt ?? 0
        rec = r
        return before != r
    }

    static func day(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ day: String, _ calendar: Calendar = .current) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// The record in the App Group.
enum ValueStore {
    private static let defaults = UserDefaults(suiteName: T1Shared.appGroup)
    private static let key = "value.points.v1"

    static func load() -> ValueRecord? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ValueRecord.self, from: data)
    }

    private static func save(_ r: ValueRecord) {
        if let data = try? JSONEncoder().encode(r) { defaults?.set(data, forKey: key) }
    }

    /// Records a summary; returns true when the widget should redraw.
    @discardableResult
    static func note(userId: String, usd: Double, cards: Int, copies: Int, fetched: Bool = false) -> Bool {
        var rec = load()
        let changed = ValueHistory.record(&rec, userId: userId, usd: usd, cards: cards, copies: copies)
        guard var r = rec else { return false }
        if fetched { r.fetchedAt = Date().timeIntervalSince1970 }
        save(r)
        return changed
    }

    static func isStale(maxAge: TimeInterval) -> Bool {
        guard let f = load()?.fetchedAt, f > 0 else { return true }
        return Date().timeIntervalSince1970 - f > maxAge
    }

    static func clear() { defaults?.removeObject(forKey: key) }

    /// The widget's own refresh: `library_summary_get` for the signed-in account.
    static func fetch() async throws -> ValueRecord? {
        struct Summary: Decodable { let totalQty: Int; let uniqueCards: Int; let valueUsd: Double }
        let user = try await T1Shared.client.auth.session.user.id.uuidString.lowercased()
        let s: Summary = try await T1Shared.client.rpc("library_summary_get").execute().value
        note(userId: user, usd: s.valueUsd, cards: s.uniqueCards, copies: s.totalQty, fetched: true)
        return load()
    }
}

extension ValueRecord {
    static let sample: ValueRecord = {
        var r: ValueRecord? = nil
        let cal = Calendar.current
        let values = [4180.12, 4192.4, 4188.0, 4201.75, 4230.1, 4226.9, 4241.3, 4262.55, 4258.0, 4275.42]
        for (i, v) in values.enumerated() {
            let d = cal.date(byAdding: .day, value: i - values.count + 1, to: .now)!
            ValueHistory.record(&r, userId: "sample", usd: v, cards: 1_284, copies: 2_016, now: d)
        }
        return r!
    }()
}
