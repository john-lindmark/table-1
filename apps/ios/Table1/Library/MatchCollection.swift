import SwiftUI

/* Card detail's Match collection (contract/owned-by-card-2026-10-31.md § 2): in a deck or cube, give a section's copies
   of the card the printings you own. Rules in OwnedByCard (autoMatch, tap, matchOps). */

enum MatchCollection {
    /// The versions you own of these printings (printing × finish, every condition and language), earliest first.
    @MainActor
    static func versions(_ printings: [CatalogPrinting]) -> [OwnedByCard.Version] {
        var n: [String: Int] = [:]
        let ids = Set(printings.map(\.cardId))
        for it in CollectionStore.shared.items.values where ids.contains(it.cardId) { n["\(it.cardId)|\(it.finish)", default: 0] += it.qty }
        return printings.flatMap { p in
            Finish.allCases.compactMap { f in n["\(p.cardId)|\(f.rawValue)"].map { OwnedByCard.Version(cardId: p.cardId, finish: f.rawValue, owned: $0) } }
        }.filter { $0.owned > 0 }
    }

    /// The card's lines in one section, in list order.
    static func lines(_ list: CardList, ids: Set<String>, board: String) -> [OwnedByCard.Need] {
        OwnedByCard.needs(list).filter { ids.contains($0.cardId) && $0.board == board }
    }

    /// Sections holding the card (not Considering) whose printings Auto would change.
    static func sections(_ list: CardList, ids: Set<String>, versions: [OwnedByCard.Version]) -> [String] {
        guard list.eventId == nil, !versions.isEmpty else { return [] }
        return ["commander", "main", "side"].filter { b in
            let ls = lines(list, ids: ids, board: b)
            return !ls.isEmpty && !OwnedByCard.matchOps(ls, OwnedByCard.autoMatch(ls, versions)).isEmpty
        }
    }

    /// "You own 3 in other printings": copies of the card in versions the list doesn't name.
    static func detail(_ list: CardList, ids: Set<String>, versions: [OwnedByCard.Version]) -> String {
        let listed = Set(list.entries.filter { ids.contains($0.cardId) }.map { "\($0.cardId)|\($0.finish)" })
        let other = versions.filter { !listed.contains("\($0.cardId)|\($0.finish)") }.reduce(0) { $0 + $1.owned }
        return other > 0 ? "You own \(other) in other printings" : "Use the printings you own"
    }

    @MainActor
    static func present(list: CardList, printings: [CatalogPrinting], report: @escaping (String, CardUndo?) -> Void) {
        let versions = versions(printings)
        let ids = Set(printings.map(\.cardId))
        let boards = sections(list, ids: ids, versions: versions)
        guard let first = boards.first else { return }
        let copies = boards.reduce(0) { n, b in n + lines(list, ids: ids, board: b).reduce(0) { $0 + $1.qty } }
        Telemetry.capture("match_collection_opened", ["kind": list.kind.rawValue, "versions": versions.count, "copies": copies])
        T1Overlays.shared.present {
            MatchCollectionPanel(listId: list.id, printings: printings, versions: versions, boards: boards, board: first, report: report)
                .screen("match_collection")
        }
    }
}

struct MatchCollectionPanel: View {
    let listId: String
    let printings: [CatalogPrinting]
    let versions: [OwnedByCard.Version]
    let boards: [String]
    @State var board: String
    let report: (String, CardUndo?) -> Void
    @State private var picks: [OwnedByCard.Pick] = []
    @State private var auto = true

    private var list: CardList? { ListsStore.shared.list(id: listId) }
    private var byId: [String: CatalogPrinting] { Dictionary(printings.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a }) }
    private var lines: [OwnedByCard.Need] { list.map { MatchCollection.lines($0, ids: Set(printings.map(\.cardId)), board: board) } ?? [] }

    var body: some View {
        let lines = lines
        let total = lines.reduce(0) { $0 + $1.qty }
        let used = picks.reduce(0) { $0 + $1.qty }
        let ops = OwnedByCard.matchOps(lines, picks)
        VStack(alignment: .leading, spacing: 10) {
            DrillHeader(title: "Match collection")
            if boards.count > 1, let list {
                T1Segmented(options: boards.map { ($0, list.boardTitle($0)) }, selection: $board)
            }
            HStack {
                LabelText("\(used) of \(total) picked · tap to pick")
                Spacer(minLength: 8)
                BarButton("Clear") { picks = []; auto = false }
                BarButton("Auto") { picks = OwnedByCard.autoMatch(lines, versions); auto = true }
            }
            GeometryReader { geo in
                let w = ((geo.size.width - 1) / 2).rounded(.down)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.fixed(w), spacing: 1), GridItem(.fixed(w), spacing: 1)], spacing: 1) {
                        ForEach(versions, id: \.self) { v in tile(v, width: w, total: total) }
                    }
                }
            }
            .frame(height: min(420, CGFloat((versions.count + 1) / 2) * 230))
            if total > used { LabelText("\(total - used) not picked stay as listed") }
            BigBarButton(text: ops.isEmpty ? "Already matches" : "Use these printings") { save(ops) }
                .disabled(ops.isEmpty)
        }
        .padding(16)
        .background(T1.bg)
        .onAppear { picks = OwnedByCard.autoMatch(lines, versions) }
        .onChange(of: board) { _, _ in picks = OwnedByCard.autoMatch(self.lines, versions); auto = true }
    }

    private func tile(_ v: OwnedByCard.Version, width: CGFloat, total: Int) -> some View {
        let n = picks.first { $0.cardId == v.cardId && $0.finish == v.finish }?.qty ?? 0
        let p = byId[v.cardId]
        return Button {
            picks = OwnedByCard.tap(picks, versions: versions, total: total, cardId: v.cardId, finish: v.finish)
            auto = false
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    if let p { p.art(width: width, finish: v.finish) } else { Rectangle().fill(T1.surface).frame(width: width, height: width / CardArt.aspect) }
                    if n > 0 {
                        Text("\(n)").font(T1.mono(15, .semibold)).monospacedDigit().foregroundStyle(T1.ink)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(T1.accent)
                            .padding(width * 0.05)
                    }
                }
                .overlay { if n > 0 { Rectangle().stroke(T1.accent, lineWidth: 1) } }
                LabelText([p?.setLabel, Finish(rawValue: v.finish).flatMap { $0 == .nonfoil ? nil : $0.label }, "Own \(v.owned)"]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p?.setLabel ?? "Printing"), own \(v.owned), \(n) picked")
    }

    private func save(_ ops: [OwnedByCard.Move]) {
        guard let list, !ops.isEmpty else { return }
        let b = board
        ListsStore.shared.swapMany(listId: list.id, board: b, moves: ops)
        let moved = ops.reduce(0) { $0 + $1.qty }
        Telemetry.capture("match_collection_saved", ["kind": list.kind.rawValue, "moved": moved, "versions": Set(ops.map { "\($0.toCardId)|\($0.toFinish)" }).count,
                                                     "auto": auto])
        let back = ops.reversed().map { OwnedByCard.Move(cardId: $0.toCardId, finish: $0.toFinish, lang: $0.lang, toCardId: $0.cardId, toFinish: $0.finish, qty: $0.qty) }
        let label = "\(moved) \(moved == 1 ? "copy" : "copies") now your printings"
        report(label, CardUndo(label: label) { await MainActor.run { ListsStore.shared.swapMany(listId: list.id, board: b, moves: back) } })
        T1Overlays.shared.dismissPanel()
    }
}
