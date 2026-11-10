import SwiftUI

/// The Limited page's cards, the grid's Overall column and the mana pips (contract/insights-2026-10-24.md § The
/// Limited page, § Matchups "Overall"). Shared cases: testdata/insights/limited-home.json, overall.json,
/// testdata/mana-symbols/cases.json.
extension Insights {
    /// Cards shown before Show all; hits from other sets once the picked set has none; the shortest query searched.
    static let limitedTop = 10
    static let othersMax = 20
    static let minQuery = 2

    /// The sorts, the rarity filter and the color filter, in their pickers' order.
    static let limitedSorts: [(key: String, label: String, code: String)] = [
        ("gih", "Win rate in hand", "GIH WR"), ("oh", "Win rate in opening hand", "OH WR"),
        ("iwd", "Improvement when drawn", "IWD"), ("ata", "Average pick taken", "ATA"),
    ]
    static let limitedRarities: [(key: String, label: String, code: String)] = [
        ("all", "Any rarity", "Any rarity"), ("common", "Common", "Common"), ("uncommon", "Uncommon", "Uncommon"),
        ("rare", "Rare", "Rare"), ("mythic", "Mythic", "Mythic"),
    ]
    static let limitedColors: [(key: String, label: String, code: String)] = [
        ("all", "Any color", "Any color"), ("W", "White", "W"), ("U", "Blue", "U"), ("B", "Black", "B"), ("R", "Red", "R"),
        ("G", "Green", "G"), ("M", "Multicolor", "Multi"), ("C", "Colorless", "C"),
    ]

    /// The cards the filters keep, best first: the sort's value high to low (ATA low to high), cards without one last;
    /// ties by games in hand, then name. A cube's cards have no rarity, so the rarity filter is ignored there.
    static func limitedCards(_ cards: [LCard], sort: String, rarity: String, color: String) -> [LCard] {
        let rated = cards.contains { $0.r != nil }
        let kept = cards.filter { c in
            if rated && rarity != "all" && c.r != rarity { return false }
            let col = c.col.flatMap { $0.isEmpty ? nil : $0 } ?? "C"
            switch color {
            case "all": return true
            case "M": return col.count > 1 && col != "C"
            default: return col == color
            }
        }
        func key(_ c: LCard) -> Double? {
            switch sort { case "oh": c.oh; case "iwd": c.iwd; case "ata": c.ata.map { -$0 }; default: c.gih }
        }
        return kept.sorted { a, b in
            switch (key(a), key(b)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.gih_n != b.gih_n ? a.gih_n > b.gih_n : a.n < b.n
            }
        }
    }

    /// A row's number for the sort, and for the win rates how far it sits from the view's average, in points.
    static func limitedValue(_ c: LCard, sort: String, average: Double) -> (value: String, vs: String?) {
        switch sort {
        case "ata": return (c.ata.map { String(format: "%.1f", $0) } ?? "–", nil)
        case "iwd": return (c.iwd.map { InsightCharts.delta($0) } ?? "–", nil)
        default:
            let x = sort == "oh" ? c.oh : c.gih
            return (InsightCharts.pct1(x), x.map { InsightCharts.delta($0 - average) })
        }
    }

    /// Lower case, accents and apostrophes gone, everything else but letters and digits a single space.
    static func searchNorm(_ s: String) -> String {
        let folded = s.lowercased().replacingOccurrences(of: "æ", with: "ae")
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let spaced = String(folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    private static func searchRank(_ name: String, _ q: String) -> Int? {
        let n = searchNorm(name)
        if n.hasPrefix(q) { return 0 }
        if (" " + n).contains(" " + q) { return 1 }
        return n.contains(q) ? 2 : nil
    }

    struct LimitedHit: Hashable { let set: String; let name: String }

    /// The picked set's cards whose name holds the query (all of them, whatever the filters), starts first; when none
    /// does, the other sets' (up to `othersMax`), with the set each is in.
    static func limitedSearch(_ query: String, here: [String], others: [(key: String, names: [String])]) -> (here: [String], elsewhere: [LimitedHit]) {
        let q = searchNorm(query)
        guard q.count >= minQuery else { return ([], []) }
        let hits = here.compactMap { n in searchRank(n, q).map { (r: $0, n: n) } }
            .sorted { ($0.r, $0.n) < ($1.r, $1.n) }
        if !hits.isEmpty { return (hits.map(\.n), []) }
        var more: [(r: Int, n: String, i: Int, k: String)] = []
        for (i, s) in others.enumerated() {
            for n in s.names { if let r = searchRank(n, q) { more.append((r, n, i, s.key)) } }
        }
        more.sort { ($0.r, $0.n, $0.i) < ($1.r, $1.n, $1.i) }
        return ([], more.prefix(othersMax).map { LimitedHit(set: $0.k, name: $0.n) })
    }

    /// A grid row's overall match record: the window's Meta now record for the archetype when it has one, else the
    /// sum of its squares against every other row (testdata/insights/overall.json).
    static func overall(_ share: [ShareRow], _ m: Matchups, _ a: Int) -> (wins: Int, losses: Int, draws: Int, fromMeta: Bool)? {
        if let rec = share.first(where: { $0.a == a })?.rec, rec.count == 3, rec[0] + rec[1] > 0 {
            return (rec[0], rec[1], rec[2], true)
        }
        var w = 0, l = 0, d = 0
        for b in m.rowIds where b != a {
            if let c = m.cell(a, b) { w += c.wins; l += c.losses; d += c.draws }
        }
        return w + l > 0 ? (w, l, d, false) : nil
    }
}

/// Scryfall's mana symbols, bundled in the asset catalog as mana-<name> (tools/mana/make.py).
enum ManaSymbols {
    /// "{2}{W}{U/B}" → ["2", "W", "UB"]; a second face's cost after " // " comes after "//".
    static func parse(_ cost: String) -> [String] {
        var out: [String] = []
        for (i, face) in cost.components(separatedBy: " // ").enumerated() {
            if i > 0 { out.append("//") }
            var rest = face[...]
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                out.append(rest[rest.index(after: open)..<close].replacingOccurrences(of: "/", with: "").uppercased())
                rest = rest[rest.index(after: close)...]
            }
        }
        return out
    }
}

/// A mana cost as Scryfall's symbols; one it doesn't bundle is a grey circle with its text.
struct ManaCostView: View {
    let cost: String
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(ManaSymbols.parse(cost).enumerated()), id: \.offset) { _, s in
                if s == "//" {
                    Text("//").font(T1.mono(size * 0.8)).foregroundStyle(T1.muted)
                } else if UIImage(named: "mana-\(s)") != nil {
                    Image("mana-\(s)").resizable().frame(width: size, height: size)
                } else {
                    Text(s).font(T1.mono(size * 0.6)).foregroundStyle(T1.ink).lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: size, height: size).background(Circle().fill(Color(red: 0.79, green: 0.77, blue: 0.75)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ManaSymbols.parse(cost).joined(separator: " "))
    }
}

/// An event code read out of pasted text (contract/qr-sign-up-2026-10-23.md § Enter or paste a code; shared cases
/// testdata/join-code/cases.json).
enum JoinCode: Equatable {
    case code(String)
    case qr(JoinLink)

    static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private static func isCode(_ s: Substring) -> Bool { s.count == 4 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    static func parse(_ text: String?) -> JoinCode? {
        guard let text else { return nil }
        if let m = text.firstMatch(of: /(?i)(?:https?:\/\/)?(?:www\.)?table-1\.site(\/[^\s<>"']*)/) {
            guard let url = URL(string: "https://table-1.site" + m.1), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, parts[0] == "j", isCode(parts[1][...]),
               let s = comps.queryItems?.first(where: { $0.name == "s" })?.value, !s.isEmpty,
               let link = JoinLink("https://table-1.site/j/\(parts[1].uppercased())?s=\(s)") {
                return .qr(link)
            }
            if parts.count >= 2, parts[0] == "join", isCode(parts[1][...]) { return .code(parts[1].uppercased()) }
            return nil
        }
        let plain = text.replacing(/https?:\/\/\S+/, with: " ")   // another site's link says nothing about the code
        let bare = plain.filter { !$0.isWhitespace && $0 != "-" }
        if isCode(bare[...]) { return .code(bare.uppercased()) }
        if let m = plain.firstMatch(of: /(?i)\bcode\b\W{0,3}(?:is\W{1,3})?([A-Za-z0-9]{4})\b/) { return .code(String(m.1).uppercased()) }
        for w in plain.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        where w.count == 4 && w.allSatisfy(alphabet.contains) && w.contains(where: \.isNumber) {
            return .code(String(w))
        }
        return nil
    }
}
