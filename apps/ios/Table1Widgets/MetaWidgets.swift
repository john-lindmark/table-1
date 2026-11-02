import AppIntents
import SwiftUI
import WidgetKit

// Meta breakdown, Matchup grid and Archetype matchups (contract/widgets-2026-10-22.md § Meta widgets). Each is set up
// from the widget's own settings (long press → Edit Widget): format, events, window and, for the archetype widget, the
// archetype. The pack is public, so they work signed out; MetaPackStore refreshes it at most every 3 hours.

enum MetaFormatOption: String, AppEnum {
    case standard, pioneer, modern, legacy, vintage, pauper, canlander
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .standard: "Standard", .pioneer: "Pioneer", .modern: "Modern", .legacy: "Legacy", .vintage: "Vintage",
        .pauper: "Pauper", .canlander: "Canadian Highlander",
    ]
}

enum MetaEventsOption: String, AppEnum {
    case big, all
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Events"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.big: "Big events", .all: "All events"]
}

enum MetaWindowOption: Int, AppEnum {
    case d7 = 7, d14 = 14, d30 = 30, d90 = 90
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Window"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .d7: "Last 7 days", .d14: "Last 14 days", .d30: "Last 30 days", .d90: "Last 90 days",
    ]
}

struct MetaWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Insights"
    static let description = IntentDescription("Pick the format, events and window.")

    @Parameter(title: "Format", default: .modern) var format: MetaFormatOption
    @Parameter(title: "Events", default: .big) var events: MetaEventsOption
    @Parameter(title: "Window", default: .d30) var window: MetaWindowOption

    var picks: MetaPicks { MetaPicks(format: format.rawValue, tier: events.rawValue, days: window.rawValue) }
}

/// An archetype of the picked format, listed from its pack: those with matchups first, most played first.
struct MetaArchetypeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Archetype"
    static let defaultQuery = MetaArchetypeQuery()
    /// "<format>:<archetype id>", so a pick from another format is never read as this one's.
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    var archetypeId: Int? { id.split(separator: ":").last.flatMap { Int($0) } }
    var format: String { String(id.split(separator: ":").first ?? "") }
}

struct MetaArchetypeQuery: EntityQuery {
    @IntentParameterDependency<ArchetypeWidgetIntent>(\.$format) var intent

    private func all() async -> [MetaArchetypeEntity] {
        let format = intent?.format.rawValue ?? "modern"
        guard let pack = await MetaPackStore.fresh(format) else { return [] }
        return MetaWidgets.choices(pack).map { MetaArchetypeEntity(id: "\(format):\($0)", name: pack.name($0)) }
    }

    func entities(for identifiers: [String]) async throws -> [MetaArchetypeEntity] {
        var out: [MetaArchetypeEntity] = []
        for id in identifiers {
            let format = String(id.split(separator: ":").first ?? "")
            var pack = MetaPackStore.load(format)
            if pack == nil { pack = await MetaPackStore.fresh(format) }
            guard let a = id.split(separator: ":").last.flatMap({ Int($0) }), let pack else { continue }
            out.append(MetaArchetypeEntity(id: id, name: pack.name(a)))
        }
        return out
    }

    func suggestedEntities() async throws -> [MetaArchetypeEntity] { await all() }
}

struct ArchetypeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Archetype matchups"
    static let description = IntentDescription("Pick the format, the archetype, events and window.")

    @Parameter(title: "Format", default: .modern) var format: MetaFormatOption
    @Parameter(title: "Archetype") var archetype: MetaArchetypeEntity?
    @Parameter(title: "Events", default: .big) var events: MetaEventsOption
    @Parameter(title: "Window", default: .d30) var window: MetaWindowOption

    var picks: MetaPicks {
        // An archetype picked under another format is ignored: the widget shows that format's most played.
        let a = archetype.flatMap { $0.format == format.rawValue ? $0.archetypeId : nil }
        return MetaPicks(format: format.rawValue, tier: events.rawValue, days: window.rawValue, archetype: a)
    }
}

struct MetaEntry: TimelineEntry {
    let date: Date
    let picks: MetaPicks
    let pack: MetaPack?
    /// What's tapped on a widget with these picks (MetaSelection): a Meta row and a grid square.
    var focus: Int? = nil
    var cell: (Int, Int)? = nil

    init(date: Date, picks: MetaPicks, pack: MetaPack?) {
        self.date = date; self.picks = picks; self.pack = pack
        focus = MetaSelection.get(MetaSelection.key("meta", picks)).flatMap { Int($0) }
        cell = MetaSelection.cell(MetaSelection.get(MetaSelection.key("grid", picks)))
    }
}

/// Every 3 hours; the pack itself changes every 6.
private func metaTimeline(_ picks: MetaPicks) async -> Timeline<MetaEntry> {
    let pack = await MetaPackStore.fresh(picks.format)
    return Timeline(entries: [MetaEntry(date: .now, picks: picks, pack: pack)], policy: .after(.now.addingTimeInterval(3 * 3600)))
}

/// The gallery's preview: the held pack, else one fetch.
private func snapshotEntry(_ picks: MetaPicks) async -> MetaEntry {
    var pack = MetaPackStore.load(picks.format)
    if pack == nil { pack = await MetaPackStore.fresh(picks.format) }
    return MetaEntry(date: .now, picks: picks, pack: pack)
}

struct MetaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MetaEntry { MetaEntry(date: .now, picks: MetaPicks(), pack: MetaPackStore.load("modern")) }
    func snapshot(for c: MetaWidgetIntent, in context: Context) async -> MetaEntry {
        await snapshotEntry(c.picks)
    }
    func timeline(for c: MetaWidgetIntent, in context: Context) async -> Timeline<MetaEntry> { await metaTimeline(c.picks) }
}

struct ArchetypeProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MetaEntry { MetaEntry(date: .now, picks: MetaPicks(), pack: MetaPackStore.load("modern")) }
    func snapshot(for c: ArchetypeWidgetIntent, in context: Context) async -> MetaEntry {
        await snapshotEntry(c.picks)
    }
    func timeline(for c: ArchetypeWidgetIntent, in context: Context) async -> Timeline<MetaEntry> { await metaTimeline(c.picks) }
}

struct MetaBreakdownWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "site.table1.meta", intent: MetaWidgetIntent.self, provider: MetaProvider()) { e in
            MetaWidgetFrame { family in MetaBreakdownView(family: family, pack: e.pack, picks: e.picks, focus: e.focus) }
                .widgetURL(e.picks.link(nil, src: "widget_meta"))
        }
        .configurationDisplayName("Meta")
        .description("A format's most played archetypes, and how their shares moved. Tap one to pick out its line.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MatchupGridWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "site.table1.matchups", intent: MetaWidgetIntent.self, provider: MetaProvider()) { e in
            MetaWidgetFrame { family in MatchupGridWidgetView(family: family, pack: e.pack, picks: e.picks, selected: e.cell) }
                .widgetURL(e.picks.link("matchups", src: "widget_grid"))
        }
        .configurationDisplayName("Matchup grid")
        .description("How the most played archetypes do against each other. Tap a square for its record.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ArchetypeMatchupsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "site.table1.archetype", intent: ArchetypeWidgetIntent.self, provider: ArchetypeProvider()) { e in
            MetaWidgetFrame { family in ArchetypeWidgetView(family: family, pack: e.pack, picks: e.picks) }
                .widgetURL(e.picks.link(e.pack.flatMap { ArchetypeWidgetView.archetype($0, e.picks) }.map { "archetype/\($0)" }, src: "widget_archetype"))
        }
        .configurationDisplayName("Archetype matchups")
        .description("One archetype's win rate and how it does against the rest of the meta.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct MetaWidgetFrame<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content
    var body: some View { content(family).containerBackground(for: .widget) { W1.bg } }
}
