import SwiftUI
import Supabase

/* Trades (contract/trades-2026-10-16.md). A trade is this account's record of a swap: what you give (copies you
   own) and what you get (any printing). Drafts save as you build them; Confirm applies both sides to the
   collection in one batch. Giving away a card a deck or cube still needs asks what to do with the list first. */

struct TradeLine: Codable, Hashable, Identifiable {
    var cardId: String
    var finish: String
    var condition: String
    var lang: String
    var qty: Int
    var id: String { CollectionStore.key(cardId, finish, condition, lang) }
}

struct Trade: Codable, Hashable, Identifiable {
    let id: String
    var partner: String?
    var note: String?
    var status: String
    var gives: [TradeLine]
    var gets: [TradeLine]
    var batchId: String?
    let createdAt: String?
    var updatedAt: String?
    var confirmedAt: String?
    var confirmed: Bool { status == "confirmed" }
}

private struct TradeConfirmResult: Decodable {
    let batchId: String?
    let duplicate: Bool?
    let trade: Trade
}

@MainActor
@Observable
final class TradesStore {
    static let shared = TradesStore()
    private(set) var trades: [Trade] = []
    private(set) var loaded = false
    var error: String?

    var isDemo: Bool { CollectionStore.shared.isDemo }

    func load() async {
        if isDemo { loaded = true; return }
        do {
            trades = try await supabase.rpc("trades_list", params: ["p_limit": AnyJSON.integer(200)]).execute().value
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        trades = []
        loaded = false
        error = nil
    }

    func trade(_ id: String) -> Trade? { trades.first { $0.id == id } }

    /// Saves a draft (creating it when `id` is nil) and returns it.
    @discardableResult
    func save(_ t: Trade?, partner: String?, gives: [TradeLine], gets: [TradeLine]) async throws -> Trade {
        if isDemo {
            let saved = Trade(id: t?.id ?? UUID().uuidString.lowercased(), partner: partner, note: nil, status: "draft",
                              gives: gives, gets: gets, batchId: nil, createdAt: t?.createdAt ?? ISO8601DateFormatter().string(from: .now),
                              updatedAt: ISO8601DateFormatter().string(from: .now), confirmedAt: nil)
            put(saved)
            return saved
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        func side(_ lines: [TradeLine]) throws -> AnyJSON { try JSONDecoder().decode(AnyJSON.self, from: enc.encode(lines)) }
        let saved: Trade = try await supabase.rpc("trade_save", params: [
            "p_trade_id": t.map { AnyJSON.string($0.id) } ?? .null, "p_partner": partner.map { .string($0) } ?? .null,
            "p_note": .null, "p_gives": try side(gives), "p_gets": try side(gets),
        ]).execute().value
        put(saved)
        return saved
    }

    /// Applies the trade to the collection. Returns the collection batch (for Undo).
    func confirm(_ t: Trade) async throws -> String? {
        let ops = t.gives.map { CollectionOp(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, delta: -$0.qty) }
            + t.gets.map { CollectionOp(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, delta: $0.qty) }
        if isDemo {
            let res = try await CollectionStore.shared.apply(ops, source: "trade")
            var done = t
            done.status = "confirmed"
            done.batchId = res.batchId
            done.confirmedAt = ISO8601DateFormatter().string(from: .now)
            put(done)
            return res.batchId
        }
        let res: TradeConfirmResult = try await supabase.rpc("trade_confirm", params: [
            "p_trade_id": AnyJSON.string(t.id), "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
        put(res.trade)
        await CollectionStore.shared.sync()
        return res.batchId
    }

    func delete(_ t: Trade) async {
        trades.removeAll { $0.id == t.id }
        if isDemo { return }
        do { try await supabase.rpc("trade_delete", params: ["p_trade_id": AnyJSON.string(t.id)]).execute() } catch {
            self.error = error.localizedDescription
        }
    }

    private func put(_ t: Trade) {
        if let i = trades.firstIndex(where: { $0.id == t.id }) { trades[i] = t } else { trades.insert(t, at: 0) }
    }
}

/// Printing ids → finishes owned, for owned-only scanning and picking.
@MainActor
func ownedFinishes() -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    for it in CollectionStore.shared.items.values where it.qty > 0 { out[it.cardId, default: []].insert(it.finish) }
    return out
}

// MARK: list

struct TradesView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: TradesStore { TradesStore.shared }

    var body: some View {
        let drafts = store.trades.filter { !$0.confirmed }
        let done = store.trades.filter(\.confirmed)
        T1Screen {
            Bar(title: "Trades", subtitle: store.loaded ? "\(drafts.count) open" : nil, back: { dismiss() })
            if let error = store.error { Notice(error, error: true) }
            ScrollView {
                HairlineList {
                    Button { path.append(.trade(nil)) } label: {
                        ListRow(title: "New trade", detail: "What you give, what you get")
                    }.buttonStyle(.plain)
                    if !drafts.isEmpty {
                        Section1("Open · \(drafts.count)")
                        ForEach(drafts) { row($0) }
                    }
                    if !done.isEmpty {
                        Section1("Confirmed · \(done.count)")
                        ForEach(done) { row($0) }
                    }
                    if store.loaded && store.trades.isEmpty { Notice("No trades yet.") }
                }
            }
        }
        .task { await store.load() }
    }

    private func row(_ t: Trade) -> some View {
        let give = t.gives.reduce(0) { $0 + $1.qty }, get = t.gets.reduce(0) { $0 + $1.qty }
        return Button { path.append(.trade(t.id)) } label: {
            ListRow(title: t.partner ?? "Trade", detail: "Give \(give) · get \(get) · \(String((t.confirmedAt ?? t.updatedAt ?? "").prefix(10)))")
        }.buttonStyle(.plain)
    }
}

// MARK: one trade

struct TradeView: View {
    let tradeId: String?
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: TradesStore { TradesStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    private var prices: PriceBook { PriceBook.shared }

    @State private var trade: Trade?
    @State private var partner = ""
    @State private var gives: [TradeLine] = []
    @State private var gets: [TradeLine] = []
    @State private var meta: [String: CatalogPrinting] = [:]
    @State private var names: [Int: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var started = false

    private var confirmed: Bool { trade?.confirmed == true }

    var body: some View {
        T1Screen {
            Bar(title: partner.isEmpty ? "Trade" : partner, subtitle: confirmed ? "Confirmed" : "Draft", back: { dismiss() }) {
                if trade != nil && !confirmed {
                    BarButton("Delete") {
                        T1Overlays.shared.showMenu("Delete this trade?", [
                            T1MenuItem(title: "Delete", destructive: true) {
                                if let t = trade { Task { await store.delete(t) } }
                                dismiss()
                            },
                        ])
                    }
                }
            }
            if let error { Notice(error, error: true) }
            CatalogStatusRow(catalog: catalog)
            if confirmed {
                if !partner.isEmpty { ListRow(title: "With", detail: partner) }
            } else {
                Field(label: "Trading with", text: $partner)
            }
            // Two columns: what you give | what you get.
            HStack(alignment: .top, spacing: 1) {
                column("You give", lines: $gives, give: true)
                column("You get", lines: $gets, give: false)
            }
            .frame(maxHeight: .infinity)
            totals
            if !confirmed {
                BigAction(text: "Confirm trade", enabled: !(gives.isEmpty && gets.isEmpty) && catalog.phase == .ready, busy: busy, accent: true) {
                    confirm()
                }
            }
        }
        .task {
            catalog.load(userInitiated: true)
            if !store.loaded { await store.load() }
            if !started, let id = tradeId, let t = store.trade(id) {
                trade = t
                partner = t.partner ?? ""
                gives = t.gives
                gets = t.gets
            }
            started = true
        }
        .task(id: "\(gives.map(\.cardId))-\(gets.map(\.cardId))-\(catalog.generation)") { await refreshMeta() }
        .onChange(of: gives) { scheduleSave() }
        .onChange(of: gets) { scheduleSave() }
        .onChange(of: partner) { scheduleSave() }
    }

    // MARK: sections

    private func column(_ title: String, lines: Binding<[TradeLine]>, give: Bool) -> some View {
        let n = lines.wrappedValue.reduce(0) { $0 + $1.qty }
        return VStack(spacing: 1) {
            VStack(alignment: .leading, spacing: 2) {
                LabelText("\(title) · \(n)")
                LabelText(value(lines.wrappedValue) ?? " ", color: T1.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8).background(T1.surface)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(lines) { $line in cell($line, give: give) { lines.wrappedValue.removeAll { $0.id == line.id } } }
                }
            }
            .frame(maxHeight: .infinity)
            if !confirmed {
                HStack(spacing: 1) {
                    Ghost(text: "Add") { pick(give: give) }
                    Ghost(text: "Scan") { scan(give: give) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var totals: some View {
        let give = PriceBook.text(sum(gives)) ?? "—", get = PriceBook.text(sum(gets)) ?? "—"
        return ListRow(title: "Market value", detail: "Give \(give) · get \(get) · TCGplayer market") {
            if let g = sum(gets), let v = sum(gives) {
                let d = g - v
                Text((d >= 0 ? "+" : "−") + (PriceBook.text(abs(d)) ?? "")).font(T1.mono(15)).monospacedDigit()
            }
        }
    }

    /// One line in a column: small art, name, printing, finish, condition, price, quantity.
    private func cell(_ line: Binding<TradeLine>, give: Bool, remove: @escaping () -> Void) -> some View {
        let l = line.wrappedValue
        let p = meta[l.cardId]
        let name = p.flatMap { names[$0.oracleIdx] } ?? "Card"
        let price = PriceBook.text(prices.usd(l.cardId, l.finish))
        return Button { if !confirmed { edit(line, give: give, remove: remove) } } label: {
            HStack(spacing: 8) {
                if let p { p.art(width: 28) } else { Rectangle().fill(T1.bg).frame(width: 28, height: 28 / CardArt.aspect) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(T1.mono(12)).lineLimit(1)
                    LabelText([p?.setLabel, Finish(rawValue: l.finish)?.label].compactMap { $0 }.joined(separator: " · "))
                    LabelText([l.condition, price].compactMap { $0 }.joined(separator: " · "))
                }
                Spacer(minLength: 0)
                Text("\(l.qty)").font(T1.mono(15)).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: actions

    /// Line menu: quantity, finish, condition, remove.
    private func edit(_ line: Binding<TradeLine>, give: Bool, remove: @escaping () -> Void) {
        let l = line.wrappedValue
        let p = meta[l.cardId]
        let ownedQty = CollectionStore.shared.items[l.id]?.qty ?? 0
        var items: [T1MenuItem] = [
            T1MenuItem(title: "One more", enabled: !give || l.qty < ownedQty) { line.wrappedValue.qty += 1 },
            T1MenuItem(title: "One fewer", enabled: l.qty > 1) { line.wrappedValue.qty -= 1 },
        ]
        if !give {
            for f in p?.finishList ?? [] where f.rawValue != l.finish {
                items.append(T1MenuItem(title: "Make it \(f.label.lowercased())") { line.wrappedValue.finish = f.rawValue })
            }
            items.append(T1MenuItem(title: "Condition", detail: Conditions.name(l.condition)) {
                T1Overlays.shared.showMenu("Condition", Conditions.all.map { c in
                    T1MenuItem(title: Conditions.name(c), checked: c == l.condition) { line.wrappedValue.condition = c }
                })
            })
        }
        items.append(T1MenuItem(title: "Remove", destructive: true) { remove() })
        T1Overlays.shared.showMenu(p.flatMap { names[$0.oracleIdx] }, items)
    }

    private func pick(give: Bool) {
        T1Overlays.shared.present(full: true) {
            TradePickView(give: give) { line in
                add(line, give: give)
            }
        }
    }

    private func scan(give: Bool) {
        T1Overlays.shared.present(full: true) {
            CardScanView(title: give ? "Scan what you give" : "Scan what you get", doneLabel: "Add", owned: give ? ownedFinishes() : nil,
                         onDone: { cards in
                for c in cards {
                    // Giving: take the condition you hold most of.
                    let condition = give ? bestOwnedCondition(c.printing.cardId, c.finish) : c.condition
                    add(TradeLine(cardId: c.printing.cardId, finish: c.finish, condition: condition, lang: "en", qty: 1), give: give)
                }
                T1Overlays.shared.dismissPanel()
            }, onCancel: { T1Overlays.shared.dismissPanel() })
        }
    }

    private func bestOwnedCondition(_ cardId: String, _ finish: String) -> String {
        CollectionStore.shared.items.values.filter { $0.cardId == cardId && $0.finish == finish }
            .max { $0.qty < $1.qty }?.condition ?? "NM"
    }

    private func add(_ line: TradeLine, give: Bool) {
        if give {
            let have = CollectionStore.shared.items[line.id]?.qty ?? 0
            if let i = gives.firstIndex(where: { $0.id == line.id }) {
                gives[i].qty = min(gives[i].qty + line.qty, max(have, gives[i].qty))
            } else { gives.append(line) }
        } else {
            if let i = gets.firstIndex(where: { $0.id == line.id }) { gets[i].qty += line.qty } else { gets.append(line) }
        }
    }

    private func refreshMeta() async {
        guard let db = catalog.db else { return }
        let ids = Array(Set((gives + gets).map(\.cardId)))
        let found = await Task.detached(priority: .userInitiated) { () -> ([String: CatalogPrinting], [Int: String]) in
            let p = db.printings(ids: ids)
            let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
            return (p, o.mapValues(\.name))
        }.value
        meta = found.0
        names = found.1
        await prices.load(ids)
    }

    private func value(_ lines: [TradeLine]) -> String? { PriceBook.text(sum(lines)) }

    /// Market value of a side; nil when none of its cards has a market price.
    private func sum(_ lines: [TradeLine]) -> Double? {
        let priced = lines.compactMap { l in prices.usd(l.cardId, l.finish).map { Double(l.qty) * $0 } }
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }

    /// Drafts save half a second after the last change.
    private func scheduleSave() {
        guard started, !confirmed else { return }
        saveTask?.cancel()
        if trade == nil && gives.isEmpty && gets.isEmpty { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            do {
                trade = try await store.save(trade, partner: partner.isEmpty ? nil : partner, gives: gives, gets: gets)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: confirm

    /// Lists that would need more copies than you'll have left after giving these away.
    private func listConflicts() -> [(list: CardList, oracleIdx: Int, short: Int)] {
        guard let db = catalog.db else { return [] }
        let giveIdx = Set(gives.compactMap { meta[$0.cardId]?.oracleIdx })
        guard !giveIdx.isEmpty else { return [] }
        let items = Array(CollectionStore.shared.items.values)
        let listIds = Set(ListsStore.shared.lists.flatMap { $0.entries.map(\.cardId) })
        let printing = db.printings(ids: Array(Set(items.map(\.cardId)).union(listIds)))
        var have: [Int: Int] = [:]
        for it in items { if let o = printing[it.cardId]?.oracleIdx, giveIdx.contains(o) { have[o, default: 0] += it.qty } }
        for g in gives { if let o = meta[g.cardId]?.oracleIdx { have[o, default: 0] -= g.qty } }
        for g in gets { if let o = meta[g.cardId]?.oracleIdx, giveIdx.contains(o) { have[o, default: 0] += g.qty } }
        var out: [(CardList, Int, Int)] = []
        for l in ListsStore.shared.lists {
            var need: [Int: Int] = [:]
            for e in l.entries where e.board != "maybe" {
                if let o = printing[e.cardId]?.oracleIdx, giveIdx.contains(o) { need[o, default: 0] += e.qty }
            }
            for (o, n) in need where n > max(have[o] ?? 0, 0) { out.append((l, o, n - max(have[o] ?? 0, 0))) }
        }
        return out
    }

    private func confirm() {
        let conflicts = listConflicts()
        if conflicts.isEmpty { run(removeFromLists: []); return }
        let lines = conflicts.map { "\(names[$0.oracleIdx] ?? "A card") in \($0.list.name)" }
        T1Overlays.shared.showMenu("Cards in your decks", message: "You're giving away copies these lists use: \(lines.joined(separator: ", ")).", [
            T1MenuItem(title: "Remove them from the lists", detail: "Then confirm the trade") { run(removeFromLists: conflicts) },
            T1MenuItem(title: "Keep them listed", detail: "The lists will show them as missing") { run(removeFromLists: []) },
        ])
    }

    private func run(removeFromLists conflicts: [(list: CardList, oracleIdx: Int, short: Int)]) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                saveTask?.cancel()
                let saved = try await store.save(trade, partner: partner.isEmpty ? nil : partner, gives: gives, gets: gets)
                trade = saved
                _ = try await store.confirm(saved)
                trade = store.trade(saved.id) ?? saved
                removeFromLists(conflicts)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Takes the missing copies out of each list's main deck and sideboard, sideboard first.
    private func removeFromLists(_ conflicts: [(list: CardList, oracleIdx: Int, short: Int)]) {
        guard let db = catalog.db, !conflicts.isEmpty else { return }
        for c in conflicts {
            var left = c.short
            let entries = c.list.entries.filter { $0.board != "maybe" }
            let printing = db.printings(ids: entries.map(\.cardId))
            for e in entries.sorted(by: { $0.board == "side" && $1.board != "side" }) where left > 0 {
                guard printing[e.cardId]?.oracleIdx == c.oracleIdx else { continue }
                let n = min(left, e.qty)
                ListsStore.shared.add(listId: c.list.id, cardId: e.cardId, board: e.board, finish: e.finish, delta: -n)
                left -= n
            }
        }
    }
}

// MARK: picking a card

struct OwnedPick: Sendable {
    let item: CollectionItem
    let printing: CatalogPrinting
    let name: String
}

/// Search for a card to add to one side of a trade. Giving: only copies you own, by printing, finish and condition.
/// Getting: any card; it starts as its default printing, non-foil, near mint (change it on the line).
struct TradePickView: View {
    let give: Bool
    let onPick: (TradeLine) -> Void
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @State private var owned: [OwnedPick] = []
    @State private var added: String?
    @FocusState private var focused: Bool

    var body: some View {
        T1Screen {
            Bar(title: give ? "Add what you give" : "Add what you get", subtitle: added, back: { T1Overlays.shared.dismissPanel() })
            CatalogStatusRow(catalog: catalog)
            T1SearchField(text: $query, prompt: give ? "Search your collection" : "Lightning Bolt").focused($focused)
            ScrollView {
                HairlineList {
                    if give {
                        ForEach(owned, id: \.item.key) { o in
                            Button { take(TradeLine(cardId: o.item.cardId, finish: o.item.finish, condition: o.item.condition, lang: o.item.lang, qty: 1), o.name) } label: {
                                CardRow(printing: o.printing, title: o.name,
                                        detail: "\(o.printing.setLabel) · \(o.item.finishLabel) · \(o.item.condition)") {
                                    Text("\(o.item.qty)").font(T1.mono(17)).monospacedDigit()
                                }
                            }.buttonStyle(.plain)
                        }
                    } else {
                        ForEach(hits, id: \.idx) { o in
                            Button {
                                if let p = covers[o.idx] {
                                    take(TradeLine(cardId: p.cardId, finish: (p.finishList.first ?? .nonfoil).rawValue, condition: "NM", lang: "en", qty: 1), o.name)
                                }
                            } label: {
                                CardRow(printing: covers[o.idx], title: o.name, detail: o.typeLine)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            BigAction(text: "Done", accent: false) { T1Overlays.shared.dismissPanel() }
        }
        .onAppear { focused = true }
        .task(id: "\(query)-\(catalog.generation)") {
            guard let db = catalog.db else { return }
            let q = query
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            if give {
                let items = Array(CollectionStore.shared.items.values)
                owned = await Task.detached(priority: .userInitiated) { Self.ownedMatching(q, items, db) }.value
            } else {
                let found = await Task.detached(priority: .userInitiated) { () -> ([CatalogOracle], [Int: CatalogPrinting]) in
                    let h = db.search(q)
                    return (h, db.covers(oracleIdxs: h.map(\.idx)))
                }.value
                if !Task.isCancelled { hits = found.0; covers = found.1 }
            }
        }
    }

    nonisolated private static func ownedMatching(_ q: String, _ items: [CollectionItem], _ db: CatalogDB) -> [OwnedPick] {
        let p = db.printings(ids: Array(Set(items.map(\.cardId))))
        let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
        let n = CardName.norm(q)
        var out: [OwnedPick] = []
        for it in items {
            guard let pr = p[it.cardId], let or = o[pr.oracleIdx] else { continue }
            if n.isEmpty || or.norm.contains(n) { out.append(OwnedPick(item: it, printing: pr, name: or.name)) }
        }
        out.sort { a, b in a.name != b.name ? a.name < b.name : a.item.key < b.item.key }
        return Array(out.prefix(200))
    }

    private func take(_ line: TradeLine, _ name: String) {
        onPick(line)
        added = "Added \(name)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
