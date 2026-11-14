import AppIntents
import SwiftUI
import WidgetKit

// Upcoming events (contract/public-events-leagues-2026-11-13.md § 6): the next events you can find, set up from the
// widget's own settings (long press → Edit Widget): any formats (none = all) and Near me | Everywhere. Public events
// draw signed out; signed in, your friends' events too. It never asks for location: Near me reads the rough place the
// app last kept. Refreshes every 30 minutes.

enum UpcomingFormatOption: String, AppEnum {
    case standard, pioneer, modern, legacy, vintage, pauper, premodern
    case canadianHighlander = "canadian_highlander"
    case limited, cube, other
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .standard: "Standard", .pioneer: "Pioneer", .modern: "Modern", .legacy: "Legacy", .vintage: "Vintage", .pauper: "Pauper",
        .premodern: "Premodern", .canadianHighlander: "Canadian Highlander", .limited: "Limited", .cube: "Cube", .other: "Other",
    ]
}

enum UpcomingWhereOption: String, AppEnum {
    case near, everywhere
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Where"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.near: "Near me", .everywhere: "Everywhere"]
}

struct UpcomingWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Upcoming events"
    static let description = IntentDescription("Pick any formats (none shows them all) and where.")

    @Parameter(title: "Formats", default: []) var formats: [UpcomingFormatOption]
    @Parameter(title: "Where", default: .near) var place: UpcomingWhereOption

    var picks: UpcomingPicks {
        UpcomingPicks(formats: Leagues.formatKeys.map(\.key).filter { k in formats.contains { $0.rawValue == k } }, nearMe: place == .near)
    }
}

struct UpcomingEntry: TimelineEntry {
    let date: Date
    let picks: UpcomingPicks
    let events: [FoundEvent]?
}

struct UpcomingProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        UpcomingEntry(date: .now, picks: UpcomingPicks(), events: UpcomingStore.load(UpcomingPicks())?.events)
    }

    func snapshot(for c: UpcomingWidgetIntent, in context: Context) async -> UpcomingEntry {
        let picks = c.picks
        var events = UpcomingStore.load(picks)?.events
        if events == nil { events = try? await LiveAPI.withTimeout(8) { try await UpcomingStore.fetch(picks) } }
        return UpcomingEntry(date: .now, picks: picks, events: events)
    }

    func timeline(for c: UpcomingWidgetIntent, in context: Context) async -> Timeline<UpcomingEntry> {
        let picks = c.picks
        var events = UpcomingStore.load(picks)?.events
        if UpcomingStore.isStale(picks, maxAge: 20 * 60),
           let fresh = try? await LiveAPI.withTimeout(8, { try await UpcomingStore.fetch(picks) }) {
            events = fresh
        }
        return Timeline(entries: [UpcomingEntry(date: .now, picks: picks, events: events)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }
}

struct UpcomingEventsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: UpcomingWidgets.kind, intent: UpcomingWidgetIntent.self, provider: UpcomingProvider()) { e in
            UpcomingFrame { family in UpcomingEventsView(family: family, events: e.events, picks: e.picks) }
                .widgetURL(e.events?.first.map(UpcomingWidgets.eventLink) ?? UpcomingWidgets.findLink)
        }
        .configurationDisplayName("Upcoming events")
        .description("The next events you can find, by format and near you.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct UpcomingFrame<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content
    var body: some View { content(family).containerBackground(for: .widget) { W1.bg } }
}
