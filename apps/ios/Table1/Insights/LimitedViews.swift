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

    @ViewBuilder private func rankRow(_ pack: Insights.LimitedPack) -> some View {
        let r = store.rankable.first { $0.key == pack.set_code }
        let kind = r?.kind ?? (pack.cube != nil ? "cube" : "set")
        Button { rank(pack.set_code, kind: kind, from: "set") } label: {
            ListRow(title: "Rank \(kind == "cube" ? "this cube" : "this set")",
                    detail: r.flatMap { $0.rankings > 0 ? $0.detail : nil } ?? "Stack-rank its cards by color, then a top 100. Compare with your friends.")
        }.buttonStyle(.plain)
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
            let setBinding = Binding<String>(get: { store.setCode.flatMap { s in chips.contains { $0.key == s } ? s : nil } ?? (chips.first { $0.pack } ?? chips[0]).key },
                                             set: { store.setCode = $0 })
            let soon = chips.contains { !$0.pack && $0.key == setBinding.wrappedValue } ? store.rankable.first { $0.key == setBinding.wrappedValue } : nil
            PickerRow(editing: $editing) {
                T1Segmented(options: chips.map { ($0.key, $0.label) }, selection: setBinding, scroll: true)
            }
            if editing {
                ShownEditor(title: "Shown sets", items: store.limitedChips.map { c in (c.key, c.label, store.limitedName(c.key).flatMap { $0 == c.label ? nil : $0 }) },
                            hidden: store.hiddenSets, set: { store.setHidden(format: false, $0, $1) }, done: { editing = false })
            }
            if let soon {
                Notice(LimitedPicker.soonText(soon, today: today))
                Button { rank(soon.key, kind: soon.kind, from: "soon") } label: { ListRow(title: "Rank this set", detail: soon.detail) }.buttonStyle(.plain)
            } else if let pack = store.limited[setBinding.wrappedValue] {
                content(pack)
            } else {
                Notice("Loading \(LimitedPicker.label(setBinding.wrappedValue, store.limitedName(setBinding.wrappedValue)))…")
                    .task { await store.load(force: true) }
            }
            alertsRow
            Color.clear.frame(height: 24)
    }

    @ViewBuilder
    private func content(_ pack: Insights.LimitedPack) -> some View {
        let events = store.events(of: pack)
        let ev = store.currentEvent(of: pack) ?? "PremierDraft"
        let evBinding = Binding<String>(get: { ev }, set: { store.event = $0 })
        if events.count > 1 { T1Segmented(options: events.map { ($0, Insights.eventLabels[$0] ?? $0) }, selection: evBinding) }
        let groups = pack.events[ev]?.groups ?? [:]
        let grp = groups[store.group] != nil ? store.group : "all"
        if groups["top"] != nil {
            T1Segmented(options: [("all", "All players"), ("top", "Top players")], selection: $store.group)
        }
        if let v = groups[grp] {
            BriefBlock(brief: v.brief, scope: "\(pack.name ?? pack.set_code) \(Insights.eventLabels[ev] ?? ev)\(grp == "top" ? ", top players (60%+)" : "")",
                       thin: v.games < 20000, credit: ("Data from 17Lands", URL(string: pack.credit.url)!))
            Stats3(items: [("Games", v.games.formatted()), ("Average", InsightCharts.pct1(v.wr)), ("Weeks", "\(v.weeks)")])
            rankRow(pack)
            newSets
            pairs(pack, ev, grp, v)
            cards(pack, ev, grp, v)
            scatter(pack, ev, grp, v)
            facts(v)
        }
    }

    @ViewBuilder
    private func pairs(_ pack: Insights.LimitedPack, _ ev: String, _ grp: String, _ v: Insights.LView) -> some View {
        Section1("Colour pairs · game win rate")
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
            Section1("Deck colours · with splashes, most played first")
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

    @ViewBuilder
    private func cards(_ pack: Insights.LimitedPack, _ ev: String, _ grp: String, _ v: Insights.LView) -> some View {
        Section1("Cards")
        T1Segmented(options: [("gih", "GIH WR"), ("oh", "OH WR"), ("iwd", "IWD"), ("ata", "ATA")], selection: Binding(get: { sort }, set: {
            sort = $0; Telemetry.capture("insights_sort_changed", ["sort": $0])
        }))
        // A cube's cards have no rarity: no rarity filter then.
        if v.cards.contains(where: { $0.r != nil }) {
            T1Segmented(options: [("all", "All"), ("common", "C"), ("uncommon", "U"), ("rare", "R"), ("mythic", "M")], selection: $rarity)
        }
        T1Segmented(options: [("all", "All"), ("W", "W"), ("U", "U"), ("B", "B"), ("R", "R"), ("G", "G"), ("M", "Multi")], selection: $color)
        let rows = sorted(v.cards).prefix(40)
        ForEach(Array(rows)) { c in
            Button { path.append(.limitedCard(pack.set_code, ev, grp, c.n)) } label: {
                ListRow(title: c.n, detail: [c.r?.capitalized, c.col, "\(c.gih_n.formatted()) in hand",
                                             c.ata.map { String(format: "taken %.1f", $0) }].compactMap { $0 }.joined(separator: " · ")) {
                    Text(value(c)).font(T1.mono(13)).foregroundStyle(c.gih == nil ? T1.disabled : T1.text)
                }
            }.buttonStyle(.plain)
        }
        if rows.isEmpty { Notice("No card matches these filters.") }
        LabelText("GIH WR: win rate with the card in hand · OH: in the opening hand · IWD: improvement when drawn · ATA: average pick taken")
            .lineLimit(3).padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(T1.surface)
    }

    private func sorted(_ cards: [Insights.LCard]) -> [Insights.LCard] {
        let rated = cards.contains { $0.r != nil }
        let f = cards.filter { c in
            (!rated || rarity == "all" || c.r == rarity) &&
            (color == "all" || (color == "M" ? (c.col?.count ?? 0) > 1 : c.col == color))
        }
        let key: (Insights.LCard) -> Double? = { c in
            switch sort { case "oh": c.oh; case "iwd": c.iwd; case "ata": c.ata.map { -$0 }; default: c.gih }
        }
        return f.sorted { a, b in
            switch (key(a), key(b)) {
            case let (x?, y?): x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.gih_n > b.gih_n
            }
        }
    }

    private func value(_ c: Insights.LCard) -> String {
        switch sort {
        case "oh": InsightCharts.pct1(c.oh)
        case "iwd": c.iwd.map { InsightCharts.delta($0) } ?? "–"
        case "ata": c.ata.map { String(format: "%.1f", $0) } ?? "–"
        default: InsightCharts.pct1(c.gih)
        }
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

/// One colour pair: its week by week, and the cards that do best in it.
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
                            Section1("By colour pair · in hand")
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
