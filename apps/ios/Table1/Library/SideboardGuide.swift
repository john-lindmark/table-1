import Foundation
import Supabase

// Sideboard guides (contract/sideboard-guide-2026-11-04.md): per matchup, what comes in (sideboard or Considering),
// what goes out (main deck) and notes; printed for Competitive REL (MTR 2.11). The rules are
// testdata/sideboard-guide/make_cases.py; web sideboardGuide.ts and Android SideboardGuide.kt match it.

struct SideboardGuide: Codable, Hashable, Sendable {
    /// [oracle_id, qty] on the wire.
    struct Card: Codable, Hashable, Sendable {
        var oracle: String
        var qty: Int
        init(_ oracle: String, _ qty: Int) { self.oracle = oracle; self.qty = qty }
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            oracle = try c.decode(String.self)
            qty = try c.decode(Int.self)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(oracle)
            try c.encode(qty)
        }
    }
    struct Matchup: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var archetype: Int? = nil
        var ins: [Card] = []
        var outs: [Card] = []
        var notes: String = ""
        enum CodingKeys: String, CodingKey { case id, name, archetype, ins = "in", outs = "out", notes }
        init(id: String, name: String, archetype: Int? = nil, ins: [Card] = [], outs: [Card] = [], notes: String = "") {
            self.id = id; self.name = name; self.archetype = archetype; self.ins = ins; self.outs = outs; self.notes = notes
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            archetype = try c.decodeIfPresent(Int.self, forKey: .archetype)
            ins = try c.decodeIfPresent([Card].self, forKey: .ins) ?? []
            outs = try c.decodeIfPresent([Card].self, forKey: .outs) ?? []
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        }

        func qty(_ oracle: String, in side: Side) -> Int { (side == .in ? ins : outs).first { $0.oracle == oracle }?.qty ?? 0 }

        /// Sets a card's count on one side (0 takes it off), keeping the order cards were added.
        mutating func set(_ oracle: String, _ qty: Int, on side: Side) {
            var cards = side == .in ? ins : outs
            if let i = cards.firstIndex(where: { $0.oracle == oracle }) {
                if qty <= 0 { cards.remove(at: i) } else { cards[i].qty = min(99, qty) }
            } else if qty > 0 {
                cards.append(Card(oracle, min(99, qty)))
            }
            if side == .in { ins = cards } else { outs = cards }
        }
    }
    enum Side: String, Sendable { case `in`, out }

    var matchups: [Matchup] = []

    func matchup(_ id: String) -> Matchup? { matchups.first { $0.id == id } }

    /// The wire value for list_guide_set: nil clears it.
    var wire: AnyJSON {
        guard !matchups.isEmpty, let data = try? JSONEncoder().encode(self),
              let json = try? JSONDecoder().decode(AnyJSON.self, from: data) else { return .null }
        return json
    }
}

enum SideboardRules {
    static let maxMatchups = 40
    static let maxCards = 40
    static let maxName = 40
    static let maxNotes = 1000
    static let sideboardMax = 15
    static let capped: Set<String> = ["modern", "pioneer", "standard", "legacy", "vintage", "pauper", "canlander"]

    /// A deck line by card: what the rules need.
    struct Line: Hashable, Sendable {
        let oracle: String
        let name: String
        let board: String
        let qty: Int
    }
    struct Copies: Hashable, Sendable {
        var name: String
        var main = 0, side = 0, maybe = 0
    }
    enum Issue: Hashable, Sendable {
        case gone(side: SideboardGuide.Side, oracle: String)
        case inOver(oracle: String, have: Int)
        case outOver(oracle: String, have: Int)
        case considering(oracle: String, qty: Int)
        case belowMin(deck: Int, min: Int)
    }
    struct Check: Hashable, Sendable {
        let ins: Int
        let outs: Int
        let deck: Int
        let label: String
        let issues: [Issue]
    }

    static func hasGuide(_ format: String) -> Bool { !CommandZone.formats.contains(format) }

    static func deckMin(_ format: String) -> Int? {
        format == "canlander" ? 100 : capped.contains(format) ? 60 : nil
    }

    /// Copies per card in the main deck, sideboard and Considering (the command zone isn't the deck here).
    static func pool(_ lines: [Line]) -> [String: Copies] {
        var out: [String: Copies] = [:]
        for l in lines {
            var c = out[l.oracle] ?? Copies(name: l.name)
            switch l.board {
            case "main": c.main += l.qty
            case "side": c.side += l.qty
            case "maybe": c.maybe += l.qty
            default: break
            }
            out[l.oracle] = c
        }
        return out
    }

    static func label(_ ins: Int, _ outs: Int) -> String { ins == 0 && outs == 0 ? "NO CHANGES" : "IN \(ins) · OUT \(outs)" }

    static func check(_ m: SideboardGuide.Matchup, _ lines: [Line], format: String) -> Check {
        let p = pool(lines)
        let mainTotal = lines.filter { $0.board == "main" }.reduce(0) { $0 + $1.qty }
        var issues: [Issue] = []
        var tookIn = 0
        for c in m.ins {
            let have = p[c.oracle] ?? Copies(name: "")
            let avail = have.side + have.maybe
            if avail == 0 { issues.append(.gone(side: .in, oracle: c.oracle)); continue }
            if c.qty > avail { issues.append(.inOver(oracle: c.oracle, have: avail)) }
            let took = min(c.qty, avail)
            tookIn += took
            if took - have.side > 0 { issues.append(.considering(oracle: c.oracle, qty: took - have.side)) }
        }
        var tookOut = 0
        for c in m.outs {
            let have = p[c.oracle]?.main ?? 0
            if have == 0 { issues.append(.gone(side: .out, oracle: c.oracle)); continue }
            if c.qty > have { issues.append(.outOver(oracle: c.oracle, have: have)) }
            tookOut += min(c.qty, have)
        }
        let after = mainTotal + tookIn - tookOut
        if let min = deckMin(format), after < min { issues.append(.belowMin(deck: after, min: min)) }
        let ins = m.ins.reduce(0) { $0 + $1.qty }, outs = m.outs.reduce(0) { $0 + $1.qty }
        return Check(ins: ins, outs: outs, deck: after, label: label(ins, outs), issues: issues)
    }

    static func sideboardCount(_ lines: [Line]) -> Int { lines.filter { $0.board == "side" }.reduce(0) { $0 + $1.qty } }

    /// The sideboard's size when it's over 15 in a capped format (CR 100.4a), else nil.
    static func overSideboard(_ lines: [Line], format: String) -> Int? {
        let n = sideboardCount(lines)
        return capped.contains(format) && n > sideboardMax ? n : nil
    }

    /// How many matchups bring each card in.
    static func uses(_ g: SideboardGuide) -> [String: Int] {
        var out: [String: Int] = [:]
        for m in g.matchups { for c in m.ins where c.qty > 0 { out[c.oracle, default: 0] += 1 } }
        return out
    }

    /// One issue as a sentence for the matchup screen.
    static func text(_ issue: Issue, names: [String: Copies]) -> String {
        func name(_ o: String) -> String { names[o]?.name ?? "A card" }
        switch issue {
        case let .gone(side, o): return side == .in ? "\(name(o)) isn't in the sideboard or Considering anymore." : "\(name(o)) isn't in the main deck anymore."
        case let .inOver(o, have): return "Only \(have) \(name(o)) to bring in."
        case let .outOver(o, have): return "Only \(have) \(name(o)) in the main deck."
        case let .considering(o, qty): return "\(qty) \(name(o)) from Considering: not printed until it's in the sideboard."
        case let .belowMin(deck, min): return "The deck goes to \(deck) cards, under \(min)."
        }
    }

    // MARK: printing

    struct PrintMatchup: Hashable, Sendable {
        let name: String
        let ins: [(Int, String)]
        let outs: [(Int, String)]
        let notes: String
        static func == (a: Self, b: Self) -> Bool {
            a.name == b.name && a.notes == b.notes && a.ins.map(\.0) == b.ins.map(\.0) && a.ins.map(\.1) == b.ins.map(\.1)
                && a.outs.map(\.0) == b.outs.map(\.0) && a.outs.map(\.1) == b.outs.map(\.1)
        }
        func hash(into h: inout Hasher) { h.combine(name) }
    }
    struct PrintModel: Sendable {
        let deck: String
        let format: String
        let date: String
        let sideboard: [(Int, String)]
        let matchups: [PrintMatchup]
    }
    enum Warning: Hashable, Sendable {
        case considering(Int), gone(Int), sideboardOver(Int), sheets(Int)
    }

    /// What the printed guide shows: only sideboard copies come in, outs capped at the main deck's copies, cards no
    /// longer in the deck left out.
    static func printModel(deck: String, formatName: String, date: String, lines: [Line], guide: SideboardGuide,
                           format: String) -> (model: PrintModel, warnings: [Warning], sheets: Int) {
        let p = pool(lines)
        var leftConsidering = 0, leftGone = 0
        var matchups: [PrintMatchup] = []
        for m in guide.matchups {
            var ins: [(Int, String)] = []
            for c in m.ins {
                guard let have = p[c.oracle], have.side + have.maybe > 0 else { leftGone += c.qty; continue }
                let took = min(c.qty, have.side)
                leftConsidering += min(c.qty, have.side + have.maybe) - took
                if took > 0 { ins.append((took, have.name)) }
            }
            var outs: [(Int, String)] = []
            for c in m.outs {
                guard let have = p[c.oracle], have.main > 0 else { leftGone += c.qty; continue }
                outs.append((min(c.qty, have.main), have.name))
            }
            matchups.append(PrintMatchup(name: m.name, ins: ins, outs: outs, notes: m.notes))
        }
        let side = p.values.filter { $0.side > 0 }.map { ($0.side, $0.name) }
            .sorted { $0.1.lowercased() < $1.1.lowercased() }
        let model = PrintModel(deck: deck, format: formatName, date: date, sideboard: side, matchups: matchups)
        var warnings: [Warning] = []
        if leftConsidering > 0 { warnings.append(.considering(leftConsidering)) }
        if leftGone > 0 { warnings.append(.gone(leftGone)) }
        if let over = overSideboard(lines, format: format) { warnings.append(.sideboardOver(over)) }
        let s = sheets(model)
        if s > 2 { warnings.append(.sheets(s)) }
        return (model, warnings, s)
    }

    static let linesPerPage = 120, headerLines = 10, noteCharsPerLine = 40

    /// About how many pages the printed guide takes (MTR 2.11 allows a sheet or two).
    static func sheets(_ m: PrintModel) -> Int {
        var total = headerLines
        for x in m.matchups {
            var notes = 0
            if !x.notes.isEmpty {
                notes = 1 + x.notes.split(separator: "\n", omittingEmptySubsequences: false)
                    .reduce(0) { $0 + max(1, Int((Double($1.count) / Double(noteCharsPerLine)).rounded(.up))) }
            }
            total += 4 + max(x.ins.count, x.outs.count, 1) + notes
        }
        total += 4 + max(m.sideboard.count, 1)
        return max(1, Int((Double(total) / Double(linesPerPage)).rounded(.up)))
    }

    static func warningText(_ w: Warning) -> String {
        switch w {
        case .considering(let n): "\(n) \(n == 1 ? "card" : "cards") from Considering left out: only the sideboard can come in."
        case .gone(let n): "\(n) \(n == 1 ? "card" : "cards") no longer in the deck left out."
        case .sideboardOver(let n): "The sideboard has \(n) cards: Constructed allows 15."
        case .sheets(let n): "About \(n) pages: the rules allow a sheet or two."
        }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static let css = "@page{margin:12mm}"
        + "*{box-sizing:border-box;margin:0;padding:0}"
        + "html{-webkit-print-color-adjust:exact;print-color-adjust:exact}"
        + "body{font-family:ui-monospace,\"SF Mono\",\"JetBrains Mono\",Menlo,Consolas,monospace;color:#171725;"
        + "background:#fff;font-size:9pt;line-height:1.35}"
        + "header{border-bottom:2px solid #00ffd9;padding-bottom:6pt;margin-bottom:8pt}"
        + ".mark,.meta,.rule,.lab,h2{text-transform:uppercase;letter-spacing:.15em}"
        + ".mark{font-size:7pt;color:#545461}"
        + "h1{font-size:16pt;font-weight:600;margin:2pt 0}"
        + ".meta{font-size:7.5pt;color:#545461}"
        + ".rule{font-size:6.5pt;color:#545461;margin-top:2pt}"
        + "main{columns:2;column-gap:8pt}"
        + "section{break-inside:avoid;border:1px solid #c4c4ca;margin-bottom:8pt;padding:6pt}"
        + "h2{font-size:8pt;font-weight:600;padding-bottom:4pt;border-bottom:1px solid #c4c4ca;margin-bottom:4pt}"
        + ".io{display:flex;gap:6pt}"
        + ".col{flex:1;min-width:0}"
        + ".lab{font-size:6.5pt;color:#545461;margin-bottom:2pt}"
        + ".row{display:flex;gap:4pt}"
        + ".q{width:2.4em;flex:none;font-weight:600}"
        + ".none{color:#545461}"
        + ".notes{margin-top:4pt;padding-top:4pt;border-top:1px solid #c4c4ca;font-size:8pt;white-space:pre-wrap}"

    static let rule = "MTR 2.11 · Between games only · Remove from the play area before each game"

    private static func rows(_ cards: [(Int, String)], _ sign: String) -> String {
        if cards.isEmpty { return "<div class=\"none\">—</div>" }
        return cards.map { "<div class=\"row\"><span class=\"q\">\(sign)\($0.0)</span><span>\(esc($0.1))</span></div>" }.joined()
    }

    /// The printed page (light paper in Table 1's type and grid); must equal testdata/sideboard-guide/guide.html.
    static func html(_ m: PrintModel) -> String {
        var out = "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        out += "<title>\(esc(m.deck)) · Sideboard guide</title>\n"
        out += "<style>\(css)</style>\n</head>\n<body>\n<header>\n"
        out += "<div class=\"mark\">Table 1</div>\n"
        out += "<h1>\(esc(m.deck))</h1>\n"
        out += "<div class=\"meta\">\(esc(m.format)) · Sideboard guide · \(esc(m.date))</div>\n"
        out += "<div class=\"rule\">\(rule)</div>\n</header>\n<main>\n"
        for x in m.matchups {
            let nIn = x.ins.reduce(0) { $0 + $1.0 }, nOut = x.outs.reduce(0) { $0 + $1.0 }
            out += "<section>\n<h2>\(esc(x.name))</h2>\n<div class=\"io\">\n"
            out += "<div class=\"col\"><div class=\"lab\">In · \(nIn)</div>\(rows(x.ins, "+"))</div>\n"
            out += "<div class=\"col\"><div class=\"lab\">Out · \(nOut)</div>\(rows(x.outs, "−"))</div>\n</div>\n"
            if !x.notes.isEmpty { out += "<p class=\"notes\">\(esc(x.notes))</p>\n" }
            out += "</section>\n"
        }
        let nSide = m.sideboard.reduce(0) { $0 + $1.0 }
        out += "<section>\n<h2>Sideboard · \(nSide)</h2>\n\(rows(m.sideboard, ""))\n</section>\n"
        out += "</main>\n</body>\n</html>\n"
        return out
    }

    /// The deck's lines by card, from the catalog (names and oracle ids).
    static func lines(_ list: CardList, _ db: CatalogDB) -> [Line] {
        ListLine.resolve(list.entries, kind: list.kind, db).compactMap { l in
            l.oracleId.map { Line(oracle: $0, name: l.name, board: l.board, qty: l.qty) }
        }
    }

    /// A matchup name as the server keeps it: trimmed, at most 40 characters.
    static func name(_ raw: String) -> String { String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName)) }
}
