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
    /// A give: the binder the copies come from. A get: the binder they go into. nil = Unsorted.
    var binderId: String? = nil
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
    let binderItems: [AllocRow]?
    let wants: [WantRow]?
}

@MainActor
@Observable
final class TradesStore {
    static let shared = TradesStore()
    private(set) var trades: [Trade] = []
    private(set) var loaded = false
    var error: String?
    /// Trades deleted this session. A list read that started before the delete committed can still carry the trade,
    /// and an editor's pending autosave can still name it: neither may bring it back (bug #5).
    private var deleted: Set<String> = []

    var isDemo: Bool { CollectionStore.shared.isDemo }

    func load() async {
        if isDemo { loaded = true; return }
        do {
            applyLoaded(try await supabase.rpc("trades_list", params: ["p_limit": AnyJSON.integer(200)]).execute().value)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func applyLoaded(_ list: [Trade]) {
        trades = list.filter { !deleted.contains($0.id) }
        loaded = true
        error = nil
    }

    func forget(_ id: String) {
        deleted.insert(id)
        trades.removeAll { $0.id == id }
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
        if let t, deleted.contains(t.id) { return t }
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

    /// Applies the trade to the collection and takes the gets off your wants. Returns the collection batch (for
    /// Undo) and how many wanted copies it met.
    func confirm(_ t: Trade) async throws -> (batchId: String?, wantsMet: Int) {
        let binders = BindersStore.shared
        func live(_ b: String?) -> String? { b.flatMap { binders.binder($0) == nil ? nil : $0 } }
        let ops = t.gives.map { CollectionOp(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, delta: -$0.qty, binderId: live($0.binderId)) }
            + t.gets.map { CollectionOp(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, delta: $0.qty, binderId: live($0.binderId)) }
        let before = binders.liveWants.reduce(0) { $0 + $1.qty }
        #if DEBUG
        if let demo = CollectionStore.shared.demo {
            let res = try await CollectionStore.shared.apply(ops, source: "trade")
            binders.reflect(wants: demo.meetWants(t.gets, batchId: res.batchId))
            var done = t
            done.status = "confirmed"
            done.batchId = res.batchId
            done.confirmedAt = ISO8601DateFormatter().string(from: .now)
            put(done)
            return (res.batchId, before - binders.liveWants.reduce(0) { $0 + $1.qty })
        }
        #endif
        let res: TradeConfirmResult = try await supabase.rpc("trade_confirm", params: [
            "p_trade_id": AnyJSON.string(t.id), "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
        put(res.trade)
        binders.reflect(allocs: res.binderItems?.map(\.alloc) ?? [])
        binders.reflect(wants: res.wants?.map(\.want) ?? [])
        await CollectionStore.shared.sync()
        return (res.batchId, max(0, before - binders.liveWants.reduce(0) { $0 + $1.qty }))
    }

    func delete(_ t: Trade) async {
        Telemetry.capture("trade_deleted", ["status": t.status])
        forget(t.id)
        if isDemo { return }
        do { try await supabase.rpc("trade_delete", params: ["p_trade_id": AnyJSON.string(t.id)]).execute() } catch {
            self.error = error.localizedDescription
        }
    }

    private func put(_ t: Trade) {
        if deleted.contains(t.id) { return }
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
    @State private var oracleIds: [Int: String] = [:]
    @State private var missingLines: [String: MissingLine] = [:]
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
                                saveTask?.cancel()
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
                    ForEach(lines) { $line in
                        cell($line, give: give, repoint: { c, f in
                            lines.wrappedValue = TradeLine.repoint(lines.wrappedValue, id: line.id, cardId: c, finish: f)
                        }) { lines.wrappedValue.removeAll { $0.id == line.id } }
                    }
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

    /// What a get is to you: a want (and whether it's over your max price), or missing from a deck or cube.
    private func wantNote(_ l: TradeLine) -> (text: String, over: Bool)? {
        guard let p = meta[l.cardId], let oracleId = oracleIds[p.oracleIdx] else { return nil }
        if let w = BinderRules.wantFor(oracleId: oracleId, cardId: l.cardId, finish: l.finish, in: BindersStore.shared.liveWants) {
            if let max = w.maxUsd, let price = prices.usd(l.cardId, l.finish), price > max { return ("Want · over your max $\(max.formatted())", true) }
            return ("Want", false)
        }
        if let m = missingLines["\(l.cardId)|\(l.finish)"] { return ("Missing · \(m.lists.prefix(2).joined(separator: ", "))", false) }
        return nil
    }

    /// One line in a column: small art, name, printing, finish, condition, price, quantity.
    private func cell(_ line: Binding<TradeLine>, give: Bool, repoint: @escaping (String, String) -> Void,
                      remove: @escaping () -> Void) -> some View {
        let l = line.wrappedValue
        let p = meta[l.cardId]
        let name = p.flatMap { names[$0.oracleIdx] } ?? "Card"
        let price = PriceBook.text(prices.usd(l.cardId, l.finish))
        let note = give ? nil : wantNote(l)
        let from = give ? l.binderId.flatMap { BindersStore.shared.binder($0)?.name } : nil
        return Button { if !confirmed { edit(line, give: give, repoint: repoint, remove: remove) } } label: {
            HStack(spacing: 8) {
                if let p { p.art(width: 28, finish: l.finish) } else { Rectangle().fill(T1.bg).frame(width: 28, height: 28 / CardArt.aspect) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(T1.mono(12)).lineLimit(1)
                    LabelText([p?.setLabel, Finish(rawValue: l.finish)?.label].compactMap { $0 }.joined(separator: " · "))
                    LabelText([l.condition, l.lang == "en" ? nil : l.lang.uppercased(), price].compactMap { $0 }.joined(separator: " · "))
                    if let note { LabelText(note.text, color: note.over ? T1.error : T1.accent) }
                    if let from { LabelText(from) }
                }
                Spacer(minLength: 0)
                Text("\(l.qty)").font(T1.mono(15)).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
            .overlay(alignment: .leading) { if note != nil { Rectangle().fill(note!.over ? T1.error : T1.accent).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: actions

    /// Line menu: quantity, printing, finish, condition, remove. A get's printing or finish change merges into a
    /// line that already has that copy.
    private func edit(_ line: Binding<TradeLine>, give: Bool, repoint: @escaping (String, String) -> Void, remove: @escaping () -> Void) {
        let l = line.wrappedValue
        let p = meta[l.cardId]
        let ownedQty = CollectionStore.shared.items[l.id]?.qty ?? 0
        var items: [T1MenuItem] = [
            T1MenuItem(title: "One more", enabled: !give || l.qty < ownedQty) { line.wrappedValue.qty += 1 },
            T1MenuItem(title: "One fewer", enabled: l.qty > 1) { line.wrappedValue.qty -= 1 },
        ]
        if !give {
            items.append(T1MenuItem(title: "Change printing", detail: p?.setLabel) {
                T1Overlays.shared.present(full: true) {
                    ChangePrintingView(target: .tradeGet(l, apply: repoint), close: { T1Overlays.shared.dismissPanel() }).screen("trade_printing")
                }
            })
            for f in p?.finishList ?? [] where f.rawValue != l.finish {
                items.append(T1MenuItem(title: "Make it \(f.label.lowercased())") { repoint(l.cardId, f.rawValue) })
            }
            items.append(T1MenuItem(title: "Condition", detail: Conditions.name(l.condition)) {
                T1Overlays.shared.showMenu("Condition", Conditions.all.map { c in
                    T1MenuItem(title: Conditions.name(c), checked: c == l.condition) { line.wrappedValue.condition = c }
                })
            })
            items.append(T1MenuItem(title: "Language", detail: Languages.name(l.lang)) {
                LanguagePicker.present(current: l.lang, subtitle: p.flatMap { names[$0.oracleIdx] }) { lang in
                    line.wrappedValue.lang = lang
                    Telemetry.capture("language_changed", ["where": "trade", "copies": l.qty])
                }
            })
        }
        items.append(T1MenuItem(title: "Remove", destructive: true) { remove() })
        T1Overlays.shared.showMenu(p.flatMap { names[$0.oracleIdx] }, items)
    }

    private func pick(give: Bool) {
        T1Overlays.shared.present(full: true) {
            TradePickView(give: give) { line in
                add(line, give: give)
                ScanReports.addedByHand(line.cardId)
            }
        }
    }

    private func scan(give: Bool) {
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: give ? "Scan what you give" : "Scan what you get", doneLabel: "Add", owned: give ? ownedFinishes() : nil,
                         preferred: give ? BindersStore.shared.forTradePrintings() : [:],
                         onDone: { cards in
                for c in cards {
                    // Giving: copies in a for-trade binder first, else the condition you hold most of.
                    if give, let copy = Self.bestGive(c.printing.cardId, c.finish) {
                        add(TradeLine(cardId: copy.item.cardId, finish: copy.item.finish, condition: copy.item.condition, lang: copy.item.lang,
                                      qty: 1, binderId: copy.binderId), give: true)
                    } else {
                        add(TradeLine(cardId: c.printing.cardId, finish: c.finish, condition: c.condition, lang: c.lang, qty: 1), give: give)
                    }
                }
                Telemetry.capture("scan_session_ended", ["context": "trade", "cards": cards.count,
                                                         "exact": cards.filter(\.exact).count, "cancelled": false])
                T1Overlays.shared.dismissPanel()
            }, onCancel: {
                Telemetry.capture("scan_session_ended", ["context": "trade", "cards": 0, "exact": 0, "cancelled": true])
                T1Overlays.shared.dismissPanel()
            })
            .screen("card_scanner")
        }
    }

    /// The copy of a printing to give: the item with the most copies in for-trade binders (and that binder), else
    /// the item you hold most of.
    static func bestGive(_ cardId: String, _ finish: String) -> (item: CollectionItem, binderId: String?)? {
        let binders = BindersStore.shared
        let mine = CollectionStore.shared.items.values.filter { $0.cardId == cardId && $0.finish == finish && $0.qty > 0 }
        if let t = mine.map({ ($0, binders.forTrade($0.key)) }).filter({ $0.1.qty > 0 }).max(by: { $0.1.qty < $1.1.qty }) {
            return (t.0, t.1.binderId)
        }
        return mine.max { $0.qty < $1.qty }.map { ($0, nil) }
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
        let found = await Task.detached(priority: .userInitiated) { () -> ([String: CatalogPrinting], [Int: String], [Int: String]) in
            let p = db.printings(ids: ids)
            let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
            return (p, o.mapValues(\.name), o.mapValues(\.oracleId))
        }.value
        meta = found.0
        names = found.1
        oracleIds = found.2
        missingLines = Dictionary(MissingView.lines(ListsStore.shared.lists, owned: ownedByPrinting()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
            T1MenuItem(title: "Remove them from the lists", detail: "Then confirm the trade") { run(removeFromLists: conflicts, choice: "removed") },
            T1MenuItem(title: "Keep them listed", detail: "The lists will show them as missing") { run(removeFromLists: [], choice: "kept") },
        ])
    }

    /// `choice` is the list-conflict answer, for telemetry: none / removed / kept.
    private func run(removeFromLists conflicts: [(list: CardList, oracleIdx: Int, short: Int)], choice: String = "none") {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                saveTask?.cancel()
                let saved = try await store.save(trade, partner: partner.isEmpty ? nil : partner, gives: gives, gets: gets)
                trade = saved
                let fromTrade = gives.filter { $0.binderId.flatMap { BindersStore.shared.binder($0)?.forTrade } == true }.reduce(0) { $0 + $1.qty }
                let res = try await store.confirm(saved)
                Telemetry.capture("trade_confirmed", ["gives": gives.reduce(0) { $0 + $1.qty }, "gets": gets.reduce(0) { $0 + $1.qty },
                                                      "list_conflict": choice, "wants_met": res.wantsMet, "from_trade_binder": fromTrade])
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
                            let trade = BindersStore.shared.forTrade(o.item.key)
                            Button {
                                take(TradeLine(cardId: o.item.cardId, finish: o.item.finish, condition: o.item.condition, lang: o.item.lang, qty: 1,
                                               binderId: trade.binderId), o.name)
                            } label: {
                                CardRow(printing: o.printing, title: o.name,
                                        detail: [o.printing.setLabel, o.item.finishLabel, o.item.condition,
                                                 trade.binderId.flatMap { BindersStore.shared.binder($0)?.name }.map { "\(trade.qty) in \($0)" }]
                                            .compactMap { $0 }.joined(separator: " · ")) {
                                    Text("\(o.item.qty)").font(T1.mono(17)).monospacedDigit().foregroundStyle(trade.qty > 0 ? T1.accent : T1.text)
                                }
                            }.buttonStyle(.plain)
                        }
                    } else {
                        ForEach(hits, id: \.idx) { o in
                            Button {
                                if let p = covers[o.idx] {
                                    take(TradeLine(cardId: p.cardId, finish: (p.finishList.first ?? .nonfoil).rawValue, condition: "NM",
                                                  lang: Languages.forNew(p, picked: UserDefaults.standard.string(forKey: "library.addLang") ?? "en"), qty: 1), o.name)
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
                let trade = Set(items.filter { BindersStore.shared.forTrade($0.key).qty > 0 }.map(\.key))
                owned = await Task.detached(priority: .userInitiated) { Self.ownedMatching(q, items, db, forTrade: trade) }.value
            } else {
                let found = await Task.detached(priority: .userInitiated) { () -> ([CatalogOracle], [Int: CatalogPrinting]) in
                    let h = db.search(q)
                    return (h, db.covers(oracleIdxs: h.map(\.idx)))
                }.value
                if !Task.isCancelled { hits = found.0; covers = found.1 }
            }
        }
    }

    /// Copies in for-trade binders first, then by name.
    nonisolated private static func ownedMatching(_ q: String, _ items: [CollectionItem], _ db: CatalogDB, forTrade: Set<String>) -> [OwnedPick] {
        let p = db.printings(ids: Array(Set(items.map(\.cardId))))
        let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
        let n = CardName.norm(q)
        var out: [OwnedPick] = []
        for it in items {
            guard let pr = p[it.cardId], let or = o[pr.oracleIdx] else { continue }
            if n.isEmpty || or.norm.contains(n) { out.append(OwnedPick(item: it, printing: pr, name: or.name)) }
        }
        out.sort { a, b in
            let ta = forTrade.contains(a.item.key), tb = forTrade.contains(b.item.key)
            if ta != tb { return ta }
            return a.name != b.name ? a.name < b.name : a.item.key < b.item.key
        }
        return Array(out.prefix(200))
    }

    private func take(_ line: TradeLine, _ name: String) {
        onPick(line)
        added = "Added \(name)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
