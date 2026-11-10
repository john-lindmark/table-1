import AppIntents
import SwiftUI
import WidgetKit

// Limited cards (contract/widgets-2026-10-22.md § Limited cards widget): a set's best cards in draft, set up from the
// widget's own settings (long press → Edit Widget): the set, the sort, and any rarities and colors. The packs are
// public, so it draws signed out too; the set list comes from Insights' index (signed in) or what the app last saw.

/// A Limited set from Insights' index.
struct LimitedSetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Set"
    static let defaultQuery = LimitedSetQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)", subtitle: "\(name)") }
}

struct LimitedSetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LimitedSetEntity] {
        let sets = LimitedSetsStore.load()
        return identifiers.map { id in LimitedSetEntity(id: id, name: sets.first { $0.key == id }?.name ?? id) }
    }

    func suggestedEntities() async throws -> [LimitedSetEntity] {
        await LimitedSetsStore.fresh().map { LimitedSetEntity(id: $0.key, name: $0.name) }
    }

    func defaultResult() async -> LimitedSetEntity? {
        (LimitedSetsStore.load().first).map { LimitedSetEntity(id: $0.key, name: $0.name) }
    }
}

enum LimitedSortOption: String, AppEnum {
    case gih, oh, iwd, ata
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sort"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .gih: "Win rate in hand", .oh: "Win rate in opening hand", .iwd: "Improvement when drawn", .ata: "Average pick taken",
    ]
}

enum LimitedRarityOption: String, AppEnum {
    case common, uncommon, rare, mythic
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Rarity"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .common: "Common", .uncommon: "Uncommon", .rare: "Rare", .mythic: "Mythic",
    ]
}

enum LimitedColorOption: String, AppEnum {
    case W, U, B, R, G, M, C
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Color"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .W: "White", .U: "Blue", .B: "Black", .R: "Red", .G: "Green", .M: "Multicolor", .C: "Colorless",
    ]
}

struct LimitedWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Limited cards"
    static let description = IntentDescription("Pick the set, the sort, and any rarities and colors. None picked shows them all.")

    @Parameter(title: "Set") var set: LimitedSetEntity?
    @Parameter(title: "Sort", default: .gih) var sort: LimitedSortOption
    @Parameter(title: "Rarity", default: []) var rarity: [LimitedRarityOption]
    @Parameter(title: "Color", default: []) var color: [LimitedColorOption]

    var picks: LimitedPicks {
        LimitedPicks(set: set?.id ?? LimitedSetsStore.load().first?.key, sort: sort.rawValue,
                     rarity: LimitedFilter.rarities.filter { r in rarity.contains { $0.rawValue == r } },
                     color: LimitedFilter.colors.filter { c in color.contains { $0.rawValue == c } })
    }
}

struct LimitedEntry: TimelineEntry {
    let date: Date
    let picks: LimitedPicks
    let pack: LimitedWidgetPack?
}

struct LimitedProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LimitedEntry {
        let set = LimitedSetsStore.load().first?.key
        return LimitedEntry(date: .now, picks: LimitedPicks(set: set), pack: set.flatMap(LimitedPackStore.load))
    }

    func snapshot(for c: LimitedWidgetIntent, in context: Context) async -> LimitedEntry {
        var picks = c.picks
        if picks.set == nil { picks.set = await LimitedSetsStore.fresh().first?.key }
        var pack = picks.set.flatMap(LimitedPackStore.load)
        if pack == nil, let s = picks.set { pack = await LimitedPackStore.fresh(s) }
        return LimitedEntry(date: .now, picks: picks, pack: pack)
    }

    /// Every 6 hours; a set's numbers change once a day.
    func timeline(for c: LimitedWidgetIntent, in context: Context) async -> Timeline<LimitedEntry> {
        var picks = c.picks
        if picks.set == nil { picks.set = await LimitedSetsStore.fresh().first?.key }
        let pack = await picks.set.asyncMap { await LimitedPackStore.fresh($0) } ?? nil
        return Timeline(entries: [LimitedEntry(date: .now, picks: picks, pack: pack)], policy: .after(.now.addingTimeInterval(6 * 3600)))
    }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        guard let x = self else { return nil }
        return await f(x)
    }
}

struct LimitedCardsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "site.table1.limited", intent: LimitedWidgetIntent.self, provider: LimitedProvider()) { e in
            LimitedFrame { family in LimitedCardsWidgetView(family: family, pack: e.pack, picks: e.picks) }
                .widgetURL(LimitedWidgets.link(e.pack?.set_code ?? e.picks.set, src: "widget_limited"))
        }
        .configurationDisplayName("Limited cards")
        .description("A set's best cards in draft from 17Lands data. Pick the set, rarities and colors in its settings.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct LimitedFrame<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content
    var body: some View { content(family).containerBackground(for: .widget) { W1.bg } }
}
