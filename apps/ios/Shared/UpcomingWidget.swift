import Foundation
import Supabase
import SwiftUI
import WidgetKit

/* The Upcoming events widget (contract/public-events-leagues-2026-11-13.md § 6): the next events you can find, from
   `find_events` (public ones signed out; your friends' too when the widget is signed in). Settings: Formats (none =
   all) and Where (Near me | Everywhere). Near me uses the app's last rough place (0.1°, kept in the App Group only
   while location is allowed; the widget never asks) with 100 km, and reads Everywhere until there is one. The views
   live here so the app's Debug gallery (`-T1WidgetsDemo upcoming`) draws them too. */

extension AnyJSON {
    /// A JSON value from Swift's own (Bool, Int, Double, String, arrays and dictionaries of them).
    static func from(_ v: Any) -> AnyJSON {
        switch v {
        case let b as Bool: return .bool(b)
        case let i as Int: return .integer(i)
        case let d as Double: return .double(d)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(AnyJSON.from))
        case let o as [String: Any]: return .object(o.mapValues(AnyJSON.from))
        default: return .null
        }
    }
}

/// The app's last rough place, for Near me. Never more exact than 0.1° (about 11 km).
enum UpcomingPlace {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: T1Shared.appGroup) }
    private static let key = "upcoming.place.v1"

    static func load() -> (lat: Double, lng: Double)? {
        guard let p = defaults?.array(forKey: key) as? [Double], p.count == 2 else { return nil }
        return (p[0], p[1])
    }

    /// Rounds and keeps it; true when it moved.
    @discardableResult
    static func store(lat: Double, lng: Double) -> Bool {
        let next = [Leagues.rough(lat), Leagues.rough(lng)]
        let old = defaults?.array(forKey: key) as? [Double]
        defaults?.set(next, forKey: key)
        return old != next
    }

    static func clear() { defaults?.removeObject(forKey: key) }
}

/// What a widget shows: its picks.
struct UpcomingPicks: Codable, Hashable {
    var formats: [String] = []
    var nearMe = true

    /// The picks as a cache key.
    var key: String { (formats.isEmpty ? "all" : formats.joined(separator: ",")) + (nearMe ? "|near" : "|everywhere") }

    /// "MODERN · LEGACY", "3 FORMATS", or nothing for every format.
    var formatsLabel: String? {
        switch formats.count {
        case 0: nil
        case 1, 2: formats.map { Leagues.label($0) }.joined(separator: " · ")
        default: "\(formats.count) formats"
        }
    }
}

enum UpcomingWidgets {
    static let kind = "site.table1.upcoming"
    /// Near me reaches this far.
    static let nearKm = 100
    /// Rows by size: small 1, medium 3, large 6.
    static let rows = 6

    /// find_events' filters for the picks: the formats, and the rough place with 100 km when Near me has one.
    static func filters(_ picks: UpcomingPicks, place: (lat: Double, lng: Double)?) -> [String: Any] {
        var f: [String: Any] = [:]
        if !picks.formats.isEmpty { f["formats"] = picks.formats }
        if picks.nearMe, let place { f["lat"] = place.lat; f["lng"] = place.lng; f["km"] = nearKm }
        return f
    }

    /// The first column of a row: `SUN 29 · 10:00`, or `NOW · R3` while it runs.
    static func whenText(_ e: FoundEvent, zone: TimeZone = .current, locale: Locale = .current) -> String {
        if (e.status == "seated" || e.status == "in_progress"), (e.currentRound ?? 0) > 0 { return "NOW · R\(e.currentRound ?? 0)" }
        return e.startDate.map { Leagues.dayText($0, zone: zone, locale: locale) } ?? "SOON"
    }

    /// `MODERN · MEH GAMES`.
    static func detail(_ e: FoundEvent) -> String {
        [e.formatLabel ?? Leagues.label(e.formatKey ?? "other"), e.venueName].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ").uppercased()
    }

    static func eventLink(_ e: FoundEvent) -> URL { URL(string: "table1://event/\(e.eventId)?src=widget_upcoming")! }
    static let findLink = URL(string: "table1://find?src=widget_upcoming")!
}

/// The last answer per picks, in the App Group.
enum UpcomingStore {
    struct Saved: Codable { var events: [FoundEvent]; var fetchedAt: Double }
    private static var defaults: UserDefaults? { UserDefaults(suiteName: T1Shared.appGroup) }
    private static func key(_ picks: UpcomingPicks) -> String { "upcoming.events.v1." + picks.key }

    static func load(_ picks: UpcomingPicks) -> Saved? {
        guard let data = defaults?.data(forKey: key(picks)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func isStale(_ picks: UpcomingPicks, maxAge: TimeInterval) -> Bool {
        guard let at = load(picks)?.fetchedAt else { return true }
        return Date().timeIntervalSince1970 - at > maxAge
    }

    /// The widget's own read. A server without `find_events` throws; the widget keeps what it had.
    static func fetch(_ picks: UpcomingPicks) async throws -> [FoundEvent] {
        let filters = UpcomingWidgets.filters(picks, place: UpcomingPlace.load())
        let events: [FoundEvent] = try await T1Shared.client
            .rpc("find_events", params: ["p_filters": AnyJSON.from(filters), "p_limit": .integer(UpcomingWidgets.rows)]).execute().value
        if let data = try? JSONEncoder().encode(Saved(events: events, fetchedAt: Date().timeIntervalSince1970)) {
            defaults?.set(data, forKey: key(picks))
        }
        return events
    }
}

// MARK: views

struct UpcomingEventsView: View {
    let family: WidgetFamily
    /// nil: nothing read yet.
    let events: [FoundEvent]?
    let picks: UpcomingPicks

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemLarge: list(6)
        default: list(3)
        }
    }

    private var header: String { picks.formatsLabel ?? "Upcoming events" }

    @ViewBuilder private var empty: some View {
        Text(events == nil ? "Open Table 1 to load events" : "No events").font(W1.mono(13)).foregroundStyle(W1.text)
        if events != nil, let formats = picks.formatsLabel { WLabel(formats) }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                WLabel(picks.formatsLabel == nil ? "Upcoming" : header)
                Spacer(minLength: 4)
                if events?.first?.isIn == true { WLabel("In", color: W1.accent) }
            }
            Spacer(minLength: 0)
            if let e = events?.first {
                let when = UpcomingWidgets.whenText(e).components(separatedBy: " · ")
                Text(when.first ?? "").font(W1.mono(22, .bold)).foregroundStyle(W1.text).lineLimit(1).minimumScaleFactor(0.7)
                if when.count > 1 {
                    Text(when[1]).font(W1.mono(22)).foregroundStyle(W1.text).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                Text(e.name).font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(2)
                WLabel(UpcomingWidgets.detail(e))
            } else {
                empty
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Link(destination: UpcomingWidgets.findLink) {
                HStack {
                    WLabel(header)
                    Spacer(minLength: 8)
                    WLabel(picks.nearMe && UpcomingPlace.load() != nil ? "Near me" : "Everywhere")
                }
                .frame(height: 16)
            }
            if let events, !events.isEmpty {
                // Always `n` slots of the same height, so a short list keeps its rows at the top.
                ForEach(0..<n, id: \.self) { i in
                    if i < events.count {
                        Rectangle().fill(W1.surface).frame(height: 1).padding(.top, 6)
                        Link(destination: UpcomingWidgets.eventLink(events[i])) { row(events[i]) }
                            .frame(maxHeight: .infinity)
                    } else {
                        Color.clear.frame(height: 1).padding(.top, 6)
                        Color.clear.frame(maxHeight: .infinity)
                    }
                }
            } else {
                Spacer(minLength: 0)
                empty
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ e: FoundEvent) -> some View {
        HStack(spacing: 10) {
            Text(UpcomingWidgets.whenText(e)).font(W1.mono(11, .semibold)).foregroundStyle(W1.text).lineLimit(1)
                .minimumScaleFactor(0.8).frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(1)
                WLabel(UpcomingWidgets.detail(e))
            }
            Spacer(minLength: 4)
            if e.isIn { WLabel("In", color: W1.accent) }
        }
        .frame(maxHeight: .infinity)
    }
}
