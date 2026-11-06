import Foundation
import ScanIndex

/* Scanner matching: OCR lines in, a card and printing out. Tuned against the photo test set in testdata/scan
   (README there; accuracy test in Table1Tests/CardMatcherTests.swift). Same rules on Android (CardMatcher.kt). */

/// Names the scanner can read, built once per catalog pack: each card's name and a split or double-faced card's
/// front face (tokens, art cards, emblems and Vanguard left out), its printed names in other languages (pack N
/// lines; never over an English name, and left out when two cards share one), with trigrams for misread names.
/// Each name knows the languages it's printed in, so a card read by its German name goes in as German.
final class ScanNames: @unchecked Sendable {
    let version: String
    let sets: Set<String>
    /// A card the name belongs to, and the languages it's printed in (empty for an English name, which doesn't
    /// tell: a German card whose name is the English one reads the same).
    struct Hit: Equatable { let idx: Int; let langs: [String] }
    /// The names, sorted, with their trigrams; in the ScanIndex package (Packages/ScanIndex), which is built
    /// optimized in Debug too: ~200k names took 5 s to index at -Onone.
    private let index: NameIndex

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
        var english: [(norm: String, idx: Int, printings: Int)] = []
        var scannable = Set<Int>()
        for o in db.scanNames() where o.printings > 0 && !Self.unscannable(o.typeLine) {
            if let cut = o.name.range(of: " // ") {
                let front = CardName.norm(String(o.name[..<cut.lowerBound]))
                if front == CardName.norm(String(o.name[cut.upperBound...])) { continue } // an art card ("X // X")
                english.append((o.norm, o.idx, o.printings))
                english.append((front, o.idx, o.printings))
            } else {
                english.append((o.norm, o.idx, o.printings))
            }
            scannable.insert(o.idx)
        }
        let bit = Dictionary(uniqueKeysWithValues: Languages.all.enumerated().map { ($1.code, UInt32(1) << UInt32($0)) })
        let foreign = db.scanForeignNames().compactMap { n in
            scannable.contains(n.idx) ? (norm: n.norm, idx: n.idx, lang: bit[n.lang] ?? 0) : nil
        }
        index = NameIndex(english: english, foreign: foreign)
    }

    private static func unscannable(_ typeLine: String) -> Bool {
        ["Token", "Card", "Emblem", "Vanguard"].contains { typeLine.hasPrefix($0) }
    }

    func exact(_ q: String) -> Hit? { index.position(q).map(hit) }

    private func hit(_ i: Int) -> Hit { Hit(idx: index.idxs[i], langs: Self.langs(index.langBits[i])) }

    private static func langs(_ bits: UInt32) -> [String] {
        Languages.all.indices.filter { bits & (1 << UInt32($0)) != 0 }.map { Languages.all[$0].code }
    }

    /// A name cut off at the edge of the frame: only one card has names starting with it (its English and printed
    /// names often share a start: "Urza's Saga", "Urzas Sage"), and it's most of one of them.
    func prefix(_ q: String) -> Hit? {
        guard q.count >= (CardName.hasCJK(q) ? 4 : 8) else { return nil }
        let keys = index.keys, idxs = index.idxs, langBits = index.langBits
        let lo = index.lowerBound(q)
        var hit: Int?, most = false
        // The languages of the names it starts; none when one of them is English (it doesn't tell).
        var bits: UInt32?
        for j in lo..<min(keys.count, lo + 16) {
            guard keys[j].hasPrefix(q) else { break }
            if let h = hit, h != idxs[j] { return nil }
            hit = idxs[j]
            bits = bits == 0 || langBits[j] == 0 ? 0 : (bits ?? 0) | langBits[j]
            if Double(q.count) >= 0.6 * Double(keys[j].count) { most = true }
        }
        return most ? hit.map { Hit(idx: $0, langs: Self.langs(bits ?? 0)) } : nil
    }

    /// A misread name: the closest name within about one edit in eight letters, if no other card's name is as close.
    /// Han, kana and Hangul carry more per character: four of them at least, and one edit in six, counted in
    /// characters rather than UTF-8 bytes.
    func fuzzy(_ q: String) -> Hit? {
        let cjk = CardName.hasCJK(q)
        guard q.count >= (cjk ? 4 : 5), q.utf8.count < 250 else { return nil }
        let cap = max(1, q.count / (cjk ? 6 : 8))
        let tg = NameIndex.trigrams(q)
        // The 60 names sharing the most trigrams, of those sharing at least 40%.
        let enough = Int((Double(tg.count) * 0.4).rounded(.up))
        let top = index.sharing(tg, enough).prefix(60)
        let keys = index.keys, idxs = index.idxs
        let target = cjk ? q.unicodeScalars.map(\.value) : q.utf8.map(UInt32.init)
        var best = (d: cap + 1, i: -1), second = cap + 1
        for i in top {
            let d = NameIndex.distance(target, cjk ? keys[i].unicodeScalars.map(\.value) : keys[i].utf8.map(UInt32.init), cap: cap)
            let other = best.i < 0 || idxs[best.i] != idxs[i]
            if d < best.d { if other { second = best.d }; best = (d, i) } else if d < second && other { second = d }
        }
        return best.i >= 0 && best.d <= cap && second > best.d ? hit(best.i) : nil
    }
}

/// Turns OCR lines into a card. Remembers every lookup, so a steady frame costs no database work.
/// Built off the main thread, then used only on it.
final class CardMatcher: @unchecked Sendable {
    let db: CatalogDB
    /// Owned-only mode (trades: what you give): printing id → finishes owned.
    let owned: [String: Set<String>]?
    /// Owned-only: printing id → finishes in for-trade binders. Among printings the card's text scores alike, these win
    /// (contract/binders-wants-2026-10-17.md), and their finish is the default.
    let preferred: [String: Set<String>]
    private let names: ScanNames
    private var oracles: [Int: CatalogOracle] = [:]
    private var printingsByOracle: [Int: [CatalogPrinting]] = [:]
    private var bySetCn: [String: [CatalogPrinting]] = [:]
    /// The last printing picked by hand this session. When nothing read tells a card's printings apart, the next
    /// card goes in as that set, nearest that collector number: after one fix, a stack of Beta cards or a run of
    /// MH2's retro fetchlands (436–440, not the regular 248–254) follows.
    private(set) var lastPick: CatalogPrinting?

    init(db: CatalogDB, owned: [String: Set<String>]?, preferred: [String: Set<String>] = [:], names: ScanNames? = nil) {
        self.db = db
        self.owned = owned
        self.preferred = preferred
        self.names = names ?? ScanNames.shared(db)
    }

    /// A card read, its printing and whether that was read (`exact`), and the languages its text says it's in
    /// (`langs`): the language code by the set code ("WAR • JP"), else the languages of the printed name read; empty
    /// when neither tells (an English name, which many cards print in every language).
    typealias Match = (oracle: CatalogOracle, printing: CatalogPrinting, exact: Bool, langs: [String])

    /// `border`: the colour of the card's border read from the camera frame (ScanBorder), when the scanner could tell.
    func match(_ lines: [String], border: ScanBorder = .unknown) -> Match? {
        let frame = Collector(lines, sets: names.sets, border: border)
        if let hit = name(lines), let o = oracle(hit.idx) {
            let bottom = remembered(o.idx, frame)
            guard let (p, exact) = pick(o, bottom, langs: hit.langs) else { missed(); return nil }
            return (o, p, exact, bottom.lang.map { [$0] } ?? hit.langs)
        }
        // Not an English name (or none legible): the set code and collector number, when they agree on one card.
        var hits: [Int: CatalogPrinting] = [:]
        for s in frame.sets {
            for n in frame.collectorNumbers {
                for p in printings(set: s, cn: n) where hits[p.oracleIdx] == nil { hits[p.oracleIdx] = p }
            }
        }
        guard hits.count == 1, let (idx, p) = hits.first, let o = oracle(idx) else { missed(); return nil }
        _ = remembered(idx, frame)
        return (o, p, true, frame.lang.map { [$0] } ?? [])
    }

    /// A printing picked by hand (the scanned row's Change printing): the guess for the next card that reads alike.
    func picked(_ p: CatalogPrinting) { lastPick = p; recent = nil }

    /// The finish a scanned copy starts as: what you own of it in owned-only mode, else non-foil when printed.
    func defaultFinish(_ p: CatalogPrinting) -> String {
        if let trade = preferred[p.cardId], let f = Finish.allCases.first(where: { trade.contains($0.rawValue) }) { return f.rawValue }
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

    /// Whether the lines include a type line ("Instant", "Creature — Elf"): text from a card, not a keyboard or a list.
    static func hasTypeLine(_ lines: [String]) -> Bool {
        lines.contains { typeLine(CardName.norm($0).split(separator: " ")) }
    }

    private static func typeLine(_ words: [Substring]) -> Bool {
        !typeWords.isDisjoint(with: words) || words.contains { w in cjkTypeWords.contains { w.contains($0) } }
    }

    /// Furigana: a short line of hiragana only, the reading printed over a Japanese name.
    private static func furigana(_ words: [Substring]) -> Bool {
        words.count == 1 && words[0].count <= 12 && words[0].unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// The card's name: the top lines first (exactly, then cut off or misread), stopping at the type line, which the
    /// name is always above; further down, only an exact name of two words or more (one word is often a keyword).
    private func name(_ lines: [String]) -> ScanNames.Hit? {
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
        func exact(_ i: Int) -> ScanNames.Hit? {
            for q in candidates(words[i]) where long(q) && fits(q, i) { if let o = names.exact(q), allowed(o.idx) { return o } }
            // A name broken over two lines.
            if i + 1 < words.count, words[i].count <= 3, words[i + 1].count <= 3 {
                for q in candidates(words[i] + words[i + 1]) where long(q) && fits(q, i) {
                    if let o = names.exact(q), allowed(o.idx) { return o }
                }
            }
            return nil
        }
        for i in 0..<min(3, words.count) {
            if let o = exact(i) { return o }
            if Self.typeLine(words[i]) { break }
            for q in candidates(words[i]) where fits(q, i) {
                if let o = names.prefix(q) ?? names.fuzzy(q), allowed(o.idx) { return o }
            }
        }
        // Not a Japanese, Chinese or Korean name: short ones turn up in rules text. And never from below the type
        // line: the title is above it, and the flavor text under it names people who are cards too (an Ice Age
        // Counterspell whose title didn't read went in as Gustha Ebbasdotter, from "-Gustha Ebbasdotter,", 2026-11-01).
        let below = words.firstIndex(where: Self.typeLine) ?? words.count
        for i in min(3, words.count)..<max(below, min(3, words.count)) where !words[i].contains(where: { CardName.hasCJK(String($0)) }) {
            if let o = exact(i), oracle(o.idx)?.norm.contains(" ") == true { return o }
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

    /// The printing, scored by what the card's bottom text says (`Collector`, merged over the last frames of the same
    /// card): set code read (4), collector number read (2; for a card with no power/toughness also a lone three-digit
    /// number that could have been a misread "2/2"), copyright year (1), an "Illus." line for a 1993 or 1997 frame
    /// (2: old cards and retro-frame reprints print one; a 2003+ frame prints the artist after a brush), the
    /// illustrator's name read (2, when the card's printings don't all share one), or for an old frame with no year
    /// (4th Edition on prints "© 1995") a 1993–94 printing (1); ties go to a for-trade copy, the set last picked by
    /// hand (nearest its number), the name's language on an old frame (French Sol Ring → Foreign Black Border),
    /// the border colour the camera read when nothing printed was (black: Alpha, Beta, Foreign Black Border; white:
    /// Unlimited, Revised), English, a regular collector number, the most printed of Revised, Unlimited, Beta, Alpha
    /// (nothing printed on them tells them apart, and Alpha was the rarest), then the default printing. Exact when one printing leads
    /// with the set code and number (or the set's only printing), or with the number and one more thing (the year,
    /// the frame), or with the set code and the artist. A prerelease date stamp picks the set's prerelease promo.
    private func pick(_ o: CatalogOracle, _ bottom: Collector, langs: [String] = []) -> (CatalogPrinting, Bool)? {
        let ps = printings(o.idx)
        guard !ps.isEmpty else { return nil }
        let old = bottom.years.isEmpty && bottom.sets.isEmpty && bottom.numbers.isEmpty && bottom.illustrated
        // Vehicles have power/toughness; a battle's defense is one number.
        let noPT = !(o.typeLine.contains("Creature") || o.typeLine.contains("Vehicle"))
        let artists = Set(ps.map(\.artist).filter { !$0.isEmpty })
        let artistTells = artists.count > 1
        func number(_ p: CatalogPrinting) -> String { Self.stripZeros(p.cn.lowercased()) }
        func year(_ p: CatalogPrinting) -> Int? { Int(p.releasedAt.prefix(4)) }
        func numbered(_ p: CatalogPrinting) -> Bool {
            bottom.numbers.contains(number(p)) || (noPT && bottom.loneNumbers.contains(number(p)))
        }
        func retro(_ p: CatalogPrinting) -> Bool { bottom.illustrated && (p.frame == "1993" || p.frame == "1997") }
        // Each artist is looked up in the frames' words once per pick, and each printing scored once: the scores are
        // read several times per printing while sorting, and the fuzzy word match over every line is the costly part.
        var drawnBy: [String: Collector.ArtistLine?] = [:]
        func drawn(_ p: CatalogPrinting) -> Collector.ArtistLine? {
            guard artistTells, !p.artist.isEmpty else { return nil }
            if let cached = drawnBy[p.artist] { return cached }
            let found = bottom.names(artist: p.artist)
            drawnBy[p.artist] = .some(found)
            return found
        }
        // The artist read after a brush, not "Illus.": a 2003 or newer frame.
        func modern(_ p: CatalogPrinting) -> Bool { drawn(p) == .plain && (p.frame == "2003" || p.frame == "2015" || p.frame == "future") }
        var scores: [String: Int] = [:]
        func score(_ p: CatalogPrinting) -> Int {
            if let s = scores[p.cardId] { return s }
            let s = (bottom.sets.contains(p.set) ? 4 : 0) + (numbered(p) ? 2 : 0)
                + (year(p).map(bottom.years.contains) == true || (old && Self.early(p)) ? 1 : 0)
                + (retro(p) ? 2 : 0) + (drawn(p) != nil ? 2 : 0) + (modern(p) ? 1 : 0)
            scores[p.cardId] = s
            return s
        }
        let last = lastPick.map { ($0.set, Self.digits($0.cn)) }
        func near(_ p: CatalogPrinting) -> Int {
            guard let last, p.set == last.0 else { return Int.min }
            return -abs(Self.digits(p.cn) - last.1)
        }
        // The border the camera read counts only when nothing printed was read (a set code, number or year read
        // always wins, and old cards print none), and after a hand-picked set: a fix still carries to the next card.
        let border = bottom.sets.isEmpty && bottom.numbers.isEmpty && bottom.years.isEmpty ? bottom.border : .unknown
        func bordered(_ p: CatalogPrinting) -> Int {
            switch border {
            case .black: Self.blackBorder.contains(p.set) ? 1 : 0
            case .white: Self.whiteBorder.contains(p.set) ? 1 : 0
            case .unknown: 0
            }
        }
        func key(_ p: CatalogPrinting) -> [Int] {
            let s = score(p), trade = preferred[p.cardId] != nil ? 1 : 0, picked = near(p)
            let lang = old && langs.contains(p.lang) ? 1 : 0, en = p.lang == "en" ? 1 : 0
            let regular = p.cn.hasSuffix("★") ? 0 : 1, run = Self.printRun[p.set] ?? 0
            return [s, trade, picked, lang, bordered(p), en, regular, run, p.original ? 1 : 0, -p.ord]
        }
        var best = ps.max { key($0).lexicographicallyPrecedes(key($1)) }!
        let top = score(best)
        let alone = ps.filter { score($0) == top }.count == 1
        let inSet = bottom.sets.contains(best.set)
        let exact = alone && (top >= 6 || (numbered(best) && top >= 3) || (inSet && ps.filter { $0.set == best.set }.count == 1))
        if bottom.dated, let promo = ps.first(where: {
            $0.set == "p" + best.set && String($0.cn.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "s★"))) == best.cn.lowercased()
        }) {
            best = promo
        }
        return (best, exact)
    }

    /// The 1993–94 core sets, most printed first: one printed card reads the same in all four.
    private static let printRun = ["3ed": 4, "2ed": 3, "leb": 2, "lea": 1]
    /// The 1993–95 printings with a black border (Alpha, Beta, Collectors' Edition, Foreign Black Border, 4th Edition's
    /// foreign black border) and a white one (Unlimited, Revised, Summer Magic): what the camera's border read picks
    /// between when nothing printed tells them apart.
    static let blackBorder: Set<String> = ["lea", "leb", "ced", "cei", "fbb", "4bb"]
    static let whiteBorder: Set<String> = ["2ed", "3ed", "sum"]

    /// Printed before cards carried a copyright year (4th Edition, April 1995).
    private static func early(_ p: CatalogPrinting) -> Bool { (Int(p.releasedAt.prefix(4)) ?? 9999) <= 1994 }

    /// A collector number's digits as a number ("437" → 437, "M20-125" → 20125), for nearness.
    private static func digits(_ cn: String) -> Int { Int(cn.filter { ("0"..."9").contains($0) }.prefix(6)) ?? 0 }

    private static func stripZeros(_ s: String) -> String {
        let t = s.drop { $0 == "0" }
        return t.isEmpty ? (s.isEmpty ? "" : "0") : String(t)
    }

    // MARK: evidence over frames

    /// Evidence about the card in view, kept over its last frames: the set code read in one frame and the number in
    /// the next pick the printing together (a borderless Tourach read "MH2 • EN" in one frame and "312" four frames
    /// later, and went in as the regular 102). Only the last `frames` frames are kept (2026-10-31: the merged
    /// evidence had grown by every frame's words for as long as the card stayed in view, and the artist's fuzzy
    /// match scanned all of them, so each frame was slower than the last; 80 frames of one card went 0.1 s → 7.9 s
    /// each). Cleared after `misses` frames that named nothing, when another card is named, after a hand-picked
    /// printing, and when the card is taken (`took`).
    private var recent: (idx: Int, frames: [Collector], misses: Int)?
    static let misses = 5
    /// Frames of the card in view whose bottom text is remembered: about 2 s at the camera's pace.
    static let frames = 10

    /// How many frames of the card in view are remembered (tests).
    var rememberedFrames: Int { recent?.frames.count ?? 0 }

    /// The evidence for this card: this frame's, merged with what the last frames of the same card read.
    private func remembered(_ idx: Int, _ bottom: Collector) -> Collector {
        var frames = recent?.idx == idx ? recent!.frames : []
        frames.append(bottom)
        if frames.count > Self.frames { frames.removeFirst(frames.count - Self.frames) }
        recent = (idx, frames, 0)
        // Newest first, so this frame's language code wins as before.
        var merged = bottom
        for f in frames.dropLast().reversed() { merged.merge(f) }
        return merged
    }

    private func missed() {
        guard var r = recent else { return }
        r.misses += 1
        recent = r.misses >= Self.misses ? nil : r
    }

    /// The card in view was taken: what its frames read mustn't pick the next copy's printing.
    func took() { recent = nil }

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

/// What a card's bottom text says about its printing: "154/196 M", "RIX • RU", "M 0244", "FRA • EN", the year and
/// number on a copyright line ("™ & © 2024 Wizards of the Coast 407"), an "Illus." line, the illustrator's name, a
/// prerelease date stamp. Built per frame; `merge` keeps what earlier frames of the same card read.
struct Collector {
    var sets = Set<String>()
    var numbers = Set<String>()
    /// The numbers written as collector numbers ("154/196", "0244", "R 1695", "297"), not a lone "212" that may be a misread 2/2.
    var collectorNumbers = Set<String>()
    /// Lone three-digit numbers that could be power/toughness read with the slash as 1 or 7 ("2/2" → "212"): a
    /// collector number only for a card that prints no power/toughness.
    var loneNumbers = Set<String>()
    /// The language printed by a known set code ("WAR • JP" → ja), when only one is.
    var lang: String?
    /// Copyright years ("© 2019 Wizards", "1993-2003", "& C 2013 W"): the last year of each line.
    var years = Set<Int>()
    /// An artist credit as 1993 and 1997 frames print it ("Illus. Mark Poole"; also read as "Ius." or "lllus,").
    var illustrated = false
    /// A prerelease date stamp ("30-31 January 2021", "27-28 giugno 2020"): a month and a year on a line that isn't the copyright.
    var dated = false
    /// The border colour the camera read in this frame (ScanBorder), when it could tell.
    var border = ScanBorder.unknown
    /// This frame's lines for the illustrator's name (then older frames' after `merge`); each frame remembers which
    /// illustrators it names, so it's searched once per artist however many frames it stays in memory.
    var lines: [ScanLines] = []

    /// How the illustrator's name was printed: after "Illus." (a 1993 or 1997 frame) or plainly, after a brush.
    enum ArtistLine { case illustrated, plain }

    /// The codes printed by the set code, as Scryfall's language codes.
    private static let langs: [String: String] = [
        "EN": "en", "DE": "de", "FR": "fr", "IT": "it", "ES": "es", "PT": "pt", "JP": "ja", "JA": "ja", "RU": "ru",
        "KR": "ko", "KO": "ko", "CS": "zhs", "CT": "zht", "PH": "ph", "ZHS": "zhs", "ZHT": "zht",
    ]
    /// An uppercase code, a bullet, star, dash or Japanese middle dot, a language code ("one it ate." in rules text is
    /// not a set and a language); the bullet is often read as a letter ("MH2 WEN", "ECL MEN", "MH2VEN") or lost, so a
    /// code of three or more may also be followed by one stray letter or nothing.
    nonisolated(unsafe) private static let setLang = #/\b([A-Z0-9]{2,5})\s*[•*·★+.\-–・]\s*([A-Z]{2,3})\b/#
    nonisolated(unsafe) private static let setLangLoose = #/\b([A-Z0-9]{3,5})\s?[A-Z]?\s?(EN|DE|FR|IT|ES|PT|JP|JA|RU|KR|KO|CS|CT|PH|ZHS|ZHT)\b/#
    /// "154/196": the number after the slash is the set's size, which tells it from power/toughness ("6/6").
    nonisolated(unsafe) private static let ofTotal = #/(?:^|[^\d\/])(\d{1,4})([a-zA-Z]?)\s*\/\s*(\d{2,4})\b/#
    /// A line that is only a collector number, maybe with its rarity: "667", "R 0244", "0014", "07 29".
    nonisolated(unsafe) private static let alone = #/\s*(?:[CURMLSTP]\s+)?(\d[\d ]{0,4}\d|\d)(?:\s+[CURMLSTP])?\s*/#
    /// A copyright line, as the camera reads it: "™ & © 2024 Wizards of the Coast 407", "& C 2013W", "2012 Wi",
    /// "ds of the Coast 248 27.", "1993-2001 Wizards of the Coast, Inc. 214/350".
    nonisolated(unsafe) private static let copyright = #/(?i)©|wizards|wi[sz]a|of the co|\bcoast|&\s*\S{0,2}\s*(?:19|20)\d\d|(?:19|20)\d\d\s*W/#
    /// The number a 1997-style copyright line ends with ("… of the Coast 407", "… Coast 248 27." with the total cut off).
    nonisolated(unsafe) private static let trailing = #/(?:^|\D)(\d{1,4})([a-z]?)(?:\s+\d{2,3}\.?)?\s*$/#
    nonisolated(unsafe) private static let yearRange = #/(19[89]\d)\s*[-–]?\s*(20[0-4]\d)/#
    nonisolated(unsafe) private static let year = #/(?:^|\D)(19[89]\d|20[0-4]\d)(?!\d)/#
    nonisolated(unsafe) private static let illus = #/^(?i)[il1|]{0,3}us[.,:\/]\s/#
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

    init(_ lines: [String], sets known: Set<String>, border: ScanBorder = .unknown) {
        self.border = border
        var langLine = false
        var printed = Set<String>()
        var digits: [Bool] = []
        var words: [[[UInt8]]] = []
        var credits: [Bool] = []
        for line in lines {
            // Cheap checks first: most lines of a busy desk have no digit and no two capitals in a row, and none of
            // these patterns can match without them (2026-10-31; Swift's regex engine is slow, more so in Debug).
            let hasDigit = line.utf8.contains { $0 >= 48 && $0 <= 57 }
            digits.append(hasDigit)
            var codes: [(String, String)] = []
            if Self.hasCode(line) {
                codes = line.matches(of: Self.setLang).map { (String($0.output.1), String($0.output.2)) }
                if codes.isEmpty { codes = line.matches(of: Self.setLangLoose).map { (String($0.output.1), String($0.output.2)) } }
            }
            for (raw, l) in codes {
                guard let lang = Self.langs[l] else { continue }
                langLine = true
                if let code = Self.known(raw, known) { sets.insert(code); printed.insert(lang) }
            }
            if hasDigit {
                for m in line.matches(of: Self.ofTotal) where (Int(m.output.3) ?? 0) >= 30 {
                    let n = Self.strip(String(m.output.1)) + m.output.2.lowercased()
                    numbers.insert(n)
                    collectorNumbers.insert(n)
                }
                if let m = line.firstMatch(of: Self.yearRange) {
                    if let y = Int(m.output.2) { years.insert(y) }
                } else if line.firstMatch(of: Self.copyright) != nil, let y = line.matches(of: Self.year).last.flatMap({ Int($0.output.1) }) {
                    years.insert(y)
                }
            }
            let credit = Self.mayCredit(line) && line.trimmingCharacters(in: .whitespaces).firstMatch(of: Self.illus) != nil
            if credit { illustrated = true }
            let norm = CardName.norm(line)
            if hasDigit, norm.firstMatch(of: Self.year) != nil, !norm.contains("wizards"),
               norm.split(whereSeparator: { !$0.isLetter }).contains(where: { Self.months.contains(String($0)) }) {
                dated = true
            }
            words.append(norm.split(separator: " ").map { Array($0.utf8) })
            credits.append(credit)
        }
        self.lines = [ScanLines(words: words, credits: credits)]
        if printed.count == 1 { lang = printed.first }
        for (line, hasDigit) in zip(lines, digits) where hasDigit {
            if let m = line.wholeMatch(of: Self.alone) {
                let n = m.output.1.replacingOccurrences(of: " ", with: "")
                guard n.count <= 4 else { continue }
                // "0244", "R 1695", or three digits that can't be power/toughness read with the slash as 1 or 7 ("2/2" → "212").
                let toughness = n.count == 3 && "17".contains(Array(n)[1])
                if toughness && !langLine { loneNumbers.insert(Self.strip(n)); continue }
                guard langLine || n.count >= 3 else { continue }
                numbers.insert(Self.strip(n))
                if (n.count == 4 && n.first == "0") || line.contains(where: \.isLetter) || (n.count == 3 && !toughness) {
                    collectorNumbers.insert(Self.strip(n))
                }
            } else if line.firstMatch(of: Self.copyright) != nil, line.firstMatch(of: Self.ofTotal) == nil,
                      let m = line.firstMatch(of: Self.trailing) {
                // The number at the end of a copyright line, never the year itself.
                let n = String(m.output.1)
                guard !(n.count == 4 && (Int(n) ?? 0) >= 1990) else { continue }
                numbers.insert(Self.strip(n) + m.output.2.lowercased())
            }
        }
    }

    /// Whether the lines name this illustrator, and how: every word of the name, in order, in one line; a word of
    /// four or five letters may be one edit off and a longer one two ("TOOD LOCKVOOD", "Shells Wan", "CANARAT" for
    /// Canavan), shorter ones exact.
    func names(artist: String) -> ArtistLine? {
        let want = CardName.norm(artist).split(separator: " ").filter { $0 != "and" && $0 != "&" }.map { Array($0.utf8) }
        guard !want.isEmpty else { return nil }
        for frame in lines { if let how = frame.names(artist: artist, want: want) { return how } }
        return nil
    }

    static func alike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = b.count
        guard abs(a.count - n) <= 2 else { return false }
        if a == b { return true }
        guard n >= 4 else { return false }
        return edits(a, b, atMost: n >= 6 ? 2 : 1)
    }

    /// Two capital letters in a row, as every set-code-and-language pattern needs ("EN", "JP").
    private static func hasCode(_ line: String) -> Bool {
        var upper = false
        for b in line.utf8 {
            let u = b >= 65 && b <= 90
            if u && upper { return true }
            upper = u
        }
        return false
    }

    /// Could be an "Illus." credit: starts with i, l, 1, | or u, like every spelling `illus` accepts.
    private static func mayCredit(_ line: String) -> Bool {
        guard let c = line.drop(while: { $0 == " " || $0 == "\t" }).first else { return false }
        return "iIlL1|uU".contains(c)
    }

    /// Whether a and b are within `atMost` single-character edits (insert, delete, replace) of each other.
    static func edits<T: Equatable>(_ a: [T], _ b: [T], atMost k: Int) -> Bool {
        if abs(a.count - b.count) > k { return false }
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            var rowMin = i
            for j in 1...max(b.count, 1) where j <= b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > k { return false }
            prev = cur
        }
        return prev[b.count] <= k
    }

    /// What earlier frames of the same card read, added to this frame's.
    mutating func merge(_ o: Collector) {
        sets.formUnion(o.sets)
        numbers.formUnion(o.numbers)
        collectorNumbers.formUnion(o.collectorNumbers)
        loneNumbers.formUnion(o.loneNumbers)
        years.formUnion(o.years)
        illustrated = illustrated || o.illustrated
        dated = dated || o.dated
        lines += o.lines
        if lang == nil { lang = o.lang }
        if border == .unknown { border = o.border }
    }

    /// A read set code as the catalog knows it: as read, else with the letters the camera swaps for digits put back
    /// ("4OK" → 40k, "MHT" → mh1, "A2S" → a25), else without a stray first or last character ("YMH2", "4A25", "MH2V").
    private static func known(_ raw: String, _ known: Set<String>) -> String? {
        let code = raw.lowercased()
        if known.contains(code) { return code }
        let swapped = String(code.map { ["o": "0", "i": "1", "l": "1", "t": "1", "s": "5"][$0] ?? $0 })
        if swapped != code, known.contains(swapped) { return swapped }
        if code.count >= 4 {
            for cut in [String(code.dropFirst()), String(code.dropLast())] where known.contains(cut) { return cut }
        }
        return nil
    }

    private static func strip(_ s: String) -> String {
        let t = s.drop { $0 == "0" }
        return t.isEmpty ? "0" : String(t)
    }
}

/// The colour of a card's border, read from the camera frame: Alpha, Beta and Foreign Black Border cards have black
/// borders, Unlimited and Revised white ones, and nothing printed on a 1993–94 card tells them apart, so this breaks
/// that tie in `CardMatcher.pick` (contract/trades-2026-10-16.md § Scanning "Border colour"; measured over the photo
/// set in testdata/scan/border.json, made by testdata/scan/tools/border.swift, which holds the reference copy of these
/// rules; Android: `ScanBorder` in CardMatcher.kt. Change all three together.)
///
/// The scanner samples luma (0–255, full range) at a few points per camera frame: just inside and just outside each
/// side of the card's edge (iOS: the card-shaped rectangle Vision finds; without one, and always on Android, the
/// card's edge is found in a short luma profile across each side of the guide box), further outside, and in the card's
/// text box, whose ink and paper are the frame's own black and white, so a dim or low-contrast frame still reads.
enum ScanBorder: String, Codable, Sendable {
    case black, white, unknown

    /// Where a side's samples are taken: six points along it, 15–85% of its length.
    static let along: [Double] = [0.15, 0.29, 0.43, 0.57, 0.71, 0.85]
    /// Offsets from the edge, as fractions of the card's width: a 1993–94 border is about 4.5% wide.
    static let depths: [Double] = [0.015, 0.03]
    /// Further out, past where a border would end: tells a border plateau outside a rectangle that was the frame
    /// inside the border (a step between the two) from a table that just goes on (no step).
    static let farDepths: [Double] = [0.065, 0.09]
    /// Where the text box is sampled (u right, v down, fractions of the card): light with dark text on every
    /// 1993–2003 card.
    static let innerU: [Double] = [0.2, 0.32, 0.44, 0.56, 0.68, 0.8]
    static let innerV: [Double] = [0.66, 0.72, 0.78, 0.84]
    /// The luma profile across a side of the guide box: from 12% outside to 12% inside its width, 25 samples.
    static let profileSteps = 25
    static let profileSpan = 0.12

    /// Luma at or under this is black, at or over the other white, whatever the card (a phone's auto exposure keeps a
    /// card about this bright); in between, the card's own text box decides.
    static let blackAtMost = 70, whiteAtLeast = 165
    /// Relative to the text box (0 = its ink, 1 = its paper): a border this far below the paper is black, this far
    /// above the ink white, within these absolute bounds (so a lit black border or a greyed white one still counts, but
    /// not frame texture), when the text box has this much contrast.
    static let blackBelow = 0.25, whiteAbove = 0.9, blackAbsMax = 115, whiteAbsMin = 140, textBoxContrast = 50
    /// A border plateau outside the rectangle found ends in a step this big (relative to the text box; in luma when it
    /// has no contrast) to the table beyond it; a table just goes on.
    static let plateauStep = 0.3, plateauStepLuma = 45

    /// The samples one frame yields: per side (top, right, bottom, left) twelve just inside the edge, twelve just
    /// outside, twelve further out; and 24 in the text box.
    struct Samples: Equatable {
        var inside: [[Int]]
        var outside: [[Int]]
        var far: [[Int]]
        var inner: [Int]
    }

    static func upperMedian(_ a: [Int]) -> Int { a.sorted()[a.count / 2] }

    /// The border from a frame's samples: at least three of the four sides one colour just inside the edge and none
    /// the other; else, when the inside is mostly neither (the rectangle was the frame inside the border), the same
    /// just outside, counting only sides where the outside band steps to what lies beyond it (a border ends; a table
    /// doesn't).
    static func classify(_ s: Samples) -> ScanBorder {
        guard s.inside.count == 4, s.outside.count == 4, s.far.count == 4, !s.inner.isEmpty,
              s.inside.allSatisfy({ !$0.isEmpty }), s.outside.allSatisfy({ !$0.isEmpty }), s.far.allSatisfy({ !$0.isEmpty }) else { return .unknown }
        let sorted = s.inner.sorted()
        let ink = sorted[0], paper = sorted[min(sorted.count - 1, sorted.count * 3 / 4)]
        let ref = paper - ink >= textBoxContrast
        func norm(_ m: Int) -> Double { Double(m - ink) / Double(paper - ink) }
        func shade(_ samples: [Int]) -> ScanBorder {
            let m = upperMedian(samples)
            if m <= blackAtMost || (ref && norm(m) <= blackBelow && m <= blackAbsMax) { return .black }
            if m >= whiteAtLeast || (ref && norm(m) >= whiteAbove && m >= whiteAbsMin) { return .white }
            return .unknown
        }
        func agree(_ shades: [ScanBorder]) -> ScanBorder {
            let black = shades.filter { $0 == .black }.count, white = shades.filter { $0 == .white }.count
            if black >= 3 && white == 0 { return .black }
            if white >= 3 && black == 0 { return .white }
            return .unknown
        }
        let ins = s.inside.map(shade)
        let a = agree(ins)
        if a != .unknown { return a }
        guard ins.filter({ $0 == .unknown }).count >= 3 else { return .unknown }
        let outs = (0..<4).map { k -> ScanBorder in
            let o = upperMedian(s.outside[k]), f = upperMedian(s.far[k])
            let step = ref ? abs(norm(o) - norm(f)) >= plateauStep : abs(o - f) >= plateauStepLuma
            return step ? shade(s.outside[k]) : .unknown
        }
        return agree(outs)
    }

    /// The samples around a card-shaped quad (corners TL, TR, BR, BL in pixels, origin top-left); `luma` reads one
    /// pixel (clamping to the image is its job). 120 reads.
    static func samples(quad q: [CGPoint], luma: (CGPoint) -> Int) -> Samples {
        let w = (hypot(q[1].x - q[0].x, q[1].y - q[0].y) + hypot(q[2].x - q[3].x, q[2].y - q[3].y)) / 2
        let c = CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
        var inside: [[Int]] = [], outside: [[Int]] = [], far: [[Int]] = []
        for k in 0..<4 {
            let a = q[k], b = q[(k + 1) % 4]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let len = max(1, hypot(c.x - mid.x, c.y - mid.y))
            let n = CGPoint(x: (c.x - mid.x) / len, y: (c.y - mid.y) / len) // inward
            var ins: [Int] = [], outs: [Int] = [], fars: [Int] = []
            for t in along {
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                for d in depths {
                    ins.append(luma(CGPoint(x: p.x + n.x * w * d, y: p.y + n.y * w * d)))
                    outs.append(luma(CGPoint(x: p.x - n.x * w * d, y: p.y - n.y * w * d)))
                }
                for d in farDepths { fars.append(luma(CGPoint(x: p.x - n.x * w * d, y: p.y - n.y * w * d))) }
            }
            inside.append(ins); outside.append(outs); far.append(fars)
        }
        return Samples(inside: inside, outside: outside, far: far, inner: innerSamples(q, luma))
    }

    /// Luma at the text-box points inside a quad (bilinear in its corners TL, TR, BR, BL).
    static func innerSamples(_ q: [CGPoint], _ luma: (CGPoint) -> Int) -> [Int] {
        innerV.flatMap { v in innerU.map { u in
            let top = CGPoint(x: q[0].x + (q[1].x - q[0].x) * u, y: q[0].y + (q[1].y - q[0].y) * u)
            let bottom = CGPoint(x: q[3].x + (q[2].x - q[3].x) * u, y: q[3].y + (q[2].y - q[3].y) * u)
            return luma(CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v))
        } }
    }

    /// The samples around the guide box (pixels, origin top-left) when no rectangle was found: along each side six
    /// luma profiles from 12% outside to 12% inside find the card's edge (the strongest step), and the bands around it
    /// are the inside, outside and far samples. 624 reads.
    static func samples(guide g: CGRect, luma: (CGPoint) -> Int) -> Samples {
        let sides: [(CGPoint, CGPoint, CGPoint)] = [ // start, end, inward unit
            (CGPoint(x: g.minX, y: g.minY), CGPoint(x: g.maxX, y: g.minY), CGPoint(x: 0, y: 1)),
            (CGPoint(x: g.maxX, y: g.minY), CGPoint(x: g.maxX, y: g.maxY), CGPoint(x: -1, y: 0)),
            (CGPoint(x: g.maxX, y: g.maxY), CGPoint(x: g.minX, y: g.maxY), CGPoint(x: 0, y: -1)),
            (CGPoint(x: g.minX, y: g.maxY), CGPoint(x: g.minX, y: g.minY), CGPoint(x: 1, y: 0)),
        ]
        var inside: [[Int]] = [], outside: [[Int]] = [], far: [[Int]] = []
        for (a, b, n) in sides {
            var ins: [Int] = [], outs: [Int] = [], fars: [Int] = []
            for t in along {
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                let s = (0..<profileSteps).map { k -> Int in
                    let d = (-profileSpan + Double(k) * (2 * profileSpan) / Double(profileSteps - 1)) * g.width
                    return luma(CGPoint(x: p.x + n.x * d, y: p.y + n.y * d))
                }
                let (i, o, f) = edge(s)
                ins += i; outs += o; fars += f
            }
            inside.append(ins); outside.append(outs); far.append(fars)
        }
        let q = [CGPoint(x: g.minX, y: g.minY), CGPoint(x: g.maxX, y: g.minY), CGPoint(x: g.maxX, y: g.maxY), CGPoint(x: g.minX, y: g.maxY)]
        return Samples(inside: inside, outside: outside, far: far, inner: innerSamples(q, luma))
    }

    /// From one profile (outside first), the samples around the card's edge: the strongest step is the edge; the two
    /// samples inward of it are inside (about 1–2% in), the two outward outside, two more beyond them far.
    static func edge(_ s: [Int]) -> (inside: [Int], outside: [Int], far: [Int]) {
        let n = s.count
        var e = n / 2, best = 0
        for k in 2..<(n - 2) where abs(s[k] - s[k - 1]) > best { best = abs(s[k] - s[k - 1]); e = k }
        return ([s[min(n - 1, e + 1)], s[min(n - 1, e + 2)]], [s[max(0, e - 2)], s[max(0, e - 3)]], [s[max(0, e - 7)], s[max(0, e - 9)]])
    }
}

/// One frame's lines, normalized, for the illustrator's name: each line's words as bytes (compared without
/// allocating) and whether it's an "Illus." credit. A class, so the answer per artist is kept while the frame stays
/// in the matcher's memory (2026-10-31: every remembered frame was searched again for every artist on every frame).
final class ScanLines {
    let words: [[[UInt8]]]
    let credits: [Bool]
    private var found: [String: Collector.ArtistLine?] = [:]

    init(words: [[[UInt8]]], credits: [Bool]) {
        self.words = words
        self.credits = credits
    }

    /// Whether these lines name the artist (`want`: the name's words as bytes), and how: every word of the name, in
    /// order, in one line, each `Collector.alike` its word. The first line that does decides.
    func names(artist: String, want: [[UInt8]]) -> Collector.ArtistLine? {
        if let cached = found[artist] { return cached }
        var how: Collector.ArtistLine?
        search: for (i, line) in words.enumerated() where line.count >= want.count {
            for start in 0...(line.count - want.count) {
                var ok = true
                for (k, w) in want.enumerated() where !Collector.alike(line[start + k], w) { ok = false; break }
                if ok { how = credits[i] ? .illustrated : .plain; break search }
            }
        }
        found[artist] = .some(how)
        return how
    }
}

/// Holds a candidate until it's steady, and keeps a card from being taken twice while it stays in frame.
/// Timings from the movement clips in testdata/scan (motion.json): a hand settling a card or holding it with a
/// little shake is taken within about a second; a card swept past the camera isn't taken at all.
struct ScanSteadiness {
    /// Taken this long after it's first seen once its printing is read; without the printing, a little longer and
    /// named in at least `reads` frames (1993–2003 frames print no set code, and their names misread in a third of
    /// frames or more: Crusade, named 6 times in 2.4 s with gaps of 0.6 s, was never taken while any gap over 0.5 s
    /// started it over).
    static let quick: TimeInterval = 0.4
    /// Sooner still when two frames read the same printing exactly (set code and number agree): a second frame
    /// that says the same is as sure as a third that says nothing (2026-10-28).
    static let quicker: TimeInterval = 0.2
    static let agree = 2
    static let slow: TimeInterval = 0.8
    static let reads = 3
    /// A blurred or unreadable frame doesn't drop the card in view unless the gap lasts this long.
    static let gap: TimeInterval = 1.0
    /// After a take, the same card has to be out of view this long before it counts again.
    static let away: TimeInterval = 1.0

    private struct Candidate {
        let idx: Int
        let since: Date
        var seen: Date
        var latest: CatalogPrinting
        /// Frames that named it.
        var named = 0
        /// Exact reads per printing; the most read one wins.
        var votes: [String: (CatalogPrinting, Int)] = [:]
    }
    private var candidate: Candidate?
    private var lastAccepted: (idx: Int, seen: Date)?

    /// Feed every frame's match (or nil). Returns the printing once a card should be taken.
    mutating func feed(_ m: CardMatcher.Match?, at now: Date = .now)
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
        c.named += 1
        if m.exact { c.votes[m.printing.cardId, default: (m.printing, 0)].1 += 1 }
        candidate = c
        let top = c.votes.values.max { $0.1 < $1.1 }
        let voted = top?.0
        let held = ms(now, c.since)
        guard (voted != nil && held >= ms(Self.quick)) || ((top?.1 ?? 0) >= Self.agree && held >= ms(Self.quicker))
                || (held >= ms(Self.slow) && c.named >= Self.reads) else { return nil }
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
