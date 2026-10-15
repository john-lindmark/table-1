import Foundation

/* Scanner matching: OCR lines in, a card and printing out. Tuned against the photo test set in testdata/scan
   (README there; accuracy test in Table1Tests/CardMatcherTests.swift). Same rules on Android (CardMatcher.kt). */

/// Names the scanner can read, built once per catalog pack: each card's name and a split or double-faced card's
/// front face (tokens, art cards, emblems and Vanguard left out), its printed names in other languages (pack N
/// lines; never over an English name, and left out when two cards share one), with trigrams for misread names.
final class ScanNames: @unchecked Sendable {
    let version: String
    let sets: Set<String>
    /// Normalized names, sorted by UTF-8 bytes (cut-off names are looked up by prefix).
    private let keys: [String]
    private let idxs: [Int]
    private let byKey: [String: Int]
    /// Trigram → the keys containing it, as a range of `postings` (key positions, ascending).
    private let grams: [Int: Range<Int>]
    private let postings: [Int32]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: ScanNames?

    /// The index for this pack, built on first use (a few hundred milliseconds; call it off the main thread).
    static func shared(_ db: CatalogDB) -> ScanNames {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached, c.version == db.version { return c }
        let n = ScanNames(db)
        cached = n
        return n
    }

    init(_ db: CatalogDB) {
        version = db.version
        sets = db.setCodes()
        // printings -1 marks a printed name in another language; idx -1 one that two cards share.
        var best: [String: (idx: Int, printings: Int)] = [:]
        var scannable = Set<Int>()
        for o in db.scanNames() where o.printings > 0 && !Self.unscannable(o.typeLine) {
            var names = [o.norm]
            if let cut = o.name.range(of: " // ") {
                let front = CardName.norm(String(o.name[..<cut.lowerBound]))
                if front == CardName.norm(String(o.name[cut.upperBound...])) { continue } // an art card ("X // X")
                names.append(front)
            }
            scannable.insert(o.idx)
            for k in names where best[k].map({ o.printings > $0.printings }) ?? true { best[k] = (o.idx, o.printings) }
        }
        let foreign = db.scanForeignNames()
        best.reserveCapacity(best.count + foreign.count)
        for n in foreign where scannable.contains(n.idx) {
            if let b = best[n.norm] {
                if b.printings < 0 && b.idx != n.idx { best[n.norm] = (-1, -1) }
            } else {
                best[n.norm] = (n.idx, -1)
            }
        }
        // Byte order: the same as String's < for these normalized names, without its Unicode comparison.
        let sorted = best.filter { $0.value.idx >= 0 }.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        keys = sorted.map(\.key)
        idxs = sorted.map(\.value.idx)
        byKey = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        // Every (trigram, key position), keys in order; a stable radix sort on the 24-bit trigram then gives one
        // ascending posting list per trigram.
        var tri: [UInt32] = [], pos: [Int32] = []
        tri.reserveCapacity(keys.count * 20)
        pos.reserveCapacity(keys.count * 20)
        var codes: [Int] = []
        for (i, k) in keys.enumerated() {
            codes.removeAll(keepingCapacity: true)
            Self.trigrams(k, into: &codes)
            codes.sort()
            var last = -1
            for c in codes where c != last { tri.append(UInt32(c)); pos.append(Int32(i)); last = c }
        }
        for shift in [0, 12] as [UInt32] {
            var t2 = [UInt32](repeating: 0, count: tri.count), p2 = [Int32](repeating: 0, count: pos.count)
            Self.radixPass(tri, pos, shift, &t2, &p2)
            tri = t2; pos = p2
        }
        var g: [Int: Range<Int>] = [:]
        var start = 0
        for j in tri.indices where j + 1 == tri.count || tri[j + 1] != tri[j] {
            g[Int(tri[j])] = start..<(j + 1)
            start = j + 1
        }
        grams = g
        postings = pos
    }

    /// One stable counting-sort pass on 12 bits of the trigram. On raw buffers: Debug builds don't optimize array
    /// access, and this runs over ~3M entries.
    private static func radixPass(_ tri: [UInt32], _ pos: [Int32], _ shift: UInt32, _ t2: inout [UInt32], _ p2: inout [Int32]) {
        var count = [Int](repeating: 0, count: 4097)
        tri.withUnsafeBufferPointer { t in
            pos.withUnsafeBufferPointer { p in
                t2.withUnsafeMutableBufferPointer { ot in
                    p2.withUnsafeMutableBufferPointer { op in
                        count.withUnsafeMutableBufferPointer { c in
                            for v in t { c[Int(v >> shift & 0xFFF) + 1] += 1 }
                            for d in 1..<c.count { c[d] += c[d - 1] }
                            for j in 0..<t.count {
                                let d = Int(t[j] >> shift & 0xFFF)
                                ot[c[d]] = t[j]
                                op[c[d]] = p[j]
                                c[d] += 1
                            }
                        }
                    }
                }
            }
        }
    }

    private static func unscannable(_ typeLine: String) -> Bool {
        ["Token", "Card", "Emblem", "Vanguard"].contains { typeLine.hasPrefix($0) }
    }

    /// Byte trigrams of the name padded with a space each side.
    private static func trigrams(_ s: String, into out: inout [Int]) {
        var a = 32, b = -1
        for c in s.utf8 {
            if b >= 0 { out.append(a << 16 | b << 8 | Int(c)); a = b }
            b = Int(c)
        }
        if b >= 0 { out.append(a << 16 | b << 8 | 32) }
    }

    private static func trigrams(_ s: String) -> Set<Int> {
        var out: [Int] = []
        trigrams(s, into: &out)
        return Set(out)
    }

    func exact(_ q: String) -> Int? { byKey[q].map { idxs[$0] } }

    /// A name cut off at the edge of the frame: only one card has names starting with it (its English and printed
    /// names often share a start: "Urza's Saga", "Urzas Sage"), and it's most of one of them.
    func prefix(_ q: String) -> Int? {
        guard q.count >= (CardName.hasCJK(q) ? 4 : 8) else { return nil }
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid].utf8.lexicographicallyPrecedes(q.utf8) { lo = mid + 1 } else { hi = mid }
        }
        var hit: Int?, most = false
        for j in lo..<min(keys.count, lo + 16) {
            guard keys[j].hasPrefix(q) else { break }
            if let h = hit, h != idxs[j] { return nil }
            hit = idxs[j]
            if Double(q.count) >= 0.6 * Double(keys[j].count) { most = true }
        }
        return most ? hit : nil
    }

    /// A misread name: the closest name within about one edit in eight letters, if no other card's name is as close.
    /// Han, kana and Hangul carry more per character: four of them at least, and one edit in six, counted in
    /// characters rather than UTF-8 bytes.
    func fuzzy(_ q: String) -> Int? {
        let cjk = CardName.hasCJK(q)
        guard q.count >= (cjk ? 4 : 5), q.utf8.count < 250 else { return nil }
        let cap = max(1, q.count / (cjk ? 6 : 8))
        let tg = Self.trigrams(q)
        var shared = [UInt8](repeating: 0, count: keys.count)
        var touched: [Int] = []
        for t in tg {
            guard let r = grams[t] else { continue }
            for j in r {
                let i = Int(postings[j])
                if shared[i] == 0 { touched.append(i) }
                shared[i] &+= 1
            }
        }
        // The 60 names sharing the most trigrams, of those sharing at least 40%.
        let enough = (Double(tg.count) * 0.4).rounded(.up)
        let top = touched.filter { Double(shared[$0]) >= enough }
            .sorted { shared[$0] != shared[$1] ? shared[$0] > shared[$1] : $0 < $1 }.prefix(60)
        let target = cjk ? q.unicodeScalars.map(\.value) : q.utf8.map(UInt32.init)
        var best = (d: cap + 1, i: -1), second = cap + 1
        for i in top {
            let d = Self.distance(target, cjk ? keys[i].unicodeScalars.map(\.value) : keys[i].utf8.map(UInt32.init), cap: cap)
            let other = best.i < 0 || idxs[best.i] != idxs[i]
            if d < best.d { if other { second = best.d }; best = (d, i) } else if d < second && other { second = d }
        }
        return best.i >= 0 && best.d <= cap && second > best.d ? idxs[best.i] : nil
    }

    /// Levenshtein distance, giving up (cap + 1) once it's sure to exceed cap.
    private static func distance(_ a: [UInt32], _ b: [UInt32], cap: Int) -> Int {
        if abs(a.count - b.count) > cap { return cap + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            var low = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                low = min(low, cur[j])
            }
            if low > cap { return cap + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Turns OCR lines into a card. Remembers every lookup, so a steady frame costs no database work.
/// Built off the main thread, then used only on it.
final class CardMatcher: @unchecked Sendable {
    let db: CatalogDB
    /// Owned-only mode (trades: what you give): printing id → finishes owned.
    let owned: [String: Set<String>]?
    private let names: ScanNames
    private var oracles: [Int: CatalogOracle] = [:]
    private var printingsByOracle: [Int: [CatalogPrinting]] = [:]
    private var bySetCn: [String: [CatalogPrinting]] = [:]

    init(db: CatalogDB, owned: [String: Set<String>]?, names: ScanNames? = nil) {
        self.db = db
        self.owned = owned
        self.names = names ?? ScanNames.shared(db)
    }

    func match(_ lines: [String]) -> (oracle: CatalogOracle, printing: CatalogPrinting, exact: Bool)? {
        let bottom = Collector(lines, sets: names.sets)
        if let idx = name(lines), let o = oracle(idx) {
            return pick(o, lines, bottom)
        }
        // Not an English name (or none legible): the set code and collector number, when they agree on one card.
        var hits: [Int: CatalogPrinting] = [:]
        for s in bottom.sets {
            for n in bottom.collectorNumbers {
                for p in printings(set: s, cn: n) where hits[p.oracleIdx] == nil { hits[p.oracleIdx] = p }
            }
        }
        guard hits.count == 1, let (idx, p) = hits.first, let o = oracle(idx) else { return nil }
        return (o, p, true)
    }

    /// The finish a scanned copy starts as: what you own of it in owned-only mode, else non-foil when printed.
    func defaultFinish(_ p: CatalogPrinting) -> String {
        if let have = owned?[p.cardId], let f = Finish.allCases.first(where: { have.contains($0.rawValue) }) { return f.rawValue }
        return (p.finishList.first ?? .nonfoil).rawValue
    }

    // MARK: name

    private static let typeWords: Set<Substring> = [
        "creature", "instant", "sorcery", "artifact", "enchantment", "land", "planeswalker", "battle", "summon", "interrupt",
        "kindred", "tribal", "legendary",
        // The same on foreign printings (normalized: no accents).
        "kreatur", "spontanzauber", "hexerei", "artefakt", "verzauberung", "beschworung", "beschworen", "invoquer", "unterbrechungszauber", "legendare",
        "legendarer", "legendares", "ephemere", "rituel", "artefact", "enchantement", "terrain", "invocation", "interruption",
        "legendaire", "bataille", "criatura", "instantaneo", "conjuro", "artefacto", "encantamiento", "tierra", "invocar",
        "interrupcion", "legendaria", "legendario", "batalla", "creatura", "stregoneria", "artefatto", "incantesimo", "terra",
        "evoca", "interruzione", "leggendaria", "leggendario", "battaglia", "instantanea", "feitico", "artefato", "encantamento",
        "terreno", "lendaria", "lendario", "batalha", "существо", "мгновенное", "волшебство", "артефакт", "чары", "земля",
        "легендарное", "легендарныи", "легендарная", "сражение",
    ]

    /// Type lines in Japanese, Chinese and Korean, normalized (no spaces): a line containing one of these is a type
    /// line, since a CJK line normalizes to a single word. "リーチャー": OCR often misreads the ク of クリーチャー.
    private static let cjkTypeWords = [
        "リーチャー", "インスタント", "ソーサリー", "エンチャント", "アーティファクト", "プレインズウォーカー", "土地", "伝説の",
        "召喚", "部族", "同族", "バトル", "割り込み", "インタラプト", "生物", "瞬间", "瞬間", "法术", "法術", "巫术", "巫術", "神器", "结界", "結界", "鹏洛客",
        "鵬洛客", "传奇", "傳奇", "基本地", "魔法力源", "战役", "戰役", "생물", "순간마법", "집중마법", "마법물체", "부여마법", "마법부여", "대지",
        "플레인즈워커", "전설적", "소환", "전투", "동족", "부족",
    ].map(CardName.norm)

    private static func typeLine(_ words: [Substring]) -> Bool {
        !typeWords.isDisjoint(with: words) || words.contains { w in cjkTypeWords.contains { w.contains($0) } }
    }

    /// Furigana: a short line of hiragana only, the reading printed over a Japanese name.
    private static func furigana(_ words: [Substring]) -> Bool {
        words.count == 1 && words[0].count <= 12 && words[0].unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// The card's name: the top lines first (exactly, then cut off or misread), stopping at the type line, which the
    /// name is always above; further down, only an exact name of two words or more (one word is often a keyword).
    private func name(_ lines: [String]) -> Int? {
        // Furigana over a Japanese name isn't a line of its own, unless it's a name itself.
        let read = lines.prefix(12).map { ($0, CardName.norm($0).split(separator: " ")) }
            .filter { (1...12).contains($0.1.count) && !(Self.furigana($0.1) && names.exact(String($0.1[0])) == nil) }
        let words = read.map(\.1)
        // A one-word name only from the first two lines of card text, not from a line in capitals: one word lower
        // down is usually a keyword ("Fliegen" is also the German name of Fly), and capitals are a grading label
        // ("FOIL"), which also doesn't count as a line above the name. Japanese, Chinese and Korean lines are one
        // word (no spaces in their names) and have no capitals.
        let text = read.map { $0.0.contains(where: \.isLowercase) || $0.1.contains { CardName.hasCJK(String($0)) } }
        // A name of one or two Han, kana or Hangul characters only from the first line: on the second it's usually a
        // keyword ("飛行", Flying, is also the Japanese name of Flight).
        func fits(_ q: String, _ i: Int) -> Bool {
            q.contains(" ") || (text[i] && text[..<i].filter { $0 }.count <= (q.count <= 2 && CardName.hasCJK(q) ? 0 : 1))
        }
        func long(_ q: String) -> Bool { q.count >= (CardName.hasCJK(q) ? 2 : 3) }
        func exact(_ i: Int) -> Int? {
            for q in candidates(words[i]) where long(q) && fits(q, i) { if let o = names.exact(q), allowed(o) { return o } }
            // A name broken over two lines.
            if i + 1 < words.count, words[i].count <= 3, words[i + 1].count <= 3 {
                for q in candidates(words[i] + words[i + 1]) where long(q) && fits(q, i) {
                    if let o = names.exact(q), allowed(o) { return o }
                }
            }
            return nil
        }
        for i in 0..<min(3, words.count) {
            if let o = exact(i) { return o }
            if Self.typeLine(words[i]) { break }
            for q in candidates(words[i]) where fits(q, i) {
                if let o = names.prefix(q) ?? names.fuzzy(q), allowed(o) { return o }
            }
        }
        // Not a Japanese, Chinese or Korean name: short ones turn up in rules text.
        for i in min(3, words.count)..<words.count where !words[i].contains(where: { CardName.hasCJK(String($0)) }) {
            if let o = exact(i), oracle(o)?.norm.contains(" ") == true { return o }
        }
        return nil
    }

    /// The line itself, then with up to three short trailing tokens (a misread mana cost) dropped.
    private func candidates(_ words: [Substring]) -> [String] {
        var out = [Self.join(words[...])]
        for drop in stride(from: 1, through: min(3, words.count - 1), by: 1) where words.suffix(drop).allSatisfy({ $0.count <= 3 }) {
            out.append(Self.join(words.dropLast(drop)))
        }
        return out
    }

    /// Words joined as CardName.norm would: a space, except between two of Han, kana and Hangul (a name over two lines).
    private static func join(_ words: ArraySlice<Substring>) -> String {
        var out = ""
        for w in words {
            if let a = out.unicodeScalars.last, let b = w.unicodeScalars.first, !(CardName.isCJK(a.value) && CardName.isCJK(b.value)) {
                out += " "
            }
            out += w
        }
        return out
    }

    // MARK: printing

    /// The printing: set code read (4), collector number read (2), copyright year (1); ties go to English, a
    /// regular collector number, then the default printing. Exact when the set code and number agree, the set has
    /// only one printing of the card, or the number and year single one out. A prerelease date stamp picks the
    /// set's prerelease promo.
    private func pick(_ o: CatalogOracle, _ lines: [String], _ bottom: Collector)
        -> (oracle: CatalogOracle, printing: CatalogPrinting, exact: Bool)? {
        let ps = printings(o.idx)
        guard !ps.isEmpty else { return nil }
        let years = Self.years(lines)
        func number(_ p: CatalogPrinting) -> String { Self.stripZeros(p.cn.lowercased()) }
        func year(_ p: CatalogPrinting) -> Int? { Int(p.releasedAt.prefix(4)) }
        func score(_ p: CatalogPrinting) -> Int {
            (bottom.sets.contains(p.set) ? 4 : 0) + (bottom.numbers.contains(number(p)) ? 2 : 0)
                + (year(p).map(years.contains) == true ? 1 : 0)
        }
        func key(_ p: CatalogPrinting) -> (Int, Int, Int, Int, Int) {
            (score(p), p.lang == "en" ? 1 : 0, p.cn.hasSuffix("★") ? 0 : 1, p.original ? 1 : 0, -p.ord)
        }
        var best = ps.max { key($0) < key($1) }!
        let exact = (bottom.sets.contains(best.set) && (bottom.numbers.contains(number(best)) || ps.filter { $0.set == best.set }.count == 1))
            || (bottom.numbers.contains(number(best)) && year(best).map(years.contains) == true
                && ps.filter { number($0) == number(best) }.count == 1)
        if Self.dated(lines), let promo = ps.first(where: {
            $0.set == "p" + best.set && String($0.cn.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "s★"))) == best.cn.lowercased()
        }) {
            best = promo
        }
        return (o, best, exact)
    }

    private static func stripZeros(_ s: String) -> String {
        let t = s.drop { $0 == "0" }
        return t.isEmpty ? (s.isEmpty ? "" : "0") : String(t)
    }

    /// Copyright years ("© 2019 Wizards", "1993-2003"): the last year of each.
    private static func years(_ lines: [String]) -> Set<Int> {
        var out = Set<Int>()
        for line in lines {
            if let m = line.firstMatch(of: yearRange) {
                if let y = Int(m.output.2) { out.insert(y) }
            } else if line.range(of: "wizards", options: .caseInsensitive) != nil || line.contains("©"),
                      let y = line.matches(of: year).last.flatMap({ Int($0.output) }) {
                out.insert(y)
            }
        }
        return out
    }

    nonisolated(unsafe) private static let yearRange = #/(19[89]\d)\s*[-–]?\s*(20[0-4]\d)/#
    nonisolated(unsafe) private static let year = #/19[89]\d|20[0-4]\d/#
    /// Month names as a date stamp prints them, normalized: English, then de, fr, it, es, pt, ru.
    private static let months: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april", "may", "jun", "june", "jul", "july", "aug",
        "august", "sep", "sept", "september", "oct", "october", "nov", "november", "dec", "december", "januar", "februar",
        "marz", "mai", "juni", "juli", "oktober", "dezember", "janvier", "fevrier", "mars", "avril", "juin", "juillet",
        "aout", "septembre", "octobre", "novembre", "decembre", "gennaio", "febbraio", "marzo", "aprile", "maggio",
        "giugno", "luglio", "agosto", "settembre", "ottobre", "dicembre", "enero", "febrero", "abril", "mayo", "junio",
        "julio", "septiembre", "octubre", "noviembre", "diciembre", "janeiro", "fevereiro", "marco", "maio", "junho",
        "julho", "setembro", "outubro", "novembro", "dezembro", "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    /// A prerelease date stamp ("30-31 January 2021", "27-28 giugno 2020"): a month and a year on a line that isn't the copyright.
    private static func dated(_ lines: [String]) -> Bool {
        lines.contains { line in
            let l = CardName.norm(line)
            return l.firstMatch(of: year) != nil && !l.contains("wizards")
                && l.split(whereSeparator: { !$0.isLetter }).contains { months.contains(String($0)) }
        }
    }

    // MARK: lookups

    private func oracle(_ idx: Int) -> CatalogOracle? {
        if let o = oracles[idx] { return o }
        let o = db.oracles(idxs: [idx])[idx]
        oracles[idx] = o
        return o
    }

    private func printings(_ idx: Int) -> [CatalogPrinting] {
        if let p = printingsByOracle[idx] { return p }
        var p = db.printings(oracleIdx: idx)
        if let owned { p = p.filter { owned[$0.cardId] != nil } }
        printingsByOracle[idx] = p
        return p
    }

    private func printings(set: String, cn: String) -> [CatalogPrinting] {
        let key = set + "|" + cn
        if let p = bySetCn[key] { return p }
        var p = db.printings(set: set, cn: cn)
        if let owned { p = p.filter { owned[$0.cardId] != nil } }
        bySetCn[key] = p
        return p
    }

    private func allowed(_ idx: Int) -> Bool { owned == nil || !printings(idx).isEmpty }
}

/// What a card's bottom text says about its printing: "154/196 M", "RIX • RU", "M 0244", "FRA • EN".
struct Collector {
    var sets = Set<String>()
    var numbers = Set<String>()
    /// The numbers written as collector numbers ("154/196", "0244", "R 1695", "297"), not a lone "212" that may be a misread 2/2.
    var collectorNumbers = Set<String>()

    private static let langs: Set<String> = ["EN", "DE", "FR", "IT", "ES", "PT", "JP", "JA", "RU", "KR", "KO", "CS", "CT", "PH", "ZHS", "ZHT"]
    /// An uppercase code, a bullet or star, a language code ("one it ate." in rules text is not a set and a language).
    nonisolated(unsafe) private static let setLang = #/\b([A-Z0-9]{2,5})\s*[•*·★+.]\s*([A-Z]{2,3})\b/#
    /// "154/196": the number after the slash is the set's size, which tells it from power/toughness ("6/6").
    nonisolated(unsafe) private static let ofTotal = #/(?:^|[^\d\/])(\d{1,4})([a-zA-Z]?)\s*\/\s*(\d{2,4})\b/#
    /// A line that is only a collector number, maybe with its rarity: "667", "R 0244", "0014", "07 29".
    nonisolated(unsafe) private static let alone = #/\s*(?:[CURMLSTP]\s+)?(\d[\d ]{0,4}\d|\d)(?:\s+[CURMLSTP])?\s*/#

    init(_ lines: [String], sets known: Set<String>) {
        var langLine = false
        for line in lines {
            for m in line.matches(of: Self.setLang) where Self.langs.contains(String(m.output.2)) {
                langLine = true
                let code = m.output.1.lowercased()
                if known.contains(code) { sets.insert(code) }
            }
            for m in line.matches(of: Self.ofTotal) where (Int(m.output.3) ?? 0) >= 30 {
                let n = Self.strip(String(m.output.1)) + m.output.2.lowercased()
                numbers.insert(n)
                collectorNumbers.insert(n)
            }
        }
        for line in lines {
            guard let m = line.wholeMatch(of: Self.alone) else { continue }
            let n = m.output.1.replacingOccurrences(of: " ", with: "")
            guard n.count <= 4, langLine || n.count == 4 else { continue }
            numbers.insert(Self.strip(n))
            // "0244", "R 1695", or three digits that can't be power/toughness read with the slash as 1 or 7 ("2/2" → "212").
            let toughness = n.count == 3 && "17".contains(Array(n)[1])
            if (n.count == 4 && n.first == "0") || line.contains(where: \.isLetter) || (n.count == 3 && !toughness) {
                collectorNumbers.insert(Self.strip(n))
            }
        }
    }

    private static func strip(_ s: String) -> String {
        let t = s.drop { $0 == "0" }
        return t.isEmpty ? "0" : String(t)
    }
}

/// Holds a candidate until it's steady, and keeps a card from being taken twice while it stays in frame.
/// Timings from the movement clips in testdata/scan (motion.json): a hand settling a card or holding it with a
/// little shake is taken within about a second; a card swept past the camera isn't taken at all.
struct ScanSteadiness {
    /// Taken this long after it's first seen once its printing is read; without the printing, a little longer.
    static let quick: TimeInterval = 0.4
    static let slow: TimeInterval = 0.8
    /// A blurred or unreadable frame doesn't drop the card in view unless the gap lasts this long.
    static let gap: TimeInterval = 0.5
    /// After a take, the same card has to be out of view this long before it counts again.
    static let away: TimeInterval = 1.0

    private struct Candidate {
        let idx: Int
        let since: Date
        var seen: Date
        var latest: CatalogPrinting
        /// Exact reads per printing; the most read one wins.
        var votes: [String: (CatalogPrinting, Int)] = [:]
    }
    private var candidate: Candidate?
    private var lastAccepted: (idx: Int, seen: Date)?

    /// Feed every frame's match (or nil). Returns the printing once a card should be taken.
    mutating func feed(_ m: (oracle: CatalogOracle, printing: CatalogPrinting, exact: Bool)?, at now: Date = .now)
        -> (CatalogPrinting, Bool)? {
        guard let m else {
            if let c = candidate, ms(now, c.seen) > ms(Self.gap) { candidate = nil }
            return nil
        }
        if let last = lastAccepted, last.idx == m.oracle.idx, ms(now, last.seen) < ms(Self.away) {
            lastAccepted = (last.idx, now)
            return nil
        }
        if candidate?.idx != m.oracle.idx || ms(now, candidate!.seen) > ms(Self.gap) {
            candidate = Candidate(idx: m.oracle.idx, since: now, seen: now, latest: m.printing)
        }
        guard var c = candidate else { return nil }
        c.seen = now
        c.latest = m.printing
        if m.exact { c.votes[m.printing.cardId, default: (m.printing, 0)].1 += 1 }
        candidate = c
        let voted = c.votes.values.max { $0.1 < $1.1 }?.0
        let held = ms(now, c.since)
        guard (voted != nil && held >= ms(Self.quick)) || held >= ms(Self.slow) else { return nil }
        candidate = nil
        lastAccepted = (m.oracle.idx, now)
        return voted.map { ($0, true) } ?? (c.latest, false)
    }

    /// Times in whole milliseconds, so 1.4 s − 1.0 s is 400 ms, not 399.99… (same as Android).
    private func ms(_ a: Date, _ b: Date) -> Int { Int((a.timeIntervalSince(b) * 1000).rounded()) }
    private func ms(_ t: TimeInterval) -> Int { Int((t * 1000).rounded()) }
}

/// Which script the camera reads. Nobody picks a language: it reads like the phone (Latin and Cyrillic, English
/// first) until there's text in view that names no card for a while, then switches to Chinese, Japanese and Korean
/// (iOS: Vision's automatic language detection, one reader; Android: ML Kit's Japanese, Chinese and Korean
/// recognizers, one a frame in turn). It stays there while cards keep matching and goes back after a run of misses.
/// The frames spent finding the script are frames ScanSteadiness sees nothing in, so a switch never takes a card early.
struct ScanLanguage: Equatable {
    /// Text naming no card for this long switches to CJK reading.
    static let detect: TimeInterval = 0.6
    /// CJK reading naming no card for this long goes back.
    static let back: TimeInterval = 1.2

    enum Mode: Equatable { case latin, cjk(Int) }

    /// How many CJK readers there are to try in turn.
    let readers: Int
    private(set) var mode = Mode.latin
    private var missSince: Date?

    init(readers: Int) { self.readers = readers }

    /// Feed every frame: whether its lines named a card, and whether there were any lines at all.
    mutating func feed(matched: Bool, text: Bool, at now: Date = .now) {
        if matched { missSince = nil; return }
        switch mode {
        case .latin:
            guard text else { missSince = nil; return }
            let since = missSince ?? now
            missSince = since
            if ms(now, since) >= ms(Self.detect) { mode = .cjk(0); missSince = now }
        case .cjk(let k):
            let since = missSince ?? now
            missSince = since
            if ms(now, since) >= ms(Self.back) { mode = .latin; missSince = nil } else { mode = .cjk((k + 1) % readers) }
        }
    }

    private func ms(_ a: Date, _ b: Date) -> Int { Int((a.timeIntervalSince(b) * 1000).rounded()) }
    private func ms(_ t: TimeInterval) -> Int { Int((t * 1000).rounded()) }
}
