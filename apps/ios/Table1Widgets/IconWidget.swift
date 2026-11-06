import AppIntents
import SwiftUI
import WidgetKit

// The card icon widget (contract/icon-widget-2026-11-06.md): the Table 1 mark over a card you picked. Its settings
// (long press → Edit Widget) list the icon cards on this device; left alone it shows the newest. A tap opens the app
// where you left it, like the icon.

struct IconCardEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Card"
    static let defaultQuery = IconCardQuery()
    let id: String
    let name: String
    let set: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(set)") }

    init(_ c: IconCard) { id = c.id; name = c.name; set = c.set }
}

struct IconCardQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [IconCardEntity] {
        IconCardStore.load().filter { identifiers.contains($0.id) }.map(IconCardEntity.init)
    }

    func suggestedEntities() async throws -> [IconCardEntity] { IconCardStore.load().map(IconCardEntity.init) }
}

struct IconWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Card icon"
    static let description = IntentDescription("Pick one of your icon cards. Add cards from a card's page in Table 1.")

    @Parameter(title: "Card") var card: IconCardEntity?
}

struct IconEntry: TimelineEntry {
    let date: Date
    let card: IconCard?
    let art: UIImage?
}

struct IconProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> IconEntry { IconEntry(date: .now, card: nil, art: nil) }

    private func entry(_ c: IconWidgetIntent) -> IconEntry {
        let card = IconCards.shown(IconCardStore.load(), chosen: c.card?.id)
        return IconEntry(date: .now, card: card, art: card.flatMap { IconCardStore.art($0.id) })
    }

    func snapshot(for c: IconWidgetIntent, in context: Context) async -> IconEntry { entry(c) }

    /// Nothing changes on its own; the app reloads it when the list changes.
    func timeline(for c: IconWidgetIntent, in context: Context) async -> Timeline<IconEntry> {
        Timeline(entries: [entry(c)], policy: .never)
    }
}

struct IconWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: IconCards.kind, intent: IconWidgetIntent.self, provider: IconProvider()) { e in
            IconCardView(art: e.art)
                .containerBackground(for: .widget) { IconCardView.background(e.art) }
        }
        .configurationDisplayName("Card icon")
        .description("Table 1 over a card you pick from its page in the app.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
