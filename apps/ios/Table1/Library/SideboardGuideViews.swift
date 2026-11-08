import SwiftUI
import WebKit

// Sideboard guide screens (contract/sideboard-guide-2026-11-04.md § Screens): the guide, a matchup, the In and Out
// pickers, the sideboard and Considering, new matchup, and the print preview. Same as web SideboardGuide.tsx and
// Android SideboardGuideScreens.kt.

/// The deck's cards, read once per change of the list or the catalog.
private struct GuideCards: ViewModifier {
    let listId: String
    @Binding var rows: [ListLine]
    func body(content: Content) -> some View {
        let list = ListsStore.shared.list(id: listId)
        content.task(id: "\(CatalogStore.shared.generation)-\(list?.entries.hashValue ?? 0)") {
            CatalogStore.shared.load(userInitiated: true)
            guard let db = CatalogStore.shared.db, let list else { return }
            let entries = list.entries, kind = list.kind
            rows = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: kind, db) }.value
        }
    }
}

private extension View {
    func guideCards(_ listId: String, _ rows: Binding<[ListLine]>) -> some View { modifier(GuideCards(listId: listId, rows: rows)) }
}

private func ruleLines(_ rows: [ListLine]) -> [SideboardRules.Line] {
    rows.compactMap { l in l.oracleId.map { SideboardRules.Line(oracle: $0, name: l.name, board: l.board, qty: l.qty) } }
}

/// One card per oracle with the art of its first line.
private struct GuideCard: Identifiable {
    let id: String
    let name: String
    let printing: CatalogPrinting?
    var copies: SideboardRules.Copies
}

private func cardsByOracle(_ rows: [ListLine]) -> [GuideCard] {
    let pool = SideboardRules.pool(ruleLines(rows))
    var seen = Set<String>(), out: [GuideCard] = []
    for l in rows.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
        guard let o = l.oracleId, !seen.contains(o), let c = pool[o] else { continue }
        seen.insert(o)
        out.append(GuideCard(id: o, name: l.name, printing: l.printing, copies: c))
    }
    return out
}

@MainActor private func editGuide(_ listId: String, _ change: (inout SideboardGuide) -> Void) {
    guard let list = ListsStore.shared.list(id: listId) else { return }
    var g = list.guide ?? SideboardGuide()
    change(&g)
    ListsStore.shared.setGuide(listId: listId, g)
}

@MainActor private func editMatchup(_ listId: String, _ id: String, _ change: (inout SideboardGuide.Matchup) -> Void) {
    editGuide(listId) { g in
        if let i = g.matchups.firstIndex(where: { $0.id == id }) { change(&g.matchups[i]) }
    }
}

// MARK: deck screen row

struct SideboardGuideRow: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    var body: some View {
        if let list = ListsStore.shared.list(id: listId) {
            let n = list.guide?.matchups.count ?? 0
            let side = list.count("side")
            Button { path.append(.sideboardGuide(listId)) } label: {
                ListRow(title: "Sideboard guide", detail: "\(n) \(n == 1 ? "matchup" : "matchups") · sideboard \(side)")
            }.buttonStyle(.plain)
        }
    }
}

// MARK: the guide

struct SideboardGuideView: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ListLine] = []

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let lines = ruleLines(rows)
        T1Screen {
            Bar(title: "Sideboard guide", back: { dismiss() }) {
                HStack(spacing: 1) {
                    T1IconButton(icon: .plus, label: "New matchup") { newMatchup() }
                    if let list, !(list.guide?.matchups.isEmpty ?? true) {
                        T1IconButton(icon: .print, label: "Print") { printGuide(list) }
                    }
                }
            }
            if let list {
                HairlineList {
                    if let over = SideboardRules.overSideboard(lines, format: list.format) {
                        Notice("The sideboard has \(over) cards: Constructed allows 15.", error: true)
                    }
                    Button { path.append(.sideboardPool(listId)) } label: {
                        ListRow(title: "Sideboard", detail: "Sideboard \(list.count("side")) · considering \(list.count("maybe"))")
                    }.buttonStyle(.plain)
                    let matchups = list.guide?.matchups ?? []
                    if !matchups.isEmpty { Section1("Matchups · \(matchups.count)") }
                    ForEach(matchups) { m in
                        let c = SideboardRules.check(m, lines, format: list.format)
                        Button { path.append(.sideboardMatchup(listId, m.id)) } label: {
                            ListRow(title: m.name, detail: c.label) {
                                if !rows.isEmpty && !c.issues.isEmpty { LabelText("Check", color: T1.danger) }
                            }
                        }.buttonStyle(.plain)
                    }
                    if matchups.isEmpty {
                        Button { newMatchup() } label: { ListRow(title: "New matchup") { T1Icon.plus.fill(T1.text).frame(width: 18, height: 18) } }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                Notice("That deck isn't here anymore.", error: true)
            }
        }
        .guideCards(listId, $rows)
        .task { Telemetry.capture("sideboard_guide_opened", ["matchups": list?.guide?.matchups.count ?? 0]) }
        #if DEBUG
        // Design QA: `-T1LibraryDemo guide -T1GuidePrint` opens the print preview.
        .task(id: rows.isEmpty) {
            guard !rows.isEmpty, T1Overlays.shared.panels.isEmpty, ProcessInfo.processInfo.arguments.contains("-T1GuidePrint"),
                  let list = ListsStore.shared.list(id: listId) else { return }
            printGuide(list)
        }
        #endif
    }

    private func newMatchup() {
        guard let list = ListsStore.shared.list(id: listId) else { return }
        if (list.guide?.matchups.count ?? 0) >= SideboardRules.maxMatchups {
            ListsStore.shared.error = "A guide has at most \(SideboardRules.maxMatchups) matchups."
            return
        }
        T1Overlays.shared.present(full: true) {
            NewMatchupPanel(list: list) { id in path.append(.sideboardMatchup(listId, id)) }.screen("sideboard_new_matchup")
        }
    }

    private func printGuide(_ list: CardList) {
        guard let guide = list.guide else { return }
        let date = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let r = SideboardRules.printModel(deck: list.name, formatName: formatName(list.format), date: date, lines: ruleLines(rows),
                                          guide: guide, format: list.format)
        T1Overlays.shared.present(full: true) {
            GuidePrintPanel(deck: list.name, html: SideboardRules.html(r.model), warnings: r.warnings, sheets: r.sheets,
                            matchups: guide.matchups.count, leftConsidering: r.warnings.reduce(0) { if case .considering(let n) = $1 { $0 + n } else { $0 } })
                .screen("sideboard_print")
        }
    }
}

// MARK: new matchup

private struct NewMatchupPanel: View {
    let list: CardList
    let created: (String) -> Void
    @State private var name = ""

    var body: some View {
        let taken = Set((list.guide?.matchups ?? []).map { $0.name.lowercased() })
        VStack(spacing: 1) {
            Bar(title: "New matchup") { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            Field(label: "Name", text: $name)
            BigAction(text: "Add", enabled: !SideboardRules.name(name).isEmpty) { add(SideboardRules.name(name), archetype: nil) }
            HairlineList {
                let options = archetypes.filter { !taken.contains($0.name.lowercased()) }
                if !options.isEmpty { Section1("\(formatName(list.format)) meta") }
                ForEach(options, id: \.id) { a in
                    Button { add(a.name, archetype: a.id) } label: {
                        ListRow(title: a.name, detail: a.share)
                    }.buttonStyle(.plain)
                }
            }
        }
        .foregroundStyle(T1.text)
        .background(T1.bg)
        .task {
            guard Insights.formats.contains(where: { $0.key == list.format }) else { return }
            await InsightsStore.shared.load()
            await InsightsStore.shared.ensure(format: list.format)
        }
    }

    /// The format's archetypes by 30-day share, when Insights has the format.
    private var archetypes: [(id: Int, name: String, share: String)] {
        guard let pack = InsightsStore.shared.constructed[list.format],
              let rows = pack.view(pack.default_tier)?.windows["30"]?.share else { return [] }
        return rows.filter { $0.a != 0 }.sorted { $0.share > $1.share }.prefix(30)
            .map { (id: $0.a, name: pack.name($0.a), share: String(format: "%.1f%%", $0.share * 100)) }
    }

    private func add(_ name: String, archetype: Int?) {
        let id = UUID().uuidString.lowercased()
        editGuide(list.id) { g in g.matchups.append(.init(id: id, name: name, archetype: archetype)) }
        Telemetry.capture("sideboard_matchup_added", ["from": archetype == nil ? "typed" : "archetype"])
        T1Overlays.shared.dismissPanel()
        created(id)
    }
}

// MARK: a matchup

struct SideboardMatchupView: View {
    let listId: String
    let matchupId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ListLine] = []

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let m = list?.guide?.matchup(matchupId)
        let lines = ruleLines(rows)
        let pool = SideboardRules.pool(lines)
        T1Screen {
            Bar(title: m?.name ?? "Matchup", back: { dismiss() }) {
                if let list, let m { BarButton("Edit") { menu(list, m) } }
            }
            if let list, let m {
                let c = SideboardRules.check(m, lines, format: list.format)
                HStack(spacing: 1) {
                    cell("In \(c.ins)") { path.append(.sideboardPick(listId, matchupId, "in")) }
                    cell("Out \(c.outs)") { path.append(.sideboardPick(listId, matchupId, "out")) }
                }
                .fixedSize(horizontal: false, vertical: true)
                HairlineList {
                    if !rows.isEmpty {
                        ForEach(Array(c.issues.enumerated()), id: \.offset) { _, i in Notice(SideboardRules.text(i, names: pool), error: true) }
                    }
                    Section1("In · \(c.ins)")
                    if m.ins.isEmpty { ListRow(title: "—") }
                    ForEach(m.ins, id: \.oracle) { card in planRow(card, sign: "+", pool: pool, side: .in) }
                    Section1("Out · \(c.outs)")
                    if m.outs.isEmpty { ListRow(title: "—") }
                    ForEach(m.outs, id: \.oracle) { card in planRow(card, sign: "−", pool: pool, side: .out) }
                    Section1("Notes")
                    Button {
                        T1Overlays.shared.present { MatchupTextPanel(title: m.name, label: "Notes", text: m.notes, limit: SideboardRules.maxNotes, multiline: true) { t in
                            editMatchup(listId, matchupId) { $0.notes = t }
                        } }
                    } label: {
                        Text(m.notes.isEmpty ? "Add notes" : m.notes).font(T1.mono(14)).lineSpacing(4)
                            .foregroundStyle(m.notes.isEmpty ? T1.muted : T1.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                    }.buttonStyle(.plain)
                }
            } else {
                Notice("That matchup isn't in the guide anymore.", error: true)
            }
        }
        .guideCards(listId, $rows)
    }

    private func cell(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabelText(text, color: T1.text).frame(maxWidth: .infinity).frame(height: 50).background(T1.surface)
        }.buttonStyle(.plain)
    }

    private func planRow(_ card: SideboardGuide.Card, sign: String, pool: [String: SideboardRules.Copies], side: SideboardGuide.Side) -> some View {
        let line = rows.first { $0.oracleId == card.oracle && (side == .out ? $0.board == "main" : $0.board != "main") } ?? rows.first { $0.oracleId == card.oracle }
        let fromMaybe = side == .in && (pool[card.oracle]?.side ?? 0) < card.qty
        return Button { path.append(.sideboardPick(listId, matchupId, side.rawValue)) } label: {
            CardRow(printing: line?.printing, title: pool[card.oracle]?.name ?? line?.name ?? "Card",
                    detail: fromMaybe ? "Considering" : nil) {
                Text("\(sign)\(card.qty)").font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }

    private func menu(_ list: CardList, _ m: SideboardGuide.Matchup) {
        let ms = list.guide?.matchups ?? []
        let i = ms.firstIndex { $0.id == m.id } ?? 0
        T1Overlays.shared.showMenu(m.name, [
            T1MenuItem(title: "Rename") {
                T1Overlays.shared.present { MatchupTextPanel(title: "Rename matchup", label: "Name", text: m.name, limit: SideboardRules.maxName, multiline: false) { t in
                    let name = SideboardRules.name(t)
                    if !name.isEmpty { editMatchup(listId, m.id) { $0.name = name } }
                } }
            },
            T1MenuItem(title: "Move up", enabled: i > 0) { editGuide(listId) { g in if i > 0 { g.matchups.swapAt(i, i - 1) } } },
            T1MenuItem(title: "Move down", enabled: i < ms.count - 1) { editGuide(listId) { g in if i < g.matchups.count - 1 { g.matchups.swapAt(i, i + 1) } } },
            T1MenuItem(title: "Delete matchup", destructive: true) {
                editGuide(listId) { g in g.matchups.removeAll { $0.id == m.id } }
                dismiss()
            },
        ])
    }
}

/// A matchup's name or notes.
private struct MatchupTextPanel: View {
    let title: String
    let label: String
    @State var text: String
    let limit: Int
    let multiline: Bool
    let save: (String) -> Void

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: title) { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            VStack(alignment: .leading, spacing: 4) {
                LabelText("\(label) · \(text.count)/\(limit)")
                TextField("", text: $text, axis: multiline ? .vertical : .horizontal)
                    .font(T1.mono(15)).tint(T1.accent).lineLimit(multiline ? 4...12 : 1...1)
                    .onChange(of: text) { if text.count > limit { text = String(text.prefix(limit)) } }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
            .focusArea()
            BigAction(text: "Save", enabled: multiline || !SideboardRules.name(text).isEmpty) {
                save(text.trimmingCharacters(in: .whitespacesAndNewlines))
                T1Overlays.shared.dismissPanel()
            }
        }
        .foregroundStyle(T1.text)
    }
}

// MARK: In / Out picker

struct SideboardPickView: View {
    let listId: String
    let matchupId: String
    let side: SideboardGuide.Side
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ListLine] = []
    @State private var query = ""

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let m = list?.guide?.matchup(matchupId)
        let cards = cardsByOracle(rows)
        T1Screen {
            Bar(title: side == .in ? "In · \(m?.ins.reduce(0) { $0 + $1.qty } ?? 0)" : "Out · \(m?.outs.reduce(0) { $0 + $1.qty } ?? 0)",
                back: { dismiss() })
            if let m {
                if side == .in { T1SearchField(text: $query, prompt: "Add a card to consider") }
                HairlineList {
                    if side == .in && !query.isEmpty {
                        let hits = CatalogStore.shared.db?.search(query, limit: 12) ?? []
                        ForEach(hits, id: \.oracleId) { o in
                            Button { consider(o) } label: {
                                ListRow(title: o.name, detail: o.typeLine) { T1Icon.plus.fill(T1.text).frame(width: 18, height: 18) }
                            }.buttonStyle(.plain)
                        }
                    } else if side == .in {
                        let side = cards.filter { $0.copies.side > 0 }, maybe = cards.filter { $0.copies.side == 0 && $0.copies.maybe > 0 }
                        group("Sideboard", side, count: side.reduce(0) { $0 + $1.copies.side }, m: m) { $0.copies.side + $0.copies.maybe }
                        group("Considering", maybe, count: maybe.reduce(0) { $0 + $1.copies.maybe }, m: m) { $0.copies.maybe }
                    } else {
                        let main = cards.filter { $0.copies.main > 0 }
                        group("Main deck", main, count: main.reduce(0) { $0 + $1.copies.main }, m: m) { $0.copies.main }
                    }
                }
            }
        }
        .guideCards(listId, $rows)
    }

    @ViewBuilder private func group(_ title: String, _ cards: [GuideCard], count: Int, m: SideboardGuide.Matchup,
                                    max: @escaping (GuideCard) -> Int) -> some View {
        if !cards.isEmpty {
            Section1("\(title) · \(count)")
            ForEach(cards) { c in
                let n = m.qty(c.id, in: side)
                HStack(spacing: 1) {
                    CardRow(printing: c.printing, title: c.name,
                            detail: Self.copies(c.copies, side)) {
                        Text(n == 0 ? "0" : "\(side == .in ? "+" : "−")\(n)").font(T1.mono(17)).monospacedDigit()
                            .foregroundStyle(n == 0 ? T1.muted : T1.text)
                    }
                    step("−", enabled: n > 0) { editMatchup(listId, matchupId) { $0.set(c.id, n - 1, on: side) } }
                    step("+", enabled: n < max(c)) { editMatchup(listId, matchupId) { $0.set(c.id, n + 1, on: side) } }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "SIDEBOARD 2 · CONSIDERING 1", "CONSIDERING 1" or "MAIN 4".
    static func copies(_ c: SideboardRules.Copies, _ side: SideboardGuide.Side) -> String {
        side == .out ? "Main \(c.main)" : [c.side > 0 ? "Sideboard \(c.side)" : nil, c.maybe > 0 ? "Considering \(c.maybe)" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func step(_ glyph: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(T1.mono(22)).foregroundStyle(enabled ? T1.text : T1.disabled)
                .frame(width: 52).frame(maxHeight: .infinity).background(T1.surfaceHover)
        }.buttonStyle(.plain).disabled(!enabled)
    }

    /// Adds a card to Considering (its original printing) and brings one copy in.
    private func consider(_ o: CatalogOracle) {
        guard let p = CatalogStore.shared.db?.printings(oracleIdx: o.idx).first else { return }
        let have = ListsStore.shared.list(id: listId)?.guide?.matchup(matchupId)?.qty(o.oracleId, in: .in) ?? 0
        let pool = SideboardRules.pool(ruleLines(rows))[o.oracleId]
        // A card already in the sideboard or Considering only needs bringing in.
        if (pool?.side ?? 0) + (pool?.maybe ?? 0) <= have {
            ListsStore.shared.add(listId: listId, cardId: p.cardId, board: "maybe", finish: p.finishList.first?.rawValue ?? "nonfoil", delta: 1)
        }
        editMatchup(listId, matchupId) { $0.set(o.oracleId, have + 1, on: .in) }
        Telemetry.capture("sideboard_card_considered")
        query = ""
    }
}

// MARK: sideboard and Considering

struct SideboardPoolView: View {
    let listId: String
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ListLine] = []

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let uses = list?.guide.map(SideboardRules.uses) ?? [:]
        T1Screen {
            Bar(title: "Sideboard", back: { dismiss() })
            if let list {
                HairlineList {
                    ForEach(["side", "maybe"], id: \.self) { board in
                        let lines = rows.filter { $0.board == board }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        Section1("\(list.boardTitle(board)) · \(lines.reduce(0) { $0 + $1.qty })")
                        if lines.isEmpty { ListRow(title: "—") }
                        ForEach(lines) { l in
                            let n = l.oracleId.flatMap { uses[$0] } ?? 0
                            Button {
                                let to = board == "side" ? "maybe" : "side"
                                T1Overlays.shared.showMenu(l.name, [
                                    T1MenuItem(title: "Move one to \(list.boardTitle(to))") {
                                        ListsStore.shared.add(listId: listId, cardId: l.cardId, board: board, finish: l.finish, lang: l.lang, cond: l.cond, delta: -1)
                                        ListsStore.shared.add(listId: listId, cardId: l.cardId, board: to, finish: l.finish, lang: l.lang, cond: l.cond, delta: 1)
                                    },
                                    T1MenuItem(title: "Move all to \(list.boardTitle(to))") {
                                        ListsStore.shared.move(listId: listId, cardId: l.cardId, finish: l.finish, lang: l.lang, cond: l.cond, from: board, to: to)
                                    },
                                ])
                            } label: {
                                CardRow(printing: l.printing, title: l.name, detail: n == 0 ? "In no matchups" : "In \(n) \(n == 1 ? "matchup" : "matchups")") {
                                    Text("\(l.qty)").font(T1.mono(17)).monospacedDigit()
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .guideCards(listId, $rows)
    }
}

// MARK: print

/// The printed page as it will print, the warnings, and Print.
private struct GuidePrintPanel: View {
    let deck: String
    let html: String
    let warnings: [SideboardRules.Warning]
    let sheets: Int
    let matchups: Int
    let leftConsidering: Int

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Print", back: { T1Overlays.shared.dismissPanel() })
            ForEach(warnings, id: \.self) { w in Notice(SideboardRules.warningText(w), error: true) }
            GuidePage(html: html).frame(maxWidth: .infinity, maxHeight: .infinity)
            BigAction(text: "Print") { print() }
        }
        .background(T1.bg)
        .foregroundStyle(T1.text)
    }

    private func print() {
        Telemetry.capture("sideboard_guide_printed", ["matchups": matchups, "left_considering": leftConsidering, "sheets": sheets])
        GuidePrinter.shared.print(html: html, name: "\(deck) sideboard guide")
    }
}

private struct GuidePage: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isOpaque = false
        v.backgroundColor = .white
        v.scrollView.contentInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        v.loadHTMLString(html, baseURL: nil)
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

/// Prints from a WebView that lives until printing ends (its print formatter needs the loaded page).
@MainActor
final class GuidePrinter: NSObject, WKNavigationDelegate {
    static let shared = GuidePrinter()
    private var web: WKWebView?
    private var name = ""

    func print(html: String, name: String) {
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        w.navigationDelegate = self
        web = w
        self.name = name
        w.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = name
            let c = UIPrintInteractionController.shared
            c.printInfo = info
            c.printFormatter = webView.viewPrintFormatter()
            c.present(animated: true) { [weak self] _, _, _ in self?.web = nil }
        }
    }
}
