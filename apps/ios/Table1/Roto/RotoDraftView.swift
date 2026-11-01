import SwiftUI

// The Draft phase of a roto event (plan-roto-2026-10-15.md "Client views"): a one-line summary, then Grid / Cube /
// Picks / My list in a Table 1 segmented control. Organizers also get Pick for, Undo last pick and the pick clock.

enum RotoTab: String, CaseIterable {
    case grid, cube, picks, list
    var label: String {
        switch self {
        case .grid: "Grid"
        case .cube: "Cube"
        case .picks: "Picks"
        case .list: "My list"
        }
    }
    var screen: String { "roto_\(rawValue)" }
}

struct RotoDraftView: View {
    let store: RotoStore
    let title: String
    let isOrganizer: Bool
    /// After round 1: the draft stays readable, nothing can be picked.
    var readOnly = false
    var back: (() -> Void)?
    /// Organizer, once the draft is done and before round 1.
    var pairRound1: (() -> Void)?
    var pairing: String?
    var busy = false
    var outsideError: String?
    @State private var tab: RotoTab
    @State private var confirmUndo = false
    /// Your linked Library deck, full screen over the draft.
    @State private var deck: RotoDeckID?

    init(store: RotoStore, title: String, isOrganizer: Bool, readOnly: Bool = false, back: (() -> Void)? = nil,
         pairRound1: (() -> Void)? = nil, pairing: String? = nil, busy: Bool = false,
         outsideError: String? = nil, tab: RotoTab = .grid) {
        self.store = store
        self.title = title
        self.isOrganizer = isOrganizer
        self.readOnly = readOnly
        self.back = back
        self.pairRound1 = pairRound1
        self.pairing = pairing
        self.busy = busy
        self.outsideError = outsideError
        _tab = State(initialValue: tab)
    }

    private var tabs: [RotoTab] { store.me == nil ? [.grid, .cube, .picks] : RotoTab.allCases }

    var body: some View {
        T1Screen {
            Bar(title: title, subtitle: subtitle, back: back) {
                if isOrganizer && !readOnly && store.phase == .drafting { BarButton("More") { showMore() } }
            }
            RotoSummary(store: store, isOrganizer: isOrganizer && !readOnly) { tab = .cube }
            if let e = outsideError ?? store.error { Notice(e, error: true) }
            if let n = store.notice { Notice(n) }
            T1Segmented(options: tabs.map { (value: $0, label: $0.label) }, selection: $tab)
            Group {
                switch tab {
                case .grid: RotoGridView(store: store, interactive: !readOnly) { tab = .cube }
                case .cube: RotoCubeView(store: store, isOrganizer: isOrganizer, readOnly: readOnly)
                case .picks: RotoPicksView(store: store, openDeck: { openDeck($0) })
                case .list: RotoListView(store: store, readOnly: readOnly) { tab = .cube }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .screen(tab.screen)
            .onChange(of: tab) { _, t in Telemetry.screen(t.screen) }

            if let pairRound1, store.phase == .done, !readOnly {
                BigAction(text: "Pair round 1", busy: busy, accent: true) { pairRound1() }
            } else if store.phase == .done, let deck = store.me?.deckListId, !readOnly {
                BigAction(text: "Open deck", accent: true) {
                    Telemetry.capture("roto_deck_opened", ["from": "event"])
                    openDeck(deck)
                }
            }
        }
        .fullScreenCover(item: $deck) { d in RotoDeckScreen(listId: d.id) }
        // Names and colors come from the catalog pack; re-read them when a pack is installed or replaced.
        .task(id: CatalogStore.shared.generation) { await store.resolveCards() }
        .alert("Undo the last pick?", isPresented: $confirmUndo) {
            Button("Keep it", role: .cancel) {}
            Button("Undo", role: .destructive) { Task { await store.undo() } }
        } message: {
            Text("Removes the last pick a person made and any automatic picks after it. Their decks follow.")
        }
    }

    /// The deck is created on the server when the draft starts; sync the Library first so it's there.
    private func openDeck(_ id: String) {
        Task {
            await ListsStore.shared.sync()
            deck = RotoDeckID(id: id)
        }
    }

    /// "Draft · 8 players · 45 picks each · Snake"
    private var subtitle: String {
        var parts = ["Draft", "\(store.players) players", "\(store.draft.picksPerPlayer) picks each"]
        parts.append(store.draft.snake ? "Snake" : "Same order")
        if readOnly, let pairing { parts[0] = pairing == "round_robin" ? "Round robin" : "Swiss" }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func showMore() {
        let store = store
        var items: [T1MenuItem] = []
        if let clock = store.onClock, clock.participantId != store.me?.participantId {
            items.append(T1MenuItem(title: "Pick for \(store.name(seat: clock.seat))") { tab = .cube })
        }
        items.append(T1MenuItem(title: "Undo last pick", enabled: store.picksMade > 0) { confirmUndo = true })
        if store.draft.clock?.isEmpty == false {
            items.append(T1MenuItem(title: store.draft.clockPaused ? "Resume clock" : "Pause clock") {
                Task { _ = await store.setClock(nil, paused: !store.draft.clockPaused) }
            })
        }
        items.append(T1MenuItem(title: "Pick clock", detail: store.draft.clock.map { "\($0.count) range\($0.count == 1 ? "" : "s")" } ?? "Off") {
            T1Overlays.shared.present {
                RotoClockPanel(store: store)
            }
        })
        T1Overlays.shared.showMenu("Draft", items)
    }
}

// MARK: summary line

/// `ON THE CLOCK · ANNA · PICK 37/360`, then `YOU PICK IN 3` / `YOUR PICK` (accent) and the clock.
struct RotoSummary: View {
    let store: RotoStore
    var isOrganizer = false
    /// Organizer: "Pick for ANNA" opens the cube.
    var pickFor: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(at: context.date)
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch store.phase {
            case .setup:
                LabelText("Draft not started")
            case .done:
                LabelText("Draft done · \(store.picksMade) picks", color: T1.text)
            case .drafting:
                if let pending = store.pending {
                    LabelText("Picking · \(store.card(slot: pending.slot)?.name ?? "card") · pick \(pending.pickNo)/\(store.total)", color: T1.text)
                } else if let c = store.onClock {
                    LabelText("On the clock · \(store.name(seat: c.seat)) · pick \(c.pickNo)/\(store.total)", color: T1.text)
                }
                HStack(spacing: 0) {
                    turnText
                    clockText(at: date)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(T1.surface)
        .overlay(alignment: .trailing) {
            if isOrganizer, store.phase == .drafting, let c = store.onClock, c.participantId != store.me?.participantId, let pickFor {
                Button(action: pickFor) {
                    LabelText("Pick for", color: T1.text)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(T1.surfaceHover)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
        }
        .onChange(of: date) { _, now in store.expireIfDue(now: now) }
    }

    @ViewBuilder
    private var turnText: some View {
        if let n = store.picksUntilMine {
            if n == 0 { LabelText("Your pick", color: T1.accent) } else { LabelText("You pick in \(n)") }
        } else if store.me == nil {
            LabelText("Watching")
        } else {
            LabelText("Your picks are done")
        }
    }

    @ViewBuilder
    private func clockText(at date: Date) -> some View {
        if store.draft.clock?.isEmpty == false, store.pending == nil, let c = store.onClock {
            if store.draft.clockPaused {
                LabelText(" · Paused")
            } else if c.overdue || (store.secondsLeft(at: date) ?? 1) == 0 {
                LabelText(" · Overdue", color: T1.danger)
            } else if let left = store.secondsLeft(at: date) {
                LabelText(" · \(RotoMath.countdownText(left))").monospacedDigit()
            }
        }
    }
}

// MARK: color bar

/// Thin bar in the card's colors (gold for none); lands get a neutral bar.
struct RotoColorBar: View {
    let colors: [String]
    var isLand = false
    var vertical = false

    static func color(_ c: String) -> Color {
        switch c {
        case "W": Color(red: 0.96, green: 0.93, blue: 0.80)
        case "U": Color(red: 0.25, green: 0.55, blue: 0.95)
        case "B": Color(red: 0.55, green: 0.50, blue: 0.58)
        case "R": Color(red: 0.92, green: 0.33, blue: 0.27)
        case "G": Color(red: 0.25, green: 0.70, blue: 0.40)
        default: Color(red: 0.62, green: 0.62, blue: 0.66)
        }
    }

    var body: some View {
        let list = colors.isEmpty ? [isLand ? "L" : "C"] : colors
        let stack = ForEach(list, id: \.self) { Self.color($0) }
        if vertical { VStack(spacing: 0) { stack } } else { HStack(spacing: 0) { stack } }
    }
}

// MARK: grid

/// Scroll offset of the grid, read only by the sticky header and column (so scrolling doesn't redraw the cells).
@Observable
final class RotoGridScroll {
    var offset: CGPoint = .zero
}

private extension View {
    /// iOS 18+: the scroll view reports its offset directly (the preference below is the iOS 17 path).
    @ViewBuilder
    func trackGridOffset(_ scroll: RotoGridScroll) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGPoint.self) { g in
                CGPoint(x: -(g.contentOffset.x + g.contentInsets.leading), y: -(g.contentOffset.y + g.contentInsets.top))
            } action: { _, p in scroll.offset = p }
        } else {
            self
        }
    }
}

private struct GridOffsetKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// The classic roto sheet: seats across (sticky names), rounds down (sticky numbers with the snake direction).
/// Cells: card name, color bar, AUTO for automatic picks; the next pick outlined in accent.
struct RotoGridView: View {
    let store: RotoStore
    var interactive = true
    let openCube: () -> Void
    @State private var scroll = RotoGridScroll()

    static let cellW: CGFloat = 108
    static let cellH: CGFloat = 46
    static let headerH: CGFloat = 34
    static let colW: CGFloat = 44

    var body: some View {
        let seats = store.orderedSeats
        let n = max(1, store.players)
        let rounds = max(1, store.draft.picksPerPlayer)
        let next = store.phase == .drafting && store.pending == nil ? store.picksMade + 1 : nil
        let current = RotoMath.round(players: n, pickNo: min(store.total, max(1, store.picksMade + 1)))
        if seats.isEmpty {
            HairlineList { Notice("No one is seated yet.") }
        } else {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(1...rounds, id: \.self) { r in
                            // Its own view, so each row observes the picks and names it shows.
                            RotoGridRow(store: store, round: r, players: n, next: next, interactive: interactive, openCube: openCube)
                                .padding(.leading, Self.colW + 1)
                                .id(r)
                        }
                    }
                    .padding(.top, Self.headerH + 1)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: GridOffsetKey.self, value: g.frame(in: .named("roto-grid")).origin)
                    })
                }
                .coordinateSpace(name: "roto-grid")
                .onPreferenceChange(GridOffsetKey.self) { scroll.offset = $0 }
                .trackGridOffset(scroll)
                .overlay(alignment: .topLeading) { RotoGridHeader(store: store, seats: seats, scroll: scroll) }
                .overlay(alignment: .topLeading) { RotoGridRounds(rounds: rounds, current: current, snake: store.draft.snake, scroll: scroll) }
                .overlay(alignment: .topLeading) {
                    LabelText("Rd").frame(width: Self.colW, height: Self.headerH).background(T1.surface)
                }
                .onAppear {
                    if current > 3 { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.35)) }
                    // First render (once per draft): from appearing to the next run of the main queue, by which time
                    // the visible cells are laid out.
                    if !store.gridTraced, store.loaded {
                        store.gridTraced = true
                        let span = RotoTrace.start("roto.grid", "first_render")
                        DispatchQueue.main.async { span?.finish() }
                    }
                }
            }
            .background(T1.bg)
        }
    }
}

/// One round of the sheet: a cell per seat.
private struct RotoGridRow: View {
    let store: RotoStore
    let round: Int
    let players: Int
    let next: Int?
    let interactive: Bool
    let openCube: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...players, id: \.self) { s in
                cell(no: RotoMath.pickNo(seat: s, round: round, players: players, snake: store.draft.snake), next: next)
            }
        }
    }

    @ViewBuilder
    private func cell(no: Int, next: Int?) -> some View {
        let p = no <= store.total ? store.pick(no) : nil
        let card = p.flatMap { store.card(slot: $0.slot) }
        let isNext = next == no
        Button {
            if let p { RotoCardPanel.present(store: store, slot: p.slot, isOrganizer: false, readOnly: !interactive, from: .grid) }
            else if isNext && interactive { openCube() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let card {
                    RotoColorBar(colors: card.colors, isLand: card.isLand).frame(height: 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let card {
                        Text(card.name).font(T1.mono(10)).lineLimit(2).foregroundStyle(store.pending?.pickNo == no ? T1.muted : T1.text)
                        if p?.automatic == true { Text("AUTO").font(T1.mono(8)).tracking(1).foregroundStyle(T1.muted) }
                    } else if isNext {
                        Text("#\(no)").font(T1.mono(10)).foregroundStyle(T1.accent)
                    } else if no <= store.total {
                        Text("\(no)").font(T1.mono(9)).foregroundStyle(T1.disabled)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                Spacer(minLength: 0)
            }
            .frame(width: RotoGridView.cellW, height: RotoGridView.cellH, alignment: .topLeading)
            .background(T1.surface)
            .overlay { if isNext { Rectangle().strokeBorder(T1.accent, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
    }
}

/// Seat names across the top, moving with the grid sideways only. Your column is accent.
private struct RotoGridHeader: View {
    let store: RotoStore
    let seats: [RotoSeat]
    let scroll: RotoGridScroll

    var body: some View {
        HStack(spacing: 1) {
            ForEach(seats) { s in
                Text((s.me ? "You" : s.displayName).uppercased())
                    .font(T1.mono(10)).tracking(1).lineLimit(1)
                    .foregroundStyle(s.me ? T1.accent : T1.text)
                    .padding(.horizontal, 6)
                    .frame(width: RotoGridView.cellW, height: RotoGridView.headerH, alignment: .leading)
                    .background(T1.surface)
            }
        }
        .offset(x: scroll.offset.x + RotoGridView.colW + 1)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: RotoGridView.headerH)
        .background(T1.bg)
        .clipped()
    }
}

/// Round numbers down the side with the direction of each round (→ seat 1 first, ← last seat first).
private struct RotoGridRounds: View {
    let rounds: Int
    let current: Int
    let snake: Bool
    let scroll: RotoGridScroll

    var body: some View {
        VStack(spacing: 1) {
            ForEach(1...rounds, id: \.self) { r in
                VStack(spacing: 0) {
                    Text("\(r)").font(T1.mono(11)).foregroundStyle(r == current ? T1.text : T1.muted)
                    Text(snake && r % 2 == 0 ? "←" : "→").font(T1.mono(10)).foregroundStyle(T1.muted)
                }
                .frame(width: RotoGridView.colW, height: RotoGridView.cellH)
                .background(r == current ? T1.surfaceHover : T1.surface)
            }
        }
        .offset(y: scroll.offset.y + RotoGridView.headerH + 1)
        .frame(width: RotoGridView.colW)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(T1.bg)
        .clipped()
    }
}

// MARK: cube

/// Every card in the pool by color, with search and Available · All · Picked. Picked cards stay in place with a
/// flat #545461 tag `#23 · ANNA`.
struct RotoCubeView: View {
    let store: RotoStore
    let isOrganizer: Bool
    var readOnly = false
    @State private var query = ""
    @State private var filter = "available"

    var body: some View {
        let groups = grouped()
        VStack(spacing: 1) {
            T1SearchField(text: $query, prompt: "Search the cube")
            T1Segmented(options: [(value: "available", label: "Available"), (value: "all", label: "All"), (value: "picked", label: "Picked")],
                        selection: $filter)
            HairlineList {
                if store.pool.isEmpty { Notice(store.loaded ? "The pool appears when the draft starts." : "Loading…") }
                ForEach(groups, id: \.name) { g in
                    Section1("\(g.name) · \(g.slots.count)")
                    ForEach(g.slots, id: \.self) { slot in
                        RotoCubeRow(store: store, slot: slot, isOrganizer: isOrganizer, readOnly: readOnly)
                    }
                }
                if !store.pool.isEmpty && groups.isEmpty { Notice(query.isEmpty ? "Nothing here." : "No card matches \u{201C}\(query)\u{201D}") }
            }
        }
    }

    private func grouped() -> [(name: String, slots: [Int])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var by: [String: [Int]] = [:]
        for slot in store.poolOrder {
            let taken = store.takenBy(slot: slot) != nil
            if filter == "available" && taken { continue }
            if filter == "picked" && !taken { continue }
            guard let card = store.card(slot: slot) else { continue }
            if !q.isEmpty && !card.name.lowercased().contains(q) { continue }
            by[card.group, default: []].append(slot)
        }
        return ListLine.colorOrder.compactMap { g in by[g].map { (g, $0) } }
    }
}

/// A pool card: color bar, name, type · mana value; picked ones carry `#23 · ANNA`, listed ones `LISTED #4`.
private struct RotoCubeRow: View {
    let store: RotoStore
    let slot: Int
    let isOrganizer: Bool
    let readOnly: Bool

    var body: some View {
        let card = store.card(slot: slot)
        let taken = store.takenBy(slot: slot)
        return Button {
            RotoCardPanel.present(store: store, slot: slot, isOrganizer: isOrganizer, readOnly: readOnly, from: .cube)
        } label: {
            HStack(spacing: 12) {
                RotoColorBar(colors: card?.colors ?? [], isLand: card?.isLand ?? false, vertical: true).frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card?.name ?? "Card").font(T1.mono(14)).lineLimit(1).foregroundStyle(taken == nil ? T1.text : T1.muted)
                    LabelText(card.map(detail) ?? "")
                }
                Spacer(minLength: 0)
                if let taken {
                    RotoPickedTag(text: "#\(taken.pickNo) · \(store.name(seat: taken.seat))")
                } else if let n = store.inList(slot) {
                    LabelText("Listed #\(n)")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(T1.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ c: RotoCard) -> String {
        let type = c.typeLine.components(separatedBy: " — ").first ?? c.typeLine
        return c.isLand ? type : "\(type) · \(c.manaValue)"
    }
}

/// The flat disabled-color tag on picked cards: `#23 · ANNA`.
struct RotoPickedTag: View {
    let text: String
    var body: some View {
        LabelText(text, color: T1.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(T1.disabled)
    }
}

// MARK: picks

/// One player's picks: You first, then seat order. Color counts, a mana-value curve, creatures; list or images.
struct RotoPicksView: View {
    let store: RotoStore
    var openDeck: ((String) -> Void)?
    @State private var seat: Int?
    @State private var images = false

    var body: some View {
        let seats = choices
        let chosen = seat ?? seats.first?.seat ?? 1
        let slots = store.picks(seat: chosen).map(\.slot)
        let cards = slots.compactMap { store.card(slot: $0) }
        VStack(spacing: 1) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(seats) { s in
                        let on = s.seat == chosen
                        Button { seat = s.seat } label: {
                            LabelText(s.me ? "You" : s.displayName, color: on ? T1.ink : T1.text)
                                .padding(.horizontal, 14).padding(.vertical, 14)
                                .background(on ? T1.text : T1.surface)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: seat)
            HairlineList {
                RotoPickStats(cards: cards)
                if store.seat(chosen)?.me == true, let deck = store.me?.deckListId, let openDeck {
                    Button {
                        Telemetry.capture("roto_deck_opened", ["from": "picks"])
                        openDeck(deck)
                    } label: {
                        ListRow(title: "Open deck", detail: "Your picks land in Main as you draft") { LabelText("›", color: T1.text) }
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 1) {
                    Section1("\(cards.count) pick\(cards.count == 1 ? "" : "s")")
                    Button { images.toggle() } label: {
                        LabelText(images ? "List" : "Images", color: T1.text)
                            .padding(.horizontal, 16).padding(.vertical, 8).background(T1.surface)
                    }
                    .buttonStyle(.plain)
                }
                if cards.isEmpty { Notice("No picks yet.") }
                if images {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(slots, id: \.self) { slot in
                            let c = store.card(slot: slot)
                            Button { RotoCardPanel.present(store: store, slot: slot, isOrganizer: false, readOnly: true) } label: {
                                if let p = c?.printing { p.art(width: 104) } else { Text(c?.name ?? "").font(T1.mono(10)).frame(width: 104, height: 145).background(T1.surface) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                } else {
                    let order = ListLine.colorOrder
                    ForEach(order, id: \.self) { g in
                        let inGroup = slots.filter { store.card(slot: $0)?.group == g }
                        if !inGroup.isEmpty {
                            Section1("\(g) · \(inGroup.count)")
                            ForEach(inGroup, id: \.self) { slot in RotoPickRow(store: store, slot: slot) }
                        }
                    }
                }
            }
        }
    }

    /// You first, then seat order.
    private var choices: [RotoSeat] {
        let seated = store.orderedSeats.filter { $0.seat != nil }
        return seated.filter(\.me) + seated.filter { !$0.me }
    }
}

/// Color counts, a mana-value curve (0 … 7+) and creatures / other spells / lands.
struct RotoPickStats: View {
    let cards: [RotoCard]

    var body: some View {
        let spells = cards.filter { !$0.isLand }
        let curve = (0...7).map { mv in spells.filter { mv == 7 ? $0.manaValue >= 7 : $0.manaValue == mv }.count }
        let top = max(1, curve.max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(["W", "U", "B", "R", "G"], id: \.self) { c in
                    let n = cards.filter { $0.colors.contains(c) }.count
                    HStack(spacing: 4) {
                        RotoColorBar(colors: [c]).frame(width: 8, height: 8)
                        Text("\(n)").font(T1.mono(13)).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<8, id: \.self) { i in
                    VStack(spacing: 3) {
                        Text("\(curve[i])").font(T1.mono(9)).foregroundStyle(T1.muted)
                        Rectangle().fill(T1.text).frame(height: max(1, CGFloat(curve[i]) / CGFloat(top) * 40))
                        Text(i == 7 ? "7+" : "\(i)").font(T1.mono(9)).foregroundStyle(T1.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 70, alignment: .bottom)
            LabelText("\(spells.filter(\.isCreature).count) creatures · \(spells.filter { !$0.isCreature }.count) other spells · \(cards.count - spells.count) lands")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
    }
}

/// One pick in the Picks list: name, type · mana value, `#37 · AUTO`.
private struct RotoPickRow: View {
    let store: RotoStore
    let slot: Int

    var body: some View {
        let c = store.card(slot: slot)
        let p = store.takenBy(slot: slot)
        Button { RotoCardPanel.present(store: store, slot: slot, isOrganizer: false, readOnly: true) } label: {
            ListRow(title: c?.name ?? "Card", detail: c.map { "\($0.typeLine.components(separatedBy: " — ").first ?? "") · \($0.manaValue)" }) {
                LabelText(p.map { "#\($0.pickNo)\($0.automatic ? " · auto" : "")" } ?? "")
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: my list

/// Your ranked pick order: drag to reorder, × to remove, the auto-pick switch. Saved ~600 ms after the last change.
struct RotoListView: View {
    let store: RotoStore
    var readOnly = false
    let addFromCube: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            T1Switch(title: "Auto-pick from my list",
                     detail: store.autoPick ? "When it's your turn, the top card still there is picked for you" : "Off: the draft waits for you",
                     isOn: Binding(get: { store.autoPick }, set: { store.setAutoPick($0) }))
                .disabled(readOnly)
            if !store.takenFromList.isEmpty {
                ForEach(store.takenFromList, id: \.slot) { t in
                    Notice("\(store.card(slot: t.slot)?.name ?? "A card") · taken by \(store.name(seat: t.pick.seat)) (#\(t.pick.pickNo))")
                }
                .onDisappear { store.dismissTaken() }
            }
            if store.queue.isEmpty {
                Notice("Nothing listed. Add cards from the cube in the order you want them; with auto-pick on they're picked for you when your turn comes.")
            }
            List {
                ForEach(Array(store.queue.enumerated()), id: \.element) { i, slot in
                    RotoListRow(store: store, slot: slot, rank: i + 1, readOnly: readOnly)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(T1.surface)
                        .listRowSeparatorTint(T1.bg)
                }
                .onMove(perform: readOnly ? nil : { store.moveInList(from: $0, to: $1) })
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(readOnly ? .inactive : .active))
            .tint(T1.muted)
            .frame(maxHeight: .infinity)
            if !readOnly { Ghost(text: "Add from the cube") { addFromCube() } }
        }
    }
}

/// One card on your list: rank, color, name (opens the card), ×.
private struct RotoListRow: View {
    let store: RotoStore
    let slot: Int
    let rank: Int
    let readOnly: Bool

    var body: some View {
        let c = store.card(slot: slot)
        HStack(spacing: 12) {
            Text("\(rank)").font(T1.mono(12)).foregroundStyle(T1.muted).frame(width: 26, alignment: .trailing)
            RotoColorBar(colors: c?.colors ?? [], isLand: c?.isLand ?? false, vertical: true).frame(width: 3, height: 24)
            Button { RotoCardPanel.present(store: store, slot: slot, isOrganizer: false, readOnly: readOnly, from: .list) } label: {
                Text(c?.name ?? "Card").font(T1.mono(14)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !readOnly {
                Button { store.removeFromList(slot) } label: {
                    Text("×").font(T1.mono(18)).foregroundStyle(T1.muted).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(c?.name ?? "card")")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .foregroundStyle(T1.text)
    }
}

// MARK: card panel

/// A card from the pool: picture, who took it, and Pick (your turn; organizers: Pick for) / your list.
struct RotoCardPanel: View {
    let store: RotoStore
    let slot: Int
    let isOrganizer: Bool
    var readOnly = false
    var from: RotoStore.PickSource = .detail
    @State private var confirm = false

    @MainActor
    static func present(store: RotoStore, slot: Int, isOrganizer: Bool, readOnly: Bool, from: RotoStore.PickSource = .detail) {
        T1Overlays.shared.present { RotoCardPanel(store: store, slot: slot, isOrganizer: isOrganizer, readOnly: readOnly, from: from) }
    }

    var body: some View {
        let card = store.card(slot: slot)
        let taken = store.takenBy(slot: slot)
        let clock = store.onClock
        let canPick = !readOnly && taken == nil && store.phase == .drafting && store.pending == nil
            && (store.isMyTurn || (isOrganizer && clock != nil))
        let forWhom = clock.flatMap { $0.participantId == store.me?.participantId ? nil : store.name(seat: $0.seat) }
        VStack(spacing: 1) {
            Bar(title: card?.name ?? "Card", subtitle: card.map { $0.typeLine }) {
                BarButton("Close") { T1Overlays.shared.dismissPanel() }
            }
            HStack {
                Spacer()
                if let p = card?.printing { p.art(width: 220) }
                Spacer()
            }
            .padding(.vertical, 16).background(T1.surface)
            if let taken {
                ListRow(title: "Picked #\(taken.pickNo) by \(store.name(seat: taken.seat))",
                        detail: taken.how == "player" ? nil : taken.how == "organizer" ? "Picked by the organizer" : "Picked from their list")
            } else if let n = store.inList(slot) {
                ListRow(title: "Available", detail: "On your list at #\(n)")
            } else {
                ListRow(title: "Available")
            }
            if !readOnly && taken == nil && store.me != nil && store.phase != .done {
                if store.inList(slot) != nil {
                    Ghost(text: "Remove from my list") { store.removeFromList(slot) }
                } else {
                    Ghost(text: "Add to my list") { store.addToList(slot) }
                }
            }
            if canPick {
                BigAction(text: forWhom.map { "Pick for \($0)" } ?? "Pick", accent: true) { confirm = true }
            }
        }
        .foregroundStyle(T1.text)
        .alert(forWhom.map { "Pick \(card?.name ?? "this card") for \($0)?" } ?? "Pick \(card?.name ?? "this card")?", isPresented: $confirm) {
            Button("Not yet", role: .cancel) {}
            Button("Pick") {
                T1Overlays.shared.dismissPanel()
                Task { await store.pick(slot: slot, from: from) }
            }
        } message: {
            Text(forWhom == nil ? "It goes into your deck. Picks can't be taken back (the organizer can undo)." : "Recorded as an organizer pick.")
        }
    }
}

struct RotoDeckID: Identifiable, Hashable { let id: String }

/// Your linked deck (an ordinary Library deck) over the draft, with the Library's screens behind it.
struct RotoDeckScreen: View {
    let listId: String
    @State private var path: [LibraryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ListDetailView(listId: listId, path: $path)
                .screen("deck")
                .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0, path: $path) }
        }
        .background(T1.bg.ignoresSafeArea())
        .overlay { RotoCoverOverlays(base: base) }
        .onAppear { base = T1Overlays.shared.panels.count }
    }

    @State private var base = 0
}

/// Menus and panels opened from inside a full-screen cover (the app's host sits behind it). Panels that were
/// already open under the cover (`base`) stay where they are.
private struct RotoCoverOverlays: View {
    let base: Int

    var body: some View {
        let overlays = T1Overlays.shared
        ZStack {
            ForEach(Array(overlays.panels.dropFirst(base))) { panel in
                if panel.full {
                    panel.content.frame(maxWidth: .infinity, maxHeight: .infinity).background(T1.bg.ignoresSafeArea())
                } else {
                    ZStack(alignment: .bottom) {
                        T1Scrim { overlays.dismissPanel() }
                        panel.content.frame(maxWidth: .infinity).padding(.top, 1).background(T1.bg.ignoresSafeArea(edges: .bottom))
                    }
                }
            }
            if let menu = overlays.menu {
                ZStack(alignment: .bottom) {
                    T1Scrim { overlays.menu = nil }
                    T1MenuPanel(spec: menu) { overlays.menu = nil }
                }
            }
        }
        .foregroundStyle(T1.text)
    }
}
