import SwiftUI

/* Card detail's Add to drilldown and info view (contract/card-detail-2026-10-23.md § Add to, § Info view). */

/// Collection / Deck / Cube / Binder / Want / Trade, each drilling down in place (Figma Add To Selection and Add to
/// Drilldown). Adds one of the version on screen; condition and language go with collection, binder and trade adds.
/// The Collection scanner opens it for every card scanned (`scanned`), many cards at once.
struct AddToPanel: View {
    let oracle: CatalogOracle
    let printings: [String: CatalogPrinting]
    /// What to add, each version with its count (one copy, or every copy in view).
    let lines: [CardVersion]
    let scope: String
    var path: Binding<[LibraryRoute]>?
    /// Several cards (the Collection scanner's list): what the done line calls them ("12 cards") and each printing's
    /// oracle id for wants. No TCGplayer row.
    var scanned: (name: String, oracleIds: [String: String])?
    let done: (String, CardUndo?) -> Void
    @State private var step: Step = .root
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    enum Step: Equatable { case root, decks, deckSection(String), cubes, binders, want, trades, tradeSide(String?) }

    private var lists: ListsStore { ListsStore.shared }
    private var version: CardVersion { lines[0] }
    /// The printing when every line shares one.
    private var printing: CatalogPrinting? { Set(lines.map(\.cardId)).count == 1 ? printings[version.cardId] : nil }
    private var name: String { scanned?.name ?? printing?.setLabel ?? oracle.name }
    private var count: Int { lines.reduce(0) { $0 + $1.qty } }

    var body: some View {
        VStack(spacing: 1) {
            if let error { Notice(error, error: true) }
            SelectorPanel(title: title, back: step == .root ? nil : { step = parent }, options: options, current: nil, pick: pick)
        }
        .task { if TradesStore.shared.trades.isEmpty { await TradesStore.shared.load() } }
    }

    private var title: String? {
        switch step {
        case .root: nil
        case .decks: "Deck"
        case .deckSection(let id): lists.list(id: id)?.name ?? "Deck"
        case .cubes: "Cube"
        case .binders: "Binder"
        case .want: "Want"
        case .trades: "Trade"
        case .tradeSide: "Get or give"
        }
    }

    private var parent: Step {
        switch step {
        case .deckSection: .decks
        case .tradeSide: .trades
        default: .root
        }
    }

    private var owned: Bool { lines.allSatisfy { (CollectionStore.shared.items[$0.itemKey]?.qty ?? 0) > 0 } }

    private var options: [SelectorOption] {
        switch step {
        case .root:
            return ([("collection", "Collection"), ("deck", "Deck"), ("cube", "Cube"), ("binder", "Binder"), ("want", "Want"), ("trade", "Trade")]
                    + (scanned == nil ? [("tcgplayer", "TCGplayer")] : []))
                .map { SelectorOption(value: $0.0, label: $0.1) }
        case .decks:
            let decks = lists.lists(.deck).filter { $0.eventId == nil }
            return decks.isEmpty ? [SelectorOption(value: "", label: "No decks yet")]
                : decks.map { SelectorOption(value: $0.id, label: $0.name, detail: Self.formatName($0.format)) }
        case .deckSection(let id):
            let l = lists.list(id: id)
            return ["main", "side", "maybe"].map { SelectorOption(value: $0, label: l?.boardTitle($0) ?? $0) }
        case .cubes:
            let cubes = lists.lists(.cube)
            return cubes.isEmpty ? [SelectorOption(value: "", label: "No cubes yet")]
                : cubes.map { SelectorOption(value: $0.id, label: $0.name, detail: "\($0.count("main")) cards") }
        case .binders:
            let all = BindersStore.shared.binders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return all.isEmpty ? [SelectorOption(value: "", label: "No binders yet")]
                : all.map { SelectorOption(value: $0.id, label: $0.name, detail: $0.forTrade ? "For trade" : nil) }
        case .want:
            var out = [SelectorOption(value: "any", label: "Any printing")]
            if scanned != nil {
                out.append(SelectorOption(value: "printing", label: "These printings"))
                out.append(SelectorOption(value: "finish", label: "These printings and finishes"))
            } else if printing == nil && lines.count > 1 {
                out.append(SelectorOption(value: "printing", label: "Each printing", detail: "\(Set(lines.map(\.cardId)).count) printings"))
                out.append(SelectorOption(value: "finish", label: "Each printing and finish"))
            } else if printing != nil {
                out.append(SelectorOption(value: "printing", label: "This printing", detail: name))
                if (printing?.finishList.count ?? 1) > 1 {
                    out.append(SelectorOption(value: "finish", label: "This printing and finish",
                                              detail: "\(name) · \(Finish(rawValue: version.finish)?.label ?? version.finish)"))
                }
            }
            return out
        case .trades:
            let drafts = TradesStore.shared.trades.filter { !$0.confirmed }
            return [SelectorOption(value: "new", label: "New trade")] + drafts.map { t in
                SelectorOption(value: t.id, label: t.partner ?? "Trade",
                               detail: "Give \(t.gives.reduce(0) { $0 + $1.qty }) · get \(t.gets.reduce(0) { $0 + $1.qty })")
            }
        case .tradeSide:
            return [SelectorOption(value: "get", label: "Get"), SelectorOption(value: "give", label: "Give", detail: "From your copies")]
        }
    }

    static func formatName(_ f: String) -> String {
        f.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    private func pick(_ value: String) {
        guard !value.isEmpty else { return }
        error = nil
        switch step {
        case .root:
            switch value {
            case "collection": addToCollection(binderId: nil, place: "your collection")
            case "deck": step = .decks
            case "cube": step = .cubes
            case "binder": step = .binders
            case "want": step = .want
            case "tcgplayer": buy()
            default: step = .trades
            }
        case .decks: step = .deckSection(value)
        case .deckSection(let id): addToList(id, board: value)
        case .cubes: addToList(value, board: "main")
        case .binders: addToCollection(binderId: value, place: BindersStore.shared.binder(value)?.name ?? "the binder")
        case .want: want(value)
        case .trades:
            let id = value == "new" ? nil : value
            if owned { step = .tradeSide(id) } else { addToTrade(id, give: false) }
        case .tradeSide(let id): addToTrade(id, give: value == "give")
        }
    }

    private func finish(_ destination: String, _ label: String, _ undo: CardUndo?) {
        Telemetry.capture(scanned == nil ? "card_added_to" : "scan_added_to", ["destination": destination, "scope": scope, "copies": count])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        T1Overlays.shared.dismissPanel()
        done(label, undo)
    }

    /// Add to → TCGplayer (contract/buy-2026-11-06.md § Card page): each printing in view to its product page.
    private func buy() {
        var items: [TCGplayerCart.Item] = []
        for l in lines where l.qty > 0 {
            if let i = items.firstIndex(where: { $0.cardId == l.cardId }) { items[i].qty += l.qty }
            else { items.append(TCGplayerCart.Item(cardId: l.cardId, qty: l.qty)) }
        }
        Task {
            do {
                let a = try await TCGplayerCart.links(items, from: "card", products: true)
                Telemetry.capture("tcgplayer_cart_opened", ["from": "card", "lines": a.lines, "parts": a.urls.count, "products": a.products.count])
                T1Overlays.shared.dismissPanel()
                if !TCGplayerCart.present(a, open: { openURL($0) }) { error = "Nothing to buy" }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addToCollection(binderId: String?, place: String) {
        let ops = lines.map { CardDetailRules.step($0, delta: $0.qty, binderId: binderId) }
        Task {
            do {
                let res = try await CollectionStore.shared.apply(ops, source: scanned == nil ? "manual" : "scan")
                let label = "Added \(count) \(name) to \(place)"
                finish(binderId == nil ? "collection" : "binder", label, CardUndo(label: label) {
                    _ = try await CollectionStore.shared.undo(batchId: res.batchId)
                })
            } catch { self.error = error.localizedDescription }
        }
    }

    private func addToList(_ id: String, board: String) {
        guard let l = lists.list(id: id) else { return }
        var added: [(cardId: String, finish: String, lang: String, cond: String, qty: Int)] = []
        for line in lines {
            guard let p = printings[line.cardId] else { continue }
            // A finish the printing lacks is saved in one it has (contract/lists-2026-10-15.md).
            let f = p.finishList.map(\.rawValue).contains(line.finish) ? line.finish : p.finishList.first?.rawValue ?? "nonfoil"
            // The copy keeps the language and condition on screen (a Japanese LP copy you own goes in as Japanese LP).
            let lang = Languages.forNew(p, picked: line.lang)
            lists.add(listId: id, cardId: p.cardId, board: board, finish: f, lang: lang, cond: line.condition, delta: line.qty)
            added.append((p.cardId, f, lang, line.condition, line.qty))
        }
        guard !added.isEmpty else { return }
        let label = "Added \(count) \(name) to \(l.name) · \(l.boardTitle(board))"
        finish(l.kind.rawValue, label, CardUndo(label: label) {
            for a in added { lists.add(listId: id, cardId: a.cardId, board: board, finish: a.finish, lang: a.lang, cond: a.cond, delta: -a.qty) }
        })
    }

    private func want(_ how: String) {
        // One want per card (any printing), printing, or printing and finish, counting the copies of each.
        var counts: [String: (oracleId: String, cardId: String?, finish: String?, qty: Int)] = [:]
        var order: [String] = []
        for line in lines {
            let oracleId = scanned?.oracleIds[line.cardId] ?? oracle.oracleId
            let cardId = how == "any" ? nil : line.cardId, finish = how == "finish" ? line.finish : nil
            let key = "\(oracleId)|\(cardId ?? "")|\(finish ?? "")"
            if counts[key] == nil { order.append(key) }
            counts[key, default: (oracleId, cardId, finish, 0)].qty += line.qty
        }
        let ops = order.compactMap { counts[$0] }.map { WantOp(oracleId: $0.oracleId, cardId: $0.cardId, finish: $0.finish, delta: $0.qty) }
        Task {
            do {
                try await BindersStore.shared.applyWants(ops, event: "want_added",
                                                         props: ["any_printing": how == "any", "finish": how == "finish", "has_max": false,
                                                                 "from": scanned == nil ? "card" : "scan"])
                finish("want", "Wanted \(count) \(how == "any" && scanned == nil ? oracle.name : name)", nil)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func addToTrade(_ id: String?, give: Bool) {
        let store = TradesStore.shared
        let t = id.flatMap { store.trade($0) }
        var gives = t?.gives ?? [], gets = t?.gets ?? []
        for v in lines {
            var line = TradeLine(cardId: v.cardId, finish: v.finish, condition: v.condition, lang: v.lang, qty: v.qty)
            if give { line.binderId = BindersStore.shared.forTrade(v.itemKey).binderId }
            func put(_ side: inout [TradeLine]) {
                if let i = side.firstIndex(where: { $0.id == line.id }) { side[i].qty += v.qty } else { side.append(line) }
            }
            if give { put(&gives) } else { put(&gets) }
        }
        Task {
            do {
                let saved = try await store.save(t, partner: t?.partner, gives: gives, gets: gets)
                finish("trade", "\(give ? "Giving" : "Getting") \(count) \(name) in the trade\(saved.partner.map { " with \($0)" } ?? "")", nil)
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: info view

/// Rules text and details from Scryfall's API for one printing, asked once per printing per launch.
struct CardDetails: Sendable {
    let text: String
    let type: String?
    let rarity: String?
    let artist: String?
}

@MainActor
enum CardDetailsSource {
    private static var cache: [String: CardDetails] = [:]

    private struct Face: Decodable { let name: String?; let oracle_text: String?; let type_line: String?; let artist: String? }
    private struct Card: Decodable {
        let oracle_text: String?
        let type_line: String?
        let rarity: String?
        let artist: String?
        let card_faces: [Face]?
    }

    static func details(_ cardId: String) async throws -> CardDetails {
        if let hit = cache[cardId] { return hit }
        var req = URLRequest(url: URL(string: "https://api.scryfall.com/cards/\(cardId)")!)
        req.setValue("Table1/1.0 (table-1.site)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let c = try JSONDecoder().decode(Card.self, from: data)
        let faces = c.card_faces ?? []
        let text = c.oracle_text?.isEmpty == false ? c.oracle_text!
            : faces.compactMap { f in f.oracle_text.map { t in faces.count > 1 ? "\(f.name ?? "")\n\(t)" : t } }.joined(separator: "\n\n")
        let out = CardDetails(text: text, type: c.type_line ?? faces.first?.type_line, rarity: c.rarity, artist: c.artist ?? faces.first?.artist)
        cache[cardId] = out
        return out
    }
}

/// The list icon's view (Figma 231:9241): a smaller image, the rules text, Price / Card type / Rarity / Artist, then
/// where the card is used, binders, wants, hero and history.
struct CardInfoView: View {
    let oracle: CatalogOracle
    let printing: CatalogPrinting?
    let version: CardVersion
    let printings: [CatalogPrinting]
    let context: CardContext?
    var path: Binding<[LibraryRoute]>?
    let versions: [CardVersion]
    let report: (String, CardUndo?) -> Void
    @State private var details: CardDetails?
    @State private var failed = false
    @State private var history: [HistoryEntry]?
    @State private var busy = false
    @State private var iconOn = false
    @State private var iconBusy = false
    private var col: CollectionStore { CollectionStore.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                if let printing {
                    printing.art(width: (259 * CardArt.aspect).rounded(), finish: version.finish)
                        .frame(maxWidth: .infinity).padding(.vertical, 16).background(T1.bg)
                }
                rules
                row("Price", PriceBook.marked(PriceBook.conditionText(PriceBook.shared.usd(version.cardId, version.finish), version.condition),
                                              converted: PriceBook.shared.converted(version.cardId, version.finish), source: true) ?? "—")
                row("Card type", details?.type ?? oracle.typeLine)
                if !oracle.manaCost.isEmpty { row("Mana cost", oracle.manaCost) }
                row("Rarity", details?.rarity ?? printing.flatMap { CatalogPack.rarityName[$0.rarity] }?.lowercased() ?? "—")
                row("Artist", details?.artist ?? "—")
                if let printing { row("Printing", [printing.setLabel, printing.lang == "en" ? nil : Languages.name(printing.lang)].compactMap { $0 }.joined(separator: " · ")) }
                extras
            }
        }
        .frame(maxHeight: .infinity)
        .background(T1.bg)
        .task(id: version.cardId) {
            failed = false
            do { details = try await CardDetailsSource.details(version.cardId) } catch { failed = true }
        }
        .task(id: "\(version.cardId)-\(col.version)") {
            history = try? await col.history(cardId: version.cardId)
        }
    }

    @ViewBuilder private var rules: some View {
        Group {
            if let details {
                Text(details.text.isEmpty ? "No rules text." : details.text).font(T1.mono(16)).tracking(0.5).lineSpacing(4)
            } else {
                Text(failed ? "Rules text needs a connection." : "Loading rules text…").font(T1.mono(12)).foregroundStyle(T1.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .background(T1.bg)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 1) {
            Text(label.uppercased()).font(T1.mono(11)).tracking(1.5).foregroundStyle(T1.muted)
            Spacer(minLength: 12)
            Text(value).font(T1.mono(11)).tracking(1.5).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 34)
        .background(T1.bg)
    }

    // MARK: the rest of the old screen

    @ViewBuilder private var extras: some View {
        if case .list(let id) = context, let list = ListsStore.shared.list(id: id), list.eventId == nil {
            listAddRow(list)
            let mine = MatchCollection.versions(printings), ids = Set(printings.map(\.cardId))
            if !MatchCollection.sections(list, ids: ids, versions: mine).isEmpty {
                Button { MatchCollection.present(list: list, printings: printings, report: report) } label: {
                    ListRow(title: "Match collection", detail: MatchCollection.detail(list, ids: ids, versions: mine))
                }.buttonStyle(.plain)
            }
        }
        let ids = Set(printings.map(\.cardId))
        let owned = col.items.values.filter { ids.contains($0.cardId) }
            .sorted { $0.cardId != $1.cardId ? $0.cardId < $1.cardId : $0.key < $1.key }
        let total = owned.reduce(0) { $0 + $1.qty }
        let uses = ListsStore.shared.uses(cardIds: ids)
        if !uses.isEmpty {
            let used = uses.reduce(0) { $0 + $1.qty }
            // Lists don't reserve copies, so say when they ask for more than you own between them.
            Section1(used > total ? "In decks and cubes · \(used) used · own \(total)" : "In decks and cubes · \(used)")
            ForEach(uses, id: \.list.id) { use in
                let kind = use.list.kind == .deck ? "\(use.list.format.capitalized) deck" : "Cube"
                Button { path?.wrappedValue.append(.list(use.list.id)) } label: {
                    ListRow(title: use.list.name, detail: use.considering > 0 ? "\(kind) · \(use.considering) considering" : kind) {
                        Text("\(use.qty)").font(T1.mono(17)).monospacedDigit()
                    }
                }.buttonStyle(.plain)
            }
        }
        if !owned.isEmpty {
            let _ = BindersStore.shared.version
            Section1("Your copies · \(total)")
            ForEach(owned, id: \.key) { it in
                let p = printings.first { $0.cardId == it.cardId }
                Button {
                    BinderMoveFlow.start(it, label: p?.setLabel ?? oracle.name) { label in if let label { report(label, nil) } }
                } label: {
                    CardRow(printing: p, title: "\(p?.setLabel ?? "?") · \(it.finishLabel)",
                            detail: [it.condition, it.lang == "en" ? nil : it.lang.uppercased(), BindersStore.shared.placementText(it)]
                                .compactMap { $0 }.joined(separator: " · "), finish: it.finish) {
                        HStack(spacing: 12) {
                            LabelText("Move", color: T1.text)
                            Text("\(it.qty)").font(T1.mono(17)).monospacedDigit()
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
        wantRow
        heroRow
        iconRow
        Section1("History · \(printing?.setLabel ?? oracle.name)")
        VStack(alignment: .leading, spacing: 4) {
            if let history {
                if history.isEmpty { LabelText("No changes yet") }
                ForEach(Array(history.enumerated()), id: \.offset) { _, h in
                    Text("\(h.at.prefix(10)) · \(h.delta > 0 ? "+\(h.delta)" : "\(h.delta)") \(Finish(rawValue: h.finish)?.label ?? h.finish) · \(h.source) → \(h.qtyAfter)")
                        .font(T1.mono(12)).monospacedDigit()
                        .foregroundStyle(h.undone ? T1.disabled : T1.text)
                        .strikethrough(h.undone)
                }
            } else {
                LabelText("Loading…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
    }

    /// Add to collection from a deck or cube: the copies of this card it lacks, every copy it lists, or one of a
    /// listed printing, in the condition picked for adds and the language of the printing listed.
    private func listAddRow(_ list: CardList) -> some View {
        let byId = Dictionary(printings.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        let lines = list.entries.filter { byId[$0.cardId] != nil }
        let only = Set(lines.map(\.cardId))
        let ownedNow = ownedByLanguage()
        let basics = CatalogStore.shared.basics
        let missing = ListToCollection.ops(list.entries, kind: list.kind, owned: ownedNow, mode: .missing, only: only, basics: basics)
        let all = ListToCollection.ops(list.entries, kind: list.kind, owned: ownedNow, mode: .all, only: only)
        let m = ListToCollection.copies(missing), a = ListToCollection.copies(all)
        func add(_ ops: [ListToCollection.Op], mode: String) {
            let n = ListToCollection.copies(ops)
            busy = true
            Task {
                defer { busy = false }
                do {
                    let res = try await col.apply(ListToCollection.collectionOps(ops, printingLang: { byId[$0]?.lang }))
                    let label = "Added \(n) \(oracle.name) to your collection"
                    report(label, CardUndo(label: label) { _ = try await CollectionStore.shared.undo(batchId: res.batchId) })
                    Telemetry.capture("list_added_to_collection", ["kind": list.kind.rawValue, "mode": mode, "sideboard": true,
                                                                  "copies": n, "lines": ops.count, "from": "card"])
                } catch { report(error.localizedDescription, nil) }
            }
        }
        return Button {
            var items: [T1MenuItem] = []
            if m > 0 { items.append(T1MenuItem(title: "Add the \(m) missing", detail: "As listed here") { add(missing, mode: "missing") }) }
            if a > 0 && a != m { items.append(T1MenuItem(title: "Add all \(a)", detail: "Every copy listed here") { add(all, mode: "all") }) }
            for l in lines.prefix(4) {
                let p = byId[l.cardId]
                let label = "\(p?.setLabel ?? "?")\(l.finish == "nonfoil" ? "" : " · \(Finish(rawValue: l.finish)?.label ?? l.finish)")\(l.lang == "en" ? "" : " · \(l.lang.uppercased())")\(l.cond == "NM" ? "" : " · \(l.cond)")"
                items.append(T1MenuItem(title: "Add 1 \(label)", detail: list.boardTitle(l.board)) {
                    add([ListToCollection.Op(cardId: l.cardId, finish: l.finish, delta: 1, lang: l.lang, cond: l.cond)], mode: "one")
                })
            }
            T1Overlays.shared.showMenu("Add \(oracle.name) to your collection", items)
        } label: {
            ListRow(title: "Add to collection", detail: ListToCollection.cardDetail(missing: m, basic: !only.isDisjoint(with: basics))) {
                LabelText(busy ? "Adding…" : "Add", color: T1.text)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy || lines.isEmpty)
    }

    /// Wanting this card: shows how many are wanted already; want one more, or open your wants.
    private var wantRow: some View {
        let mine = BindersStore.shared.liveWants.filter { $0.oracleId == oracle.oracleId }
        let n = mine.reduce(0) { $0 + $1.qty }
        return Button {
            var items = [T1MenuItem(title: "Any printing") { want(nil) }]
            if let printing { items.append(T1MenuItem(title: "Only \(printing.setLabel)") { want(printing) }) }
            items.append(T1MenuItem(title: "Pick a printing…", detail: "One printing, or one finish") {
                T1Overlays.shared.present(full: true) {
                    WantPrintingPanel(oracleId: oracle.oracleId, from: "card") { report($0, nil) }.screen("want_printing")
                }
            })
            if !mine.isEmpty { items.append(T1MenuItem(title: "Open wants") { path?.wrappedValue.append(.wants) }) }
            T1Overlays.shared.showMenu("Want \(oracle.name)", items)
        } label: {
            ListRow(title: n > 0 ? "Wanted · \(n)" : "Add to wants", detail: n > 0 ? "Want one more, or open your wants" : "Trades marks it when you get one")
        }.buttonStyle(.plain)
    }

    private func want(_ p: CatalogPrinting?) {
        Task {
            do {
                try await BindersStore.shared.applyWants([WantOp(oracleId: oracle.oracleId, cardId: p?.cardId, delta: 1)], event: "want_added",
                                                         props: ["any_printing": p == nil, "finish": false, "has_max": false, "from": "card"])
                report("Wanted 1 \(p?.setLabel ?? oracle.name)", nil)
            } catch { report(error.localizedDescription, nil) }
        }
    }

    /// The card icon widget (contract/icon-widget-2026-11-06.md): this printing's art behind the Table 1 mark on the
    /// home screen. Adds it to the device's icon cards (newest first); on the list, a tap offers to take it off.
    @ViewBuilder private var iconRow: some View {
        if let printing, printing.imageFaces > 0,
           let url = CatalogPack.imageURL(cardId: printing.cardId, imageTs: printing.imageTs, size: "art_crop") {
            let card = IconCard(id: printing.cardId, name: oracle.name, set: printing.setLabel)
            Button {
                if iconOn {
                    T1Overlays.shared.showMenu("Icon widget", [T1MenuItem(title: "Remove from icon widgets", destructive: true) {
                        IconCardStore.remove(card.id)
                        iconOn = false
                        report("Removed \(oracle.name) from your icon widgets", nil)
                        Telemetry.capture("icon_card_removed", ["count": IconCardStore.load().count])
                    }])
                    return
                }
                iconBusy = true
                Task {
                    defer { iconBusy = false }
                    guard let image = await CardImageLoader.shared.image(url, maxPixel: Int(IconCardStore.maxPixel)),
                          IconCardStore.add(card, image: image) else {
                        report("Couldn't load the art. Try again when you're online.", nil)
                        return
                    }
                    iconOn = true
                    report("Added to your icon widgets. Long-press your home screen to add one.", nil)
                    Telemetry.capture("icon_card_added", ["count": IconCardStore.load().count])
                }
            } label: {
                ListRow(title: iconOn ? "On your icon widget" : "Use for the icon widget",
                        detail: iconOn ? "Tap to take it off" : "Table 1 over this art on your home screen") {
                    if iconBusy { LabelText("Saving…") } else if iconOn { LabelText("Icon", color: T1.text) }
                }
            }
            .buttonStyle(.plain)
            .disabled(iconBusy)
            .task(id: printing.cardId) { iconOn = IconCardStore.contains(printing.cardId) }
        }
    }

    /// Makes the card a hero of where it was opened from: the deck or cube, the binder, or the collection.
    @ViewBuilder private var heroRow: some View {
        if let scope = HeroScope(context) {
            let store = HeroesStore.shared
            let on = store.isHero(oracle.oracleId, scope)
            let place: String = switch scope {
            case .collection: "your collection"
            case .list(let id): ListsStore.shared.list(id: id)?.name ?? "this list"
            case .binder(let id): BindersStore.shared.binder(id)?.name ?? "this binder"
            }
            Button {
                if !store.toggle(oracle.oracleId, scope) { report("\(place.prefix(1).uppercased() + place.dropFirst()) has \(HeroesStore.limit) hero cards already.", nil) }
            } label: {
                ListRow(title: on ? "Hero of \(place)" : "Make it a hero",
                        detail: on ? "Tap to stop highlighting it" : "Highlighted in \(place) and where it's listed") {
                    if on { LabelText("Hero", color: T1.text) }
                }
            }.buttonStyle(.plain)
        }
    }
}
