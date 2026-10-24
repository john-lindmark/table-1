import SwiftUI

/* Change printing (contract/change-printing-2026-10-18.md): every card line that names a printing can point some
   or all of its copies at another printing or finish, from one screen: a deck or cube line, owned copies (from the
   collection or a binder) and a trade's gets. Wants use WantPrintingPanel, which adds "Any printing". */

/// Where a printing change applies.
enum PrintingTarget {
    /// A deck or cube line (one `list_edit` swap op, so the version history shows it).
    case listLine(listId: String, cardId: String, board: String, finish: String)
    /// Owned copies. `place` is the binder id (or `BinderRoute.unsorted`) to take them from first; nil picks the
    /// place holding the most.
    case owned(CollectionItem, place: String?)
    /// A get in a trade draft: the whole line moves; `apply` gets the new card id and finish.
    case tradeGet(TradeLine, apply: (String, String) -> Void)

    var cardId: String {
        switch self {
        case .listLine(_, let c, _, _): c
        case .owned(let it, _): it.cardId
        case .tradeGet(let l, _): l.cardId
        }
    }

    var finish: String {
        switch self {
        case .listLine(_, _, _, let f): f
        case .owned(let it, _): it.finish
        case .tradeGet(let l, _): l.finish
        }
    }

    /// The copies' condition, which prices each printing (a deck or cube line has none: near mint).
    var condition: String {
        switch self {
        case .listLine: "NM"
        case .owned(let it, _): it.condition
        case .tradeGet(let l, _): l.condition
        }
    }

    /// `printing_changed` telemetry: where the change was made.
    var telemetryWhere: String {
        switch self {
        case .listLine: "list"
        case .owned(_, let place): place == nil ? "collection" : "binder"
        case .tradeGet: "trade"
        }
    }
}

/// Owned copies changing printing: take `qty` out of one place and put as many of the other printing back in that
/// same place, keeping condition (and language, unless the new printing is in another one). One batch, so Undo puts
/// them back. nil when there's nothing to change.
enum PrintingChange {
    static func ops(_ item: CollectionItem, place: String?, toCardId: String, toFinish: String, toLang: String? = nil,
                    qty: Int) -> [CollectionOp]? {
        let lang = toLang.flatMap { $0 == "en" ? nil : $0 } ?? item.lang
        let to = CollectionStore.key(toCardId, toFinish, item.condition, lang)
        guard qty > 0, qty <= item.qty, to != item.key else { return nil }
        let binderId = place == BinderRoute.unsorted ? nil : place
        return [
            CollectionOp(cardId: item.cardId, finish: item.finish, condition: item.condition, lang: item.lang, delta: -qty, binderId: binderId),
            CollectionOp(cardId: toCardId, finish: toFinish, condition: item.condition, lang: lang, delta: qty, binderId: binderId),
        ]
    }

    /// Every place an item's copies sit, the binders by name then Unsorted, as (place, name, qty).
    @MainActor
    static func places(_ item: CollectionItem) -> [(place: String, name: String, qty: Int)] {
        let p = BindersStore.shared.placement(item)
        return p.binders.map { ($0.binder.id, $0.binder.name, $0.qty) } + (p.unsorted > 0 ? [(BinderRoute.unsorted, "Unsorted", p.unsorted)] : [])
    }
}

extension TradeLine {
    /// Points the line `id` at another printing and/or finish, merging it into a line that already holds that copy.
    static func repoint(_ lines: [TradeLine], id: String, cardId: String, finish: String) -> [TradeLine] {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return lines }
        var out = lines
        var moved = out[i]
        moved.cardId = cardId
        moved.finish = finish
        if moved.id == id { return lines }
        if let j = out.firstIndex(where: { $0.id == moved.id }) {
            out[j].qty += moved.qty
            out.remove(at: i)
        } else {
            out[i] = moved
        }
        return out
    }
}

/// The one Change printing screen: the line as it is, where from (owned copies in several places), how many, then
/// every printing of the card with a button per finish. Pushed as a route (deck/cube edit mode) or shown as a panel.
struct ChangePrintingView: View {
    let target: PrintingTarget
    /// Panels pass how to close; routes dismiss.
    var close: (() -> Void)?
    /// Owned copies: the batch and a label, for Undo on the screen underneath.
    var changed: ((String, String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var printings: [CatalogPrinting] = []
    @State private var name = ""
    @State private var count = 0
    @State private var place: String?
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let have = have
        let current = printings.first { $0.cardId == target.cardId }
        let shown = query.isEmpty ? printings : printings.filter { CardSearch.matches(query, set: $0.set, cn: $0.cn, releasedAt: $0.releasedAt) }
        let n = min(max(count, 1), max(have, 1))
        T1Screen {
            Bar(title: "Change printing", subtitle: name, back: { finish() })
            if let error { Notice(error, error: true) }
            CatalogStatusRow(catalog: catalog)
            if have == 0 {
                Notice("This line has no copies left.")
            } else {
                if printings.count > 8 { T1SearchField(text: $query, prompt: "Set, number or year") }
                HairlineList {
                    CardRow(printing: current, title: name, detail: currentDetail(current)) {
                        Text("\(have)").font(T1.mono(17)).monospacedDigit()
                    }
                    if case .owned(let it, _) = target {
                        let places = PrintingChange.places(it)
                        if places.count > 1 {
                            Section1("From")
                            ForEach(places, id: \.place) { p in
                                let on = p.place == selectedPlace
                                Button { place = p.place; count = p.qty } label: {
                                    ListRow(title: p.name, detail: "\(p.qty) here") {
                                        if on { LabelText("From here", color: T1.accent) }
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if have > 1 && splits {
                        HStack(spacing: 1) {
                            LabelText("Change \(n) of \(have)")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                            stepper("−") { count = max(1, min(count, have) - 1) }
                            stepper("+") { count = min(have, max(count, 1) + 1) }
                        }
                        .frame(height: 52).background(T1.surface)
                    }
                    if case .owned(let it, _) = target {
                        LanguageRow(lang: it.lang) { changeLanguage(n: n) }
                    }
                    Section1(query.isEmpty ? "Change to · \(printings.count)" : "Change to · \(shown.count) of \(printings.count)")
                    if shown.isEmpty && !query.isEmpty { ListRow(title: "No printings match") }
                    ForEach(shown, id: \.cardId) { row($0, n: n) }
                }
            }
        }
        .onAppear { if count == 0 { count = have } }
        .searchUsed(query, screen: "change_printing")
        .task(id: catalog.generation) {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let id = target.cardId
            let found = await Task.detached(priority: .userInitiated) { () -> (String, [CatalogPrinting]) in
                guard let p = db.printings(ids: [id])[id], let o = db.oracles(idxs: [p.oracleIdx])[p.oracleIdx] else { return ("", []) }
                return (o.name, db.printings(oracleIdx: o.idx))
            }.value
            name = found.0
            printings = found.1
            await PriceBook.shared.load(found.1.map(\.cardId))
        }
    }

    /// Owned copies: the chosen place, else the one the screen was opened from, else the one holding the most.
    private var selectedPlace: String? {
        guard case .owned(let it, let from) = target else { return nil }
        let places = PrintingChange.places(it)
        if let place, places.contains(where: { $0.place == place }) { return place }
        if let from, places.contains(where: { $0.place == from }) { return from }
        return places.max { $0.qty < $1.qty }?.place
    }

    /// A trade get moves as a whole line; everything else can move some of its copies.
    private var splits: Bool {
        if case .tradeGet = target { return false }
        return true
    }

    /// Copies the change can move: the line's count, or the copies in the chosen place.
    private var have: Int {
        switch target {
        case .listLine(let l, let c, let b, let f):
            return ListsStore.shared.list(id: l)?.entries.first { $0.cardId == c && $0.board == b && $0.finish == f }?.qty ?? 0
        case .owned(let it, _):
            let live = CollectionStore.shared.items[it.key] ?? it
            let _ = BindersStore.shared.version
            return PrintingChange.places(live).first { $0.place == selectedPlace }?.qty ?? 0
        case .tradeGet(let l, _):
            return l.qty
        }
    }

    private func currentDetail(_ p: CatalogPrinting?) -> String {
        var parts = [p?.setLabel, Finish(rawValue: target.finish)?.label ?? target.finish]
        switch target {
        case .listLine(let l, _, let b, _): parts.append(ListsStore.shared.list(id: l)?.boardTitle(b))
        case .owned(let it, _): parts += [it.condition, it.lang == "en" ? nil : it.lang.uppercased()]
        case .tradeGet(let l, _): parts.append(l.condition)
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func row(_ p: CatalogPrinting, n: Int) -> some View {
        let price = PriceBook.text(PriceBook.shared.usd(p.cardId, p.finishList.first?.rawValue ?? "nonfoil", target.condition))
        let detail = [CatalogPack.rarityName[p.rarity], p.releasedAt.isEmpty ? nil : String(p.releasedAt.prefix(4)),
                      p.original ? "Original" : nil, p.lang == "en" ? nil : p.lang.uppercased(), price].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 1) {
            HStack(spacing: 12) {
                p.art(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.setLabel).font(T1.mono(13)).lineLimit(1)
                    LabelText(detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            ForEach(p.finishList, id: \.self) { f in
                let same = p.cardId == target.cardId && f.rawValue == target.finish
                Button { pick(p, f.rawValue, n: n) } label: {
                    LabelText(same ? "Current" : f.label, color: same || busy ? T1.disabled : T1.text)
                        .padding(.horizontal, 12).frame(maxHeight: .infinity)
                        .background(T1.surfaceHover)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(same || busy)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(T1.surface)
    }

    private func pick(_ p: CatalogPrinting, _ toFinish: String, n: Int) {
        let props: [String: Any] = ["where": target.telemetryWhere, "copies": n, "finish_only": p.cardId == target.cardId]
        switch target {
        case .listLine(let l, let c, let b, let f):
            ListsStore.shared.swap(listId: l, cardId: c, board: b, finish: f, toCardId: p.cardId, toFinish: toFinish, qty: n)
            Telemetry.capture("printing_changed", props)
            finish()
        case .tradeGet(_, let apply):
            apply(p.cardId, toFinish)
            Telemetry.capture("printing_changed", props)
            finish()
        case .owned(let it, _):
            let live = CollectionStore.shared.items[it.key] ?? it
            guard let ops = PrintingChange.ops(live, place: selectedPlace, toCardId: p.cardId, toFinish: toFinish, toLang: p.lang, qty: n) else { return }
            let label = "Changed \(n) to \(p.setLabel)\(toFinish == Finish.nonfoil.rawValue ? "" : " \(Finish(rawValue: toFinish)?.label ?? toFinish)")"
            busy = true
            error = nil
            Task {
                defer { busy = false }
                do {
                    let res = try await CollectionStore.shared.apply(ops)
                    Telemetry.capture("printing_changed", props)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    changed?(res.batchId, label)
                    finish()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    /// Owned copies: the same printing and finish in another language, `n` of them from the chosen place.
    private func changeLanguage(n: Int) {
        guard case .owned(let it, _) = target else { return }
        let live = CollectionStore.shared.items[it.key] ?? it
        LanguagePicker.present(current: live.lang, subtitle: name) { lang in
            let places = PrintingChange.places(live).map { (place: $0.place, qty: $0.qty) }
            guard let ops = LanguageChange.ops(live, places: places, to: lang, qty: n, from: selectedPlace) else { return }
            busy = true
            error = nil
            Task {
                defer { busy = false }
                do {
                    let res = try await CollectionStore.shared.apply(ops)
                    Telemetry.capture("language_changed", ["where": target.telemetryWhere, "copies": n])
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    changed?(res.batchId, "Moved \(n) to \(Languages.name(lang))")
                    finish()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func finish() { if let close { close() } else { dismiss() } }

    private func stepper(_ glyph: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(T1.mono(22)).frame(width: 52).frame(maxHeight: .infinity).background(T1.surfaceHover)
        }.buttonStyle(.plain)
    }
}
