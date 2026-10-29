import SwiftUI

/// Screens pushed from the Insights tab.
enum InsightsRoute: Hashable {
    case archetype(String, Int)            // format, archetype id (0 = Other)
    case card(String, String, String)      // format, oracle id, name
    case ban(String, Int)                  // format, change id
    case matchups(String)                  // format
    case finish(String, Int, Int)          // format, archetype id, finish index on its page
    case pair(String, String, String, String) // set, event, group, pair
    case limitedCard(String, String, String, String) // set, event, group, card name
    case review
    case library(LibraryRoute)             // a Library screen pushed from Insights (an example list's cards)

    /// The Library routes on top of an Insights path, so Library screens push and pop in the Insights tab.
    static func library(_ path: Binding<[InsightsRoute]>) -> Binding<[LibraryRoute]> {
        Binding(
            get: { path.wrappedValue.compactMap { if case .library(let r) = $0 { r } else { nil } } },
            set: { routes in
                let base = path.wrappedValue.prefix { if case .library = $0 { false } else { true } }
                path.wrappedValue = Array(base) + routes.map { .library($0) }
            })
    }
}

struct InsightsDestination: View {
    let route: InsightsRoute
    @Binding var path: [InsightsRoute]
    var body: some View {
        switch route {
        case .archetype(let f, let id): ArchetypeInsightView(format: f, id: id, path: $path).screen("insights_archetype")
        case .card(let f, let id, let n): CardInsightView(format: f, oracleId: id, name: n, path: $path).screen("insights_card")
        case .ban(let f, let id): BanStudyView(format: f, changeId: id, path: $path).screen("insights_ban")
        case .matchups(let f): MatchupsView(format: f, path: $path).screen("insights_matchups")
        case .finish(let f, let a, let i): FinishView(format: f, archetypeId: a, index: i, path: $path).screen("insights_finish")
        case .pair(let s, let e, let g, let p): PairInsightView(set: s, event: e, group: g, pair: p, path: $path).screen("insights_pair")
        case .limitedCard(let s, let e, let g, let n): LimitedCardView(set: s, event: e, group: g, name: n, path: $path).screen("insights_limited_card")
        case .review: InsightsReviewView(path: $path).screen("insights_review")
        case .library(let r): LibraryDestination(route: r, path: InsightsRoute.library($path))
        }
    }
}

/// The tab's root: Constructed | Limited.
struct InsightsHomeView: View {
    @Binding var path: [InsightsRoute]
    var isFront = true
    @Bindable private var store = InsightsStore.shared

    var body: some View {
        T1Screen {
            Bar(title: "Insights", subtitle: store.section == "limited" ? "Arena draft" : "Constructed metagame")
            T1Segmented(options: [("constructed", "Constructed"), ("limited", "Limited")], selection: $store.section)
            InsightsPage {
                VStack(spacing: 1) {
                    if store.section == "limited" { LimitedHomeSection(path: $path) } else { ConstructedHomeSection(path: $path) }
                    if ModerationStore.shared.me?.moderator == true {
                        Button { path.append(.review) } label: {
                            ListRow(title: "Review", detail: "Proposed archetypes and bans")
                        }.buttonStyle(.plain)
                    }
                }
            }
            .refreshable { await store.load(force: true) }
        }
        .task(id: isFront) { if isFront { await store.load() } }
        .task(id: store.format) { await store.ensure(format: store.format) }
    }
}

// MARK: shared blocks

/// The vertical page every Insights screen scrolls in: held to the screen's width, with no sideways bounce, so the
/// page can't be pulled left and right (an iPhone on build 26 let Limited's rows slide sideways, cutting off the
/// win rates).
struct InsightsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { content.containerRelativeFrame(.horizontal) }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// The brief (2–3 sentences), what it covers, and the source credit.
/// A picker row with Edit at its end (which formats or sets the row shows).
struct PickerRow<Content: View>: View {
    @Binding var editing: Bool
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 1) {
            content
            Button { editing.toggle() } label: {
                LabelText("Edit", color: editing ? T1.ink : T1.muted)
                    .padding(.horizontal, 16).frame(maxHeight: .infinity)
                    .background(editing ? T1.text : T1.surface)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(T1.bg)
    }
}

/// Insights → Edit: On / Off per format or set; the last one shown can't be hidden. Kept on this device.
struct ShownEditor: View {
    let title: String
    let items: [(key: String, label: String, detail: String?)]
    let hidden: [String]
    let set: (String, Bool) -> Void
    let done: () -> Void
    var body: some View {
        Section1(title)
        let all = items.map(\.key)
        ForEach(items, id: \.key) { item in
            let on = !hidden.contains(item.key)
            T1Switch(title: item.label, detail: item.detail, isOn: Binding(get: { on }, set: { set(item.key, !$0) }))
                .disabled(on && !Insights.canHide(all, hidden, item.key))
        }
        Button(action: done) { ListRow(title: "Done") { EmptyView() } }.buttonStyle(.plain)
    }
}

struct BriefBlock: View {
    let brief: String?
    let scope: String
    var thin = false
    var credit: (String, URL)?
    @Environment(SessionModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabelText("In brief · \(scope)")
            if let brief {
                Text(brief).font(T1.mono(14)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(thin ? "Too few results in this window to say much yet." : "The summary is on its way.")
                    .font(T1.mono(13)).foregroundStyle(T1.muted)
            }
            if let credit {
                Button { session.webPage = WebPage(url: credit.1); Telemetry.capture("insights_source_opened", ["source": credit.0]) } label: {
                    LabelText(credit.0, color: T1.muted).underline()
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(T1.surface)
    }
}

struct ThinNote: View {
    var body: some View { Notice("Few results in this window: these numbers can swing.") }
}

// MARK: constructed

struct ConstructedHomeSection: View {
    @Binding var path: [InsightsRoute]
    @Bindable private var store = InsightsStore.shared
    @State private var board = "main"
    @State private var highlighted: Int?
    @Environment(SessionModel.self) private var session

    @State private var editing = false

    var body: some View {
        PickerRow(editing: $editing) {
            T1Segmented(options: store.shownFormats.map { ($0.key, $0.label) }, selection: $store.format, scroll: true)
        }
        if editing {
            ShownEditor(title: "Shown formats", items: Insights.formats.map { ($0.key, $0.label, nil) }, hidden: store.hiddenFormats,
                        set: { store.setHidden(format: true, $0, $1) }, done: { editing = false })
        }
        if let pack = store.pack {
            let tier = store.tier(for: pack)
            let tierBinding = Binding<Insights.Tier>(get: { tier }, set: { store.tierPicked = $0 })
            T1Segmented(options: [(.big, "Big events"), (.all, "All events")], selection: tierBinding)
            T1Segmented(options: Insights.windows.map { ($0, "\($0)D") }, selection: $store.days)
            if let view = pack.view(tier), let w = view.windows[String(store.days)] {
                content(pack, view, w, tier)
            }
        } else if let e = store.error {
            Notice(e, error: true)
        } else if store.loading || store.index.isEmpty && store.loadedAt == nil {
            Notice("Loading the metagame…")
        } else {
            Notice("No \(Insights.formats.first { $0.key == store.format }?.label ?? store.format) results yet.")
        }
    }

    @ViewBuilder
    private func content(_ pack: Insights.ConstructedPack, _ view: Insights.View, _ w: Insights.Window, _ tier: Insights.Tier) -> some View {
        let scope = "\(tier == .big ? "Big events" : "All events"), last \(store.days) days"
        let credit = Insights.sourcesCredit(pack.sources)
        BriefBlock(brief: w.brief, scope: scope, thin: w.thin, credit: credit)
        if w.thin { ThinNote() }
        Stats3(items: [("Decks", "\(w.decks)"), ("Events", "\(w.events)"), ("Through", InsightCharts.shortDay(pack.through))])

        Section1("Meta now · share of top finishes")
        let maxShare = w.share.map(\.share).max() ?? 0.1
        let lead = w.share.first { $0.a != 0 }?.a
        ForEach(w.share.prefix(12), id: \.a) { s in
            Button { path.append(.archetype(pack.format, s.a)) } label: {
                InsightBar(label: pack.name(s.a), value: s.share, maxValue: maxShare,
                           detail: InsightCharts.rates(wr: s.wr, t8r: s.t8r, won: s.won, wonOf: w.won_of).nilIfEmpty,
                           change: s.prev.map { s.share - $0 }, highlighted: s.a == lead)
            }.buttonStyle(.plain)
        }

        Section1("Meta over time · 7-day share")
        // The chart covers the picked window; lines with no decks in it are left out.
        let span = InsightCharts.window(from: view.series.from, days: view.series.days, keep: store.days)
        let lines = view.series.lines.map { (a: $0.a, v: Array($0.v.dropFirst(span.offset))) }.filter { $0.v.contains { $0 != nil } }
        let hl = highlighted.flatMap { h in lines.contains { $0.a == h } ? h : nil } ?? lines.first?.a
        InsightLineChart(series: lines.map { .init(id: $0.a, label: short(pack.name($0.a)), values: $0.v, highlighted: $0.a == hl) },
                         markers: markers(pack, from: span.from, days: span.days),
                         xLabels: span.labels,
                         count: span.days, height: 300, endLabels: false)
            .padding(.vertical, 12).padding(.leading, 8).padding(.trailing, 8).background(T1.surface)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(lines, id: \.a) { l in
                    Button { highlighted = l.a } label: {
                        // the picked line's latest share, since the chart has no end labels
                        LabelText(l.a == hl ? [pack.name(l.a), l.v.last(where: { $0 != nil }).flatMap { $0 }.map(InsightCharts.pct)].compactMap { $0 }.joined(separator: " · ") : pack.name(l.a),
                                  color: l.a == hl ? T1.ink : T1.text)
                            .padding(.horizontal, 12).padding(.vertical, 10).background(l.a == hl ? T1.text : T1.surface)
                    }.buttonStyle(.plain)
                }
            }
        }

        if !pack.matchups.cells.isEmpty {
            Section1("Matchups · last 90 days")
            MatchupGrid(pack: pack)
        }

        Section1("Cards · rising and falling")
        T1Segmented(options: [("main", "Main deck"), ("side", "Sideboard")], selection: $board)
        if let m = w.cards[board] {
            ForEach(m.up.prefix(8), id: \.c) { c in cardRow(pack, c, up: true) }
            ForEach(m.down.prefix(5), id: \.c) { c in cardRow(pack, c, up: false) }
            if m.up.isEmpty && m.down.isEmpty { Notice("No card moved much in this window.") }
        }

        if let ns = view.new_set, !ns.cards.isEmpty {
            Section1("New set · \(ns.name)")
            ForEach(ns.cards.prefix(8), id: \.c) { c in
                Button { path.append(.card(pack.format, c.c, c.n)) } label: {
                    ListRow(title: c.n, detail: "in \(InsightCharts.pct(c.rate)) of decks" + (c.in?.first.map { " · most in \(pack.name($0))" } ?? "")) {
                        Text(InsightCharts.pct(c.rate)).font(T1.mono(13))
                    }
                }.buttonStyle(.plain)
            }
        }

        let bans = pack.bans
        if !bans.isEmpty {
            Section1(Insights.bansTitle(bans.map { pack.change($0.change)?.kind ?? "" }))
            ForEach(bans, id: \.change) { b in
                if let ch = pack.change(b.change) {
                    Button { path.append(.ban(pack.format, b.change)) } label: {
                        ListRow(title: ch.words, detail: InsightCharts.shortDay(ch.on) + (b.settled_days.map { " · settled after \($0) days" } ?? ""))
                    }.buttonStyle(.plain)
                }
            }
        }

        let events = pack.events.filter { tier == .all || ["major", "large"].contains($0.tier) }
        if !events.isEmpty {
            Section1(tier == .big ? "Big events" : "Events")
            ForEach(events.prefix(12), id: \.self) { e in
                Button {
                    if let u = e.url.flatMap(URL.init) { session.webPage = WebPage(url: u); Telemetry.capture("insights_source_opened", ["source": e.source]) }
                } label: {
                    ListRow(title: e.name, detail: [InsightCharts.shortDay(e.on), e.players.map { "\($0) players" }, e.winner.map { "won by \(pack.name($0))" }]
                        .compactMap { $0 }.joined(separator: " · ")) {
                        LabelText(e.tier)
                    }
                }.buttonStyle(.plain)
            }
        }
        Color.clear.frame(height: 24)
    }

    private func cardRow(_ pack: Insights.ConstructedPack, _ c: Insights.CardRow, up: Bool) -> some View {
        Button { path.append(.card(pack.format, c.c, c.n)) } label: {
            ListRow(title: c.n, detail: "in \(InsightCharts.pct(c.rate)) of decks · was \(InsightCharts.pct(c.prev ?? 0))" + (c.copies.map { String(format: " · %.1f copies", $0) } ?? "")) {
                Text("\(up ? "▲" : "▼") \(InsightCharts.delta(c.rate - (c.prev ?? 0)).dropFirst())")
                    .font(T1.mono(12)).foregroundStyle(up ? T1.accent : T1.muted)
            }
        }.buttonStyle(.plain)
    }

    private func short(_ s: String) -> String { s.count > 14 ? String(s.prefix(13)) + "…" : s }

    private func markers(_ pack: Insights.ConstructedPack, from: String, days: Int) -> [InsightLineChart.Marker] {
        guard let d0 = InsightCharts.day(from) else { return [] }
        // one marker per day: a ban and an unban on May 18 read BAN/UNBAN
        var out: [InsightLineChart.Marker] = []
        for c in pack.changes {
            guard let d = InsightCharts.day(c.on) else { continue }
            let i = Int((d.timeIntervalSince(d0) / 86400).rounded())
            guard (0..<days).contains(i) else { continue }
            let label = c.isBan ? c.kind.uppercased() : (c.set_code ?? "").uppercased()
            if let k = out.firstIndex(where: { $0.index == i }) {
                out[k] = .init(index: i, label: out[k].label + "/" + label, ban: out[k].ban || c.isBan)
            } else { out.append(.init(index: i, label: label, ban: c.isBan)) }
        }
        return out
    }
}

/// Three stats in a row.
struct Stats3: View {
    let items: [(String, String)]
    var body: some View {
        HStack(spacing: 1) {
            ForEach(items.indices, id: \.self) { i in
                Stat(label: items[i].0, value: items[i].1).padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
            }
        }
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

// MARK: archetype

struct ArchetypeInsightView: View {
    let format: String
    let id: Int
    @Binding var path: [InsightsRoute]
    @State private var page: Insights.ArchetypePage?
    @State private var error: String?
    @State private var added: AddedDeck?
    @Environment(SessionModel.self) private var session
    private var store: InsightsStore { InsightsStore.shared }

    var body: some View {
        let pack = store.constructed[format]
        T1Screen {
            Bar(title: pack?.name(id) ?? "Archetype", subtitle: "\(pack?.name ?? format) · all events, last \(store.days) days") { path.removeLast() }
            InsightsPage {
                VStack(spacing: 1) {
                    if let page, let pack { content(page, pack) }
                    else if let error { Notice(error, error: true) }
                    else { Notice("Loading…") }
                }
            }
        }
        .task {
            do { page = try await store.archetype(format: format, id: id, tier: .all, days: store.days) }
            catch { if !error.isCancellation { self.error = "This archetype couldn't load: \(error.localizedDescription)" } }
        }
    }

    @ViewBuilder
    private func content(_ p: Insights.ArchetypePage, _ pack: Insights.ConstructedPack) -> some View {
        let share = pack.view(.all)?.windows[String(store.days)]?.share.first { $0.a == id }
        BriefBlock(brief: p.brief, scope: "last 30 days, all events", thin: p.decks < 20)
        Stats3(items: [
            ("Share", InsightCharts.pct(share?.share)),
            ("Decks", "\(p.decks)"),
            ("Record", p.record.map { "\($0.wins)-\($0.losses)" } ?? "–"),
        ])
        if let r = p.record {
            Notice(r.basis == "topdeck" ? "Record from paper events' rounds." : "Record of players who reached a Challenge's top 32, so it runs high.")
        }
        if id == 0, let groups = p.groups, !groups.isEmpty {
            Section1("Inside Other · by colours")
            Notice("Decks no archetype names yet, grouped by their colours. Open one for an example list.")
            ForEach(groups, id: \.self) { g in
                Button { if let ex = g.example { path.append(.finish(format, id, ex)) } } label: {
                    ListRow(title: Insights.colorsName(g.colors.isEmpty ? "C" : g.colors, ""),
                            detail: (["\(g.decks) deck\(g.decks == 1 ? "" : "s")"] + [g.cards.joined(separator: ", ")].filter { !$0.isEmpty }).joined(separator: " · ")) {
                        Text(InsightCharts.pct(g.share)).font(T1.mono(13))
                    }
                }.buttonStyle(.plain)
            }
        } else if id != 0, let ex = Insights.exampleFinish(p.finishes) {
            let f = p.finishes[ex]
            Section1("Example list · " + (f.rank.map { "\(Insights.place($0)) at " } ?? "") + f.event)
            ListRow(title: [InsightCharts.shortDay(f.on), f.players.map { "\($0) players" }, f.tier == "major" || f.tier == "large" ? "big event" : nil]
                        .compactMap { $0 }.joined(separator: " · "),
                    detail: "\(f.main.reduce(0) { $0 + $1.qty }) cards · sideboard \(f.side.reduce(0) { $0 + $1.qty })")
            AddToDecksRow(added: added, add: { added = AddedDeck.add(f, name: p.archetype.name, format: format, from: "example") },
                          open: { session.openWebLink(URL(string: "https://table-1.site/library/list/\($0)")!) })
            ForEach(f.main.prefix(12), id: \.self) { l in ListRow(title: l.name) { Text("\(l.qty)").font(T1.mono(13)) } }
            Button { path.append(.finish(format, id, ex)) } label: {
                ListRow(title: "See the whole list", detail: f.main.count > 12 ? "\(f.main.count - 12) more cards and the sideboard" : "With the sideboard")
            }.buttonStyle(.plain)
        }
        Section1("Share by week")
        InsightLineChart(series: [.init(id: id, label: "", values: p.series.v, highlighted: true)], count: p.series.weeks, height: 140, labelWidth: 40)
            .padding(.vertical, 12).padding(.leading, 8).background(T1.surface)
        if id != 0 {
            cards("Core · in 80%+ of lists", p.core, pack)
            cards("Flex slots", p.flex, pack)
            cards("Sideboard", p.side, pack)
        }
        if !p.matchups.isEmpty {
            Section1("Matchups · last 90 days")
            ForEach(p.matchups.prefix(8), id: \.self) { m in
                let n = m.wins + m.losses
                let ci = InsightCharts.wilson(wins: m.wins, n: n)
                ListRow(title: "vs \(pack.name(m.vs))", detail: n >= 30 ? "\(InsightCharts.pct(ci.lo))–\(InsightCharts.pct(ci.hi)) likely" : "Too few matches to say") {
                    Text("\(m.wins)-\(m.losses)").font(T1.mono(13))
                }
            }
        }
        if !p.finishes.isEmpty {
            Section1("Best finishes")
            ForEach(Array(p.finishes.enumerated()), id: \.offset) { i, f in
                Button { path.append(.finish(format, id, i)) } label: {
                    ListRow(title: f.event, detail: [f.rank.map { "#\($0)" }, InsightCharts.shortDay(f.on), f.players.map { "\($0) players" }].compactMap { $0 }.joined(separator: " · "))
                }.buttonStyle(.plain)
            }
        }
        Color.clear.frame(height: 24)
    }

    @ViewBuilder
    private func cards(_ title: String, _ rows: [Insights.CardRow], _ pack: Insights.ConstructedPack) -> some View {
        if !rows.isEmpty {
            Section1(title)
            ForEach(rows.prefix(16), id: \.c) { c in
                Button { path.append(.card(format, c.c, c.n)) } label: {
                    ListRow(title: c.n, detail: c.copies.map { String(format: "%.1f copies", $0) }) {
                        Text(InsightCharts.pct(c.rate)).font(T1.mono(13))
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}

/// A finish's list as a new private deck in the viewer's Library (original printings); what happened, and the deck.
struct AddedDeck: Equatable {
    let text: String
    var listId: String?
    @MainActor static func add(_ f: Insights.ArchetypePage.Finish, name: String, format: String, from: String) -> AddedDeck {
        guard let db = CatalogStore.shared.db else { return AddedDeck(text: "The card catalog is still loading") }
        let resolved = db.printings(names: (f.main + f.side).map(\.name))
        var entries: [CardList.Entry] = []
        var missing = 0
        for (board, lines) in [("main", f.main), ("side", f.side)] {
            for l in lines { if let p = resolved[l.name] { entries.append(.init(cardId: p.cardId, board: board, qty: l.qty)) } else { missing += l.qty } }
        }
        let l = ListsStore.shared.create(kind: .deck, name: String(name.prefix(60)), format: format, entries: entries,
                                         note: String("From \(f.event), \(f.on)".prefix(120)), from: "insights")
        Telemetry.capture("insights_copy_to_library", ["format": format, "archetype": name, "from": from])
        return AddedDeck(text: "Added to your decks as \(l.name)" + (missing > 0 ? " (\(missing) card\(missing == 1 ? "" : "s") not found)" : ""), listId: l.id)
    }
}

/// Add to my decks, then what happened with Open (the new deck) once it's there.
struct AddToDecksRow: View {
    let added: AddedDeck?
    let add: () -> Void
    let open: (String) -> Void
    var body: some View {
        if let added, let id = added.listId {
            Button { open(id) } label: {
                ListRow(title: added.text, detail: "A new private deck") { LabelText("Open", color: T1.accent) }
            }.buttonStyle(.plain)
        } else {
            Button(action: add) {
                ListRow(title: "Add to my decks", detail: added?.text ?? "A new private deck with these cards") { LabelText("Add", color: T1.accent) }
            }.buttonStyle(.plain)
        }
    }
}

/// One finish's list drawn like a deck shared with you (View, Group by, Sort, card art, Export, Deck image),
/// with Add to my decks on top.
struct FinishView: View {
    let format: String
    let archetypeId: Int
    let index: Int
    @Binding var path: [InsightsRoute]
    @State private var page: Insights.ArchetypePage?
    @State private var added: AddedDeck?
    /// The list in its original printings, once the catalog is in; and how many cards it couldn't name.
    @State private var resolved: (rows: [ProfileCard], missing: Int)?
    @Environment(SessionModel.self) private var session
    private var store: InsightsStore { InsightsStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }

    var body: some View {
        let f = page?.finishes[safe: index]
        // an Other group's example is named for its colours
        let group = archetypeId == 0 ? page?.groups?.first { $0.example == index } : nil
        let title = group.map { Insights.colorsName($0.colors.isEmpty ? "C" : $0.colors, "") } ?? page?.archetype.name ?? "Deck"
        Group {
            if let f, let resolved {
                ProfileCardsView(userId: "", section: ProfileSection(kind: "deck"), title: title, list: SharedList(format: format),
                                 byline: Self.byline(f, missing: resolved.missing), mine: true, preset: resolved.rows,
                                 actions: AnyView(AddToDecksRow(added: added, add: { added = AddedDeck.add(f, name: title, format: format, from: "finish") },
                                                                open: { session.openWebLink(URL(string: "https://table-1.site/library/list/\($0)")!) })),
                                 path: InsightsRoute.library($path))
            } else {
                T1Screen {
                    Bar(title: title, subtitle: f.map { "\($0.event) · \(InsightCharts.shortDay($0.on))" }) { path.removeLast() }
                    CatalogStatusRow(catalog: catalog)
                    InsightsPage { Notice("Loading…") }
                }
            }
        }
        .task { page = try? await store.archetype(format: format, id: archetypeId, tier: .all, days: store.days) }
        .task(id: "\(page == nil)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let f, let db = catalog.db else { return }
            let lines = [("main", f.main.map { ($0.name, $0.qty) }), ("side", f.side.map { ($0.name, $0.qty) })]
            resolved = await Task.detached(priority: .userInitiated) { Self.rows(lines, db) }.value
        }
    }

    /// Each name in its original printing, non-foil, like Add to my decks.
    nonisolated static func rows(_ boards: [(String, [(name: String, qty: Int)])], _ db: CatalogDB) -> (rows: [ProfileCard], missing: Int) {
        let printings = db.printings(names: boards.flatMap { $0.1.map(\.name) })
        var rows: [ProfileCard] = [], missing = 0
        for (board, lines) in boards {
            for l in lines {
                if let p = printings[l.name] { rows.append(ProfileCard(cardId: p.cardId, board: board, qty: l.qty)) }
                else { missing += l.qty }
            }
        }
        return (rows, missing)
    }

    /// "2nd at Modern Challenge 64 · 26 Oct · 64 players"
    static func byline(_ f: Insights.ArchetypePage.Finish, missing: Int) -> String {
        ([(f.rank.map { "\(Insights.place($0)) at " } ?? "") + f.event, InsightCharts.shortDay(f.on), f.players.map { "\($0) players" }]
            .compactMap { $0 } + (missing > 0 ? ["\(missing) card\(missing == 1 ? "" : "s") not found"] : [])).joined(separator: " · ")
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

// MARK: card

struct CardInsightView: View {
    let format: String
    let oracleId: String
    let name: String
    @Binding var path: [InsightsRoute]
    @State private var page: Insights.CardPage?
    @State private var error: String?
    private var store: InsightsStore { InsightsStore.shared }

    var body: some View {
        let pack = store.constructed[format]
        T1Screen {
            Bar(title: name, subtitle: "\(pack?.name ?? format) · all events") { path.removeLast() }
            InsightsPage {
                VStack(spacing: 1) {
                    if let page, let pack {
                        Stats3(items: [("Main decks", InsightCharts.pct(page.series.main.last ?? nil)),
                                       ("Copies", page.copies.map { String(format: "%.1f", $0) } ?? "–"),
                                       ("First seen", page.first_seen.map(InsightCharts.shortDay) ?? "–")])
                        Section1("Share of decks by week")
                        InsightLineChart(series: [.init(id: 0, label: "Main", values: page.series.main, highlighted: true),
                                                  .init(id: 1, label: "Side", values: page.series.side, highlighted: false)],
                                         count: page.series.weeks, height: 150, labelWidth: 70)
                            .padding(.vertical, 12).padding(.leading, 8).background(T1.surface)
                        if !page.by_archetype.isEmpty {
                            Section1("Played in · last 30 days")
                            let m = page.by_archetype.map(\.rate).max() ?? 1
                            ForEach(page.by_archetype, id: \.self) { a in
                                Button { path.append(.archetype(format, a.a)) } label: {
                                    InsightBar(label: pack.name(a.a), value: a.rate, maxValue: max(m, 0.01),
                                               detail: a.copies.map { String(format: "%.1f copies in its lists", $0) })
                                }.buttonStyle(.plain)
                            }
                        }
                    } else if let error { Notice(error, error: true) } else { Notice("Loading…") }
                }
            }
        }
        .task {
            do { page = try await store.card(format: format, oracleId: oracleId, tier: .all) }
            catch { if !error.isCancellation { self.error = "This card couldn't load: \(error.localizedDescription)" } }
        }
    }
}

// MARK: ban study

struct BanStudyView: View {
    let format: String
    let changeId: Int
    @Binding var path: [InsightsRoute]
    private var store: InsightsStore { InsightsStore.shared }

    var body: some View {
        let pack = store.constructed[format]
        let b = pack?.bans.first { $0.change == changeId }
        let ch = pack?.change(changeId)
        T1Screen {
            Bar(title: ch?.words ?? "Format change", subtitle: ch.map { "\(pack?.name ?? "") · \(InsightCharts.shortDay($0.on))" }) { path.removeLast() }
            InsightsPage {
                VStack(spacing: 1) {
                    if let b, let pack {
                        BriefBlock(brief: b.brief, scope: "what changed after", thin: b.before.isEmpty || b.afterWindow == nil)
                        if let aw = b.afterWindow {
                            Section1("Share before → \(aw.days) days after")
                            let ids = Array(Set(b.before.prefix(6).map(\.a) + aw.shares.prefix(6).map(\.a))).prefix(8)
                            let loser = Set(b.losers.map(\.a))
                            InsightSlopeChart(rows: ids.map { a in
                                .init(id: a, label: pack.name(a), before: b.before.first { $0.a == a }?.share ?? 0,
                                      after: aw.shares.first { $0.a == a }?.share ?? 0, highlighted: loser.contains(a) || b.gainers.first?.a == a)
                            }, leftTitle: "Before", rightTitle: "After")
                            .padding(12).background(T1.surface)
                        } else {
                            Notice("No window after the change has ended yet.")
                        }
                        Stats3(items: [("Settled", b.settled_days.map { "\($0) days" } ?? "Not yet"),
                                       ("Lost most", b.losers.first.map { pack.name($0.a) } ?? "–"),
                                       ("Gained most", b.gainers.first.map { pack.name($0.a) } ?? "–")])
                        if !b.replacements.isEmpty {
                            Section1(ch?.kind == "unban" || ch?.kind == "unrestrict" ? "Where it's played" : "What replaced it")
                            ForEach(b.replacements, id: \.self) { r in
                                Button { path.append(.card(format, r.c, r.n)) } label: {
                                    ListRow(title: r.n, detail: "in \(pack.name(r.in)) · \(InsightCharts.pct(r.before)) → \(InsightCharts.pct(r.after)) of lists")
                                }.buttonStyle(.plain)
                            }
                        }
                    } else { Notice("This change isn't in the pack.") }
                }
            }
        }
    }
}

// MARK: matchups

struct MatchupsView: View {
    let format: String
    @Binding var path: [InsightsRoute]
    private var store: InsightsStore { InsightsStore.shared }

    var body: some View {
        let pack = store.constructed[format]
        T1Screen {
            Bar(title: "Matchups", subtitle: "\(pack?.name ?? format) · last 90 days") { path.removeLast() }
            InsightsPage {
                VStack(spacing: 1) {
                    if let pack { MatchupGrid(pack: pack) }
                }
            }
        }
    }
}

/// The matchup grid (rows against labelled columns) and the record of the square last tapped; on the format page
/// under Meta over time, and on its own screen for push taps and older links.
struct MatchupGrid: View {
    let pack: Insights.ConstructedPack
    @State private var picked: (Int, Int)?

    var body: some View {
        let ids = pack.matchups.archetypes
        Notice("Row's match win rate against each column. Faded: fewer than 30 matches, so treat it as a hint. Tap a square for the record. From MTGO top 8 brackets and paper events' rounds.")
        InsightHeatmap(labels: ids.map { pack.name($0) }, cell: { r, c in
            pack.matchups.cell(ids[r], ids[c]).map { ($0.wins, $0.losses) }
        }, picked: picked.map { (row: $0.0, col: $0.1) }, onTap: { r, c in
            picked = (r, c)
            Telemetry.capture("insights_matchup_opened", ["format": pack.format])
        })
        if let (r, c) = picked, let m = pack.matchups.cell(ids[r], ids[c]) {
            let n = m.wins + m.losses
            let ci = InsightCharts.wilson(wins: m.wins, n: n)
            ListRow(title: "\(pack.name(ids[r])) vs \(pack.name(ids[c]))",
                    detail: n >= 30 ? "\(InsightCharts.pct1(Double(m.wins) / Double(n))) · likely \(InsightCharts.pct(ci.lo))–\(InsightCharts.pct(ci.hi))" : "Only \(n) matches: too few to say") {
                Text("\(m.wins)-\(m.losses)\(m.draws > 0 ? "-\(m.draws)" : "")").font(T1.mono(13))
            }
        }
    }
}
