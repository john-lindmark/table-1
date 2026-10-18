import Foundation

// Collection CSV import and export (contract/collection-import-2026-10-17.md). CollectionCSV reads another app's
// export into rows (format detection, columns, each app's words for finish, condition and language) and writes the
// collection in Moxfield's or ManaBox's layout. ImportResolver matches rows to printings in the local catalog.
// Same rules as table-1-events-web/src/lib/collectionCsv.ts; the fixtures in testdata/collection-import test both.

enum CSVFormat: String, CaseIterable, Sendable {
    case manabox, moxfield, archidekt, deckbox, dragonshield, tcgplayer, delverlens, other

    var label: String {
        switch self {
        case .manabox: "ManaBox"
        case .moxfield: "Moxfield"
        case .archidekt: "Archidekt"
        case .deckbox: "Deckbox"
        case .dragonshield: "Dragon Shield"
        case .tcgplayer: "TCGplayer"
        case .delverlens: "Delver Lens"
        case .other: "CSV"
        }
    }

    /// ManaBox and Dragon Shield grade on Cardmarket's scale (Excellent, Good, Light played, Played, Poor).
    var cardmarketScale: Bool { self == .manabox || self == .dragonshield }
}

/// One line of an imported file, its values already mapped to ours.
struct ImportRow: Hashable, Sendable {
    /// 1-based line number in the file.
    let line: Int
    var name: String
    /// Lowercased.
    var setCode: String?
    var setName: String?
    var cn: String?
    var scryfallId: String?
    var qty: Int
    var finish: String
    var condition: String
    var lang: String
    /// Why the line can't be read at all (it's listed as unmatched).
    var problem: String?

    var setLabel: String {
        [setCode?.uppercased() ?? setName, cn.map { "#\($0)" }].compactMap { $0 }.joined(separator: " ")
    }
}

struct ParsedImport: Sendable {
    let format: CSVFormat
    let rows: [ImportRow]
}

enum CollectionCSV {
    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: reading

    static func parse(_ text: String) throws -> ParsedImport {
        var bytes = Array(text.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var start = 0
        var line = 1
        var delimiter: UInt8?
        // Dragon Shield and Excel: a first line `sep=,` names the delimiter.
        let firstEnd = bytes.firstIndex(of: 0x0A) ?? bytes.count
        let first = String(decoding: bytes[0..<firstEnd], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\r ")).lowercased()
        if first.hasPrefix("sep="), first.count == 5 {
            delimiter = first.utf8.last
            start = min(firstEnd + 1, bytes.count)
            line = 2
        }
        let sepLine = delimiter != nil
        let d = delimiter ?? guessDelimiter(bytes[start...])
        let records = Self.records(bytes[start...], delimiter: d, firstLine: line)
        guard let header = records.first else { throw Failure(message: "This file is empty.") }
        let keys = header.fields.map(headerKey)
        let format = detect(Set(keys), sepLine: sepLine)
        let cols = Columns(keys, format)
        guard cols.name != nil || cols.id != nil else { throw Failure(message: "This file has no card name column.") }

        var rows: [ImportRow] = []
        rows.reserveCapacity(records.count)
        for r in records.dropFirst() {
            func at(_ i: Int?) -> String {
                guard let i, i < r.fields.count else { return "" }
                return r.fields[i].trimmingCharacters(in: .whitespaces)
            }
            let name = at(cols.name), id = at(cols.id)
            if name.isEmpty && id.isEmpty { continue }
            var problem: String?
            var qty = 1
            if cols.qty != nil {
                if let q = quantity(at(cols.qty)) { qty = q } else { problem = "Quantity isn't a number" }
            }
            if qty == 0 && problem == nil { continue }
            var finish = Self.finish(at(cols.finish))
            var rawCondition = at(cols.condition)
            // TCGplayer seller exports grade foils as "Near Mint Foil"; its app marks etched in the name.
            if rawCondition.lowercased().hasSuffix(" foil") {
                rawCondition = String(rawCondition.dropLast(5))
                if finish == "nonfoil" { finish = "foil" }
            }
            if format == .tcgplayer, at(cols.fullName).lowercased().contains("etched") { finish = "etched" }
            var setCode = at(cols.setCode).lowercased()
            if format == .dragonshield, let m = setCode.range(of: #"^gk[12]_"#, options: .regularExpression) {
                setCode = String(setCode[m].dropLast()) // GK2_AZORIU → gk2
            }
            var setName = at(cols.setName)
            if cols.setEither != nil {
                let v = at(cols.setEither)
                if setCode.isEmpty { setCode = v.lowercased() }
                if setName.isEmpty { setName = v }
            }
            var cn = at(cols.cn)
            if let slash = cn.firstIndex(of: "/") { cn = String(cn[..<slash]) }
            rows.append(ImportRow(
                line: r.line, name: name, setCode: setCode.isEmpty ? nil : setCode, setName: setName.isEmpty ? nil : setName,
                cn: cn.isEmpty ? nil : cn, scryfallId: id.isEmpty ? nil : id.lowercased(), qty: qty, finish: finish,
                condition: condition(rawCondition, cardmarket: format.cardmarketScale), lang: language(at(cols.lang)),
                problem: problem))
        }
        return ParsedImport(format: format, rows: rows)
    }

    /// Lowercase, letters and digits only: `Collector's number` → `collectorsnumber`.
    static func headerKey(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }))
    }

    static func detect(_ h: Set<String>, sepLine: Bool = false) -> CSVFormat {
        if h.contains("quantityx") || h.contains("delverlocalid") { return .delverlens }
        if (h.contains("foldername") && h.contains("cardname")) || (sepLine && h.contains("tradequantity")) { return .dragonshield }
        if h.contains("simplename") || (h.contains("tcgplayerid") && h.contains("productname")) { return .tcgplayer }
        if h.contains("manaboxid") || h.contains("bindertype") || h.contains("purchasepricecurrency") { return .manabox }
        if (h.contains("editioncode") && h.contains("editionname")) || (h.contains("dateadded") && h.contains("finish")) { return .archidekt }
        if h.contains("tradelistcount") && h.contains("cardnumber") { return .deckbox }
        if h.contains("tradelistcount") && h.contains("edition") { return .moxfield }
        return .other
    }

    /// Which column holds what, by format (contract table "Columns").
    private struct Columns {
        var name, fullName, qty, setCode, setName, setEither, cn, finish, condition, lang, id: Int?

        init(_ keys: [String], _ format: CSVFormat) {
            func col(_ names: [String]) -> Int? {
                for n in names { if let i = keys.firstIndex(of: n) { return i } }
                return nil
            }
            name = col(format == .tcgplayer ? ["simplename", "productname", "name"] : ["name", "cardname", "card", "simplename", "productname"])
            fullName = col(["name", "productname"])
            qty = col(["quantity", "count", "qty", "quantityx", "totalquantity", "amount"])
            switch format {
            case .moxfield:
                setCode = col(["edition", "setcode", "editioncode"])
                setName = col(["setname", "editionname"])
            case .deckbox, .delverlens:
                setCode = col(["editioncode", "setcode"])
                setName = col(["edition", "editionname", "setname"])
            case .tcgplayer:
                setCode = col(["setcode"])
                setName = col(["set", "setname"])
            default:
                setCode = col(["setcode", "editioncode", "code"])
                setName = col(["setname", "editionname", "expansion"])
                if setCode == nil || setName == nil { setEither = col(["set", "edition"]) }
            }
            cn = col(["collectornumber", "cardnumber", "collectorsnumber", "number", "cn", "collectorno"])
            finish = col(["foil", "finish", "printing", "foiling"])
            condition = col(["condition"])
            lang = col(["language", "lang"])
            id = col(["scryfallid", "scryfalluuid"])
        }
    }

    /// `2x` → 2, blank → 1, not a number → nil.
    static func quantity(_ v: String) -> Int? {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 1 }
        let digits = t.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty, t.lowercased().allSatisfy({ $0.isNumber || $0 == "x" || $0 == " " }) else { return nil }
        return Int(digits.prefix(9))
    }

    static func finish(_ v: String) -> String {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        if s.contains("etched") { return "etched" }
        if ["", "normal", "nonfoil", "non-foil", "non foil", "no", "false", "0", "n", "regular"].contains(s) { return "nonfoil" }
        if s.contains("foil") || ["true", "yes", "1", "y"].contains(s) { return "foil" }
        return "nonfoil"
    }

    private static let usConditions: [String: String] = [
        "m": "NM", "mint": "NM", "nm": "NM", "nearmint": "NM", "nmm": "NM",
        "lp": "LP", "lightlyplayed": "LP", "goodlightlyplayed": "LP", "slightlyplayed": "LP", "sp": "LP",
        "ex": "LP", "excellent": "LP", "good": "LP", "gd": "LP", "lightplayed": "LP",
        "mp": "MP", "moderatelyplayed": "MP", "played": "MP", "pl": "MP",
        "hp": "HP", "heavilyplayed": "HP",
        "d": "DMG", "dmg": "DMG", "damaged": "DMG", "poor": "DMG", "po": "DMG",
    ]
    private static let cardmarketConditions: [String: String] = [
        "m": "NM", "mint": "NM", "nm": "NM", "nearmint": "NM",
        "ex": "LP", "excellent": "LP", "gd": "LP", "good": "LP",
        "lp": "MP", "lightplayed": "MP", "lightlyplayed": "MP",
        "pl": "HP", "played": "HP",
        "po": "DMG", "poor": "DMG",
    ]

    static func condition(_ v: String, cardmarket: Bool) -> String {
        let k = headerKey(v)
        return (cardmarket ? cardmarketConditions[k] : nil) ?? usConditions[k] ?? "NM"
    }

    private static let languages: [String: String] = [
        "en": "en", "english": "en", "de": "de", "german": "de", "deutsch": "de", "fr": "fr", "french": "fr",
        "it": "it", "italian": "it", "es": "es", "sp": "es", "spanish": "es", "pt": "pt", "ptbr": "pt", "portuguese": "pt",
        "portuguesebrazil": "pt", "ja": "ja", "jp": "ja", "japanese": "ja", "ko": "ko", "kr": "ko", "korean": "ko",
        "ru": "ru", "russian": "ru", "zhs": "zhs", "zhcn": "zhs", "zhhans": "zhs", "cs": "zhs", "chinese": "zhs",
        "chinesesimplified": "zhs", "simplifiedchinese": "zhs", "zht": "zht", "zhtw": "zht", "zhhant": "zht", "ct": "zht",
        "chinesetraditional": "zht", "traditionalchinese": "zht", "he": "he", "hebrew": "he", "la": "la", "latin": "la",
        "grc": "grc", "ancientgreek": "grc", "ar": "ar", "arabic": "ar", "sa": "sa", "sanskrit": "sa", "ph": "ph",
        "phyrexian": "ph", "qya": "qya", "quenya": "qya",
    ]

    static func language(_ v: String) -> String { languages[headerKey(v)] ?? "en" }

    /// The delimiter that appears most in the first line, outside quotes.
    static func guessDelimiter(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var counts: [UInt8: Int] = [0x2C: 0, 0x09: 0, 0x3B: 0]
        var quoted = false
        for b in bytes {
            if b == 0x0A && !quoted { break }
            if b == 0x22 { quoted.toggle() } else if !quoted, counts[b] != nil { counts[b]! += 1 }
        }
        return [0x2C, 0x09, 0x3B].max { counts[$0]! < counts[$1]! }!
    }

    struct Record {
        let line: Int
        let fields: [String]
    }

    /// RFC 4180 records over UTF-8 bytes (quotes, `""`, newlines in quotes, CRLF or LF), each with its first line number.
    static func records(_ bytes: ArraySlice<UInt8>, delimiter: UInt8, firstLine: Int = 1) -> [Record] {
        var out: [Record] = []
        var fields: [String] = []
        var field: [UInt8] = []
        var quoted = false, wasQuoted = false
        var line = firstLine, recordLine = firstLine
        var i = bytes.startIndex
        func endField() {
            var f = field[...]
            if !wasQuoted, f.last == 0x0D { f = f.dropLast() }
            fields.append(String(decoding: f, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            wasQuoted = false
        }
        func endRecord() {
            endField()
            if !(fields.count == 1 && fields[0].isEmpty) { out.append(Record(line: recordLine, fields: fields)) }
            fields = []
        }
        while i < bytes.endIndex {
            let b = bytes[i]
            if quoted {
                if b == 0x22 {
                    if i + 1 < bytes.endIndex && bytes[i + 1] == 0x22 { field.append(0x22); i += 1 } else { quoted = false }
                } else {
                    if b == 0x0A { line += 1 }
                    field.append(b)
                }
            } else if b == 0x22 && field.isEmpty {
                quoted = true
                wasQuoted = true
            } else if b == delimiter {
                endField()
            } else if b == 0x0A {
                endRecord()
                line += 1
                recordLine = line
            } else if !(b == 0x0D && wasQuoted) {
                field.append(b)
            }
            i += 1
        }
        if !field.isEmpty || !fields.isEmpty { endRecord() }
        return out
    }

    // MARK: writing

    enum Layout: String, CaseIterable, Sendable {
        case moxfield, manabox
        var label: String { self == .moxfield ? "Moxfield" : "ManaBox" }
    }

    struct ExportCard: Sendable {
        let name: String
        let set: String
        let setName: String
        let cn: String
        let rarity: String
        let cardId: String
        let finish: String
        let condition: String
        let lang: String
        let qty: Int
    }

    private static let moxfieldConditions = ["NM": "Near Mint", "LP": "Lightly Played", "MP": "Moderately Played",
                                             "HP": "Heavily Played", "DMG": "Damaged"]
    private static let manaboxConditions = ["NM": "near_mint", "LP": "excellent", "MP": "light_played", "HP": "played", "DMG": "poor"]
    private static let languageNames = [
        "en": "English", "de": "German", "fr": "French", "it": "Italian", "es": "Spanish", "pt": "Portuguese",
        "ja": "Japanese", "ko": "Korean", "ru": "Russian", "zhs": "Chinese Simplified", "zht": "Chinese Traditional",
        "he": "Hebrew", "la": "Latin", "grc": "Ancient Greek", "ar": "Arabic", "sa": "Sanskrit", "ph": "Phyrexian", "qya": "Quenya",
    ]
    private static let rarities = ["c": "common", "u": "uncommon", "r": "rare", "m": "mythic", "s": "special", "b": "bonus"]

    /// Sorted by name, set and collector number; CRLF line ends.
    static func export(_ cards: [ExportCard], layout: Layout) -> String {
        let sorted = cards.sorted {
            ($0.name, $0.set, $0.cn.count, $0.cn, "\($0.finish)|\($0.condition)|\($0.lang)")
                < ($1.name, $1.set, $1.cn.count, $1.cn, "\($1.finish)|\($1.condition)|\($1.lang)")
        }
        var lines: [String] = []
        switch layout {
        case .moxfield:
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            lines.append(["Count", "Tradelist Count", "Name", "Edition", "Condition", "Language", "Foil", "Tags", "Last Modified",
                          "Collector Number", "Alter", "Proxy", "Purchase Price"].map(q).joined(separator: ","))
            for c in sorted {
                lines.append([String(c.qty), "0", c.name, c.set, moxfieldConditions[c.condition] ?? "Near Mint",
                              languageNames[c.lang] ?? "English", c.finish == "nonfoil" ? "" : c.finish, "", "", c.cn,
                              "False", "False", ""].map(q).joined(separator: ","))
            }
        case .manabox:
            func q(_ s: String) -> String {
                s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                    ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
            }
            lines.append("Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency")
            for c in sorted {
                lines.append([c.name, c.set.uppercased(), c.setName, c.cn, c.finish == "nonfoil" ? "normal" : c.finish,
                              rarities[c.rarity] ?? "common", String(c.qty), "", c.cardId, "", "false", "false",
                              manaboxConditions[c.condition] ?? "near_mint", c.lang, "USD"].map(q).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: matching

/// How a line found its printing (contract "Matching").
enum MatchHow: String, Sendable {
    case id, setNumber, setName, name, fixed
}

struct ResolvedLine: Hashable, Sendable {
    let row: ImportRow
    let printing: CatalogPrinting
    let finish: String
    let how: MatchHow
}

/// One collection item the import writes.
struct ImportItem: Hashable, Sendable {
    let cardId: String
    let finish: String
    let condition: String
    let lang: String
    var qty: Int
    var key: String { CollectionStore.key(cardId, finish, condition, lang) }
}

/// Matches imported rows to printings: Scryfall id, then set + collector number, then set + name, then the name's
/// original printing. Builds its name index once and loads each set's printings once, so a 20k-line file costs one
/// pass. Used from one task at a time.
final class ImportResolver: @unchecked Sendable {
    let db: CatalogDB
    /// Normalized set name → set code (mtg_sets).
    private let setByName: [String: String]
    private let setCodes: Set<String>
    private var byFullName: [String: Int] = [:]
    private var byFace: [String: Int] = [:]
    private var names: [Int: (norm: String, faces: [String])] = [:]
    private var sets: [String: (byCn: [String: [CatalogPrinting]], byOracle: [Int: [CatalogPrinting]])] = [:]
    private var originals: [Int: CatalogPrinting] = [:]
    private var byId: [String: CatalogPrinting] = [:]
    private var askedIds: Set<String> = []
    private var nameCache: [String: Int?] = [:]

    init(db: CatalogDB, setNames: [(code: String, name: String)]) {
        self.db = db
        setCodes = db.setCodes()
        var m: [String: String] = [:]
        for s in setNames { m[CardName.norm(s.name)] = m[CardName.norm(s.name)] ?? s.code }
        setByName = m
        // Two cards with one name: the non-token one with more printings.
        var rank: [Int: (Bool, Int)] = [:]
        func better(_ a: Int, than b: Int?) -> Bool {
            guard let b, let rb = rank[b], let ra = rank[a] else { return true }
            return ra.0 != rb.0 ? !ra.0 : ra.1 > rb.1
        }
        for o in db.importNames() {
            rank[o.idx] = (o.token, o.printings)
            let faces = o.faces.isEmpty ? [] : o.faces.components(separatedBy: " // ").map(CardName.norm)
            names[o.idx] = (o.norm, faces)
            if better(o.idx, than: byFullName[o.norm]) { byFullName[o.norm] = o.idx }
            for f in faces where better(o.idx, than: byFace[f]) { byFace[f] = o.idx }
        }
    }

    /// Matched lines in file order, and the rows that matched nothing.
    func resolve(_ rows: [ImportRow]) -> (matched: [ResolvedLine], unmatched: [ImportRow]) {
        loadIds(rows.compactMap(\.scryfallId))
        loadOriginals(Set(rows.compactMap { r in r.scryfallId.flatMap { byId[$0] } == nil ? oracle(named: r.name) : nil }))
        var matched: [ResolvedLine] = [], unmatched: [ImportRow] = []
        matched.reserveCapacity(rows.count)
        for r in rows {
            if let m = resolve(r) { matched.append(m) } else { unmatched.append(r) }
        }
        return (matched, unmatched)
    }

    func resolve(_ r: ImportRow) -> ResolvedLine? {
        if r.problem != nil { return nil }
        if let id = r.scryfallId {
            loadIds([id])
            if let p = byId[id] { return line(r, p, .id) }
        }
        let idx = oracle(named: r.name)
        for code in setCandidates(r) {
            let set = printings(set: code)
            if let cn = r.cn {
                for v in [cn, cn.lowercased(), String(cn.drop { $0 == "0" })] where !v.isEmpty {
                    let found = (set.byCn[v] ?? []).filter { p in idx == nil || r.name.isEmpty || matches(p.oracleIdx, r.name, idx) }
                    if let p = best(found, r.lang) { return line(r, p, .setNumber) }
                }
            }
            if let idx, let p = best(set.byOracle[idx] ?? [], r.lang) { return line(r, p, .setName) }
        }
        if let idx, let p = original(idx) { return line(r, p, .name) }
        return nil
    }

    /// A line fixed by hand: the picked card's printing in the line's set when it has one, else its original printing.
    func resolve(_ r: ImportRow, oracleIdx: Int) -> ResolvedLine? {
        var row = r
        row.problem = nil
        for code in setCandidates(row) {
            if let p = best(printings(set: code).byOracle[oracleIdx] ?? [], row.lang) { return line(row, p, .fixed) }
        }
        return original(oracleIdx).map { line(row, $0, .fixed) }
    }

    /// Lines on the same item summed, in first-seen order.
    static func items(_ lines: [ResolvedLine]) -> [ImportItem] {
        var order: [String] = []
        var by: [String: ImportItem] = [:]
        for l in lines {
            let it = ImportItem(cardId: l.printing.cardId, finish: l.finish, condition: l.row.condition, lang: l.row.lang, qty: l.row.qty)
            if by[it.key] == nil { order.append(it.key); by[it.key] = it } else { by[it.key]!.qty += it.qty }
        }
        return order.map { by[$0]! }
    }

    // MARK: lookups

    private func loadIds(_ ids: [String]) {
        // Filtered one by one: Set.subtracting walks the whole asked set, which is every id in the file.
        let fresh = Set(ids.filter { !askedIds.contains($0) })
        if fresh.isEmpty { return }
        askedIds.formUnion(fresh)
        for (id, p) in db.printings(ids: Array(fresh)) { byId[id] = p }
    }

    /// Exact name, then a face, then the name without a trailing `[…]`/`(…)` or ` Token`/` Emblem`.
    func oracle(named raw: String) -> Int? {
        if let hit = nameCache[raw] { return hit }
        let found = lookup(raw)
        nameCache[raw] = found
        return found
    }

    private func lookup(_ raw: String) -> Int? {
        let n = CardName.norm(raw)
        if n.isEmpty { return nil }
        if let i = byFullName[n] ?? byFace[n] { return i }
        var s = raw.trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: #"\s*[\[(][^\[\]()]*[\])]$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"\s+(token|emblem)$"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        let n2 = CardName.norm(s)
        return n2 == n || n2.isEmpty ? nil : byFullName[n2] ?? byFace[n2]
    }

    private func matches(_ oracleIdx: Int, _ name: String, _ nameIdx: Int?) -> Bool {
        if oracleIdx == nameIdx { return true }
        guard let o = names[oracleIdx] else { return false }
        let n = CardName.norm(name)
        return o.norm == n || o.faces.contains(n)
    }

    /// The set code if the catalog has it, else the set name's code (Deckbox token sets "Extras: X" → tX first).
    private func setCandidates(_ r: ImportRow) -> [String] {
        var out: [String] = []
        if let c = r.setCode, setCodes.contains(c) { out.append(c) }
        if let name = r.setName {
            var n = name
            var extras = false
            if n.lowercased().hasPrefix("extras:") { n = String(n.dropFirst(7)); extras = true }
            let k = CardName.norm(n)
            let code = setByName[k] ?? (setCodes.contains(n.lowercased()) ? n.lowercased() : nil)
                ?? (k.hasSuffix(" edition") ? setByName[String(k.dropLast(8))] : nil)
            if let code {
                if extras && setCodes.contains("t" + code) { out.append("t" + code) }
                if setCodes.contains(code) { out.append(code) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private func printings(set code: String) -> (byCn: [String: [CatalogPrinting]], byOracle: [Int: [CatalogPrinting]]) {
        if let s = sets[code] { return s }
        let all = db.printings(set: code)
        let s = (Dictionary(grouping: all, by: \.cn), Dictionary(grouping: all, by: \.oracleIdx))
        sets[code] = s
        return s
    }

    private func loadOriginals(_ idxs: Set<Int>) {
        let missing = idxs.filter { originals[$0] == nil }
        if missing.isEmpty { return }
        for (i, p) in db.covers(oracleIdxs: Array(missing)) { originals[i] = p }
    }

    private func original(_ idx: Int) -> CatalogPrinting? {
        if originals[idx] == nil { loadOriginals([idx]) }
        return originals[idx]
    }

    /// The copy's language printed, then English, then the original printing, then the lowest collector number.
    private func best(_ ps: [CatalogPrinting], _ lang: String) -> CatalogPrinting? {
        func num(_ p: CatalogPrinting) -> Int { Int(p.cn.prefix { $0.isNumber }) ?? Int.max }
        return ps.min { a, b in
            let ka = (a.lang == lang ? 0 : a.lang == "en" ? 1 : 2, a.original ? 0 : 1, num(a), a.ord)
            let kb = (b.lang == lang ? 0 : b.lang == "en" ? 1 : 2, b.original ? 0 : 1, num(b), b.ord)
            return ka < kb
        }
    }

    /// The file's finish when the printing has it; etched falls back to foil, then the printing's first finish.
    private func line(_ r: ImportRow, _ p: CatalogPrinting, _ how: MatchHow) -> ResolvedLine {
        let have = p.finishList.map(\.rawValue)
        let finish = have.contains(r.finish) ? r.finish : (r.finish == "etched" && have.contains("foil")) ? "foil" : have.first ?? "nonfoil"
        return ResolvedLine(row: r, printing: p, finish: finish, how: how)
    }
}
