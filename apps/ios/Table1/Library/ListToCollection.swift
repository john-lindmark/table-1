import SwiftUI

/// Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the
/// printing and finish the list names, either what the collection lacks or every copy. Cases in
/// testdata/list-to-collection/cases.json.
enum ListToCollection {
    enum Mode: String, CaseIterable { case missing, all }

    struct Op: Hashable {
        let cardId: String
        let finish: String
        let delta: Int
        var lang = "en"
    }

    /// Main (and Commander) always counts, a deck's sideboard unless `sideboard` is off, Considering never. Each line
    /// keeps its language. `owned` is keyed "card_id|finish" (English copies) or "card_id|finish|lang"; Missing goes by
    /// printing + finish over every condition and language: owned copies cover lines in their own language first, then
    /// the rest, English lines first, then by language code. `only` limits it to some printings (card detail). Basic
    /// lands (`basics`) are never missing, so only Every card adds them (contract/basics-2026-10-24.md).
    static func ops(_ entries: [CardList.Entry], kind: CardList.Kind, owned: [String: Int], mode: Mode,
                    sideboard: Bool = true, only: Set<String>? = nil, basics: Set<String> = []) -> [Op] {
        var need: [String: [String: Int]] = [:] // "card|finish" → lang → copies
        for e in entries where e.board == "main" || e.board == "commander" || (e.board == "side" && kind == .deck && sideboard) {
            if let only, !only.contains(e.cardId) { continue }
            if mode == .missing && basics.contains(e.cardId) { continue }
            need["\(e.cardId)|\(e.finish)", default: [:]][e.lang, default: 0] += e.qty
        }
        var have: [String: [String: Int]] = [:]
        if mode == .missing {
            for (k, n) in owned {
                let parts = k.split(separator: "|", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { continue }
                have["\(parts[0])|\(parts[1])", default: [:]][parts.count > 2 ? parts[2] : "en", default: 0] += n
            }
        }
        var out: [Op] = []
        for (key, langs) in need {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            var left = langs
            if mode == .missing {
                let mine = have[key] ?? [:]
                var spare = mine.values.reduce(0, +)
                for (l, n) in left { let c = min(n, mine[l] ?? 0); left[l] = n - c; spare -= c }
                for l in left.keys.sorted(by: langOrder) where spare > 0 {
                    let c = min(left[l]!, spare)
                    left[l]! -= c
                    spare -= c
                }
            }
            for (l, n) in left where n > 0 { out.append(Op(cardId: parts[0], finish: parts[1], delta: n, lang: l)) }
        }
        return out.sorted { ($0.cardId, $0.finish, $0.lang) < ($1.cardId, $1.finish, $1.lang) }
    }

    /// English first, then by language code.
    private static func langOrder(_ a: String, _ b: String) -> Bool { a == "en" ? b != "en" : b == "en" ? false : a < b }

    static func copies(_ ops: [Op]) -> Int { ops.reduce(0) { $0 + $1.delta } }

    /// Card detail's Add to collection row for one card in a list: a basic land is never missing, so it doesn't claim
    /// you own every copy either (contract/basics-2026-10-24.md).
    static func cardDetail(missing: Int, basic: Bool) -> String {
        missing > 0 ? "Missing \(missing) · the printing listed here" : basic ? "Basic land · add the copies listed here" : "You own every copy listed here"
    }

    /// Collection ops in the picked condition, each copy in the language its line names (a non-English printing is
    /// always its own); the language picked for other adds never applies here.
    static func collectionOps(_ ops: [Op], printingLang: (String) -> String?, condition: String) -> [CollectionOp] {
        ops.map { o in
            let p = printingLang(o.cardId) ?? "en"
            return CollectionOp(cardId: o.cardId, finish: o.finish, condition: condition, lang: p != "en" ? p : o.lang, delta: o.delta)
        }
    }
}

/// Add to collection from a deck or cube: what's missing or every card, sideboard or not, in one undoable batch. A list
/// names no condition, so copies go in near mint (no picker; John, 2026-10-27).
struct ListToCollectionPanel: View {
    let listId: String
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var mode = ListToCollection.Mode.missing
    @State private var sideboard = true
    @State private var meta: [String: ListLine] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var done: (batchId: String, copies: Int)?

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let owned = ownedByLanguage()
        let entries = list?.entries ?? []
        let kind = list?.kind ?? .deck
        let missing = ListToCollection.ops(entries, kind: kind, owned: owned, mode: .missing, sideboard: sideboard, basics: catalog.basics)
        let all = ListToCollection.ops(entries, kind: kind, owned: owned, mode: .all, sideboard: sideboard)
        let ops = mode == .missing ? missing : all
        let copies = ListToCollection.copies(ops)
        let side = entries.filter { $0.board == "side" }.reduce(0) { $0 + $1.qty }
        T1Screen {
            Bar(title: "Add to collection", subtitle: list?.name, back: { T1Overlays.shared.dismissPanel() })
            HairlineList {
                if let error { Notice(error, error: true) }
                if let done {
                    Notice("Added \(done.copies) \(done.copies == 1 ? "card" : "cards") to your collection.")
                    Button { Task { await undo(done.batchId) } } label: {
                        ListRow(title: busy ? "Undoing…" : "Undo", detail: "Takes those copies out again")
                    }.buttonStyle(.plain).disabled(busy)
                }
                T1Segmented(options: [(ListToCollection.Mode.missing, "Missing \(ListToCollection.copies(missing))"),
                                      (ListToCollection.Mode.all, "Every card \(ListToCollection.copies(all))")], selection: $mode)
                if kind == .deck && side > 0 { T1Switch(title: "Sideboard", detail: "\(side) \(side == 1 ? "card" : "cards")", isOn: $sideboard) }
                Notice("Each card goes in near mint, as the printing, finish and language this \(kind == .deck ? "deck" : "cube") lists. Considering isn't added.")
                Section1("To add · \(copies)")
                if ops.isEmpty {
                    ListRow(title: mode == .missing ? "You own every card here" : "No cards to add",
                            detail: mode == .missing ? "Pick Every card to add another copy of each" : nil)
                }
                ForEach(ops, id: \.self) { o in
                    let line = meta[o.cardId]
                    CardRow(printing: line?.printing, title: line?.name ?? "…",
                            detail: [line?.printing?.setLabel, o.finish == "nonfoil" ? nil : Finish(rawValue: o.finish)?.label ?? o.finish,
                                     o.lang == "en" ? nil : Languages.name(o.lang)]
                                .compactMap { $0 }.joined(separator: " · "),
                            finish: o.finish) {
                        Text("+\(o.delta)").font(T1.mono(17)).monospacedDigit()
                    }
                }
            }
            Group {
                if done != nil {
                    Ghost(text: "Done") { T1Overlays.shared.dismissPanel() }
                } else {
                    Ghost(text: busy ? "Adding…" : copies == 0 ? "Nothing to add" : "Add \(copies) \(copies == 1 ? "card" : "cards")", accent: true) {
                        Task { await add(ops, list: list) }
                    }
                    .disabled(busy || copies == 0 || meta.isEmpty)
                }
            }
            .padding(.bottom, 1)
        }
        .task(id: catalog.generation) {
            catalog.load(userInitiated: true)
            guard let db = catalog.db, let list = ListsStore.shared.list(id: listId) else { return }
            let entries = list.entries, kind = list.kind
            let resolved = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: kind, db) }.value
            meta = Dictionary(resolved.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func add(_ ops: [ListToCollection.Op], list: CardList?) async {
        guard let list, !ops.isEmpty else { return }
        guard ops.count <= 5000 else { error = "That's more than 5,000 different printings at once. Add the deck in parts."; return }
        busy = true
        error = nil
        defer { busy = false }
        let printings = meta.compactMapValues(\.printing)
        do {
            let res = try await CollectionStore.shared.apply(
                ListToCollection.collectionOps(ops, printingLang: { printings[$0]?.lang }, condition: "NM"), source: "import")
            done = (res.batchId, ListToCollection.copies(ops))
            Telemetry.capture("list_added_to_collection", ["kind": list.kind.rawValue, "mode": mode.rawValue, "sideboard": sideboard,
                                                          "copies": ListToCollection.copies(ops), "lines": ops.count, "from": "list"])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func undo(_ batchId: String) async {
        busy = true
        defer { busy = false }
        do {
            try await CollectionStore.shared.undo(batchId: batchId)
            done = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
