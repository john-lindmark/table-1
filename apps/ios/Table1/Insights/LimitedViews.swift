import SwiftUI

/// Limited: Arena draft sets from 17Lands' public data (contract/insights-2026-10-24.md § Limited pack). The 17Lands
/// credit sits at the top of every Limited screen.
struct LimitedHomeSection: View {
    @Binding var path: [InsightsRoute]
    @Bindable private var store = InsightsStore.shared
    @State private var sort = "gih"
    @State private var rarity = "all"
    @State private var color = "all"
    @State private var editing = false
    @State private var query = ""
    @State private var all = false
    /// Each card's mana cost and its printing in the set (art), by name, for the pack on screen.
    @State private var faces: [String: LimitedFace] = [:]

    var body: some View {
        // The picker waits for the sets to rank (kept on the device after the first visit) so it draws whole.
        let chips = store.rankableReady ? store.shownChips : []
        Group {
            if let s = store.stale { Notice(s) }
            if chips.isEmpty {
                if let e = store.error {
                    Notice(e, error: true)
                    Ghost(text: "Try again") { Task { await store.load(force: true) } }
                } else { Notice(store.loading || !store.rankableReady ? "Loading draft data…" : "No set has 17Lands data yet. A new set's numbers arrive about three weeks after it comes out on Arena.") }
                newSets
            } else {
                picked(chips)
            }
        }
        .task { await store.loadExtras() }
    }

    /// Opens the Rankings of a set or cube version inside the Insights tab (contract/cube-rankings-2026-10-21.md § Sets).
    private func rank(_ key: String, kind: String, from: String) {
        Telemetry.capture("insights_rank_opened", ["set": key, "kind": kind, "from": from])
        path.append(.library(.rankings(RankSubject.setId(key))))
    }

    /// Sets out (or about to be) that have no 17Lands data yet: rank them now.
    @ViewBuilder private var newSets: some View {
        let fresh = store.rankable.filter { !$0.pack }
        if !fresh.isEmpty {
            Section1("New sets to rank")
            ForEach(fresh) { s in
                Button { rank(s.key, kind: s.kind, from: "new_sets") } label: { ListRow(title: "Rank \(s.name)", detail: s.detail) }.buttonStyle(.plain)
            }
        }
    }

    /// The page's one big action: rank the set (or cube), with who has already.
    @ViewBuilder private func rankBlock(_ pack: Insights.LimitedPack) -> some View {
        let r = store.rankable.first { $0.key == pack.set_code }
        let kind = r?.kind ?? (pack.cube != nil ? "cube" : "set")
        RankAction(title: "Rank this \(kind == "cube" ? "cube" : "set")",
                   detail: r.flatMap { $0.rankings > 0 ? $0.detail : nil } ?? "Stack-rank its cards by color, then a top 100. Compare with friends.") {
            rank(pack.set_code, kind: kind, from: "set")
        }
    }

    @ViewBuilder private var alertsRow: some View {
        if let on = store.alerts {
            T1Switch(title: "New in Insights", detail: "A push when a new set, cube or format arrives",
                     isOn: Binding(get: { on }, set: { v in Task { await store.setAlerts(v) } }))
        }
    }

    /// Sets with no 17Lands data yet (spoiler season, or just out) lead the picker and open Rank this set; Edit hides any.
    @ViewBuilder private func picked(_ chips: [LimitedPicker.Chip]) -> some View {
        let today = LimitedPicker.today
        let current = store.setCode.flatMap { s in chips.contains { $0.key == s } ? s : nil } ?? (chips.first { $0.pack } ?? chips[0]).key
        let soon = chips.contains { !$0.pack && $0.key == current } ? store.rankable.first { $0.key == current } : nil
        let setCell = FilterCell(name: "Set", value: chips.first { $0.key == current }?.label ?? current,
                                 options: chips.map { c in SelectorOption(value: c.key, label: c.label, detail: store.limitedName(c.key).flatMap { $0 == c.label ? nil : $0 }) }
                                     + [SelectorOption(value: FilterCell.editValue, label: "Shown sets…")],
                                 current: current) { v in
            if v == FilterCell.editValue { editing = true } else { store.setCode = v; query = ""; all = false }
        }
        if let soon {
            FilterRow(cells: [setCell])
            editor
            Notice(LimitedPicker.soonText(soon, today: today))
            RankAction(title: "Rank this set", detail: soon.detail) { rank(soon.key, kind: soon.kind, from: "soon") }
        } else if let pack = store.limited[current] {
            content(pack, setCell)
        } else {
            FilterRow(cells: [setCell])
            editor
            Notice("Loading \(LimitedPicker.label(current, store.limitedName(current)))…")
                .task { await store.load(force: true) }
        }
        alertsRow
        Color.clear.frame(height: 24)
    }

    /// Event (when the set has more than one) and Players (when there's a Top players view) after Set.
    private func eventCells(_ events: [String], _ ev: String, _ groups: [String: Insights.LView], _ grp: String) -> [FilterCell] {
        var cells: [FilterCell] = []
        if events.count > 1 {
            cells.append(FilterCell(name: "Event", value: Insights.eventLabels[ev] ?? ev, options: events.map { SelectorOption(value: $0, label: Insights.eventLabels[$0] ?? $0) },
                                    current: ev) { store.event = $0 })
        }
        if groups["top"] != nil {
            cells.append(FilterCell(name: "Players", value: grp == "top" ? "Top players" : "All players",
                                    options: [SelectorOption(value: "all", label: "All players"), SelectorOption(value: "top", label: "Top players", detail: "60%+ win rate")],
                                    current: grp) { store.group = $0 })
        }
        return cells
    }

    @ViewBuilder private var editor: some View {
        if editing {
            ShownEditor(title: "Shown sets", items: store.limitedChips.map { c in (c.key, c.label, store.limitedName(c.key).flatMap { $0 == c.label ? nil : $0 }) },
                        hidden: store.hiddenSets, set: { store.setHidden(format: false, $0, $1) }, done: { editing = false })
        }
    }

    /// Cards first (the best of them, then search and Show all), then Rank this set, the color pairs and the rest, the
    /// brief last (John's friend, 2026-11-09).
    @ViewBuilder
    private func content(_ pack: Insights.LimitedPack, _ setCell: FilterCell) -> some View {
        let events = store.events(of: pack)
        let ev = store.currentEvent(of: pack) ?? "PremierDraft"
        let groups = pack.events[ev]?.groups ?? [:]
        let grp = groups[store.group] != nil ? store.group : "all"
        let cells = [setCell] + eventCells(events, ev, groups, grp)
        FilterRow(cells: cells)
        editor
        if let v = groups[grp] {
            cards(pack, ev, grp, v)
                .task(id: "\(pack.set_code) \(CatalogStore.shared.generation)") {
                    // art and mana costs come from the card catalog: ask for it (any network) like the Library does
                    CatalogStore.shared.load(userInitiated: true)
                    faces = await LimitedFace.load(set: pack.set_code, cards: v.cards)
                }
            rankBlock(pack)
            newSets
            pairs(pack, ev, grp, v)
            scatter(pack, ev, grp, v)
            facts(v)
            BriefBlock(brief: v.brief, scope: "\(pack.name ?? pack.set_code) \(Insights.eventLabels[ev] ?? ev)\(grp == "top" ? ", top players (60%+)" : "")",
                       thin: v.games < 20000, credit: ("Data from 17Lands", URL(string: pack.credit.url)!))
            Stats3(items: [("Games", v.games.formatted()), ("Average", InsightCharts.pct1(v.wr)), ("Weeks", "\(v.weeks)")])
        }
    }

    @ViewBuilder
    private func pairs(_ pack: Insights.LimitedPack, _ ev: String, _ grp: String, _ v: Insights.LView) -> some View {
        Section1("Color pairs · game win rate")
        let shown = v.pairs.filter { $0.share >= 0.01 }.sorted { $0.wr > $1.wr }
        let lo = max(0.4, (shown.map(\.wr).min() ?? 0.5) - 0.02), hi = min(0.7, (shown.map(\.wr).max() ?? 0.6) + 0.01)
        ForEach(shown) { p in
            Button { path.append(.pair(pack.set_code, ev, grp, p.p)) } label: {
                InsightBar(label: "\(Insights.pairNames[p.p] ?? p.p) \(p.p == "3C" ? "" : p.p)", value: p.wr, maxValue: hi,
                           detail: "\(InsightCharts.pct(p.share)) of games · splash \(InsightCharts.pct(p.splash))",
                           highlighted: p.id == shown.first?.id, format: InsightCharts.pct1, reference: v.wr, minValue: lo)
            }.buttonStyle(.plain)
        }
        if let colors = v.colors, !colors.isEmpty {
            Section1("Deck colors · with splashes, most played first")
            let rows = Array(colors.prefix(15))
            let clo = max(0.35, (rows.map(\.wr).min() ?? 0.5) - 0.02), chi = min(0.75, (rows.map(\.wr).max() ?? 0.6) + 0.01)
            let best = rows.max { $0.wr < $1.wr }
            ForEach(rows, id: \.self) { c in
                InsightBar(label: Insights.colorsName(c.m, c.s), value: c.wr, maxValue: chi,
                           detail: "\(InsightCharts.pct(c.share)) of games · \(c.games.formatted()) games",
                           highlighted: c == best, format: InsightCharts.pct1, reference: v.wr, minValue: clo)
            }
        }
        if v.weeks >= 2 {
            Section1("Pairs by week · win rate")
            let top = shown.filter { $0.p.count == 2 && $0.p != "3C" }.prefix(5)
            InsightLineChart(series: top.map { .init(id: $0.p.hashValue, label: $0.p, values: $0.week_wr, highlighted: $0.id == top.first?.id) },
                             xLabels: (0..<v.weeks).map { ($0, "W\($0 + 1)") }, count: v.weeks, height: 160,
                             format: InsightCharts.pct1, labelWidth: 70, fit: true, reference: ("AVG", v.wr))
                .padding(.vertical, 12).padding(.leading, 8).background(T1.surface)
        }
    }

    /// The best cards for the sort and filters (ten, then Show all), with search across the set and then every other set.
    @ViewBuilder
    private func cards(_ pack: Insights.LimitedPack, _ ev: String, _ grp: String, _ v: Insights.LView) -> some View {
        let rated = v.cards.contains { $0.r != nil }
        let sortLabel = Insights.limitedSorts.first { $0.key == sort }
        Section1("Top cards · \(sortLabel?.label.lowercased() ?? sort)")
        FilterRow(cells: [
            FilterCell(name: "Sort", value: sortLabel?.code ?? sort, options: Insights.limitedSorts.map { SelectorOption(value: $0.key, label: $0.label, detail: $0.code) },
                       current: sort) { sort = $0; all = false; Telemetry.capture("insights_sort_changed", ["sort": $0]) },
        ] + (rated ? [FilterCell(name: "Rarity", value: Insights.limitedRarities.first { $0.key == rarity }?.code ?? rarity,
                                 options: Insights.limitedRarities.map { SelectorOption(value: $0.key, label: $0.label) }, current: rarity) { rarity = $0; all = false }] : []) + [
            FilterCell(name: "Color", value: Insights.limitedColors.first { $0.key == color }?.code ?? color,
                       options: Insights.limitedColors.map { SelectorOption(value: $0.key, label: $0.label) }, current: color) { color = $0; all = false },
        ])
        T1SearchField(text: $query, prompt: "Search cards")
        let q = Insights.searchNorm(query)
        if q.count >= Insights.minQuery {
            searchResults(pack, ev, grp, v)
        } else {
            let rows = Insights.limitedCards(v.cards, sort: sort, rarity: rarity, color: color)
            let shown = all ? rows : Array(rows.prefix(Insights.limitedTop))
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                cardRow(c, rank: i + 1, v) { path.append(.limitedCard(pack.set_code, ev, grp, c.n)) }
            }
            if rows.isEmpty { Notice("No card matches these filters.") }
            if rows.count > Insights.limitedTop {
                Ghost(text: all ? "Show the top \(Insights.limitedTop)" : "Show all \(rows.count)") {
                    all.toggle()
                    if all { Telemetry.capture("insights_cards_expanded", ["set": pack.set_code, "count": rows.count]) }
                }
            }
        }
        LabelText("GIH WR: win rate with the card in hand · OH: in the opening hand · IWD: improvement when drawn · ATA: average pick taken · under it: points above or below the average")
            .lineLimit(4).padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(T1.surface)
    }

    @ViewBuilder
    private func searchResults(_ pack: Insights.LimitedPack, _ ev: String, _ grp: String, _ v: Insights.LView) -> some View {
        let others = store.limited.values.filter { $0.set_code != pack.set_code }.sorted { ($0.released ?? "") > ($1.released ?? "") }
            .map { p in (key: p.set_code, names: p.events.values.flatMap { $0.groups["all"]?.cards.map(\.n) ?? [] }) }
            .map { (key: $0.key, names: Array(Set($0.names)).sorted()) }
        let hits = Insights.limitedSearch(query, here: v.cards.map(\.n), others: others)
        let byName = Dictionary(v.cards.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
        ForEach(hits.here, id: \.self) { n in
            if let c = byName[n] { cardRow(c, rank: nil, v) { path.append(.limitedCard(pack.set_code, ev, grp, c.n)) } }
        }
        if hits.here.isEmpty && !hits.elsewhere.isEmpty {
            Section1("Not in \(LimitedPicker.label(pack.set_code, pack.name)) · in other sets")
            ForEach(hits.elsewhere, id: \.self) { h in
                Button {
                    Telemetry.capture("insights_card_search_elsewhere", ["set": h.set])
                    let other = store.limited[h.set]
                    let e = other.flatMap { store.currentEvent(of: $0) } ?? "PremierDraft"
                    path.append(.limitedCard(h.set, e, "all", h.name))
                } label: {
                    ListRow(title: h.name, detail: LimitedPicker.label(h.set, store.limitedName(h.set)))
                }.buttonStyle(.plain)
            }
        }
        if hits.here.isEmpty && hits.elsewhere.isEmpty {
            Notice("No card in any set's draft data is called that.")
        }
    }

    private func cardRow(_ c: Insights.LCard, rank: Int?, _ v: Insights.LView, open: @escaping () -> Void) -> some View {
        let shown = Insights.limitedValue(c, sort: sort, average: v.wr)
        return Button(action: open) {
            LimitedCardRow(rank: rank, card: c, face: faces[c.n], value: shown.value, vs: shown.vs, dim: c.gih == nil)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func scatter(_ pack: Insights.LimitedPack, _ ev: String, _ grp: String, _ v: Insights.LView) -> some View {
        let pts = v.cards.compactMap { c -> InsightScatter.Point? in
            guard let g = c.gih, let a = c.ata, c.gih_n >= 1000 else { return nil }
            return .init(id: c.n, label: c.n, x: a, y: g)
        }
        if pts.count >= 20 {
            Section1("Taken vs win rate · above the line is taken too late")
            InsightScatter(points: pts) { p in path.append(.limitedCard(pack.set_code, ev, grp, p.id)) }
                .padding(12).background(T1.surface)
        }
    }

    @ViewBuilder
    private func facts(_ v: Insights.LView) -> some View {
        Section1("Game facts")
        Stats3(items: [("On the play", InsightCharts.pct1(v.facts.play_wr)), ("On the draw", InsightCharts.pct1(v.facts.draw_wr)),
                       ("Turns", v.facts.turns.map { String(format: "%.1f", $0) } ?? "–")])
        Stats3(items: [("Mulligans", InsightCharts.pct(v.facts.mull_rate)), ("Kept 7", InsightCharts.pct1(v.facts.keep7_wr)),
                       ("After a mull", InsightCharts.pct1(v.facts.mull_wr))])
    }
}

/// A card's mana cost and its printing in the set (for the art); a cube's cards take their original printing.
struct LimitedFace: Hashable {
    let cost: String
    let printing: CatalogPrinting?

    @MainActor static func load(set: String, cards: [Insights.LCard]) async -> [String: LimitedFace] {
        guard let db = CatalogStore.shared.db else { return [:] }
        let ids = cards.compactMap(\.c)
        return await Task.detached(priority: .userInitiated) {
            let oracles = db.oracles(oracleIds: ids)
            var inSet: [Int: CatalogPrinting] = [:]
            for p in db.printings(set: set.lowercased()) where inSet[p.oracleIdx] == nil || (p.lang == "en" && inSet[p.oracleIdx]?.lang != "en") {
                inSet[p.oracleIdx] = p
            }
            let missing = oracles.values.map(\.idx).filter { inSet[$0] == nil }
            let covers = missing.isEmpty ? [:] : db.covers(oracleIdxs: missing)
            var out: [String: LimitedFace] = [:]
            for c in cards {
                guard let id = c.c, let o = oracles[id] else { continue }
                out[c.n] = LimitedFace(cost: o.manaCost, printing: inSet[o.idx] ?? covers[o.idx])
            }
            return out
        }.value
    }
}

/// One card on the Limited page: its place, art, name, mana cost, rarity and games, and the sort's number with how far
/// it sits from the average under it.
struct LimitedCardRow: View {
    let rank: Int?
    let card: Insights.LCard
    let face: LimitedFace?
    let value: String
    let vs: String?
    var dim = false

    var body: some View {
        HStack(spacing: 10) {
            if let rank {
                Text("\(rank)").font(T1.mono(11)).foregroundStyle(T1.muted).frame(width: 22, alignment: .trailing)
            }
            Group { if let p = face?.printing { CardArtCrop(printing: p) } else { T1.bg } }.frame(width: 52, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.n).font(T1.mono(14)).lineLimit(1)
                HStack(spacing: 6) {
                    if let cost = face?.cost, !cost.isEmpty { ManaCostView(cost: cost, size: 12) }
                    LabelText([card.r.map { String($0.prefix(1)).uppercased() }, "\(card.gih_n.formatted()) in hand"].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value).font(T1.mono(14)).foregroundStyle(dim ? T1.disabled : T1.text)
                if let vs { LabelText(vs, color: vs.hasPrefix("+") ? T1.text : T1.muted) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(T1.surface)
        .contentShape(Rectangle())
    }
}

/// A screen's one big action with a line of data under it (Rank this set): the words large, the data small.
struct RankAction: View {
    let title: String
    let detail: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title.uppercased()).font(T1.mono(15, .semibold)).tracking(4)
                if let detail { LabelText(detail).multilineTextAlignment(.center).lineLimit(2) }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(T1.surface)
            .overlay(alignment: .top) { Rectangle().fill(T1.text).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatPress())
    }
}

/// One color pair: its week by week, and the cards that do best in it.
struct PairInsightView: View {
    let set: String, event: String, group: String, pair: String
    @Binding var path: [InsightsRoute]
    private var store: InsightsStore { InsightsStore.shared }

    var body: some View {
        let pack = store.limited[set]
        let v = pack?.events[event]?.groups[group]
        let p = v?.pairs.first { $0.p == pair }
        T1Screen {
            Bar(title: "\(Insights.pairNames[pair] ?? pair) \(pair)", subtitle: "\(LimitedPicker.label(set, store.limited[set]?.name)) \(Insights.eventLabels[event] ?? event)") { path.removeLast() }
            InsightsPage {
                VStack(spacing: 1) {
                    if let p, let v, let pack {
                        CreditRow(url: pack.credit.url)
                        Stats3(items: [("Win rate", InsightCharts.pct1(p.wr)), ("Of games", InsightCharts.pct(p.share)), ("Splash", InsightCharts.pct(p.splash))])
                        Stats3(items: [("On the play", InsightCharts.pct1(p.play_wr)), ("On the draw", InsightCharts.pct1(p.draw_wr)), ("Games", p.games.formatted())])
                        if v.weeks >= 2 {
                            Section1("Win rate by week")
                            InsightLineChart(series: [.init(id: 0, label: pair, values: p.week_wr, highlighted: true)],
                                             xLabels: (0..<v.weeks).map { ($0, "W\($0 + 1)") }, count: v.weeks, height: 140, format: InsightCharts.pct1, labelWidth: 60)
                                .padding(.vertical, 12).padding(.leading, 8).background(T1.surface)
                        }
                        Section1("Best cards in \(pair) · win rate in hand")
                        let best = v.cards.compactMap { c in c.pair_gih?[pair].map { (c, $0) } }.sorted { $0.1 > $1.1 }.prefix(20)
                        ForEach(Array(best), id: \.0.n) { c, wr in
                            Button { path.append(.limitedCard(set, event, group, c.n)) } label: {
                                ListRow(title: c.n, detail: [c.r?.capitalized, c.col].compactMap { $0 }.joined(separator: " · ")) {
                                    Text(InsightCharts.pct1(wr)).font(T1.mono(13))
                                }
                            }.buttonStyle(.plain)
                        }
                    } else { Notice("This pair isn't in the pack.") }
                }
            }
        }
    }
}

struct CreditRow: View {
    let url: String
    @Environment(SessionModel.self) private var session
    var body: some View {
        Button { if let u = URL(string: url) { session.webPage = WebPage(url: u) } } label: {
            LabelText("Data from 17Lands").underline().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10).background(T1.surface)
        }.buttonStyle(.plain)
    }
}

/// One card in a Limited format: its win rates, week by week, and by pair.
struct LimitedCardView: View {
    let set: String, event: String, group: String, name: String
    @Binding var path: [InsightsRoute]
    @Environment(SessionModel.self) private var session
    @State private var face: LimitedFace?
    private var store: InsightsStore { InsightsStore.shared }

    var body: some View {
        let pack = store.limited[set]
        let v = pack?.events[event]?.groups[group]
        let c = v?.cards.first { $0.n == name }
        T1Screen {
            Bar(title: name, subtitle: "\(LimitedPicker.label(set, store.limited[set]?.name)) \(Insights.eventLabels[event] ?? event)") { path.removeLast() }
            InsightsPage {
                VStack(spacing: 1) {
                    if let c, let v, let pack {
                        // the card first: its picture in the set's printing and its mana cost
                        VStack(spacing: 12) {
                            if let p = face?.printing { p.art(width: 220) } else {
                                RoundedRectangle(cornerRadius: 220 * 0.0432).fill(T1.surface).frame(width: 220, height: 220 / CardArt.aspect)
                            }
                            if let cost = face?.cost, !cost.isEmpty { ManaCostView(cost: cost, size: 16) }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .task(id: "\(name) \(CatalogStore.shared.generation)") {
                            CatalogStore.shared.load(userInitiated: true)
                            face = await LimitedFace.load(set: set, cards: [c]).values.first
                        }
                        CreditRow(url: pack.credit.url)
                        if c.gih == nil { Notice("Fewer than 500 games with this card in hand: no win rates yet.") }
                        Stats3(items: [("In hand", InsightCharts.pct1(c.gih)), ("Opening hand", InsightCharts.pct1(c.oh)), ("Drawn", InsightCharts.pct1(c.gd))])
                        Stats3(items: [("Not seen", InsightCharts.pct1(c.gns)), ("IWD", c.iwd.map { InsightCharts.delta($0) } ?? "–"),
                                       ("Taken at", c.ata.map { String(format: "%.1f", $0) } ?? "–")])
                        Stats3(items: [("In decks", InsightCharts.pct(c.deck)), ("Games in hand", c.gih_n.formatted()), ("Rarity", c.r?.capitalized ?? "–")])
                        if let w = c.week_gih, v.weeks >= 2 {
                            Section1("Win rate in hand by week")
                            InsightLineChart(series: [.init(id: 0, label: "", values: w, highlighted: true)],
                                             xLabels: (0..<v.weeks).map { ($0, "W\($0 + 1)") }, count: v.weeks, height: 140, format: InsightCharts.pct1, labelWidth: 50)
                                .padding(.vertical, 12).padding(.leading, 8).background(T1.surface)
                        }
                        if let pg = c.pair_gih, !pg.isEmpty {
                            Section1("By color pair · in hand")
                            let rows = pg.sorted { $0.value > $1.value }
                            let lo = max(0.35, (rows.map(\.value).min() ?? 0.5) - 0.02), hi = min(0.8, (rows.map(\.value).max() ?? 0.6) + 0.01)
                            ForEach(rows, id: \.key) { k, wr in
                                Button { path.append(.pair(set, event, group, k)) } label: {
                                    InsightBar(label: "\(Insights.pairNames[k] ?? k) \(k)", value: wr, maxValue: hi, highlighted: k == rows.first?.key,
                                               format: InsightCharts.pct1, reference: c.gih, minValue: lo)
                                }.buttonStyle(.plain)
                            }
                        }
                        if let id = c.c {
                            Button { session.pendingLibrary = [.card(id)] } label: { ListRow(title: "Open the card", detail: "Prices, printings and your copies") }.buttonStyle(.plain)
                        }
                    } else { Notice("This card isn't in the pack.") }
                }
            }
        }
    }
}
