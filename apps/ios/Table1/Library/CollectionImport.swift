import SwiftUI
import Supabase
import UniformTypeIdentifiers

/* Library → Import and export (contract/collection-import-2026-10-17.md). Pick another app's CSV export, see what
   matched, fix or skip what didn't, then add it to the collection (or replace the collection with it) as
   collection_apply batches of up to 5000 ops, each with its own idempotency key, with one Undo for the lot.
   Export writes the collection in Moxfield's or ManaBox's layout. */

/// Scryfall's set names (mtg_sets, readable signed out), for files that name the set instead of its code.
/// Kept on the device so an import works offline once the list has been read.
@MainActor
final class SetNames {
    static let shared = SetNames()
    private struct Row: Codable { let code: String; let name: String }
    private var rows: [Row] = []
    private var fetched = false
    private let cacheKey = "library.setNames"

    func load() async -> [(code: String, name: String)] {
        if rows.isEmpty, let data = UserDefaults.standard.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode([Row].self, from: data) {
            rows = saved
        }
        if !fetched {
            do {
                var all: [Row] = []
                for start in stride(from: 0, to: 10_000, by: 1000) {
                    let page: [Row] = try await supabase.from("mtg_sets").select("code,name").order("code")
                        .range(from: start, to: start + 999).execute().value
                    all += page
                    if page.count < 1000 { break }
                }
                rows = all
                fetched = true
                UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: cacheKey)
            } catch {
                // Offline: the saved list (or none: set codes and names of cards still match).
            }
        }
        return rows.map { ($0.code, $0.name) }
    }

    func name(_ code: String) -> String? { rows.first { $0.code == code }?.name }
}

@MainActor
@Observable
final class CollectionImportModel {
    enum Phase: Equatable { case start, reading, preview, writing, done }
    var phase: Phase = .start
    var error: String?
    var fileName = ""
    var format: CSVFormat = .other
    var lines = 0
    private(set) var matched: [ResolvedLine] = []
    private(set) var unmatched: [ImportRow] = []
    private(set) var items: [ImportItem] = []
    /// Copies going into binders (by name), and ManaBox wishlist lines (contract/binders-wants-2026-10-17.md).
    private(set) var placements: [ImportPlacement] = []
    private(set) var wantLines: [(cardId: String, finish: String, qty: Int)] = []
    var fixed = 0
    var skipped = 0
    var mode = "add"
    /// USD over the priced items, and how many items have a price.
    private(set) var value: (usd: Double, priced: Int)?
    /// Each chunk keeps its key until the import is done, so Try again resends the same batches.
    private var parts: [(key: String, ops: [CollectionOp], batchId: String?)] = []
    /// Replace mode: binder moves after the quantities are set (copies out to Unsorted, then into binders).
    private var moveParts: [(key: String, moves: [BinderMove], batchId: String?)]?
    private var wantsDone = false
    private(set) var batchIds: [String] = []
    private(set) var undone = false
    private(set) var exportNote: String?
    @ObservationIgnored private var resolver: ImportResolver?

    var copies: Int { items.reduce(0) { $0 + $1.qty } }
    var binderCopies: Int { placements.reduce(0) { $0 + $1.qty } }
    var binderNames: [String] {
        var seen = Set<String>()
        return placements.map(\.binder).filter { seen.insert($0.lowercased()).inserted }
    }
    /// Binders the import makes (names you don't have yet).
    var newBinders: [String] {
        let have = Set(BindersStore.shared.binders.map { $0.name.lowercased() })
        return binderNames.filter { !have.contains($0.lowercased()) }
    }
    var wantCopies: Int { wantLines.reduce(0) { $0 + $1.qty } }
    var partsDone: Int { parts.filter { $0.batchId != nil }.count }
    var retrying: Bool { (partsDone > 0 && partsDone < parts.count) || (partsDone > 0 && partsDone == parts.count && error != nil) }

    /// Copies held now that a replace would remove (items the file doesn't have).
    var removedByReplace: Int {
        let keep = Set(items.map(\.key))
        return CollectionStore.shared.items.values.filter { !keep.contains($0.key) }.reduce(0) { $0 + $1.qty }
    }

    func reset() {
        phase = .start
        error = nil
        matched = []
        unmatched = []
        items = []
        placements = []
        wantLines = []
        fixed = 0
        skipped = 0
        value = nil
        parts = []
        moveParts = nil
        wantsDone = false
        batchIds = []
        undone = false
        resolver = nil
    }

    func read(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            await read(data: data, name: url.lastPathComponent)
        } catch {
            self.error = "That file couldn't be opened."
        }
    }

    func read(data: Data, name: String) async {
        guard let db = CatalogStore.shared.db else { error = "Card data is still loading."; return }
        reset()
        phase = .reading
        fileName = name
        // UTF-8 nearly always; Windows exports (Excel) can be Latin-1.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        let sets = await SetNames.shared.load()
        do {
            let out = try await Task.detached(priority: .userInitiated) { () throws -> (ParsedImport, [ResolvedLine], [ImportRow], ImportResolver) in
                let parsed = try CollectionCSV.parse(text)
                let resolver = ImportResolver(db: db, setNames: sets)
                let r = resolver.resolve(parsed.rows)
                return (parsed, r.matched, r.unmatched, resolver)
            }.value
            format = out.0.format
            lines = out.0.rows.count
            matched = out.1
            unmatched = out.2
            resolver = out.3
            refresh()
            phase = .preview
            Telemetry.capture("collection_import_previewed", ["format": format.rawValue, "lines": lines,
                                                              "matched": matched.count, "unmatched": unmatched.count])
            await priceItems()
        } catch {
            phase = .start
            self.error = error.localizedDescription
        }
    }

    func fix(_ row: ImportRow, oracleIdx: Int) {
        guard let line = resolver?.resolve(row, oracleIdx: oracleIdx) else { return }
        unmatched.removeAll { $0 == row }
        matched.append(line)
        fixed += 1
        refresh()
        Task { await priceItems() }
    }

    func skip(_ row: ImportRow) {
        unmatched.removeAll { $0 == row }
        skipped += 1
    }

    func skipAll() {
        skipped += unmatched.count
        unmatched = []
    }

    private func refresh() {
        items = ImportResolver.items(matched)
        placements = ImportResolver.placements(matched)
        wantLines = ImportResolver.wants(matched)
        parts = []
        moveParts = nil
        wantsDone = false
    }

    /// Your binder for each name the file uses: matched case-insensitively, else made (for trade when the name says
    /// "trade"). Lower-cased name → binder id.
    private func ensureBinders() async throws -> [String: String] {
        let store = BindersStore.shared
        var out: [String: String] = [:]
        for name in binderNames {
            if let b = store.binders.first(where: { $0.name.lowercased() == name.lowercased() }) {
                out[name.lowercased()] = b.id
            } else {
                let b = try await store.save(name: name, forTrade: name.lowercased().contains("trade"))
                out[name.lowercased()] = b.id
            }
        }
        return out
    }

    /// Replace mode, once the quantities are set: each item in the file ends with the file's binders, copies out to
    /// Unsorted first, then into binders.
    private func plannedMoves(_ ids: [String: String]) -> [(key: String, moves: [BinderMove], batchId: String?)] {
        let store = BindersStore.shared
        var target: [String: [String: Int]] = [:]
        for p in placements { if let id = ids[p.binder.lowercased()] { target[p.itemKey, default: [:]][id, default: 0] += p.qty } }
        var out: [BinderMove] = [], into: [BinderMove] = []
        for it in items {
            let item = CollectionItem(cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: it.qty, seq: 0)
            let want = target[it.key] ?? [:]
            let cur = Dictionary(store.placement(item).binders.map { ($0.binder.id, $0.qty) }, uniquingKeysWith: +)
            for (b, n) in cur where n > (want[b] ?? 0) { out.append(BinderMove(item: item, from: b, to: nil, qty: n - (want[b] ?? 0))) }
            for (b, n) in want where n > (cur[b] ?? 0) { into.append(BinderMove(item: item, from: nil, to: b, qty: n - (cur[b] ?? 0))) }
        }
        func chunks(_ ms: [BinderMove]) -> [(key: String, moves: [BinderMove], batchId: String?)] {
            stride(from: 0, to: ms.count, by: 2500).map { (UUID().uuidString.lowercased(), Array(ms[$0..<min($0 + 2500, ms.count)]), nil) }
        }
        return chunks(out) + chunks(into)
    }

    private func priceItems() async {
        let prices = PriceBook.shared
        await prices.load(items.map(\.cardId))
        var usd = 0.0, priced = 0
        for it in items {
            if let p = prices.usd(it.cardId, it.finish, it.condition) { usd += p * Double(it.qty); priced += 1 }
        }
        value = (usd, priced)
    }

    /// Writes the import: every chunk that hasn't landed yet, in order.
    func write() async {
        let col = CollectionStore.shared
        phase = .writing
        error = nil
        let binderIds: [String: String]
        do {
            binderIds = try await ensureBinders()
        } catch {
            phase = .preview
            self.error = error.localizedDescription
            return
        }
        if parts.isEmpty {
            var ops: [CollectionOp]
            if mode == "replace" {
                await col.sync()
                ops = items.map { CollectionOp(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, qty: $0.qty) }
                let keep = Set(items.map(\.key))
                ops += col.items.values.filter { !keep.contains($0.key) }.map {
                    CollectionOp(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, qty: 0)
                }
            } else {
                // Add: each item's copies go straight into their binders; the rest are Unsorted.
                let placed = Dictionary(grouping: placements, by: \.itemKey)
                ops = items.flatMap { it -> [CollectionOp] in
                    var left = it.qty
                    var out: [CollectionOp] = []
                    for p in placed[it.key] ?? [] {
                        guard let id = binderIds[p.binder.lowercased()], left > 0 else { continue }
                        let n = min(p.qty, left)
                        out.append(CollectionOp(cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: n, binderId: id))
                        left -= n
                    }
                    if left > 0 { out.append(CollectionOp(cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: left)) }
                    return out
                }
            }
            parts = stride(from: 0, to: ops.count, by: 5000).map {
                (UUID().uuidString.lowercased(), Array(ops[$0..<min($0 + 5000, ops.count)]), nil)
            }
        }
        for i in parts.indices where parts[i].batchId == nil {
            do {
                let res = try await col.apply(parts[i].ops, source: "import", key: parts[i].key)
                parts[i].batchId = res.batchId
            } catch {
                phase = .preview
                let done = partsDone
                self.error = done > 0
                    ? "Imported \(done) of \(parts.count) parts, then: \(error.localizedDescription) Try again to send the rest."
                    : error.localizedDescription
                return
            }
        }
        if mode == "replace" && !placements.isEmpty {
            if moveParts == nil {
                await BindersStore.shared.sync()
                moveParts = plannedMoves(binderIds)
            }
            for i in moveParts!.indices where moveParts![i].batchId == nil {
                do {
                    moveParts![i].batchId = try await BindersStore.shared.move(moveParts![i].moves)
                } catch {
                    phase = .preview
                    self.error = "The cards are in; sorting them into binders stopped: \(error.localizedDescription) Try again to finish."
                    return
                }
            }
        }
        if !wantLines.isEmpty && !wantsDone {
            guard let db = CatalogStore.shared.db else { return }
            let p = db.printings(ids: wantLines.map(\.cardId))
            let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
            let ops = wantLines.compactMap { w in
                p[w.cardId].flatMap { o[$0.oracleIdx] }.map { WantOp(oracleId: $0.oracleId, cardId: w.cardId, finish: w.finish, delta: w.qty) }
            }
            do {
                try await BindersStore.shared.applyWants(ops)
                wantsDone = true
            } catch {
                phase = .preview
                self.error = "The cards are in; the wants stopped: \(error.localizedDescription) Try again to finish."
                return
            }
        }
        batchIds = parts.compactMap(\.batchId) + (moveParts ?? []).compactMap(\.batchId)
        Telemetry.capture("collection_imported", ["format": format.rawValue, "mode": mode, "cards": copies, "items": items.count,
                                                  "parts": parts.count, "fixed": fixed, "skipped": skipped,
                                                  "binders": binderNames.count, "binder_copies": binderCopies, "wants": wantCopies])
        phase = .done
    }

    /// Undoes every batch of the import, newest first.
    func undo() async {
        let col = CollectionStore.shared
        error = nil
        while let id = batchIds.last {
            do {
                try await col.undo(batchId: id)
                batchIds.removeLast()
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        undone = true
    }

    /// The collection as a CSV file in a temporary folder, or nil without card data.
    func export(_ layout: CollectionCSV.Layout) async -> URL? {
        guard let db = CatalogStore.shared.db else { return nil }
        let held = Array(CollectionStore.shared.items.values)
        let binders = BindersStore.shared
        // Item × binder: each binder's copies, then the Unsorted rest.
        let split: [(item: CollectionItem, binder: String?, forTrade: Bool, qty: Int)] = held.flatMap { it in
            let p = binders.placement(it)
            return p.binders.map { (it, Optional($0.binder.name), $0.binder.forTrade, min($0.qty, it.qty)) } + (p.unsorted > 0 ? [(it, nil, false, p.unsorted)] : [])
        }
        let wants = binders.liveWants
        let sets = Dictionary(await SetNames.shared.load().map { ($0.code, $0.name) }, uniquingKeysWith: { a, _ in a })
        let (text, cards, left) = await Task.detached(priority: .userInitiated) { () -> (String, Int, Int) in
            let printings = db.printings(ids: Array(Set(held.map(\.cardId)).union(wants.compactMap(\.cardId))))
            let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
            var rows: [CollectionCSV.ExportCard] = []
            var left = 0
            for s in split {
                let it = s.item
                guard let p = printings[it.cardId], let o = oracles[p.oracleIdx] else { left += s.qty; continue }
                rows.append(.init(name: o.name, set: p.set, setName: sets[p.set] ?? p.set.uppercased(), cn: p.cn, rarity: p.rarity,
                                  cardId: p.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: s.qty,
                                  binder: s.binder, forTrade: s.forTrade))
            }
            // Wants: a want for any printing goes out as the card's original printing.
            for w in wants {
                guard let o = db.oracle(id: w.oracleId),
                      let p = w.cardId.flatMap({ printings[$0] }) ?? db.covers(oracleIdxs: [o.idx])[o.idx] else { continue }
                rows.append(.init(name: o.name, set: p.set, setName: sets[p.set] ?? p.set.uppercased(), cn: p.cn, rarity: p.rarity,
                                  cardId: p.cardId, finish: w.finish ?? "nonfoil", condition: "NM", lang: "en", qty: w.qty, wanted: true))
            }
            return (CollectionCSV.export(rows, layout: layout), rows.filter { !$0.wanted }.reduce(0) { $0 + $1.qty }, left)
        }.value
        let today = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        let day = String(format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0)
        let url = FileManager.default.temporaryDirectory.appending(path: "table1-collection-\(layout.rawValue)-\(day).csv")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
        exportNote = left > 0 ? "\(left) card\(left == 1 ? "" : "s") newer than the card data \(left == 1 ? "was" : "were") left out." : nil
        Telemetry.capture("collection_exported", ["layout": layout.rawValue, "cards": cards])
        return url
    }
}

/// What the share sheet hands over: a file URL (Save to Files, AirDrop, Mail …) or text (Copy, Messages, Notes …).
struct ShareFile: Identifiable {
    let id = UUID()
    let item: Any
    init(url: URL) { item = url }
    init(text: String) { item = text }
}

/// The system share sheet for one file or text.
struct ShareSheet: UIViewControllerRepresentable {
    let share: ShareFile
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [share.item], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct CollectionImportView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var model = CollectionImportModel()
    @State private var picking = false
    @State private var confirmReplace = false
    @State private var share: ShareFile?
    @State private var exporting: CollectionCSV.Layout?
    @State private var undoing = false
    private var catalog: CatalogStore { CatalogStore.shared }
    private var col: CollectionStore { CollectionStore.shared }

    var body: some View {
        T1Screen {
            Bar(title: "Import and export", subtitle: subtitle, back: { dismiss() })
            CatalogStatusRow(catalog: catalog)
            if let error = model.error { Notice(error, error: true) }
            HairlineList {
                switch model.phase {
                case .start, .reading: start
                case .preview, .writing: preview
                case .done: done
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text]) { result in
            if case .success(let url) = result { Task { await model.read(url: url) } }
        }
        .alert("Replace your collection?", isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { Task { await model.write() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your collection becomes exactly this file. \(model.removedByReplace.formatted()) cards that aren't in it are removed. Undo puts them back.")
        }
        .sheet(item: $share) { ShareSheet(share: $0).ignoresSafeArea() }
        .onAppear { catalog.load(userInitiated: true) }
        #if DEBUG
        .task(id: catalog.generation) {
            // Design QA and the end-to-end check: `-T1ImportFile <path>` reads that file as if it had been picked.
            let args = ProcessInfo.processInfo.arguments
            guard model.phase == .start, catalog.db != nil, let i = args.firstIndex(of: "-T1ImportFile"), i + 1 < args.count else { return }
            await model.read(url: URL(fileURLWithPath: args[i + 1]))
            // `-T1ImportAuto import|undo`: after 4 s on the preview, skip what didn't match and import (then, for
            // `undo`, undo it 4 s later), so the whole flow runs without taps.
            guard let a = args.firstIndex(of: "-T1ImportAuto"), a + 1 < args.count, model.phase == .preview else { return }
            try? await Task.sleep(for: .seconds(4))
            model.skipAll()
            await model.write()
            if args[a + 1] == "undo" {
                try? await Task.sleep(for: .seconds(4))
                await model.undo()
            }
        }
        #endif
    }

    private var subtitle: String? {
        switch model.phase {
        case .start: col.summary.map { "\($0.totalQty.formatted()) cards in collection" }
        case .reading: "Reading…"
        case .preview, .writing: model.format.label
        case .done: model.undone ? "Import undone" : "Imported"
        }
    }

    // MARK: start

    @ViewBuilder private var start: some View {
        Section1("Import")
        BigAction(text: "Choose a file", enabled: catalog.db != nil, busy: model.phase == .reading) { picking = true }
        Notice("Export the collection as CSV from ManaBox, Moxfield, Archidekt, Deckbox, Dragon Shield, TCGplayer or Delver Lens, then choose the file here. A card name and its set are enough; collector number, foil, condition and language are read when the file has them.")
        Section1("Export")
        ForEach(CollectionCSV.Layout.allCases, id: \.self) { layout in
            Button { export(layout) } label: {
                ListRow(title: "For \(layout.label)", detail: exporting == layout ? "Writing…" : "CSV in \(layout.label)'s layout")
            }
            .buttonStyle(.plain)
            .disabled(exporting != nil || catalog.db == nil || col.items.isEmpty)
        }
        if let note = model.exportNote { Notice(note) }
    }

    private func export(_ layout: CollectionCSV.Layout) {
        exporting = layout
        Task {
            defer { exporting = nil }
            if let url = await model.export(layout) { share = ShareFile(url: url) }
        }
    }

    // MARK: preview

    @ViewBuilder private var preview: some View {
        let copies = model.copies
        ListRow(title: model.fileName, detail: "\(model.format.label) · \(model.lines.formatted()) lines")
        HStack(spacing: 16) {
            Stat(label: "Matched", value: "\(copies.formatted()) cards", accent: true)
            Stat(label: "Printings", value: model.items.count.formatted())
            Stat(label: "Value", value: valueText, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
        if model.binderCopies > 0 || model.wantCopies > 0 {
            let names = model.binderNames
            let fresh = model.newBinders.count
            Notice([model.binderCopies > 0 ? "\(model.binderCopies.formatted()) cards go into \(names.count) binder\(names.count == 1 ? "" : "s") (\(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? "…" : ""))\(fresh > 0 ? ", \(fresh) new" : "")." : nil,
                    model.wantCopies > 0 ? "\(model.wantCopies.formatted()) cards from wishlists go into your wants, not your collection." : nil]
                .compactMap { $0 }.joined(separator: " "))
        }
        if !model.unmatched.isEmpty {
            HStack {
                LabelText("Not matched · \(model.unmatched.count)")
                Spacer(minLength: 0)
                BarButton("Skip all") { model.skipAll() }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(T1.surface)
            ForEach(model.unmatched, id: \.self) { unmatchedRow($0) }
        }
        T1Segmented(options: [("add", "Add to collection"), ("replace", "Replace collection")], selection: $model.mode)
        if model.mode == "replace" {
            Notice("Your collection becomes exactly this file: \(model.removedByReplace.formatted()) cards that aren't in it are removed. Undo puts them back.")
        }
        if !model.unmatched.isEmpty {
            Notice("Lines left unmatched aren't imported. Fix them or skip them first.")
        }
        BigAction(text: model.retrying ? "Try again" : model.mode == "replace" ? "Replace with \(copies.formatted()) cards" : "Import \(copies.formatted()) cards",
                  enabled: model.unmatched.isEmpty && (copies > 0 || model.mode == "replace" || model.wantCopies > 0),
                  busy: model.phase == .writing) {
            if model.mode == "replace" && !model.retrying { confirmReplace = true } else { Task { await model.write() } }
        }
        Section1("Matched · \(model.matched.count.formatted()) lines")
        ForEach(model.matched.prefix(80), id: \.self) { l in
            CardRow(printing: l.printing, title: l.row.name.isEmpty ? l.printing.setLabel : l.row.name, detail: detail(l)) {
                Text("\(l.row.qty)").font(T1.mono(17)).monospacedDigit()
            }
        }
        if model.matched.count > 80 { Notice("And \((model.matched.count - 80).formatted()) more lines.") }
        Button { model.reset() } label: { ListRow(title: "Choose another file") }.buttonStyle(.plain)
            .disabled(model.phase == .writing)
    }

    private var valueText: String {
        guard let v = model.value else { return "…" }
        if v.priced == 0 { return "—" }
        return v.usd.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    private func detail(_ l: ResolvedLine) -> String {
        [l.printing.setLabel, l.finish == "nonfoil" ? nil : Finish(rawValue: l.finish)?.label, l.row.condition,
         l.row.lang == "en" ? nil : l.row.lang.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }

    private func unmatchedRow(_ r: ImportRow) -> some View {
        HStack(spacing: 1) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name.isEmpty ? "No name" : r.name).font(T1.mono(14)).lineLimit(1)
                LabelText([r.problem, "Line \(r.line)", r.setLabel.isEmpty ? nil : r.setLabel, "\(r.qty) cop\(r.qty == 1 ? "y" : "ies")"]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            rowButton("Fix") { fix(r) }
            rowButton("Skip") { model.skip(r) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(T1.surface)
    }

    private func rowButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabelText(text, color: T1.text).padding(.horizontal, 14).frame(maxHeight: .infinity)
                .background(T1.surfaceHover).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fix(_ r: ImportRow) {
        let model = model
        T1Overlays.shared.present(full: true) {
            ImportFixPanel(row: r) { o in
                T1Overlays.shared.dismissPanel()
                model.fix(r, oracleIdx: o.idx)
            }
            .screen("collection_import_fix")
        }
    }

    // MARK: done

    @ViewBuilder private var done: some View {
        let copies = model.copies
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.undone ? "Import undone" : "\(model.mode == "replace" ? "Replaced with" : "Imported") \(copies.formatted()) cards")
                    .font(T1.mono(14))
                LabelText("\(model.items.count.formatted()) printings · \(model.format.label)")
            }
            Spacer(minLength: 0)
            if !model.undone {
                BarButton(undoing ? "Undoing…" : "Undo") {
                    guard !undoing else { return }
                    undoing = true
                    Task { await model.undo(); undoing = false }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
        Button { path.append(.allCards) } label: {
            ListRow(title: "All cards", detail: col.summary.map { "\($0.totalQty.formatted()) cards in collection" })
        }.buttonStyle(.plain)
        Button { model.reset() } label: { ListRow(title: "Import another file") }.buttonStyle(.plain)
    }
}

/// Fix one unmatched line: search the catalog with the line's name filled in, pick the card.
private struct ImportFixPanel: View {
    let row: ImportRow
    let onPick: (CatalogOracle) -> Void
    @State private var query: String
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @FocusState private var focused: Bool

    init(row: ImportRow, onPick: @escaping (CatalogOracle) -> Void) {
        self.row = row
        self.onPick = onPick
        _query = State(initialValue: row.name)
    }

    var body: some View {
        T1Screen {
            Bar(title: "Line \(row.line)", subtitle: [row.name, row.setLabel].filter { !$0.isEmpty }.joined(separator: " · "),
                back: { T1Overlays.shared.dismissPanel() })
            T1SearchField(text: $query, prompt: "Card name").focused($focused)
            HairlineList {
                if CardName.norm(query).count >= 2 && hits.isEmpty { Notice("No card by that name") }
                ForEach(hits, id: \.idx) { o in
                    Button { onPick(o) } label: {
                        CardRow(printing: covers[o.idx], title: o.name, detail: o.typeLine) {
                            LabelText("Pick", color: T1.text)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            guard let db = CatalogStore.shared.db else { return }
            let q = query
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { () -> ([CatalogOracle], [Int: CatalogPrinting]) in
                // A name with set or version noise ("Bolt (Borderless)") still finds the card by its first words.
                var hits = db.search(q)
                if hits.isEmpty, let cut = q.firstIndex(where: { "([".contains($0) }) { hits = db.search(String(q[..<cut])) }
                return (hits, db.covers(oracleIdxs: hits.map(\.idx)))
            }.value
            if !Task.isCancelled { hits = found.0; covers = found.1 }
        }
    }
}
