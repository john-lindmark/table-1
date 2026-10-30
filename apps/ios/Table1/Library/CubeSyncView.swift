import Supabase
import SwiftUI

/// Sync with Cube Cobra (contract/cube-sync-2026-10-30.md): reads the cube on Cube Cobra again, shows what's in, out
/// and in a new printing or finish, and on Accept saves it as one new version.
struct CubeSyncView: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }

    /// What Cube Cobra answered, compared with the cube as it was then.
    struct Checked {
        let source: String
        let name: String
        let cards: Int
        let seq: Int?
        let result: CubeSync.Result
        let missing: [String]
        let lines: [String: ListLine]
    }

    @State private var link = ""
    @State private var asking = false
    @State private var busy = false
    @State private var error: String?
    @State private var conflict = false
    @State private var checked: Checked?
    @State private var started = false

    #if DEBUG
    /// Design QA (`-T1LibraryDemo cubesync`): a made-up Cube Cobra answer instead of the network.
    static var demo = false
    #endif

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        T1Screen {
            Bar(title: "Sync with Cube Cobra", subtitle: list?.name, back: { dismiss() })
            CatalogStatusRow(catalog: catalog)
            if let error { Notice(error, error: true) }
            HairlineList {
                if let list {
                    if asking {
                        Field(label: "Cube Cobra link", text: $link, url: true)
                        Notice("Paste the cube's link from Cube Cobra. Table 1 remembers it for next time.")
                        BigAction(text: busy ? "Reading Cube Cobra…" : "Check", enabled: !busy && catalog.db != nil
                                  && !link.trimmingCharacters(in: .whitespaces).isEmpty) {
                            Task { await check(list) }
                        }
                    } else if let checked {
                        changes(list, checked)
                    } else if started {
                        ListRow(title: "Reading Cube Cobra…", detail: CubeSync.cubeId(link).map { "cubecobra.com · \($0)" })
                    }
                } else {
                    ListRow(title: "This cube isn't here any more")
                }
            }
        }
        .task(id: catalog.generation) {
            catalog.load(userInitiated: true)
            guard !started, catalog.db != nil, let list = ListsStore.shared.list(id: listId) else { return }
            started = true
            if let url = list.sourceUrl {
                link = url
                await check(list)
            } else {
                asking = true
            }
        }
    }

    @ViewBuilder private func changes(_ list: CardList, _ c: Checked) -> some View {
        let r = c.result
        ListRow(title: r.summary, detail: "Cube Cobra · \(c.name) · \(c.cards) cards")
        if !c.missing.isEmpty {
            Notice("Not in the card data, left out: \(c.missing.prefix(12).joined(separator: ", "))\(c.missing.count > 12 ? " and \(c.missing.count - 12) more" : "")", error: true)
        }
        if conflict {
            BigAction(text: busy ? "Reading Cube Cobra…" : "Check again", enabled: !busy) { Task { await check(list) } }
        } else if !r.isEmpty {
            BigAction(text: busy ? "Saving…" : "Accept changes", enabled: !busy, busy: busy) { Task { await accept(list, c) } }
        }
        Button { dismiss() } label: { ListRow(title: r.isEmpty ? "Back to the cube" : "Keep as it is") }.buttonStyle(.plain)
        Button { asking = true; checked = nil; error = nil; conflict = false } label: {
            ListRow(title: "Change link", detail: CubeSync.cubeId(c.source).map { "cubecobra.com · \($0)" })
        }.buttonStyle(.plain)
        if !r.into.isEmpty {
            Section1("In · \(r.inCount)")
            ForEach(r.into, id: \.self) { l in lineRow(l, c, out: false) }
        }
        if !r.out.isEmpty {
            Section1("Out · \(r.outCount)")
            ForEach(r.out, id: \.self) { l in lineRow(l, c, out: true) }
        }
        if !r.changed.isEmpty {
            Section1("New printing or finish · \(r.changedCount)")
            ForEach(r.changed, id: \.self) { ch in changedRow(ch, c) }
        }
    }

    private func lineRow(_ l: CubeSync.Line, _ c: Checked, out: Bool) -> some View {
        let card = c.lines[l.cardId]
        return Button { if let o = card?.oracleId { path.append(.cardIn(o, .list(listId))) } } label: {
            CardRow(printing: card?.printing, title: card?.name ?? "…",
                    detail: [card?.printing?.setLabel, l.finish == "nonfoil" ? nil : l.finish.capitalized,
                             l.lang == "en" ? nil : l.lang.uppercased(), l.board == "maybe" ? "Considering" : nil]
                        .compactMap { $0 }.joined(separator: " · ")) {
                Text(out ? "−\(l.qty)" : "+\(l.qty)").font(T1.mono(17)).monospacedDigit().foregroundStyle(out ? T1.error : T1.text)
            }
        }.buttonStyle(.plain)
    }

    private func changedRow(_ ch: CubeSync.Changed, _ c: Checked) -> some View {
        let from = c.lines[ch.fromCard], to = c.lines[ch.toCard]
        let finish = ch.fromFinish == "nonfoil" && ch.toFinish == "nonfoil" ? nil
            : "\(ch.fromFinish == ch.toFinish ? "" : "\(ch.fromFinish.capitalized) → ")\(ch.toFinish.capitalized)"
        let sets = ch.fromCard == ch.toCard ? to?.printing?.setLabel
            : "\(from?.printing?.setLabel ?? "?") → \(to?.printing?.setLabel ?? "?")"
        return Button { if let o = to?.oracleId { path.append(.cardIn(o, .list(listId))) } } label: {
            CardRow(printing: to?.printing, title: to?.name ?? "…",
                    detail: [sets, finish, ch.toLang == "en" ? nil : ch.toLang.uppercased(), ch.board == "maybe" ? "Considering" : nil]
                        .compactMap { $0 }.joined(separator: " · ")) {
                Text("\(ch.qty)").font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }

    private func check(_ list: CardList) async {
        guard let db = catalog.db else { return }
        var url = link.trimmingCharacters(in: .whitespaces)
        if !url.lowercased().hasPrefix("http") { url = "https://" + url }
        guard CubeSync.cubeId(url) != nil else { error = "That isn't a Cube Cobra cube link."; return }
        busy = true
        error = nil
        conflict = false
        defer { busy = false }
        let seq = ListsStore.shared.list(id: listId)?.seq ?? list.seq
        let current = ListsStore.shared.list(id: listId)?.entries ?? list.entries
        let r: ImportedList
        do {
            r = try await read(url, current: current, db)
        } catch FunctionsError.httpError(_, let data) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            error = (try? decoder.decode(ImportedList.self, from: data))?.error ?? "Cube Cobra couldn't be read."
            asking = true
            Telemetry.capture("cube_sync_failed", ["reason": "read"])
            return
        } catch {
            self.error = error.localizedDescription
            asking = true
            Telemetry.capture("cube_sync_failed", ["reason": "read"])
            return
        }
        guard let lines = r.entries else { error = r.error ?? "Cube Cobra sent no cards."; asking = true; return }
        let known = list.sourceUrl != nil
        let out = await Task.detached(priority: .userInitiated) { () -> Checked in
            let resolved = ListImportView.resolve(lines, kind: .cube, db)
            let ids = Array(Set(current.map(\.cardId) + resolved.entries.map(\.cardId)))
            let printings = db.printings(ids: ids).mapValues { CubeSync.Printing(oracle: "\($0.oracleIdx)", lang: $0.lang) }
            let result = CubeSync.diff(current: current, incoming: resolved.entries, printings: printings)
            let shown = ListLine.resolve(ids.map { CardList.Entry(cardId: $0, board: "main", qty: 1) }, kind: .cube, db)
            return Checked(source: r.sourceUrl ?? url, name: r.name ?? "", cards: lines.filter { $0.board == "main" }.reduce(0) { $0 + $1.qty },
                           seq: seq, result: result, missing: resolved.missing,
                           lines: Dictionary(shown.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a }))
        }.value
        checked = out
        asking = false
        let res = out.result
        Telemetry.capture("cube_sync_checked", ["in": res.inCount, "out": res.outCount, "changed": res.changedCount, "same": res.same,
                                                "missing": out.missing.count, "known_link": known])
    }

    private func read(_ url: String, current: [CardList.Entry], _ db: CatalogDB) async throws -> ImportedList {
        #if DEBUG
        if Self.demo { return Self.demoAnswer(current, db) }
        #endif
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await supabase.functions.invoke("list-import", options: FunctionInvokeOptions(body: ["url": url])) { data, _ in
            try decoder.decode(ImportedList.self, from: data)
        }
    }

    private func accept(_ list: CardList, _ c: Checked) async {
        busy = true
        defer { busy = false }
        do {
            try await ListsStore.shared.sync(listId: listId, seq: c.seq, entries: c.result.entries, sourceUrl: c.source)
            Telemetry.capture("cube_sync_accepted", ["in": c.result.inCount, "out": c.result.outCount, "changed": c.result.changedCount])
            dismiss()
        } catch CubeSyncError.unsaved {
            error = "This cube isn't saved to your account yet. Try again once it is."
            Telemetry.capture("cube_sync_failed", ["reason": "save"])
        } catch let e as PostgrestError where e.code == "PT409" {
            error = "This cube changed since you checked. Check again."
            conflict = true
            Telemetry.capture("cube_sync_failed", ["reason": "conflict"])
            await ListsStore.shared.sync()
        } catch {
            self.error = error.localizedDescription
            Telemetry.capture("cube_sync_failed", ["reason": "save"])
        }
    }

    #if DEBUG
    /// The cube with its third Main card foil, the fourth in another printing, the first two gone, and two cards from a
    /// deck added.
    static func demoAnswer(_ current: [CardList.Entry], _ db: CatalogDB) -> ImportedList {
        var main = current.filter { $0.board == "main" }
        let rest = current.filter { $0.board != "main" }
        var lines: [ImportedList.Line] = []
        let line = { (e: CardList.Entry, card: String, finish: String) in
            ImportedList.Line(qty: e.qty, board: e.board, name: "Demo card", scryfallId: card, finish: finish == "nonfoil" ? nil : finish)
        }
        if main.count > 4 {
            let third = main[2], fourth = main[3]
            lines.append(line(third, third.cardId, "foil"))
            let other = db.printings(ids: [fourth.cardId])[fourth.cardId].flatMap { p in
                db.printings(oracleIdx: p.oracleIdx).first { $0.cardId != fourth.cardId }
            }
            lines.append(line(fourth, other?.cardId ?? fourth.cardId, fourth.finish))
            main.removeFirst(4)
        }
        lines += (main + rest).map { line($0, $0.cardId, $0.finish) }
        let have = Set(current.map(\.cardId))
        for e in (ListsStore.shared.lists(.deck).first?.entries ?? []).filter({ $0.board == "main" && !have.contains($0.cardId) }).prefix(2) {
            lines.append(ImportedList.Line(qty: 1, board: "main", name: "Demo card", scryfallId: e.cardId))
        }
        return ImportedList(kind: "cube", name: "Demo cube", format: "vintage", sourceUrl: "https://cubecobra.com/cube/list/demo", entries: lines)
    }
    #endif
}

enum CubeSyncError: Error { case unsaved }
