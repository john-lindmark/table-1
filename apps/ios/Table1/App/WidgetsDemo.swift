#if DEBUG
import SwiftUI
import WidgetKit

/// Design QA for the widgets batch without a home screen: `-T1WidgetsDemo [organizer|next|value|meta|grid|archetype|limited|icon|tinted]`
/// draws every family on sample data at its real size (iPhone 17 points); the Insights widgets on the live Modern pack
/// of 2026-11-02 (DebugResources/insights-demo-widget-modern.json). Debug only.
struct WidgetsDemoRoot: View {
    private let only: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-T1WidgetsDemo"), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
        return args[i + 1]
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if only == nil || only == "organizer" { organizer }
                if only == nil || only == "next" { next }
                if only == nil || only == "value" { value }
                if only == nil || only == "meta" { meta }
                if only == nil || only == "grid" { grid }
                if only == nil || only == "archetype" { archetype }
                if only == nil || only == "limited" { limited }
                if only == nil || only == "icon" { IconDemo() }
                if only == "tinted" { tintedAll }
            }
            .padding(16)
        }
        .background(Color(white: 0.32).ignoresSafeArea())
    }

    private static var between: OrganizerSnapshot {
        var s = OrganizerSnapshot.sample
        s.state.phase = "between"; s.state.endsAt = nil; s.state.matches = 0; s.state.done = 0; s.state.waiting = 0
        s.state.disputes = 0; s.state.guestWaiting = 0
        return s
    }

    private static var ready: OrganizerSnapshot {
        var s = OrganizerSnapshot.sample
        s.state.round = 4; s.state.done = 8; s.state.waiting = 0; s.state.disputes = 0; s.state.guestWaiting = 0
        s.state.endsAt = nil; s.state.pausedRemaining = 312
        return s
    }

    @ViewBuilder private var organizer: some View {
        caption("Organizer Live Activity · lock screen")
        OrganizerLockScreenView(snap: .sample).frame(width: 370).background(W1.bg)
        OrganizerLockScreenView(snap: Self.ready).frame(width: 370).background(W1.bg)
        OrganizerLockScreenView(snap: Self.between).frame(width: 370).background(W1.bg)
    }

    @ViewBuilder private var next: some View {
        let data = NextEventData(events: [
            NextEventItem(id: "a", name: "Friday Modern", status: "open", bucket: "upcoming", organizing: true, playing: true,
                          venueName: "Mox Boarding House", startsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(2 * 3600 + 600)),
                          numberOfRounds: 4, currentRound: 0, players: 12, formatLabel: "Modern", format: "modern"),
            NextEventItem(id: "b", name: "Sunday Vintage Cube", status: "open", bucket: "upcoming", organizing: false, playing: true,
                          venueName: nil, startsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(2 * 86400)),
                          numberOfRounds: 3, currentRound: 0, players: 8, formatLabel: "Cube draft", format: "cube"),
        ], invites: 2)
        caption("Next event · small, medium, lock screen, empty")
        HStack(spacing: 16) {
            tile(.systemSmall) { NextEventView(family: .systemSmall, data: data) }
            tile(.systemSmall) { NextEventView(family: .systemSmall, data: NextEventData()) }
        }
        tile(.systemMedium) { NextEventView(family: .systemMedium, data: data) }
        tile(.accessoryRectangular) { NextEventView(family: .accessoryRectangular, data: data) }
        tile(.accessoryInline) { NextEventView(family: .accessoryInline, data: data) }
    }

    @ViewBuilder private var value: some View {
        caption("Collection value · small, medium, no history")
        HStack(spacing: 16) {
            tile(.systemSmall) { ValueView(family: .systemSmall, record: .sample) }
            tile(.systemSmall) {
                ValueView(family: .systemSmall, record: ValueRecord(userId: "x", points: [ValuePoint(day: ValueHistory.day(.now), usd: 812.4)]))
            }
        }
        tile(.systemMedium) { ValueView(family: .systemMedium, record: .sample) }
    }

    private static let pack: MetaPack? = Bundle.main.url(forResource: "insights-demo-widget-modern", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap(MetaPackStore.decode)

    @ViewBuilder private var meta: some View {
        let picks = MetaPicks()
        caption("Meta · small, medium, large, all events 7 days, no pack")
        HStack(spacing: 16) {
            tile(.systemSmall) { MetaBreakdownView(family: .systemSmall, pack: Self.pack, picks: picks) }
            tile(.systemSmall) { MetaBreakdownView(family: .systemSmall, pack: nil, picks: picks) }
        }
        tile(.systemMedium) { MetaBreakdownView(family: .systemMedium, pack: Self.pack, picks: picks) }
        tile(.systemMedium) { MetaBreakdownView(family: .systemMedium, pack: Self.pack, picks: MetaPicks(tier: "all", days: 7)) }
        tile(.systemLarge) { MetaBreakdownView(family: .systemLarge, pack: Self.pack, picks: picks) }
        caption("Meta · a row tapped (Izzet Prowess), tinted Home Screen")
        tile(.systemMedium) { MetaBreakdownView(family: .systemMedium, pack: Self.pack, picks: picks, focus: 18) }
        tinted(.systemLarge) { MetaBreakdownView(family: .systemLarge, pack: Self.pack, picks: picks, focus: 18, tintedPreview: true) }
    }

    @ViewBuilder private var grid: some View {
        caption("Matchup grid · medium, large")
        tile(.systemMedium) { MatchupGridWidgetView(family: .systemMedium, pack: Self.pack, picks: MetaPicks()) }
        tile(.systemLarge) { MatchupGridWidgetView(family: .systemLarge, pack: Self.pack, picks: MetaPicks(tier: "all", days: 90)) }
        caption("Matchup grid · a square tapped, tinted Home Screen")
        tile(.systemMedium) { MatchupGridWidgetView(family: .systemMedium, pack: Self.pack, picks: MetaPicks(), selected: (1, 18)) }
        tinted(.systemLarge) { MatchupGridWidgetView(family: .systemLarge, pack: Self.pack, picks: MetaPicks(), selected: (17, 22), tintedPreview: true) }
        tinted(.systemMedium) { MatchupGridWidgetView(family: .systemMedium, pack: Self.pack, picks: MetaPicks(), tintedPreview: true) }
    }

    @ViewBuilder private var archetype: some View {
        let picks = MetaPicks(tier: "all", days: 30)
        caption("Archetype matchups · small, medium, large")
        HStack(spacing: 16) {
            tile(.systemSmall) { ArchetypeWidgetView(family: .systemSmall, pack: Self.pack, picks: picks) }
            tile(.systemSmall) { ArchetypeWidgetView(family: .systemSmall, pack: Self.pack, picks: MetaPicks(tier: "all", days: 30, archetype: 17)) }
        }
        tile(.systemMedium) { ArchetypeWidgetView(family: .systemMedium, pack: Self.pack, picks: picks) }
        tile(.systemLarge) { ArchetypeWidgetView(family: .systemLarge, pack: Self.pack, picks: MetaPicks(tier: "all", days: 30, archetype: 17)) }
        tinted(.systemMedium) { ArchetypeWidgetView(family: .systemMedium, pack: Self.pack, picks: picks, tintedPreview: true) }
    }

    private static let limitedPack: LimitedWidgetPack? = Bundle.main.url(forResource: "insights-demo-limited-FRA", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap(LimitedPackStore.decode)

    @ViewBuilder private var limited: some View {
        let picks = LimitedPicks(set: "FRA")
        caption("Limited cards · small, medium, large; commons and uncommons in W + U; no match; no set")
        HStack(spacing: 16) {
            tile(.systemSmall) { LimitedCardsWidgetView(family: .systemSmall, pack: Self.limitedPack, picks: picks) }
            tile(.systemSmall) { LimitedCardsWidgetView(family: .systemSmall, pack: nil, picks: LimitedPicks()) }
        }
        tile(.systemMedium) { LimitedCardsWidgetView(family: .systemMedium, pack: Self.limitedPack, picks: picks) }
        tile(.systemMedium) {
            LimitedCardsWidgetView(family: .systemMedium, pack: Self.limitedPack,
                                   picks: LimitedPicks(set: "FRA", sort: "iwd", rarity: ["common", "uncommon"], color: ["W", "U"]))
        }
        tile(.systemMedium) {
            LimitedCardsWidgetView(family: .systemMedium, pack: Self.limitedPack, picks: LimitedPicks(set: "FRA", rarity: ["mythic"], color: ["C"]))
        }
        tile(.systemLarge) { LimitedCardsWidgetView(family: .systemLarge, pack: Self.limitedPack, picks: LimitedPicks(set: "FRA", sort: "ata", color: ["R", "M"])) }
        tinted(.systemMedium) { LimitedCardsWidgetView(family: .systemMedium, pack: Self.limitedPack, picks: picks, tintedPreview: true) }
    }

    /// Every Insights widget on a tinted Home Screen, a square and a row tapped.
    @ViewBuilder private var tintedAll: some View {
        caption("Insights widgets · tinted Home Screen")
        tinted(.systemMedium) { MatchupGridWidgetView(family: .systemMedium, pack: Self.pack, picks: MetaPicks(), selected: (1, 18), tintedPreview: true) }
        tinted(.systemMedium) { MetaBreakdownView(family: .systemMedium, pack: Self.pack, picks: MetaPicks(), focus: 18, tintedPreview: true) }
        tinted(.systemMedium) { ArchetypeWidgetView(family: .systemMedium, pack: Self.pack, picks: MetaPicks(tier: "all"), tintedPreview: true) }
        tinted(.systemLarge) { MatchupGridWidgetView(family: .systemLarge, pack: Self.pack, picks: MetaPicks(), tintedPreview: true) }
    }

    /// A tinted Home Screen as near as the gallery gets: a green glass behind, everything white by opacity.
    private func tinted(_ family: WidgetFamily, @ViewBuilder _ content: () -> some View) -> some View {
        // how bright each thing is becomes how opaque it is, drawn in the tint's near-white
        let size = family == .systemLarge ? CGSize(width: 364, height: 382) : CGSize(width: 364, height: 170)
        return Color(red: 0.88, green: 1, blue: 0.95)
            .mask(tile(family, content).compositingGroup().luminanceToAlpha())
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.24, green: 0.42, blue: 0.36)).clipShape(RoundedRectangle(cornerRadius: 22))
    }

    /// The card icon widget: Lightning Bolt (2XM), the newest icon card on this device, and none (the plain icon).
    private struct IconDemo: View {
        @State private var bolt: UIImage?
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("CARD ICON · CARD, NEWEST ICON CARD, NONE").font(.system(size: 11, design: .monospaced)).tracking(1.2).foregroundStyle(.white)
                HStack(spacing: 16) {
                    face(bolt)
                    face(IconCardStore.load().first.flatMap { IconCardStore.art($0.id) })
                }
                face(nil)
            }
            .task {
                if let url = CatalogPack.imageURL(cardId: "f29ba16f-c8fb-42fe-aabf-87089cb214a7", imageTs: "", size: "art_crop") {
                    bolt = await CardImageLoader.shared.image(url, maxPixel: Int(IconCardStore.maxPixel))
                }
            }
        }

        private func face(_ art: UIImage?) -> some View {
            IconCardView(art: art)
                .frame(width: 170, height: 170)
                .background(IconCardView.background(art))
                .clipShape(RoundedRectangle(cornerRadius: 22))
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 11, design: .monospaced)).tracking(1.2).foregroundStyle(.white)
    }

    private func tile(_ family: WidgetFamily, @ViewBuilder _ content: () -> some View) -> some View {
        let size: CGSize = switch family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 250, height: 22)
        default: CGSize(width: 170, height: 170)
        }
        let system = family == .systemSmall || family == .systemMedium || family == .systemLarge
        return content()
            .padding(system ? 16 : 0)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .foregroundStyle(.white)
            .background(system ? W1.bg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: system ? 22 : 0))
    }
}
#endif
