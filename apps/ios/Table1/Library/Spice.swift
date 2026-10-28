import SwiftUI
import Supabase

/* Spice (contract/spice-2026-10-28.md): how much of a deck or cube its peers rarely or never play. The server works it
   out (list_spice); this file decodes the answer, words it exactly as testdata/spice/cases.json says, and draws the
   Spice section on the Stats screen, the Spice screen of a shared deck or cube, and the score in the Stats row. */

struct SpiceResult: Decodable, Equatable, Sendable {
    struct Basis: Decodable, Equatable, Sendable {
        struct Cube: Decodable, Equatable, Sendable {
            let name: String
            let overlap: Double
        }
        let kind: String          // archetype / closest / format / colors / cubes
        let format: String?
        let archetype: Int?
        let name: String?
        let lists: Int
        let days: Int?
        let sources: [String]
        let close: Bool?
        let cubes: [Cube]?
    }
    struct Card: Decodable, Equatable, Sendable, Identifiable {
        let c: String
        let n: String
        let section: String       // main / side
        let copies: Int
        let rate: Double
        let seen: Int
        let of: Int
        var id: String { "\(section)|\(c)" }
    }
    struct Missing: Decodable, Equatable, Sendable, Identifiable {
        let c: String
        let n: String
        let rate: Double
        let seen: Int
        let of: Int
        var id: String { c }
    }
    let kind: String
    let score: Int?
    let word: String?
    let reason: String?
    let basis: Basis?
    let cards: [Card]
    let stockMissing: [Missing]
}

/// The words every client shows (the `display` of each case in testdata/spice/cases.json).
enum Spice {
    static let words = ["stock": "Stock", "tuned": "Tuned", "spicy": "Spicy", "brew": "Brew"]
    static let formats = ["standard": "Standard", "pioneer": "Pioneer", "modern": "Modern", "pauper": "Pauper",
                          "canlander": "Canadian Highlander", "legacy": "Legacy"]
    private static let sources = ["mtgo": "MTGO", "topdeck": "TopDeck.gg", "cubecobra": "Cube Cobra"]
    private static let reasons = ["empty": "Add cards to see how spicy this is",
                                  "no_data": "No tournament lists for this format yet",
                                  "no_cubes": "No cubes to compare with yet"]

    /// The end of the Stats row: "Spice 34".
    static func summary(_ r: SpiceResult) -> String? { r.score.map { "Spice \($0)" } }

    /// "34 · Spicy".
    static func headline(_ r: SpiceResult) -> String? {
        guard let s = r.score, let w = r.word else { return nil }
        return "\(s) · \(words[w] ?? w)"
    }

    static func reason(_ r: SpiceResult) -> String? {
        r.score == nil ? reasons[r.reason ?? ""] ?? reasons["no_data"] : nil
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// What the deck was compared with.
    static func basis(_ r: SpiceResult) -> String? {
        guard r.score != nil, let b = r.basis else { return nil }
        let when = b.days.map { $0 == 365 ? "last year" : "last \($0) days" } ?? ""
        let src = b.sources.map { sources[$0] ?? $0 }.joined(separator: " and ")
        let fmt = b.format.map { formats[$0] ?? $0 } ?? ""
        let name = b.name ?? ""
        switch b.kind {
        case "archetype": return "\(plural(b.lists, "\(name) list", "\(name) lists")) · \(when) · \(src)"
        case "closest": return "Closest archetype: \(name) · \(plural(b.lists, "list", "lists")) · \(when) · \(src)"
        case "format": return "Nothing close in \(fmt) · \(plural(b.lists, "list", "lists")) · \(when) · \(src)"
        case "colors": return "\(fmt) lists that can play each card · \(plural(b.lists, "list", "lists")) · \(when) · \(src)"
        default:
            return "\(b.close == true ? "The \(b.lists) cubes most like yours" : "No cubes much like this one") · \(src)"
        }
    }

    /// The nearest cubes: "LSVCube · 62% alike" (whole percent from the overlap's basis points, half up).
    static func cubes(_ r: SpiceResult) -> [String] {
        guard r.score != nil else { return [] }
        return (r.basis?.cubes ?? []).map { "\($0.name) · \((Int(($0.overlap * 10000).rounded()) + 50) / 100)% alike" }
    }

    static func cardTitle(_ c: SpiceResult.Card) -> String { "\(c.copies) \(c.n)" }

    /// "in 2 of 412 lists", "never seen", "in 3 of 40 lists that can play it", "in 3 of 20 similar cubes".
    static func cardDetail(_ c: SpiceResult.Card, _ r: SpiceResult) -> String {
        let kind = r.basis?.kind ?? ""
        let noun = kind == "colors" ? "lists that can play it" : kind == "cubes" ? "similar cubes" : "lists"
        let seen = c.seen == 0 ? (kind == "cubes" ? "in no similar cube" : "never seen") : "in \(c.seen) of \(c.of) \(noun)"
        return seen + (c.section == "side" ? " · sideboard" : "")
    }

    static func cardLine(_ c: SpiceResult.Card, _ r: SpiceResult) -> String { "\(cardTitle(c)) · \(cardDetail(c, r))" }

    static func missingDetail(_ m: SpiceResult.Missing, _ r: SpiceResult) -> String {
        "in \(m.seen) of \(m.of) \(r.basis?.kind == "cubes" ? "similar cubes" : "lists")"
    }

    static func missingLine(_ m: SpiceResult.Missing, _ r: SpiceResult) -> String { "\(m.n) · \(missingDetail(m, r))" }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// A card the demo makes a result from.
struct SpiceDemoCard: Sendable {
    let oracleId: String
    let name: String
    let qty: Int
    let board: String
    let basic: Bool
    static let basics: Set<String> = ["Plains", "Island", "Swamp", "Mountain", "Forest", "Wastes", "Snow-Covered Plains",
                                      "Snow-Covered Island", "Snow-Covered Swamp", "Snow-Covered Mountain", "Snow-Covered Forest"]
}

@MainActor
@Observable
final class SpiceStore {
    static let shared = SpiceStore()
    /// By list id.
    private(set) var results: [String: SpiceResult] = [:]
    /// Lists whose last ask failed (offline, or no longer shared): "Not available".
    private(set) var failed: Set<String> = []
    @ObservationIgnored private var keys: [String: String] = [:]
    @ObservationIgnored private var viewed: Set<String> = []

    /// Asks the server once per `key` (the list's cards: a change asks again). `token` when opened from a link.
    func load(listId: String, key: String, token: String? = nil, kind: CardList.Kind, format: String,
              demo: [SpiceDemoCard]? = nil, name: String = "") async {
        if keys[listId] == key, results[listId] != nil { return }
        keys[listId] = key
        #if DEBUG
        if CollectionStore.shared.demo != nil {
            if let demo { results[listId] = Self.demoResult(demo, kind: kind, format: format, name: name) }
            return
        }
        #endif
        do {
            var params: [String: AnyJSON] = ["p_list_id": .string(listId)]
            if let token { params["p_token"] = .string(token) }
            let r: SpiceResult = try await supabase.rpc("list_spice", params: params).execute().value
            results[listId] = r
            failed.remove(listId)
        } catch {
            keys[listId] = nil
            if !error.isCancellation { failed.insert(listId) }
        }
    }

    /// spice_viewed, once per list per screen open (the view passes its own open id).
    func viewed(_ r: SpiceResult, listId: String, open: UUID, format: String) {
        guard viewed.insert("\(listId)|\(open)").inserted else { return }
        Telemetry.capture("spice_viewed", ["kind": r.kind, "format": format, "basis": r.basis?.kind ?? r.reason ?? "none",
                                           "word": r.word ?? "none"])
    }

    #if DEBUG
    /// Demo: a made-up comparison from the list's own cards, so every part of the section shows.
    nonisolated static func demoResult(_ cards: [SpiceDemoCard], kind: CardList.Kind, format: String, name: String = "Similar decks") -> SpiceResult {
        let isCube = kind == .cube
        let main = cards.filter { !$0.basic && ($0.board == "main" || $0.board == "commander") }
        let side = isCube ? [] : cards.filter { !$0.basic && $0.board == "side" }
        guard !main.isEmpty else {
            return SpiceResult(kind: kind.rawValue, score: nil, word: nil, reason: "empty", basis: nil, cards: [], stockMissing: [])
        }
        let n = isCube ? 20 : 412
        func seen(_ c: SpiceDemoCard) -> Int {
            let h = c.oracleId.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return h % 6 == 0 ? h % 7 : n / 3 + h % (n - n / 3)
        }
        var num = 0, total = 0
        for c in main { num += c.qty * max(0, n - 4 * seen(c)); total += c.qty }
        let score = (200 * num + n * total) / (2 * n * total)
        let word = score < 10 ? "stock" : score < 25 ? "tuned" : score < 50 ? "spicy" : "brew"
        let spicy = (main.map { ($0, "main") } + side.map { ($0, "side") }).filter { 4 * seen($0.0) < n }
            .sorted { ($0.1 != "main" ? 1 : 0, seen($0.0), -$0.0.qty, $0.0.name) < ($1.1 != "main" ? 1 : 0, seen($1.0), -$1.0.qty, $1.0.name) }
            .map { SpiceResult.Card(c: $0.0.oracleId, n: $0.0.name, section: $0.1, copies: $0.0.qty,
                                    rate: Double(seen($0.0)) / Double(n), seen: seen($0.0), of: n) }
        let missing = ["Thoughtseize", "Fable of the Mirror-Breaker", "Consider"].enumerated().map { i, name in
            SpiceResult.Missing(c: "demo-missing-\(i)", n: name, rate: Double(n - 60 * (i + 1)) / Double(n), seen: n - 60 * (i + 1), of: n)
        }
        let basis = isCube
            ? SpiceResult.Basis(kind: "cubes", format: nil, archetype: nil, name: nil, lists: n, days: nil, sources: ["cubecobra"],
                                close: true, cubes: [.init(name: "MTGO Vintage Cube", overlap: 0.62), .init(name: "LSVCube", overlap: 0.58),
                                                     .init(name: "AlphaFrog Vintage Cube", overlap: 0.51)])
            : SpiceResult.Basis(kind: "archetype", format: format, archetype: 1, name: name, lists: n, days: 90,
                                sources: ["mtgo", "topdeck"], close: nil, cubes: nil)
        return SpiceResult(kind: kind.rawValue, score: score, word: word, reason: nil, basis: basis, cards: spicy,
                           stockMissing: isCube ? [] : missing)
    }
    #endif
}

// MARK: views

/// The Spice section: score and word, what it was compared with, the spiciest cards, stock cards you don't play.
struct SpiceSection: View {
    let listId: String
    let kind: CardList.Kind
    let format: String
    /// The Stats screen logs deck_spice / cube_spice here; the Spice screen logs it as its own screen.
    var logScreen = true
    let open: (String) -> Void
    @State private var all = false
    @State private var openId = UUID()
    private var store: SpiceStore { SpiceStore.shared }

    var body: some View {
        Section1("Spice")
        if let r = store.results[listId] {
            if let headline = Spice.headline(r) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline.uppercased()).font(T1.mono(24)).tracking(1.5).foregroundStyle(T1.accent)
                    if let basis = Spice.basis(r) {
                        Text(basis).font(T1.mono(12)).lineSpacing(4).foregroundStyle(T1.muted)
                    }
                    ForEach(Spice.cubes(r), id: \.self) { line in
                        Text(line).font(T1.mono(12)).foregroundStyle(T1.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                if !r.cards.isEmpty {
                    Section1("Spiciest cards")
                    VStack(spacing: 1) {
                        ForEach(all ? r.cards : Array(r.cards.prefix(8))) { c in
                            Button { opened(r, c.section, c.c) } label: {
                                ListRow(title: Spice.cardTitle(c), detail: Spice.cardDetail(c, r))
                            }.buttonStyle(.plain)
                        }
                    }
                    if r.cards.count > 8, !all {
                        Button { all = true } label: { ListRow(title: "Show all \(r.cards.count)") }.buttonStyle(.plain)
                    }
                }
                if !r.stockMissing.isEmpty {
                    Section1("Stock cards you don't play")
                    VStack(spacing: 1) {
                        ForEach(r.stockMissing) { m in
                            Button { opened(r, "missing", m.c) } label: {
                                ListRow(title: m.n, detail: Spice.missingDetail(m, r))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else if let reason = Spice.reason(r) {
                Notice(reason)
            }
            Color.clear.frame(height: 0)
                .onAppear { store.viewed(r, listId: listId, open: openId, format: format) }
                .screen(kind == .cube ? "cube_spice" : "deck_spice", when: logScreen)
        } else if store.failed.contains(listId) {
            Notice("Spice isn't available right now")
        } else {
            ListRow(title: "Reading spice…")
        }
    }

    private func opened(_ r: SpiceResult, _ section: String, _ oracleId: String) {
        Telemetry.capture("spice_card_opened", ["kind": r.kind, "section": section])
        if !oracleId.hasPrefix("demo-") { open(oracleId) }
    }
}

/// A shared deck or cube's Spice screen (from its row on the shared list).
struct SpiceView: View {
    let listId: String
    let token: String?
    let kind: CardList.Kind
    let format: String
    let title: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        T1Screen {
            Bar(title: "Spice", subtitle: title, back: { dismiss() })
            HairlineList {
                SpiceSection(listId: listId, kind: kind, format: format, logScreen: false) { path.append(.cardIn($0, .search)) }
            }
        }
        .task { await SpiceStore.shared.load(listId: listId, key: "shared", token: token, kind: kind, format: format) }
    }
}

/// The Spice row on a shared deck or cube: the score, opening its Spice screen.
struct SpiceRow: View {
    let listId: String
    let token: String?
    let kind: CardList.Kind
    let format: String
    let title: String
    let demo: [SpiceDemoCard]
    @Binding var path: [LibraryRoute]

    var body: some View {
        let r = SpiceStore.shared.results[listId]
        Button { path.append(.spice(listId, token, kind, format, title)) } label: {
            ListRow(title: "Spice", detail: r.flatMap { Spice.headline($0) ?? Spice.reason($0) }
                        ?? (SpiceStore.shared.failed.contains(listId) ? "Not available" : "Reading spice…"))
        }
        .buttonStyle(.plain)
        .task { await SpiceStore.shared.load(listId: listId, key: "shared", token: token, kind: kind, format: format, demo: demo, name: title) }
    }
}
