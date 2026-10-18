import SwiftUI

/* Deck and cube stats, one tap below the list (contract/lists-2026-10-15.md, "Stats"). The list screen shows a
   one-line summary (ListStatsRow); the Stats screen has the detail, and the sample hand, draw odds and sample pack
   are each one more tap. All math is in DeckStats.swift. */

/// A list line read for stats, with what the screens need to draw it.
struct StatLine: Identifiable, Hashable {
    let id: String
    var card: StatCard
    let cardId: String
    let finish: String
    let printing: CatalogPrinting?
    let oracleId: String?

    /// The list's lines with catalog data; lines the pack doesn't know are left out.
    nonisolated static func resolve(_ entries: [CardList.Entry], _ db: CatalogDB) -> [StatLine] {
        let printings = db.printings(ids: entries.map(\.cardId))
        let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
        return entries.enumerated().compactMap { i, e in
            guard let p = printings[e.cardId], let o = oracles[p.oracleIdx] else { return nil }
            return StatLine(id: "\(e.board)|\(e.cardId)|\(e.finish)|\(i)",
                            card: StatCard(name: o.name, qty: e.qty, board: e.board, type: o.typeLine, cost: o.manaCost, cmc: o.cmc,
                                           colors: o.colors, legal: o.legal, rarity: p.rarity),
                            cardId: e.cardId, finish: e.finish, printing: p, oracleId: o.oracleId)
        }
    }

    /// Resolves the current list off the main thread, with prices filled from the PriceBook.
    @MainActor
    static func load(listId: String) async -> [StatLine]? {
        let catalog = CatalogStore.shared
        catalog.load(userInitiated: true)
        guard let db = catalog.db, let list = ListsStore.shared.list(id: listId) else { return nil }
        let entries = list.entries
        let lines = await Task.detached(priority: .userInitiated) { resolve(entries, db) }.value
        await PriceBook.shared.load(lines.map(\.cardId))
        return withPrices(lines)
    }

    @MainActor
    static func withPrices(_ lines: [StatLine]) -> [StatLine] {
        lines.map { var l = $0; l.card.usd = PriceBook.shared.usd(l.cardId, l.finish); return l }
    }
}

private func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
private func dec(_ x: Double) -> String { String(format: "%.2f", x) }
private func usd(_ x: Double) -> String { x.formatted(.currency(code: "USD").precision(.fractionLength(2))) }

/// The task id that re-resolves stats when the catalog, the list's cards or its counts change.
@MainActor
private func statsKey(_ listId: String) -> String {
    let l = ListsStore.shared.list(id: listId)
    return "\(CatalogStore.shared.generation)|\(l?.current?.number ?? 0)|\(l?.entries.reduce(0) { $0 &* 31 &+ $1.qty &+ $1.cardId.hashValue } ?? 0)"
}

// MARK: the summary row on the list screen

struct ListStatsRow: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @State private var lines: [StatLine]?

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        if let list, !list.entries.isEmpty {
            Button { path.append(.listStats(listId)) } label: {
                ListRow(title: "Stats", detail: lines.map { summary($0.map(\.card), kind: list.kind) } ?? "Reading cards…")
            }
            .buttonStyle(.plain)
            .task(id: statsKey(listId)) { lines = await StatLine.load(listId: listId) }
        }
    }

    private func summary(_ cards: [StatCard], kind: CardList.Kind) -> String {
        if kind == .cube {
            let main = cards.filter { $0.board == "main" }
            let b = DeckStats.colorBalance(main)
            return zip(["W", "U", "B", "R", "G", "M", "C", "L"], b).filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        }
        let deck = DeckStats.deck(cards)
        let lands = deck.filter(DeckStats.isLand).reduce(0) { $0 + $1.qty }
        let price = DeckStats.price(cards)
        return ["\(lands) lands", "avg MV \(dec(DeckStats.averageMV(cards, withLands: false)))",
                price.total > 0 ? usd(price.total) : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: shared pieces

/// A label + value cell in a hairline row of cells.
private struct StatCell: View {
    let label: String
    let value: String
    var accent = false
    var body: some View {
        VStack(spacing: 2) {
            LabelText(label)
            Text(value).font(T1.mono(20)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(accent ? T1.accent : T1.text)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14).background(T1.surface)
    }
}

/// A row of `cells.count` equal columns on the hairline grid.
private struct CellRow: View {
    let cells: [(String, String)]
    var body: some View {
        HStack(spacing: 1) { ForEach(cells.indices, id: \.self) { i in StatCell(label: cells[i].0, value: cells[i].1) } }
    }
}

/// A text-only button in the kit's look; disabled is a flat fill, never dimmed.
private struct StatsButton: View {
    let text: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            LabelText(text, color: enabled ? T1.text : T1.ink)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(enabled ? T1.surface : T1.disabled)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Columns of stacked bars on the hairline grid, one per mana value: creatures solid, other spells muted.
private struct CurveBars: View {
    let creatures: [Int]
    let other: [Int]
    var height: CGFloat = 120

    var body: some View {
        let top = max(1, zip(creatures, other).map { $0 + $1 }.max() ?? 1)
        VStack(spacing: 1) {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<8, id: \.self) { i in
                    let total = creatures[i] + other[i]
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(total == 0 ? "" : "\(total)").font(T1.mono(12)).monospacedDigit().padding(.bottom, 4)
                        Rectangle().fill(T1.muted).frame(height: height * CGFloat(other[i]) / CGFloat(top))
                        Rectangle().fill(T1.text).frame(height: height * CGFloat(creatures[i]) / CGFloat(top))
                    }
                    .frame(maxWidth: .infinity).frame(height: height + 22)
                    .padding(.horizontal, 6).padding(.top, 8)
                    .background(T1.surface)
                }
            }
            HStack(spacing: 1) {
                ForEach(DeckStats.buckets, id: \.self) { b in
                    LabelText(b).frame(maxWidth: .infinity).padding(.vertical, 8).background(T1.surface)
                }
            }
            HStack(spacing: 16) {
                legend(T1.text, "Creatures \(creatures.reduce(0, +))")
                legend(T1.muted, "Other spells \(other.reduce(0, +))")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(T1.surface)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) { Rectangle().fill(color).frame(width: 10, height: 10); LabelText(text) }
    }
}

/// A plain table on the hairline grid: a header row, then rows of equal-width cells (the first one wider).
private struct StatTable: View {
    let header: [String]
    let rows: [[String]]
    /// Width of every column after the first, which takes the rest.
    var cellWidth: CGFloat = 72
    var body: some View {
        VStack(spacing: 1) {
            line(header, label: true)
            ForEach(rows.indices, id: \.self) { i in line(rows[i], label: false) }
        }
    }

    private func line(_ cells: [String], label: Bool) -> some View {
        HStack(spacing: 1) {
            ForEach(cells.indices, id: \.self) { i in
                Group {
                    if label { LabelText(cells[i]) } else { Text(cells[i]).font(T1.mono(13)).monospacedDigit().lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
                .padding(.leading, i == 0 ? 16 : 0).padding(.trailing, i == 0 ? 8 : cellWidth < 60 ? 6 : 8)
                .padding(.vertical, label ? 8 : 12)
                .frame(maxWidth: i == 0 ? .infinity : cellWidth)
                .background(T1.surface)
            }
        }
    }
}

/// A whole card with no count tag (sample hands and packs hold single copies).
private struct PlainCard: View {
    let line: StatLine
    let width: CGFloat
    var body: some View {
        Group {
            if let p = line.printing {
                p.art(width: width)
            } else {
                RoundedRectangle(cornerRadius: width * 0.0432).fill(T1.surface).frame(width: width, height: width / CardArt.aspect)
                    .overlay { LabelText(line.card.name).padding(6) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.card.name)
    }
}

// MARK: the Stats screen

struct ListStatsView: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [StatLine]?
    @State private var asfanBy: DeckStats.AsfanBy = .color
    @AppStorage("library.cube.packSize") private var packSize = 15

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        T1Screen {
            Bar(title: "Stats", subtitle: list?.name, back: { dismiss() })
            CatalogStatusRow(catalog: CatalogStore.shared)
            if let list, let lines {
                HairlineList {
                    if list.kind == .deck { deck(list, lines.map(\.card)) } else { cube(lines.map(\.card).filter { $0.board == "main" }) }
                }
            } else if list == nil {
                Notice("That list isn't here anymore.", error: true)
            }
        }
        .task(id: statsKey(listId)) { lines = await StatLine.load(listId: listId) }
    }

    // MARK: deck

    @ViewBuilder private func deck(_ list: CardList, _ cards: [StatCard]) -> some View {
        let deck = DeckStats.deck(cards)
        let size = deck.reduce(0) { $0 + $1.qty }
        let lands = deck.filter(DeckStats.isLand).reduce(0) { $0 + $1.qty }
        let curve = DeckStats.curve(cards)
        let price = DeckStats.price(cards)
        CellRow(cells: [("Cards", "\(size)"), ("Lands", "\(lands)"), ("Spells", "\(size - lands)"),
                        ("Avg MV", dec(DeckStats.averageMV(cards, withLands: false)))])

        Section1("Mana curve · spells by mana value")
        CurveBars(creatures: curve.creatures, other: curve.other)

        Section1("Types")
        let types = DeckStats.typeCounts(deck)
        // Its own stack: index ids would collide with other rows in the lazy list.
        VStack(spacing: 1) {
            ForEach(DeckStats.types.indices.filter { types[$0] > 0 }, id: \.self) { i in
                ListRow(title: DeckStats.types[i]) { Text("\(types[i])").font(T1.mono(17)).monospacedDigit() }
            }
        }
        ListRow(title: "Average mana value",
                detail: "With lands \(dec(DeckStats.averageMV(cards, withLands: true))) · without \(dec(DeckStats.averageMV(cards, withLands: false)))")
        if types.reduce(0, +) > size {
            Notice("A card counts once for each of its types: an artifact creature is in both.")
        }

        Section1("Colors · pips in costs vs sources")
        colors(cards)

        legality(list, cards)

        Section1("Price")
        ListRow(title: price.total > 0 ? usd(price.total) : "No prices yet",
                detail: price.unpriced > 0 ? "TCGplayer market · \(price.unpriced) unpriced" : "TCGplayer market · main and side")

        Section1("Try it")
        Button { path.append(.sampleHand(listId)) } label: {
            ListRow(title: "Sample hand", detail: "Draw seven, mulligan, draw the next card")
        }.buttonStyle(.plain)
        Button { path.append(.drawOdds(listId)) } label: {
            ListRow(title: "Draw odds", detail: "Chance to see cards by a turn")
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func colors(_ cards: [StatCard]) -> some View {
        let pips = DeckStats.pipTotals(cards)
        let src = DeckStats.sources(cards)
        let pipSum = max(1, pips.reduce(0, +))
        let lands = max(1, DeckStats.deck(cards).filter(DeckStats.isLand).reduce(0) { $0 + $1.qty })
        let shown = (0..<5).filter { pips[$0] > 0 || src.colors[$0] > 0 }
        if shown.isEmpty {
            ListRow(title: "Colorless", detail: "No colored mana symbols or colored lands")
        } else {
            StatTable(header: ["Color", "Pips", "Share", "Lands", "Share"],
                      rows: shown.map { i in
                          [DeckStats.colorGroups[i], "\(pips[i])", pct(Double(pips[i]) / Double(pipSum)),
                           "\(src.colors[i])", pct(Double(src.colors[i]) / Double(lands))]
                      })
        }
        if src.unread > 0 {
            Notice("Lands count by their basic land types. \(src.unread) land\(src.unread == 1 ? " has" : "s have") none (fetch or utility lands) and \(src.unread == 1 ? "isn't" : "aren't") counted.")
        }
    }

    @ViewBuilder private func legality(_ list: CardList, _ cards: [StatCard]) -> some View {
        let checked = CatalogPack.legalityFormats + ["canlander"]
        Section1("Legality · \(formatName(list.format))")
        if checked.contains(list.format) {
            let issues = DeckStats.legality(cards, format: list.format)
            if issues.isEmpty {
                ListRow(title: "Legal in \(formatName(list.format))", detail: "Main deck and sideboard") { LabelText("Legal", color: T1.accent) }
            } else {
                // Its own stack: index ids would collide with other rows in the lazy list.
                VStack(spacing: 1) {
                    ForEach(issues, id: \.name) { i in
                        ListRow(title: i.name) { LabelText(i.reason, color: T1.error) }
                    }
                }
            }
        } else {
            ListRow(title: "Not checked", detail: "\(formatName(list.format)) has no legality list")
        }
        let others = checked.filter { $0 != list.format }
        let cells = others.map { f in (f == "canlander" ? "Canlander" : formatName(f), DeckStats.legality(cards, format: f).count) }
        VStack(spacing: 1) {
            ForEach(Array(stride(from: 0, to: cells.count, by: 4)), id: \.self) { start in
                HStack(spacing: 1) {
                    ForEach(start..<min(start + 4, cells.count), id: \.self) { i in
                        VStack(spacing: 2) {
                            LabelText(cells[i].0)
                            Text(cells[i].1 == 0 ? "Legal" : "\(cells[i].1) card\(cells[i].1 == 1 ? "" : "s")").font(T1.mono(12))
                                .foregroundStyle(cells[i].1 == 0 ? T1.text : T1.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10).background(T1.surface)
                    }
                    if start + 4 > cells.count { ForEach(0..<(start + 4 - cells.count), id: \.self) { _ in T1.surface.frame(maxWidth: .infinity) } }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: cube

    @ViewBuilder private func cube(_ cards: [StatCard]) -> some View {
        let size = cards.reduce(0) { $0 + $1.qty }
        let balance = DeckStats.colorBalance(cards)
        CellRow(cells: [("Cards", "\(size)"), ("Lands", "\(balance[7])"),
                        ("Avg MV", dec(DeckStats.averageMV(cards.map { var c = $0; c.board = "main"; return c }, withLands: false)))])

        Section1("Color balance")
        StatTable(header: ["Color", "Cards", "Share"],
                  rows: DeckStats.colorGroups.indices.filter { balance[$0] > 0 }.map { i in
                      [DeckStats.colorGroups[i], "\(balance[i])", pct(Double(balance[i]) / Double(max(1, size)))]
                  })

        Section1("Curve per color · mana value")
        let byColor = DeckStats.curveByColor(cards)
        // One letter per color so nine columns fit a phone: W U B R G, M multicolor, C colorless.
        StatTable(header: ["Color"] + DeckStats.buckets,
                  rows: byColor.indices.filter { byColor[$0].reduce(0, +) > 0 }.map { i in
                      [["W", "U", "B", "R", "G", "M", "C"][i]] + byColor[i].map { $0 == 0 ? "·" : "\($0)" }
                  },
                  cellWidth: 36)

        Section1("Type mix")
        let types = DeckStats.typeCounts(cards)
        // Its own stack: index ids would collide with other rows in the lazy list.
        VStack(spacing: 1) {
            ForEach(DeckStats.types.indices.filter { types[$0] > 0 }, id: \.self) { i in
                ListRow(title: DeckStats.types[i], detail: pct(Double(types[i]) / Double(max(1, size)))) {
                    Text("\(types[i])").font(T1.mono(17)).monospacedDigit()
                }
            }
        }

        Section1("Asfan · expected per pack")
        T1Segmented(options: [(DeckStats.AsfanBy.color, "Color"), (.type, "Type"), (.mv, "Mana value")], selection: $asfanBy)
        T1Stepper(label: "Pack size", value: $packSize, range: 1...30)
        let asfan = DeckStats.asfan(cards, pack: packSize, by: asfanBy)
        let labels = DeckStats.asfanLabels(asfanBy)
        // Its own stack: index ids would collide with other rows in the lazy list.
        VStack(spacing: 1) {
            ForEach(labels.indices.filter { asfan[$0] > 0 }, id: \.self) { i in
                ListRow(title: labels[i]) { Text(dec(asfan[i])).font(T1.mono(17)).monospacedDigit().foregroundStyle(T1.accent) }
            }
        }
        .onChange(of: asfanBy) { Telemetry.capture("cube_asfan_changed", ["by": asfanBy.rawValue, "pack": packSize]) }

        Section1("Try it")
        Button { path.append(.samplePack(listId)) } label: {
            ListRow(title: "Sample pack", detail: "\(packSize) random cards from the cube")
        }.buttonStyle(.plain)
    }
}

// MARK: sample hand

struct SampleHandView: View {
    let listId: String
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [StatLine]?
    @State private var library: [Int] = []
    @State private var hand: SampleHand?
    @State private var hands = 0
    @State private var mulligans = 0
    @State private var draws = 0

    var body: some View {
        T1Screen {
            Bar(title: "Sample hand", subtitle: subtitle, back: { dismiss() })
            CatalogStatusRow(catalog: CatalogStore.shared)
            if let lines, let hand {
                if library.isEmpty {
                    Notice("The main deck is empty.")
                } else {
                    if hand.toBottom > 0 {
                        Notice("Mulligan to \(7 - hand.mulligans): tap \(hand.toBottom == 1 ? "a card" : "\(hand.toBottom) cards") to put on the bottom.")
                    }
                    GeometryReader { geo in
                        let width = ((geo.size.width - 2) / 3).rounded(.down)
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1), count: 3), spacing: 1) {
                                ForEach(Array(hand.hand.enumerated()), id: \.offset) { i, pos in
                                    let line = lines[library[pos]]
                                    Button { self.hand?.bottom(i) } label: {
                                        PlainCard(line: line, width: width)
                                            .overlay(alignment: .bottomLeading) {
                                                if i >= hand.hand.count - hand.drawn {
                                                    LabelText("Drawn", color: T1.ink).padding(.horizontal, 6).padding(.vertical, 3).background(T1.text)
                                                        .padding(width * 0.05)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    HStack(spacing: 1) {
                        StatsButton(text: "New hand") { deal() }
                        StatsButton(text: hand.canMulligan ? "Mulligan to \(6 - hand.mulligans)" : "Mulligan", enabled: hand.canMulligan) {
                            self.hand?.mulligan()
                            mulligans += 1
                        }
                        StatsButton(text: "Draw", enabled: hand.canDraw) {
                            self.hand?.draw()
                            draws += 1
                        }
                    }
                }
            }
        }
        .task(id: statsKey(listId)) {
            guard let l = await StatLine.load(listId: listId) else { return }
            let main = l.filter { $0.card.board == "main" }
            lines = main
            library = DeckStats.expand(main.map(\.card))
            if hand == nil || hand?.size != library.count { deal() }
        }
        .onDisappear {
            if hands > 0 { Telemetry.capture("sample_hand_used", ["hands": hands, "mulligans": mulligans, "draws": draws]) }
        }
    }

    private var subtitle: String {
        guard let hand else { return "" }
        return ["\(hand.hand.count) in hand", "library \(hand.library.count)",
                hand.mulligans > 0 ? "\(hand.mulligans) mulligan\(hand.mulligans == 1 ? "" : "s")" : nil,
                hand.drawn > 0 ? "drew \(hand.drawn)" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func deal() {
        hand = SampleHand(size: library.count, seed: StatsRNG.randomSeed())
        hands += 1
    }
}

// MARK: draw odds

struct DrawOddsView: View {
    let listId: String
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [StatLine]?
    @State private var group = "type:Land"
    @State private var atLeast = 1
    @State private var turn = 3
    @State private var onPlay = true
    @State private var changed = false

    /// Groups the calculator offers: each card type in the main deck, then each card.
    private func groups(_ main: [StatCard]) -> [(id: String, title: String, count: Int)] {
        let types = DeckStats.typeCounts(main)
        var out = DeckStats.types.indices.filter { types[$0] > 0 }.map { i in
            (id: "type:\(DeckStats.types[i])", title: DeckStats.types[i] == "Sorcery" ? "Sorceries" : "\(DeckStats.types[i])s", count: types[i])
        }
        var byName: [String: Int] = [:]
        for c in main { byName[c.name, default: 0] += c.qty }
        out += byName.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (id: "card:\($0.key)", title: $0.key, count: $0.value) }
        return out
    }

    var body: some View {
        T1Screen {
            Bar(title: "Draw odds", subtitle: ListsStore.shared.list(id: listId)?.name, back: { dismiss() })
            CatalogStatusRow(catalog: CatalogStore.shared)
            if let lines {
                let main = lines.map(\.card).filter { $0.board == "main" }
                let N = main.reduce(0) { $0 + $1.qty }
                let all = groups(main)
                let chosen = all.first { $0.id == group } ?? all.first
                let K = chosen?.count ?? 0
                HairlineList {
                    if N == 0 {
                        Notice("The main deck is empty.")
                    } else {
                        let draws = DeckStats.drawsByTurn(turn, onPlay: onPlay)
                        let p = DeckStats.hypergeometric(population: N, successes: K, draws: draws, atLeast: atLeast)
                        VStack(spacing: 6) {
                            LabelText("At least \(atLeast) of \(K) \(chosen?.title ?? "") by turn \(turn)")
                            Text(pct(p)).font(T1.mono(44)).monospacedDigit().foregroundStyle(T1.accent)
                            LabelText("\(draws) of \(N) cards seen \(onPlay ? "on the play" : "on the draw")")
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 22).background(T1.surface)
                        T1Segmented(options: [(true, "On the play"), (false, "On the draw")], selection: $onPlay)
                        T1Stepper(label: "At least", value: $atLeast, range: 1...max(1, min(K, 7 + 15)))
                        T1Stepper(label: "By turn", value: $turn, range: 1...15)

                        Section1("By turn")
                        StatTable(header: ["Turn", "Seen", "Chance"], rows: (1...8).map { t in
                            let n = DeckStats.drawsByTurn(t, onPlay: onPlay)
                            return ["Turn \(t)", "\(min(n, N))", pct(DeckStats.hypergeometric(population: N, successes: K, draws: n, atLeast: atLeast))]
                        })

                        Section1("Card group")
                        ForEach(all, id: \.id) { g in
                            Button {
                                group = g.id
                                atLeast = min(atLeast, max(1, g.count))
                            } label: {
                                ListRow(title: g.title, detail: "\(g.count) in the main deck") {
                                    if g.id == chosen?.id { LabelText("Selected", color: T1.accent) }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .onChange(of: "\(group)|\(atLeast)|\(turn)|\(onPlay)") { changed = true }
            }
        }
        .task(id: statsKey(listId)) { lines = await StatLine.load(listId: listId) }
        .onDisappear {
            if changed {
                Telemetry.capture("draw_odds_used", ["group": group.hasPrefix("card:") ? "card" : group.replacingOccurrences(of: "type:", with: "").lowercased(),
                                                     "turn": turn, "on_play": onPlay, "at_least": atLeast])
            }
        }
    }
}

// MARK: sample pack

struct SamplePackView: View {
    let listId: String
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [StatLine]?
    @State private var pack: [Int] = []
    @State private var packs = 0
    @AppStorage("library.cube.packSize") private var packSize = 15

    var body: some View {
        T1Screen {
            Bar(title: "Sample pack", subtitle: "\(pack.count) cards", back: { dismiss() })
            CatalogStatusRow(catalog: CatalogStore.shared)
            if let lines {
                let pool = DeckStats.expand(lines.map(\.card))
                if pool.isEmpty {
                    Notice("The cube is empty.")
                } else {
                    GeometryReader { geo in
                        let width = ((geo.size.width - 2) / 3).rounded(.down)
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1), count: 3), spacing: 1) {
                                ForEach(Array(pack.enumerated()), id: \.offset) { _, pos in
                                    let line = lines[pool[pos]]
                                    PlainCard(line: line, width: width)
                                }
                            }
                        }
                    }
                    StatsButton(text: "Another pack") { open(pool.count) }
                }
            }
        }
        .task(id: statsKey(listId)) {
            guard let l = await StatLine.load(listId: listId) else { return }
            lines = l.filter { $0.card.board == "main" }
            open(DeckStats.expand(lines!.map(\.card)).count)
        }
        .onDisappear { if packs > 0 { Telemetry.capture("sample_pack_used", ["packs": packs, "size": packSize]) } }
    }

    private func open(_ n: Int) {
        var rng = StatsRNG(seed: StatsRNG.randomSeed())
        pack = Array(rng.shuffle(n).prefix(packSize))
        packs += 1
    }
}
