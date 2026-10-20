import Foundation

/* Advanced search (contract/library-polish-2026-10-19.md § Advanced search): Scryfall's query syntax in every Add
   cards search. A plain name is the usual name search. A query with syntax runs on the local card data when every
   key it uses is one the pack carries (name, type, colors, mana value, mana cost, rarity, set, collector number,
   year, language, finish, format legality, mana produced); anything else (card text, power, artist, …) is sent to
   Scryfall's search API and the hits are matched back to the local data by printing id. Cases shared with web and
   Android: testdata/card-query/cases.json. */

enum CardQuery {
    struct Term: Hashable {
        /// Lowercased key; "" for a bare word (the card's name).
        let key: String
        /// ":", "=", "!=", "<", ">", "<=", ">=".
        let op: String
        let value: String
        /// `!"Name"`: the whole name, not a part of it.
        var exact = false
    }

    indirect enum Node: Hashable {
        case and([Node])
        case or([Node])
        case not(Node)
        case term(Term)
    }

    // MARK: parsing

    private enum Token: Equatable { case open, close, or, neg, term(Term) }

    /// True when the query uses any syntax (a key, an operator, a quote, a minus, parentheses or "or"); a plain name
    /// goes to the ranked name search instead.
    static func hasSyntax(_ q: String) -> Bool {
        guard let tokens = tokenize(q) else { return true }
        return tokens.contains { t in
            if case .term(let term) = t { return !term.key.isEmpty || term.exact || term.value.contains(" ") }
            return true
        }
    }

    static func parse(_ q: String) -> Node? {
        guard let tokens = tokenize(q), !tokens.isEmpty else { return nil }
        var i = 0
        func orExpr() -> Node? {
            var parts: [Node] = []
            guard let first = andExpr() else { return nil }
            parts.append(first)
            while i < tokens.count, tokens[i] == .or {
                i += 1
                guard let next = andExpr() else { return nil }
                parts.append(next)
            }
            return parts.count == 1 ? parts[0] : .or(parts)
        }
        func andExpr() -> Node? {
            var parts: [Node] = []
            while i < tokens.count, tokens[i] != .or, tokens[i] != .close {
                guard let u = unary() else { return nil }
                parts.append(u)
            }
            if parts.isEmpty { return nil }
            return parts.count == 1 ? parts[0] : .and(parts)
        }
        func unary() -> Node? {
            guard i < tokens.count else { return nil }
            switch tokens[i] {
            case .neg:
                i += 1
                return unary().map { .not($0) }
            case .open:
                i += 1
                guard let inner = orExpr(), i < tokens.count, tokens[i] == .close else { return nil }
                i += 1
                return inner
            case .term(let t):
                i += 1
                return .term(t)
            case .close, .or:
                return nil
            }
        }
        guard let node = orExpr(), i == tokens.count else { return nil }
        return node
    }

    private static let ops = ["!=", "<=", ">=", ":", "=", "<", ">"]

    private static func tokenize(_ q: String) -> [Token]? {
        let chars = Array(q)
        var out: [Token] = []
        var i = 0
        func readValue() -> String? {
            if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                let quote = chars[i]
                i += 1
                var v = ""
                while i < chars.count, chars[i] != quote { v.append(chars[i]); i += 1 }
                guard i < chars.count else { return nil }
                i += 1
                return v
            }
            var v = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "(", chars[i] != ")" { v.append(chars[i]); i += 1 }
            return v
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "(" { out.append(.open); i += 1; continue }
            if c == ")" { out.append(.close); i += 1; continue }
            if c == "-", i + 1 < chars.count, !chars[i + 1].isWhitespace { out.append(.neg); i += 1; continue }
            if c == "!" {
                i += 1
                guard let v = readValue(), !v.isEmpty else { return nil }
                out.append(.term(Term(key: "", op: ":", value: v, exact: true)))
                continue
            }
            if c == "\"" || c == "'" {
                guard let v = readValue() else { return nil }
                if !v.isEmpty { out.append(.term(Term(key: "", op: ":", value: v))) }
                continue
            }
            // A key is letters followed by an operator; otherwise the word is part of the name.
            var j = i
            while j < chars.count, chars[j].isLetter { j += 1 }
            if j > i, let op = ops.first(where: { op in
                let o = Array(op)
                return j + o.count <= chars.count && Array(chars[j..<(j + o.count)]) == o
            }) {
                let key = String(chars[i..<j]).lowercased()
                // Not a key Scryfall knows ("Circle of Protection: Red"): part of the name.
                guard knownKeys.contains(key) else {
                    if let word = readValue(), !word.isEmpty { out.append(.term(Term(key: "", op: ":", value: word))) }
                    continue
                }
                i = j + op.count
                guard let v = readValue() else { return nil }
                out.append(.term(Term(key: key, op: op, value: v)))
                continue
            }
            guard let word = readValue(), !word.isEmpty else { i += 1; continue }
            switch word.lowercased() {
            case "or": out.append(.or)
            case "and": break // the default between terms
            default: out.append(.term(Term(key: "", op: ":", value: word)))
            }
        }
        return out
    }

    // MARK: what runs locally

    private static let nameKeys: Set = ["", "name", "n"]
    private static let typeKeys: Set = ["t", "type"]
    private static let colorKeys: Set = ["c", "color", "colors"]
    private static let mvKeys: Set = ["mv", "cmc", "manavalue"]
    private static let manaKeys: Set = ["m", "mana"]
    private static let rarityKeys: Set = ["r", "rarity"]
    private static let setKeys: Set = ["s", "set", "e", "edition"]
    private static let cnKeys: Set = ["cn", "number"]
    private static let langKeys: Set = ["lang", "language"]
    private static let legalKeys: Set = ["f", "format", "legal"]
    private static let printingKeys = rarityKeys.union(setKeys).union(cnKeys).union(langKeys).union(["year", "date", "is"])

    private static let formats: Set = Set(CatalogPack.legalityFormats + ["canlander"])

    /// Every key Scryfall's syntax has (local or not); any other "word:" is part of a card name.
    private static let knownKeys: Set<String> = nameKeys.subtracting([""]).union(typeKeys).union(colorKeys).union(mvKeys)
        .union(manaKeys).union(printingKeys).union(legalKeys).union(["banned", "restricted", "produces",
        "o", "oracle", "fo", "fulloracle", "pow", "power", "tou", "toughness", "pt", "powtou", "loy", "loyalty", "def", "defense",
        "id", "identity", "ci", "commander", "kw", "keyword", "a", "artist", "ft", "flavor", "wm", "watermark", "border",
        "frame", "game", "in", "st", "art", "atag", "otag", "function", "devotion", "usd", "eur", "tix", "prints", "sets",
        "papersets", "cube", "block", "b", "new", "not", "has", "include", "layout", "stamp", "unique", "order", "prefer",
        "direction", "lore", "hand", "life", "paper"])

    /// Whether the local data can answer this term.
    static func isLocal(_ t: Term) -> Bool {
        let k = t.key, v = t.value.lowercased()
        if nameKeys.contains(k) || typeKeys.contains(k) || setKeys.contains(k) || langKeys.contains(k) { return !v.isEmpty }
        if colorKeys.contains(k) { return colorSet(v) != nil || Int(v) != nil }
        if mvKeys.contains(k) { return Double(v) != nil || v == "even" || v == "odd" }
        if manaKeys.contains(k) { return !manaSymbols(v).isEmpty }
        if rarityKeys.contains(k) { return rarityRank(v) != nil }
        if cnKeys.contains(k) { return !v.isEmpty }
        if k == "year" { return Int(v) != nil }
        if k == "date" { return v.count == 10 }
        if k == "is" { return ["foil", "nonfoil", "etched"].contains(v) }
        if legalKeys.contains(k) || k == "banned" || k == "restricted" { return formats.contains(v) }
        if k == "produces" { return colorSet(v) != nil }
        return false
    }

    static func isLocal(_ n: Node) -> Bool {
        switch n {
        case .and(let xs), .or(let xs): xs.allSatisfy(isLocal)
        case .not(let x): isLocal(x)
        case .term(let t): isLocal(t)
        }
    }

    /// Whether any term is about a printing (set, rarity, year, …): those match card by card's printings.
    static func usesPrinting(_ n: Node) -> Bool {
        switch n {
        case .and(let xs), .or(let xs): xs.contains(where: usesPrinting)
        case .not(let x): usesPrinting(x)
        case .term(let t): printingKeys.contains(t.key)
        }
    }

    /// The name words the query asks for (not negated), for ranking.
    static func nameWords(_ n: Node) -> [String] {
        switch n {
        case .and(let xs), .or(let xs): xs.flatMap(nameWords)
        case .not: []
        case .term(let t): nameKeys.contains(t.key) ? [t.value] : []
        }
    }

    // MARK: matching

    static func matches(_ n: Node, _ o: CatalogOracle, _ p: CatalogPrinting?) -> Bool {
        switch n {
        case .and(let xs): xs.allSatisfy { matches($0, o, p) }
        case .or(let xs): xs.contains { matches($0, o, p) }
        case .not(let x): !matches(x, o, p)
        case .term(let t): matches(t, o, p)
        }
    }

    static func matches(_ t: Term, _ o: CatalogOracle, _ p: CatalogPrinting?) -> Bool {
        let k = t.key, v = t.value.lowercased()
        if nameKeys.contains(k) {
            let name = CardName.norm(o.name), q = CardName.norm(t.value)
            return t.exact ? name == q || o.name.lowercased().components(separatedBy: " // ").contains(t.value.lowercased()) : name.contains(q)
        }
        if typeKeys.contains(k) { return CardName.norm(o.typeLine).contains(CardName.norm(t.value)) }
        if colorKeys.contains(k) || k == "produces" {
            let have = Set(k == "produces" ? (o.produced ?? "").uppercased().filter { "WUBRGC".contains($0) } : o.colors.uppercased().filter { "WUBRG".contains($0) })
            if let n = Int(v), k != "produces" { return compare(Double(have.count), t.op, Double(n)) }
            guard let want = colorSet(v) else { return false }
            switch want {
            case .colorless: return t.op == "!=" ? !have.isEmpty : have.isEmpty
            case .multicolor: return t.op == "!=" ? have.count < 2 : have.count >= 2
            case .colors(let w):
                switch t.op {
                case "=": return have == w
                case "!=": return have != w
                case "<=": return have.isSubset(of: w)
                case "<": return have.isStrictSubset(of: w)
                case ">": return have.isStrictSuperset(of: w)
                default: return have.isSuperset(of: w) // ":" and ">=": at least these
                }
            }
        }
        if mvKeys.contains(k) {
            if v == "even" { return Int(o.cmc) % 2 == 0 }
            if v == "odd" { return Int(o.cmc) % 2 == 1 }
            return Double(v).map { compare(o.cmc, t.op, $0) } ?? false
        }
        if manaKeys.contains(k) {
            let want = manaSymbols(v), have = manaSymbols(o.manaCost.lowercased())
            func counts(_ xs: [String]) -> [String: Int] { xs.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
            let w = counts(want), h = counts(have)
            if t.op == "=" { return w == h }
            if t.op == "!=" { return w != h }
            return w.allSatisfy { (h[$0.key] ?? 0) >= $0.value }
        }
        if legalKeys.contains(k) { return ["legal", "restricted"].contains(o.legality(v) ?? "") }
        if k == "banned" { return o.legality(v) == "banned" }
        if k == "restricted" { return o.legality(v) == "restricted" }
        guard let p else { return false }
        if rarityKeys.contains(k) {
            guard let have = rarityRank(p.rarity), let want = rarityRank(v) else { return false }
            return compare(Double(have), t.op, Double(want))
        }
        if setKeys.contains(k) { return t.op == "!=" ? p.set.lowercased() != v : p.set.lowercased() == v }
        if cnKeys.contains(k) {
            if ["<", ">", "<=", ">="].contains(t.op), let a = Int(p.cn.filter(\.isNumber)), let b = Int(v) { return compare(Double(a), t.op, Double(b)) }
            return t.op == "!=" ? p.cn.lowercased() != v : p.cn.lowercased() == v
        }
        if langKeys.contains(k) { return t.op == "!=" ? p.lang != v : p.lang == v }
        if k == "year" { return Int(p.releasedAt.prefix(4)).map { compare(Double($0), t.op, Double(v) ?? 0) } ?? false }
        if k == "date" {
            let d = String(p.releasedAt.prefix(10))
            switch t.op {
            case "<": return d < v
            case ">": return d > v
            case "<=": return d <= v
            case ">=": return d >= v
            case "!=": return d != v
            default: return d == v
            }
        }
        if k == "is" { return p.finishList.contains { $0.rawValue == v } }
        return false
    }

    private static func compare(_ a: Double, _ op: String, _ b: Double) -> Bool {
        switch op {
        case "<": a < b
        case ">": a > b
        case "<=": a <= b
        case ">=": a >= b
        case "!=": a != b
        default: a == b
        }
    }

    enum ColorWant: Equatable { case colors(Set<Character>), colorless, multicolor }

    private static let colorNames: [String: String] = [
        "white": "W", "blue": "U", "black": "B", "red": "R", "green": "G",
        "azorius": "WU", "dimir": "UB", "rakdos": "BR", "gruul": "RG", "selesnya": "GW",
        "orzhov": "WB", "izzet": "UR", "golgari": "BG", "boros": "RW", "simic": "GU",
        "bant": "GWU", "esper": "WUB", "grixis": "UBR", "jund": "BRG", "naya": "RGW",
        "abzan": "WBG", "jeskai": "URW", "sultai": "BGU", "mardu": "RWB", "temur": "GUR",
    ]

    static func colorSet(_ v: String) -> ColorWant? {
        let v = v.lowercased()
        if v == "c" || v == "colorless" { return .colorless }
        if v == "m" || v == "multicolor" { return .multicolor }
        if let named = colorNames[v] { return .colors(Set(named)) }
        let letters = v.uppercased()
        guard !letters.isEmpty, letters.allSatisfy({ "WUBRG".contains($0) }) else { return nil }
        return .colors(Set(letters))
    }

    /// Mana symbols as lowercased strings without braces: "{2}{R}{R}" and "2rr" both read as ["2", "r", "r"].
    static func manaSymbols(_ v: String) -> [String] {
        var out: [String] = []
        let chars = Array(v.lowercased())
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                var s = ""
                i += 1
                while i < chars.count, chars[i] != "}" { s.append(chars[i]); i += 1 }
                i += 1
                if !s.isEmpty { out.append(s) }
            } else if chars[i].isNumber {
                var s = ""
                while i < chars.count, chars[i].isNumber { s.append(chars[i]); i += 1 }
                out.append(s)
            } else if "wubrgcxs".contains(chars[i]) {
                out.append(String(chars[i]))
                i += 1
            } else {
                return []
            }
        }
        return out
    }

    private static func rarityRank(_ v: String) -> Int? {
        switch v.lowercased() {
        case "c", "common": 0
        case "u", "uncommon": 1
        case "r", "rare": 2
        case "m", "mythic": 3
        case "s", "special": 4
        case "b", "bonus": 5
        default: nil
        }
    }
}

/// Runs a search for an Add cards screen: the ranked name search, the local advanced search, or Scryfall.
enum CardSearchEngine {
    struct Result: Sendable {
        var hits: [CatalogOracle] = []
        /// The printing each hit shows (and adds): the one a set/rarity/year term matched, else the card's cover.
        var covers: [Int: CatalogPrinting] = [:]
        var total = 0
        var remote = false
        var error: String?
    }

    static let limit = 200

    /// Delay before running: typing settles faster for local searches than for a request to Scryfall.
    static func debounce(_ q: String) -> Duration {
        guard CardQuery.hasSyntax(q) else { return .milliseconds(120) }
        return CardQuery.parse(q).map(CardQuery.isLocal) == true ? .milliseconds(150) : .milliseconds(450)
    }

    static func run(_ q: String, _ db: CatalogDB) async -> Result {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard CardQuery.hasSyntax(trimmed) else {
            let hits = db.search(trimmed)
            return Result(hits: hits, covers: db.covers(oracleIdxs: hits.map(\.idx)), total: hits.count)
        }
        if let node = CardQuery.parse(trimmed), CardQuery.isLocal(node) { return local(node, db) }
        return await scryfall(trimmed, node: CardQuery.parse(trimmed), db)
    }

    static func local(_ node: CardQuery.Node, _ db: CatalogDB) -> Result {
        let oracles = db.allOracles()
        var found: [CatalogOracle] = []
        var covers: [Int: CatalogPrinting] = [:]
        if CardQuery.usesPrinting(node) {
            let byIdx = Dictionary(oracles.map { ($0.idx, $0) }, uniquingKeysWith: { a, _ in a })
            var best: [Int: CatalogPrinting] = [:]
            for p in db.allPrintings() {
                guard let o = byIdx[p.oracleIdx], CardQuery.matches(node, o, p) else { continue }
                if let b = best[o.idx] {
                    // Prefer English with an image, then the original printing, then newest (pack order).
                    func score(_ x: CatalogPrinting) -> Int { (x.lang == "en" && x.imageFaces > 0 ? 2 : 0) + (x.original ? 1 : 0) }
                    if score(p) > score(b) { best[o.idx] = p }
                } else {
                    best[o.idx] = p
                    found.append(o)
                }
            }
            covers = best
        } else {
            found = oracles.filter { CardQuery.matches(node, $0, nil) }
        }
        let words = CardQuery.nameWords(node).joined(separator: " ")
        var ordered = found.sorted { $0.name < $1.name }
        if CardName.norm(words).count >= 2 {
            let ranked = CatalogPack.rank(found.map { .init(idx: $0.idx, norm: $0.norm, type: $0.typeLine, printings: $0.printings) },
                                          query: words, limit: found.count)
            let byIdx = Dictionary(found.map { ($0.idx, $0) }, uniquingKeysWith: { a, _ in a })
            let rankedHits = ranked.compactMap { byIdx[$0] }
            let rest = ordered.filter { o in !ranked.contains(o.idx) }
            ordered = rankedHits + rest
        }
        let shown = Array(ordered.prefix(limit))
        if covers.isEmpty { covers = db.covers(oracleIdxs: shown.map(\.idx)) }
        return Result(hits: shown, covers: covers, total: found.count)
    }

    private struct Page: Decodable {
        struct Card: Decodable { let id: String; let oracleId: String? }
        let totalCards: Int?
        let data: [Card]?
        let details: String?
        let status: Int?
    }

    /// Scryfall's /cards/search (one card per Oracle card, by name), matched to the local data by printing id.
    static func scryfall(_ q: String, node: CardQuery.Node?, _ db: CatalogDB) async -> Result {
        var comps = URLComponents(string: "https://api.scryfall.com/cards/search")!
        comps.queryItems = [.init(name: "q", value: q), .init(name: "unique", value: "cards"), .init(name: "order", value: "name")]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.setValue("Table1/1.0 (table-1.site)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            let page = try dec.decode(Page.self, from: data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 404 { return Result(remote: true) }
            if status != 200 { return Result(remote: true, error: page.details ?? "Scryfall couldn't read that search (\(status))") }
            let cards = page.data ?? []
            let printings = db.printings(ids: cards.map { $0.id.lowercased() })
            var idxs: [Int] = []
            var shownPrinting: [Int: CatalogPrinting] = [:]
            for c in cards {
                if let p = printings[c.id.lowercased()] {
                    if shownPrinting[p.oracleIdx] == nil { idxs.append(p.oracleIdx); shownPrinting[p.oracleIdx] = p }
                } else if let oid = c.oracleId, let o = db.oracle(id: oid.lowercased()), !idxs.contains(o.idx) {
                    idxs.append(o.idx)
                }
            }
            let oracles = db.oracles(idxs: idxs)
            let hits = idxs.compactMap { oracles[$0] }.prefix(limit)
            // Scryfall's printing only when the query names one (a set, a year, …); otherwise the usual cover.
            let usePrinting = node.map(CardQuery.usesPrinting) ?? true
            var covers = db.covers(oracleIdxs: hits.map(\.idx))
            if usePrinting { for (k, p) in shownPrinting { covers[k] = p } }
            return Result(hits: Array(hits), covers: covers, total: page.totalCards ?? hits.count, remote: true)
        } catch is CancellationError {
            return Result(remote: true)
        } catch {
            if (error as? URLError)?.code == .cancelled { return Result(remote: true) }
            return Result(remote: true, error: "Searching card text needs a connection to Scryfall.")
        }
    }
}

/// The Advanced search form's fields; `query` writes them as Scryfall syntax into the search box.
struct AdvancedSearchFields: Equatable {
    enum ColorMode: String, CaseIterable { case exactly, including, atMost }
    var name = ""
    var text = ""
    var type = ""
    var colors: Set<Character> = [] // WUBRG, or C for colorless
    var colorMode = ColorMode.including
    var mvOp = "="
    var mv = ""
    var rarities: Set<Character> = [] // c u r m
    var set = ""
    var format = ""

    var query: String {
        func quoted(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            return t.contains(" ") ? "\"\(t)\"" : t
        }
        var parts: [String] = []
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { parts.append(n) }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("o:\(quoted(text))") }
        for word in type.split(separator: " ") where !word.isEmpty { parts.append("t:\(word.lowercased())") }
        if colors.contains("C") {
            parts.append("c:c")
        } else if !colors.isEmpty {
            let letters = String("WUBRG".filter(colors.contains)).lowercased()
            parts.append("c\(colorMode == .exactly ? "=" : colorMode == .atMost ? "<=" : ">=")\(letters)")
        }
        if let v = Double(mv.replacingOccurrences(of: ",", with: ".")) {
            let num = v == v.rounded() ? String(Int(v)) : String(v)
            parts.append("mv\(mvOp == "=" ? "=" : mvOp)\(num)")
        }
        let r = "curm".filter(rarities.contains).map { "r:\($0)" }
        if r.count == 1 { parts.append(r[0]) } else if r.count > 1 { parts.append("(\(r.joined(separator: " or ")))") }
        let s = set.trimmingCharacters(in: .whitespaces).lowercased()
        if !s.isEmpty { parts.append("s:\(s)") }
        if !format.isEmpty { parts.append("f:\(format)") }
        return parts.joined(separator: " ")
    }
}
