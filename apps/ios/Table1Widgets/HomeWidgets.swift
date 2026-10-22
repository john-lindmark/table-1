import SwiftUI
import WidgetKit

// Next event and Collection value (contract/widgets-2026-10-22.md). Both read the App Group first and refresh from
// the server with a hard timeout only when the cache is old; the app also writes the cache and reloads them.

// MARK: - next event

struct NextEventEntry: TimelineEntry {
    let date: Date
    let data: NextEventData?
}

struct NextEventProvider: TimelineProvider {
    static let sample = NextEventData(events: [
        NextEventItem(id: "a", name: "Friday Modern", status: "open", bucket: "upcoming", organizing: true, playing: true,
                      venueName: "Mox Boarding House", startsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(2 * 3600 + 600)),
                      numberOfRounds: 4, currentRound: 0, players: 12, formatLabel: "Modern", format: "modern"),
        NextEventItem(id: "b", name: "Sunday Cube", status: "open", bucket: "upcoming", organizing: false, playing: true,
                      venueName: nil, startsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(2 * 86400)),
                      numberOfRounds: 3, currentRound: 0, players: 8, formatLabel: "Cube draft", format: "cube"),
    ], invites: 1)

    func placeholder(in context: Context) -> NextEventEntry { NextEventEntry(date: .now, data: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (NextEventEntry) -> Void) {
        let cached = NextEventStore.load()
        completion(NextEventEntry(date: .now, data: context.isPreview ? (cached ?? Self.sample) : cached))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEventEntry>) -> Void) {
        Task {
            var data = NextEventStore.load()
            if NextEventStore.isStale(maxAge: 15 * 60),
               let fresh = try? await LiveAPI.withTimeout(8, { try await NextEventStore.fetch() }) {
                data = fresh
            }
            let next = NextEvent.nextReload(NextEvent.pick(data?.events ?? []))
            completion(Timeline(entries: [NextEventEntry(date: .now, data: data)], policy: .after(next)))
        }
    }
}

struct NextEventWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "site.table1.next", provider: NextEventProvider()) { entry in
            NextEventEntryView(entry: entry)
        }
        .configurationDisplayName("Next event")
        .description("Your next event: when, where and who's coming.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct NextEventEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextEventEntry

    var body: some View {
        let first = NextEvent.pick(entry.data?.events ?? []).first
        NextEventView(family: family, data: entry.data, now: entry.date)
            .widgetURL(first?.deepLink(src: "widget_next") ?? URL(string: "table1://events?src=widget_next"))
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium { W1.bg } else { Color.clear }
            }
    }
}

// MARK: - collection value

struct ValueEntry: TimelineEntry {
    let date: Date
    let record: ValueRecord?
}

struct ValueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ValueEntry { ValueEntry(date: .now, record: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (ValueEntry) -> Void) {
        let cached = ValueStore.load()
        completion(ValueEntry(date: .now, record: context.isPreview ? (cached ?? .sample) : cached))
    }

    /// Prices change once a night, so a refresh every 6 hours (and a redraw after midnight) is plenty.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ValueEntry>) -> Void) {
        Task {
            var record = ValueStore.load()
            if ValueStore.isStale(maxAge: 6 * 3600),
               let fresh = try? await LiveAPI.withTimeout(8, { try await ValueStore.fetch() }) {
                record = fresh
            }
            completion(Timeline(entries: [ValueEntry(date: .now, record: record)], policy: .after(.now.addingTimeInterval(6 * 3600))))
        }
    }
}

struct ValueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "site.table1.value", provider: ValueProvider()) { entry in
            ValueEntryView(entry: entry)
        }
        .configurationDisplayName("Collection value")
        .description("What your collection is worth, and how it moved this week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ValueEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ValueEntry

    var body: some View {
        ValueView(family: family, record: entry.record, now: entry.date)
            .widgetURL(URL(string: "table1://collection?src=widget_value"))
            .containerBackground(for: .widget) { W1.bg }
    }
}
