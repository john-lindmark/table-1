import SwiftUI

/* The Buy screen (contract/buy-2026-11-06.md): a deck, a cube, Wants or Missing as a TCGplayer cart, Moxfield's way:
   the options, the cards to buy by board, price − owned = total, then Buy on TCGplayer. Rules in BuyList.swift. */

enum BuySource: Hashable {
    case list(String) // deck or cube id
    case wants
    case missing
}

struct BuyView: View {
    let source: BuySource
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var catalog: CatalogStore { CatalogStore.shared }

    @State private var lines: [BuyList.Line] = []
    @State private var holdings = Holdings(owned: [:], cardOf: [:])
    @State private var cards: [String: (name: String, oracleId: String?, printing: CatalogPrinting?)] = [:]
    @State private var options = BuyList.Options()
    @State private var tokens = false
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    private var list: CardList? { if case .list(let id) = source { ListsStore.shared.list(id: id) } else { nil } }
    private var isDeck: Bool { list?.kind == .deck }
    /// Options are remembered per family: deck, cube, wants, missing.
    private var family: String {
        switch source {
        case .list: isDeck ? "deck" : "cube"
        case .wants: "wants"
        case .missing: "missing"
        }
    }
    private var ownsOptions: Bool { list != nil }
    /// Boards with cards, in screen order (decks and cubes; tokens are their own switch).
    private var boards: [String] {
        let have = Set(lines.map(\.board))
        return BuyList.boardOrder.filter { $0 != "tokens" && have.contains($0) }
    }

    /// What the rules see: Wants and Missing are already what's needed, so nothing is owned and every line counts.
    private var effective: BuyList.Options {
        var o = options
        if !ownsOptions { o.skipOwned = false; o.boards = ["main"] }
        if tokens && isDeck { o.boards.insert("tokens") } else { o.boards.remove("tokens") }
        return o
    }

    var body: some View {
        let rows = BuyList.rows(lines, holdings, effective)
        let t = BuyList.totals(rows)
        T1Screen {
            Bar(title: "Buy", subtitle: list?.name, back: { dismiss() })
            CatalogStatusRow(catalog: catalog)
            if let error { Notice(error, error: true) }
            HairlineList {
                if loaded {
                    header(t)
                    optionRows
                    ForEach(BuyList.boardOrder, id: \.self) { b in
                        let inBoard = rows.filter { $0.line.board == b }
                        let buying = inBoard.filter { $0.buy > 0 }
                        let owned = inBoard.reduce(0) { $0 + $1.owned }
                        if !inBoard.isEmpty {
                            Section1(([title(b), "\(buying.reduce(0) { $0 + $1.buy }) to buy", owned > 0 ? "\(owned) owned" : nil] as [String?])
                                .compactMap { $0 }.joined(separator: " · "))
                            ForEach(Array(buying.enumerated()), id: \.offset) { _, r in row(r) }
                        }
                    }
                    Section1("Total")
                    ListRow(title: "Price") { amount(BuyList.money(t.price)) }
                    if t.ownedValue > 0 { ListRow(title: "Owned") { amount("−" + BuyList.money(t.ownedValue)) } }
                    ListRow(title: "Total") { amount(BuyList.money(t.total), accent: true) }
                } else {
                    ListRow(title: "Loading the cards…")
                }
            }
            BuyBarButton(text: busy ? "Opening TCGplayer…" : "Buy on TCGplayer", enabled: t.buy > 0 && !busy) { buy(rows) }
        }
        .task(id: "\(catalog.generation)-\(CollectionStore.shared.version)-\(ListsStore.shared.lists.count)") { await load() }
        .onAppear {
            restore()
            Telemetry.capture("buy_opened", ["from": family])
        }
    }

    // MARK: parts

    private func header(_ t: BuyList.Totals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BuyList.money(t.total)).font(T1.mono(34, .semibold)).monospacedDigit().foregroundStyle(T1.accent)
            LabelText(([ "\(t.cards) cards", ownsOptions && effective.skipOwned ? "\(t.owned) owned" : nil, "\(t.buy) to buy",
                         t.unpriced > 0 ? "\(t.unpriced) unpriced" : nil ] as [String?]).compactMap { $0 }.joined(separator: " · "))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 20)
        .background(T1.surface)
    }

    @ViewBuilder private var optionRows: some View {
        if ownsOptions {
            T1Switch(title: "Skip cards I own", isOn: option(\.skipOwned, "skip"))
            if options.skipOwned { T1Switch(title: "Any printing I own counts", isOn: option(\.anyPrinting, "any")) }
        }
        T1Switch(title: "Exact printings", isOn: option(\.exact, "exact"))
        if isDeck {
            T1Switch(title: "Tokens", isOn: Binding(get: { tokens }, set: { v in
                tokens = v
                save("tokens", v)
                Telemetry.capture("buy_option", ["from": family, "option": "tokens", "on": v])
            }))
        }
        if ownsOptions && boards.count > 1 {
            Button { pickBoards() } label: {
                ListRow(title: "Boards", detail: boards.filter { options.boards.contains($0) }.map(title).joined(separator: " · ").nonEmpty ?? "None")
            }.buttonStyle(.plain)
        }
    }

    private func row(_ r: BuyList.Row) -> some View {
        let c = cards[r.line.cardId]
        let detail = r.line.any ? "Any printing"
            : [c?.printing?.setLabel, r.line.finish == "nonfoil" ? nil : Finish(rawValue: r.line.finish)?.label].compactMap { $0 }.joined(separator: " · ")
        return Button { if let o = c?.oracleId { path.append(.card(o)) } } label: {
            CardRow(printing: c?.printing, title: c?.name ?? "Card not in local data yet", detail: detail.nonEmpty,
                    finish: r.line.finish, note: r.owned > 0 ? "Own \(r.owned) of \(r.line.qty)" : nil) {
                Text("\(r.buy)").font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }

    private func amount(_ s: String, accent: Bool = false) -> some View {
        Text(s).font(T1.mono(15)).monospacedDigit().foregroundStyle(accent ? T1.accent : T1.text)
    }

    private func title(_ board: String) -> String {
        switch source {
        case .wants: return "Wants"
        case .missing: return "Missing"
        case .list: return board == "tokens" ? "Tokens" : list?.boardTitle(board) ?? board.capitalized
        }
    }

    // MARK: options

    private func key(_ o: String) -> String { "buy.\(family).\(o)" }

    private func save(_ o: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: key(o)) }

    private func option(_ kp: WritableKeyPath<BuyList.Options, Bool>, _ name: String) -> Binding<Bool> {
        Binding(get: { options[keyPath: kp] }, set: { v in
            options[keyPath: kp] = v
            save(name, v)
            Telemetry.capture("buy_option", ["from": family, "option": name, "on": v])
        })
    }

    private func restore() {
        let d = UserDefaults.standard
        var o = BuyList.Options()
        o.exact = family == "wants"
        let saved: [(String, WritableKeyPath<BuyList.Options, Bool>)] = [("skip", \.skipOwned), ("any", \.anyPrinting), ("exact", \.exact)]
        for (name, kp) in saved where d.object(forKey: key(name)) != nil {
            o[keyPath: kp] = d.bool(forKey: key(name))
        }
        if let b = d.stringArray(forKey: key("boards")) { o.boards = Set(b) }
        options = o
        tokens = d.bool(forKey: key("tokens"))
    }

    private func pickBoards() {
        T1Overlays.shared.showMenu("Boards", boards.map { b in
            let on = options.boards.contains(b)
            return T1MenuItem(title: title(b), detail: on ? "On" : "Off") {
                if on { options.boards.remove(b) } else { options.boards.insert(b) }
                UserDefaults.standard.set(Array(options.boards).sorted(), forKey: key("boards"))
                Telemetry.capture("buy_option", ["from": family, "option": "board_\(b)", "on": !on])
            }
        })
    }

    // MARK: data

    private func load() async {
        catalog.load(userInitiated: true)
        guard let db = catalog.db else { return }
        var out: [BuyList.Line] = []
        var wantNow: [String: Double] = [:] // a want for any printing: its "From" price, by the printing drawn
        var listing: [String] = []
        switch source {
        case .list(let id):
            guard let list = ListsStore.shared.list(id: id) else { loaded = true; return }
            let basics = catalog.basics
            let order = Dictionary(uniqueKeysWithValues: BuyList.boardOrder.enumerated().map { ($1, $0) })
            let entries = list.eventId != nil ? [] : list.entries.enumerated().sorted {
                (order[$0.element.board] ?? 9, $0.offset) < (order[$1.element.board] ?? 9, $1.offset)
            }.map(\.element)
            out = entries.map { BuyList.Line(cardId: $0.cardId, board: $0.board, finish: $0.finish, qty: $0.qty, basic: basics.contains($0.cardId)) }
            if list.kind == .deck {
                // The tokens the main deck, commander and sideboard make, one each, in their catalog printing.
                let ps = db.printings(ids: entries.filter { $0.board != "maybe" }.map(\.cardId))
                let os = db.oracles(idxs: Array(Set(ps.values.map(\.oracleIdx))))
                var seen: [Int] = []
                for e in entries where e.board != "maybe" {
                    for t in ps[e.cardId].flatMap({ os[$0.oracleIdx] })?.tokens ?? [] where !seen.contains(t) { seen.append(t) }
                }
                let covers = db.covers(oracleIdxs: seen)
                out += seen.compactMap { covers[$0] }.map { BuyList.Line(cardId: $0.cardId, board: "tokens", qty: 1) }
            }
            listing = out.map(\.cardId)
            holdings = Holdings.current(listing: listing)
        case .wants:
            let prices = WantPricesStore.shared
            for w in BindersStore.shared.liveWants {
                if let c = w.cardId {
                    out.append(BuyList.Line(cardId: c, oracleId: w.oracleId, board: "main", finish: w.finish ?? "nonfoil", qty: w.qty))
                } else if let o = db.oracle(id: w.oracleId) {
                    let drawn = prices.items[w.id]?.nowCardId ?? db.covers(oracleIdxs: [o.idx])[o.idx]?.cardId
                    guard let drawn else { continue }
                    if let now = prices.items[w.id]?.now { wantNow[drawn] = now }
                    out.append(BuyList.Line(cardId: drawn, oracleId: w.oracleId, any: true, board: "main", finish: w.finish ?? "nonfoil", qty: w.qty))
                }
            }
        case .missing:
            let lists = ListsStore.shared.lists
            let h = Holdings.current(listing: lists.flatMap { $0.entries.map(\.cardId) })
            out = MissingView.lines(lists, h, basics: db.basicCardIds())
                .map { BuyList.Line(cardId: $0.cardId, board: "main", finish: $0.finish, qty: $0.short) }
        }
        let ids = Array(Set(out.map(\.cardId)))
        let ps = db.printings(ids: ids)
        let os = db.oracles(idxs: Array(Set(ps.values.map(\.oracleIdx))))
        cards = Dictionary(uniqueKeysWithValues: ids.map { id in
            let p = ps[id], o = p.flatMap { os[$0.oracleIdx] }
            return (id, (o?.name ?? "Card not in local data yet", o?.oracleId, p))
        })
        lines = out
        loaded = true
        await PriceBook.shared.load(ids)
        lines = out.map { l in
            var l = l
            l.unit = BuyList.cents(l.any ? wantNow[l.cardId] ?? PriceBook.shared.usd(l.cardId, l.finish) : PriceBook.shared.usd(l.cardId, l.finish))
            return l
        }
    }

    // MARK: buy

    private func buy(_ rows: [BuyList.Row]) {
        let calls = BuyList.calls(rows, exact: effective.exact)
        guard !calls.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                var answers: [TCGplayerCart.Answer] = []
                for c in calls { answers.append(try await TCGplayerCart.links(c.items, from: family, products: c.products)) }
                let a = BuyList.merge(answers)
                Telemetry.capture("tcgplayer_cart_opened", ["from": family, "lines": a.lines, "parts": a.urls.count, "products": a.products.count,
                                                           "skip": effective.skipOwned, "any": effective.anyPrinting, "exact": effective.exact,
                                                           "tokens": effective.boards.contains("tokens")])
                if !TCGplayerCart.present(a, open: { openURL($0) }) { error = "Nothing to buy" }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension TCGplayerCart {
    /// One link opens straight away; more are the Buy on TCGplayer menu. False when there's nothing to open.
    @MainActor
    static func present(_ a: Answer, open: @escaping (URL) -> Void) -> Bool {
        if let u = direct(a).flatMap(URL.init(string:)) { open(u); return true }
        let entries = menu(a)
        guard !entries.isEmpty else { return false }
        T1Overlays.shared.showMenu("Buy on TCGplayer", entries.compactMap { e in
            URL(string: e.url).map { u in T1MenuItem(title: e.title, detail: e.detail) { open(u) } }
        })
        return true
    }
}

/// The screen's one big action along the bottom; flat disabled fill when there's nothing to do.
struct BuyBarButton: View {
    let text: String
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text.uppercased()).font(T1.mono(15, .semibold)).tracking(4).foregroundStyle(enabled ? T1.text : T1.muted)
                .frame(height: 18).padding(.top, 24)
                .frame(maxWidth: .infinity).frame(height: 54, alignment: .top)
                .background((enabled ? T1.surface : T1.disabled).ignoresSafeArea(edges: .bottom))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The Buy row on a deck or cube: copies to buy with the remembered options (tokens left out) and, once prices are
/// in, what they cost.
struct BuyRow: View {
    let list: CardList
    @Binding var path: [LibraryRoute]
    var body: some View {
        let family = list.kind == .deck ? "deck" : "cube"
        let d = UserDefaults.standard
        var o = BuyList.Options()
        if d.object(forKey: "buy.\(family).skip") != nil { o.skipOwned = d.bool(forKey: "buy.\(family).skip") }
        if d.object(forKey: "buy.\(family).any") != nil { o.anyPrinting = d.bool(forKey: "buy.\(family).any") }
        if let b = d.stringArray(forKey: "buy.\(family).boards") { o.boards = Set(b) }
        let basics = CatalogStore.shared.basics
        let prices = PriceBook.shared
        _ = prices.version
        let lines = list.entries.map {
            BuyList.Line(cardId: $0.cardId, board: $0.board, finish: $0.finish, qty: $0.qty,
                         unit: BuyList.cents(prices.usd($0.cardId, $0.finish)), basic: basics.contains($0.cardId))
        }
        let t = BuyList.totals(BuyList.rows(lines, Holdings.current(listing: list.entries.map(\.cardId)), o))
        return Button { path.append(.buy(.list(list.id))) } label: {
            ListRow(title: "Buy", detail: t.buy == 0 ? "You own every card" : "\(t.buy) to buy\(t.total > 0 ? " · " + BuyList.money(t.total) : "")")
        }.buttonStyle(.plain)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
