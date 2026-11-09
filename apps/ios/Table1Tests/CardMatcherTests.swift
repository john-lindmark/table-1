import XCTest
@testable import Table1

/* Scanner accuracy over the photo test set (testdata/scan/README.md): the matcher on each photo's OCR lines, the
   movement clips through ScanSteadiness, and every reported scan correction in testdata/scan/reports. Prints a
   report and fails when accuracy drops below what the set reached when it was tuned (2026-10-15). */

/// Lowest accuracy the tests accept: what the set reached when last tuned (README has the numbers).
private enum Floor {
    static let englishName = 0.95, englishPrinting = 0.85, foreignName = 0.93, cjkName = 0.6
    /// Of the cards in other languages named right, how many go in as their own language (2026-10-20).
    static let language = 0.93
    /// Reported corrections (phone clips) whose printing comes out right (2026-10-28).
    static let reportPrinting = 0.44
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/scan").standardized

/// One photo or reported case: the lines to read and the card it is.
private struct Case {
    let id: String
    let name: String
    let set: String   // "*" = any printing
    let cn: String    // "*" = any number in the set
    let tags: Set<String>
    var lang = "en"   // the language printed on the card
}

private struct Tally {
    var n = 0, name = 0, wrong = 0, printingChecked = 0, printingOK = 0, exactWrong = 0
    var line: String {
        "name \(name)/\(n) (\(pct(name, n))), wrong \(wrong), none \(n - name - wrong); "
            + "printing \(printingOK)/\(printingChecked) (\(pct(printingOK, printingChecked))), sure-but-wrong \(exactWrong)"
    }
}

private func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }

final class CardMatcherTests: XCTestCase {
    private static var db: CatalogDB!
    private static var names: ScanNames!
    /// Normalized name (and a split or double-faced card's front face) → oracle index, for the expected cards.
    private static var expectedIdx: [String: Int] = [:]

    override class func setUp() {
        super.setUp()
        let path = FileManager.default.temporaryDirectory.appending(path: "scan-test-catalog.sqlite").path
        let pack = try! CatalogPack.gunzip(Data(contentsOf: root.appending(path: "catalog.tsv.gz")))
        let started = Date()
        let header = try! CatalogDB.build(pack: pack, at: path)
        let built = Date()
        db = try! CatalogDB(path: path, version: header.version)
        names = ScanNames(db)
        let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
        print("Catalog: pack into SQLite \(ms(started, built)) ms, scanner name index \(ms(built, Date())) ms")
        var printings: [Int: Int] = [:]
        _ = try! CatalogPack.parse(pack, oracle: { _ in }, printing: { printings[$0.oracleIdx, default: 0] += 1 })
        var best: [String: (Int, Int)] = [:]
        _ = try! CatalogPack.parse(pack, oracle: { o in
            var keys = [o.nameNorm]
            if let cut = o.name.range(of: " // ") { keys.append(CardName.norm(String(o.name[..<cut.lowerBound]))) }
            let count = printings[o.idx] ?? 0
            for k in keys where best[k].map({ count > $0.1 }) ?? true { best[k] = (o.idx, count) }
        }, printing: { _ in })
        expectedIdx = best.mapValues(\.0)
    }

    private func photos() throws -> [Case] {
        try String(contentsOf: root.appending(path: "photos.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { row in
                let c = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return Case(id: c[0], name: c[1], set: c[2], cn: c[3], tags: Set(c[5].split(separator: ",").map(String.init)), lang: c[4])
            }
    }

    private func matcher() -> CardMatcher { CardMatcher(db: Self.db, owned: nil, names: Self.names) }

    private func strip(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "★", with: "").drop { $0 == "0" }
        return String(t)
    }

    /// Grades one result against the case.
    private func grade(_ c: Case, _ oracle: CatalogOracle?, _ printing: CatalogPrinting?, exact: Bool, into t: inout Tally) {
        t.n += 1
        guard let oracle, let printing else { return }
        let want = Self.expectedIdx[CardName.norm(c.name)]
        XCTAssertNotNil(want, "\(c.id): \(c.name) isn't in the catalog")
        guard oracle.idx == want else { t.wrong += 1; return }
        t.name += 1
        guard c.set != "*" else { return }
        t.printingChecked += 1
        if printing.set == c.set && (c.cn == "*" || strip(printing.cn) == strip(c.cn)) { t.printingOK += 1 } else if exact { t.exactWrong += 1 }
    }

    func testStillPhotos() throws {
        let ocr = try JSONDecoder().decode([String: [String: [String]]].self, from: Data(contentsOf: root.appending(path: "ocr.json")))
        let cases = try photos()
        var report = ["Still photos (\(cases.count)):"]
        var results: [String: Tally] = [:], englishResults: [String: Tally] = [:]
        // English cards a scan would put in another language (a misread English name close to a printed one).
        var notEnglish: [String: Int] = [:]
        // `dim` and `dimFixed` exist only for the 1993 and 1997 frames (README § Low-contrast reads).
        var oldFrame: [String: Tally] = [:]
        for mode in ["accurate", "fast", "small", "multi", "title", "bottom", "dim", "dimFixed"] {
            var all = Tally(), english = Tally(), foreign = Tally()
            var byTag: [String: Tally] = [:]
            for c in cases {
                guard let lines = ocr[c.id]?[mode] else { continue }
                let m = matcher().match(lines)
                if c.tags.contains("frame93") || c.tags.contains("frame97") {
                    grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &oldFrame[mode, default: Tally()])
                }
                if let got = m?.oracle, got.idx != Self.expectedIdx[CardName.norm(c.name)] {
                    report.append("    WRONG \(mode) \(c.id): \(got.name)")
                }
                if c.lang == "en", let m, Languages.forScan(m.printing, read: m.langs, picked: "en") != "en" {
                    notEnglish[mode, default: 0] += 1
                    report.append("    LANGUAGE \(mode) \(c.id): \(m.langs)")
                }
                grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &all)
                if c.tags.contains("lang") { grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &foreign) }
                else { grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &english) }
                if mode == "accurate" {
                    for tag in c.tags { grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &byTag[tag, default: Tally()]) }
                }
            }
            results[mode] = all
            englishResults[mode] = english
            report += ["  \(mode): \(all.line)", "    English: \(english.line)", "    other languages: \(foreign.line)"]
            if mode == "accurate" {
                report += byTag.keys.sorted().map { "      \($0): \(byTag[$0]!.line)" }
            }
        }
        report.append("  1993 and 1997 frames (\(oldFrame["dim"]?.n ?? 0)): " + ["accurate", "multi", "dim", "dimFixed"].map { "\($0) \(oldFrame[$0]?.line ?? "-")" }.joined(separator: "; "))
        print(report.joined(separator: "\n"))
        // Other languages have their own test (testForeignCards).
        let accurate = results["accurate"]!, english = englishResults["accurate"]!
        XCTAssertEqual(accurate.wrong, 0, "a wrong card from a steady photo")
        XCTAssertGreaterThanOrEqual(Double(english.name) / Double(english.n), Floor.englishName)
        XCTAssertGreaterThanOrEqual(Double(english.printingOK) / Double(english.printingChecked), Floor.englishPrinting)
        XCTAssertLessThanOrEqual(accurate.exactWrong, 2)
        XCTAssertLessThanOrEqual(results["fast"]!.wrong + results["small"]!.wrong, 1)
        XCTAssertEqual(results["multi"]!.wrong, 0, "a wrong card from a steady photo read as the scanner reads")
        // Dim, low-contrast copies of the old-frame photos (2026-11-01): no wrong card, and names within a few of the
        // plain read's (README § Low-contrast reads has the numbers; `dimFixed`, a contrast stretch before OCR, is
        // only measured: it read fewer names and two wrong cards, so the scanners don't do it).
        XCTAssertEqual(results["dim"]!.wrong, 0, "a wrong card from a dim photo")
        XCTAssertGreaterThanOrEqual(oldFrame["dim"]!.name, oldFrame["accurate"]!.name - 8)
        XCTAssertEqual(notEnglish["accurate", default: 0] + notEnglish["multi", default: 0], 0, "an English card put in another language")
    }

    /// The card gate (2026-10-16): with a card found in the frame (`inCard`: a card-shaped rectangle, upright), only
    /// the text inside it is read, so text beside it can't name a card; with none found, the whole frame is read but
    /// a card is taken only when the lines have a type line or a set code and number that agree with the name. A
    /// keyboard's "command" / "option" keys matched Opt (its French name is Option) before this.
    func testCardGate() throws {
        let ocr = try JSONDecoder().decode([String: [String: [String]]].self, from: Data(contentsOf: root.appending(path: "ocr.json")))
        let cases = try photos()
        var report = ["Card gate (\(cases.count)):"]
        var found = 0
        var tallies: [String: (all: Tally, english: Tally)] = [:]
        func gated(_ lines: [String], onCard: Bool) -> CardMatcher.Match? {
            guard let m = matcher().match(lines) else { return nil }
            return onCard || m.exact || CardMatcher.hasTypeLine(lines) ? m : nil
        }
        for c in cases {
            if ocr[c.id]?["inCard"] != nil { found += 1 }
            for (mode, inCard, frame) in [("accurate", "inCard", "accurate"), ("multi", "inCardMulti", "multi")] {
                let card = ocr[c.id]?[inCard]
                guard let lines = card ?? ocr[c.id]?[frame] else { continue }
                let m = gated(lines, onCard: card != nil)
                if let got = m?.oracle, got.idx != Self.expectedIdx[CardName.norm(c.name)] { report.append("    WRONG \(mode) \(c.id): \(got.name)") }
                var t = tallies[mode] ?? (Tally(), Tally())
                grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &t.all)
                if !c.tags.contains("lang") { grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &t.english) }
                tallies[mode] = t
            }
        }
        report.append("  card found in \(found)/\(cases.count)")
        for (mode, t) in tallies.sorted(by: { $0.key < $1.key }) { report += ["  \(mode): \(t.all.line)", "    English: \(t.english.line)"] }
        print(report.joined(separator: "\n"))
        for (mode, t) in tallies { XCTAssertEqual(t.all.wrong, 0, "a wrong card through the gate (\(mode))") }
        let english = tallies["accurate"]!.english
        XCTAssertGreaterThanOrEqual(Double(english.name) / Double(english.n), 0.94)
        // No card in view: the keys of a MacBook keyboard, as a phone read them (scan report, 2026-10-15).
        XCTAssertNotNil(matcher().match(["command", "option"]), "the matcher alone names Opt")
        XCTAssertNil(gated(["command", "option"], onCard: false))
        XCTAssertNil(gated(["/", "command", "option"], onCard: false))
    }

    /// The language code printed by the set code, only by a set the catalog has.
    /// What the bottom text says (2026-10-28, from 232 phone reports): the number at the end of a 1997-style copyright
    /// line, years on copyright lines the camera garbles, more spellings of the set code line, an "Illus." line, lone
    /// numbers that could be a misread power/toughness kept apart, and the illustrator's name read with a few errors.
    func testBottomLineParsing() {
        let sets: Set<String> = ["mh2", "mh1", "rvr", "40k", "ecl", "neo", "a25", "gtc"]
        var c = Collector(["Illus. Rob Alexander", "™ & C 2024 Wizande of the Coart 407"], sets: sets)
        XCTAssertEqual(c.numbers, ["407"]); XCTAssertEqual(c.years, [2024]); XCTAssertTrue(c.illustrated)
        XCTAssertTrue(c.collectorNumbers.isEmpty, "a number on the copyright line isn't enough to name a card by")
        XCTAssertEqual(c.names(artist: "Rob Alexander"), .illustrated); XCTAssertNil(c.names(artist: "Svetlin Velinov"))
        c = Collector(["ds of the Coast 248 27."], sets: sets)
        XCTAssertEqual(c.numbers, ["248"], "the total cut off")
        c = Collector(["& C 2013W", "2012 Wi", "* & 6 2013 W", "1995"], sets: sets)
        XCTAssertEqual(c.years, [2013, 2012])
        c = Collector(["1993-2001 Wizards of the Coast, Inc. 214/350"], sets: sets)
        XCTAssertEqual(c.years, [2001]); XCTAssertEqual(c.numbers, ["214"])
        for line in ["MH2 - EN A ZEZHOU CHEN", "MH2 WEN N PAUL", "MH2VEN & PM", "YMH2 • EN - GREG STAPLES", "4OK•EN SHI", "MHT-EN A NICHOLAS", "NEO・JP ©えすていお", "A25. EN * TODD"] {
            let got = Collector([line], sets: sets).sets
            XCTAssertEqual(got.count, 1, line); XCTAssertTrue(["mh2", "40k", "mh1", "neo", "a25"].contains(got.first ?? ""), line)
        }
        XCTAssertEqual(Collector(["NEO・JP ©えすていお/ESUTHIO"], sets: sets).lang, "ja")
        XCTAssertTrue(Collector(["one IT - ES ate", "THE END"], sets: sets).sets.isEmpty)
        c = Collector(["Tourach, Dread Cantor", "312", "2/1"], sets: sets)
        XCTAssertEqual(c.loneNumbers, ["312"], "could be a 3/2"); XCTAssertTrue(c.numbers.isEmpty)
        c = Collector(["392", "3/3"], sets: sets)
        XCTAssertEqual(c.numbers, ["392"]); XCTAssertEqual(c.collectorNumbers, ["392"])
        c = Collector(["MH2 • EN A- ZEZHOU CHEN", "TOOD LOCKVOOD", "Shells Wan", "CUNT LANGLEY", "PAUL SCOTT CANARAT"], sets: sets)
        XCTAssertEqual(c.names(artist: "Zezhou Chen"), .plain); XCTAssertEqual(c.names(artist: "Todd Lockwood"), .plain)
        XCTAssertEqual(c.names(artist: "Shelly Wan"), .plain); XCTAssertEqual(c.names(artist: "Paul Scott Canavan"), .plain)
        XCTAssertNil(c.names(artist: "Clint Langley"), "two errors in a five-letter word is another word")
        XCTAssertNil(c.names(artist: "Greg Staples")); XCTAssertNil(c.names(artist: "Won"), "a short name must read exactly")
        var m = Collector(["MH2 • EN"], sets: sets); m.merge(Collector(["312"], sets: sets))
        XCTAssertEqual(m.sets, ["mh2"]); XCTAssertEqual(m.loneNumbers, ["312"])
    }

    /// The printing from frame and artist evidence (2026-10-28): a retro-frame MH2 fetchland reads "Illus." and goes
    /// in as MH2's retro printing, not Zendikar's; the illustrator tells a set's variants apart; evidence read over
    /// several frames of one card adds up; an old card still goes in as Revised.
    func testPrintingEvidence() {
        func pick(_ frames: [[String]]) -> (set: String, cn: String, exact: Bool)? {
            let m = matcher()
            var last: CardMatcher.Match?
            for f in frames { last = m.match(f) ?? last }
            return last.map { ($0.printing.set, $0.printing.cn, $0.exact) }
        }
        let misty = ["Misty Rainforest", "Land", "r, Pay 1 life, Sacrifice Misty", "Illus. Shelly Wan"]
        var got = pick([misty])
        XCTAssertEqual(got?.set, "mh2"); XCTAssertEqual(got?.cn, "438"); XCTAssertEqual(got?.exact, false)
        got = pick([misty + ["ants of the Coast 438"]])
        XCTAssertEqual(got?.set, "mh2"); XCTAssertEqual(got?.cn, "438"); XCTAssertEqual(got?.exact, true, "frame and number single it out")
        got = pick([["Misty Rainforest", "Land", "r, Pay 1 life, Sacrifice Misty", "Shelly Wan"]])
        XCTAssertEqual(got?.set, "zen", "a 2003 frame prints the artist without Illus.")
        got = pick([["Overgrown Tomb", "Land - Swamp Forest", "Illus. Rob Alexander", "™ & C 2024 Wizards of the Coast 407"]])
        XCTAssertEqual(got?.set, "rvr"); XCTAssertEqual(got?.cn, "407"); XCTAssertEqual(got?.exact, true)
        got = pick([["Tourach, Dread Cantor", "Legendary Creature - Human Cleric", "MH2 • EN A- ZEZHOU CHEN"]])
        XCTAssertEqual(got?.cn, "312", "the artist tells the borderless printing from the regular one"); XCTAssertEqual(got?.exact, true)
        got = pick([["Tourach, Dread Cantor", "Legendary Creature - Human Cleric", "312", "2/1"]])
        XCTAssertEqual(got?.cn, "102", "312 alone could be a creature's 3/2")
        got = pick([["Zagoth Triome", "Land - Swamp Forest Island", "313"]])
        XCTAssertEqual(got?.cn, "313", "a land has no power/toughness, so 313 is its number")
        got = pick([["Zagoth Triome", "Land - Swamp Forest Island", "IKO • EN"],
                    ["Zagoth Triome", "Land - Swamp Forest Island"],
                    ["Zagoth Triome", "Land - Swamp Forest Island", "313"]])
        XCTAssertEqual(got?.cn, "313", "the set code from one frame and the number from another"); XCTAssertEqual(got?.exact, true)
        got = pick([["Temporal Manipulation", "Sorcery", "Take an extra turn after this one.", "- Franz Vohwinkel"]])
        XCTAssertEqual(got?.set, "mb2", "an artist after a brush, not Illus., is a 2003 or newer frame")
        got = pick([["Lightning Bolt", "Instant", "Lightning Bolt does 3", "Illus. © Christopher Rush"]])
        XCTAssertEqual(got?.set, "3ed", "old frames still go in as the most printed")
        // Another card between clears what was read: the artist alone names 312 but can't be sure of it.
        let m = matcher()
        _ = m.match(["Tourach, Dread Cantor", "Legendary Creature - Human Cleric", "MH2 • EN"])
        _ = m.match(["Lightning Bolt", "Instant"])
        let after = m.match(["Tourach, Dread Cantor", "Legendary Creature - Human Cleric", "A- ZEZHOU CHEN"])
        XCTAssertEqual(after?.printing.cn, "312"); XCTAssertEqual(after?.exact, false)
    }

    /// The matcher's work per frame must not grow while a card stays in view (2026-10-31): the evidence merged over
    /// frames had kept every frame's words for as long as the card was named, and the artist's fuzzy match scanned
    /// all of them several times per printing, so each frame of a card held on a cluttered desk was slower than the
    /// last (80 frames: 0.1 s → 7.9 s each), on the main thread. Only the last `CardMatcher.frames` are kept and each
    /// artist is looked up once per frame.
    func testEvidenceStaysBounded() {
        let m = matcher()
        let clutter = (0..<30).map { "desk line number \($0) with some other words printed on it" }
        let frame = ["Lightning Bolt", "Instant", "Lightning Bolt deals 3 damage to any target.", "Illus. Christopher Rush"] + clutter
        var times: [TimeInterval] = []
        for _ in 0..<80 {
            let t = Date()
            XCTAssertEqual(m.match(frame)?.oracle.name, "Lightning Bolt")
            times.append(Date().timeIntervalSince(t))
        }
        XCTAssertEqual(m.rememberedFrames, CardMatcher.frames)
        let first = times.prefix(20).reduce(0, +) * 1000, last = times.suffix(20).reduce(0, +) * 1000
        XCTAssertLessThan(last, first * 2 + 50, "later frames must not be slower: first 20 \(Int(first)) ms, last 20 \(Int(last)) ms")
        // The same card scanned in owned-only mode (trades) and a plain frame: every scan mode stays flat.
        let owned = CardMatcher(db: Self.db, owned: ["": []], names: Self.names)
        let plain = ["Lightning Bolt", "Instant", "Lightning Bolt deals 3 damage to any target.", "3ED • EN"]
        var ownedMs = 0.0, plainMs = 0.0
        for _ in 0..<80 {
            var t = Date(); _ = owned.match(frame); ownedMs += Date().timeIntervalSince(t) * 1000
            t = Date(); XCTAssertEqual(m.match(plain)?.exact, true); plainMs += Date().timeIntervalSince(t) * 1000
        }
        print("Matcher per frame: cluttered first 20 \(Int(first / 20)) ms, last 20 \(Int(last / 20)) ms; owned-only \(Int(ownedMs / 80)) ms; plain \(Int(plainMs / 80)) ms")
        // Evidence still carries across frames: a set code, then nothing, then the number.
        let triome = ["Zagoth Triome", "Land - Swamp Forest Island"]
        _ = m.match(triome + ["IKO • EN"])
        for _ in 0..<(CardMatcher.frames - 2) { _ = m.match(triome) }
        let got = m.match(triome + ["313"])
        XCTAssertEqual(got?.printing.set, "iko"); XCTAssertEqual(got?.printing.cn, "313"); XCTAssertEqual(got?.exact, true)
        // Frames that name nothing forget the card after `misses`; a take forgets it at once.
        for _ in 0..<CardMatcher.misses { XCTAssertNil(m.match(["nothing here"])) }
        XCTAssertEqual(m.rememberedFrames, 0)
        _ = m.match(frame); m.took()
        XCTAssertEqual(m.rememberedFrames, 0)
    }

    /// A name is never read from below the type line (2026-11-01): the title is above it, and the flavor text
    /// under it names people who are cards too. An Ice Age Counterspell whose title the camera missed went in as
    /// Gustha Ebbasdotter (Mystery Booster Commander) from "-Gustha Ebbasdotter," on John's phone, three takes in a
    /// row (report 17843b42, in testdata/scan/reports).
    func testNoNameFromBelowTheTypeLine() {
        let m = matcher()
        let flavor = ["Interrupt", "Counter target spell.", "\"The duel was going badly for me,", "and Zur thought I was finished. He",
                      "-Lightning Bolt,", "Kjeldoran Royal Mage", "Illus. L.A. Williams"]
        XCTAssertNil(m.match(flavor), "a card named in the flavor text isn't the card")
        XCTAssertEqual(m.match(["Lightning Bolt", "Instant", "Lightning Bolt deals 3 damage to any target."])?.oracle.name, "Lightning Bolt")
        // Without a type line read, a multi-word name lower down still counts, as before.
        XCTAssertEqual(m.match(["smudge", "glare", "more glare", "Lightning Bolt", "deals 3 damage to any target."])?.oracle.name, "Lightning Bolt")
    }

    /// Split cards (2026-11-08, README § Split cards): Vision's reads of Boom // Bust, Fire // Ice, Wear // Tear, a
    /// fuse card, an Aftermath card, Dead // Gone and a Room, each held four ways (testdata/scan/split.json, from
    /// tools/split.swift). Put in the text's own order (ScanOrder), every read names its card; in the order they come
    /// (top of each line's box first, as the scanners handed them on before), never a wrong card. Same cases on Android.
    func testSplitCards() throws {
        struct Read: Decodable {
            struct L: Decodable { let t: String; let q: [Double] }
            let id: String, name: String, set: String, cn: String, lines: [L]
        }
        let reads = try JSONDecoder().decode([Read].self, from: Data(contentsOf: root.appending(path: "split.json")))
        XCTAssertEqual(reads.count, 36)
        var ordered = Tally(), unordered = Tally(), misses: [String] = []
        for r in reads {
            let c = Case(id: r.id, name: r.name, set: r.set, cn: r.cn, tags: [])
            let lines = r.lines.map { l in ScanOrder.Line(text: l.t, quad: stride(from: 0, to: 8, by: 2).map { i in CGPoint(x: l.q[i], y: l.q[i + 1]) }) }
            let o = ScanOrder.order(lines)
            let m = matcher().match(o.lines), plain = matcher().match(lines.map(\.text))
            let before = ordered.name
            grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &ordered)
            grade(c, plain?.oracle, plain?.printing, exact: plain?.exact ?? false, into: &unordered)
            if ordered.name == before { misses.append("\(r.id) (\(ScanOrder.name(o.turn))): \(m?.oracle.name ?? "nothing") from \(o.lines.prefix(4))") }
        }
        print("Split cards (\(reads.count) reads): ordered \(ordered.line); as they came \(unordered.line)" + misses.map { "\n  missed \($0)" }.joined())
        XCTAssertEqual(ordered.wrong + unordered.wrong, 0, "a wrong card from a split card")
        XCTAssertEqual(ordered.name, reads.count, "a split card read in the text's order that named nothing")
    }

    /// Either half's name, or both, name a split card; a half that's also another card's name stays that card's.
    func testSplitHalves() {
        let m = matcher()
        XCTAssertEqual(m.match(["Ice", "Instant", "Tap target permanent.", "Draw a card."])?.oracle.name, "Fire // Ice")
        XCTAssertEqual(m.match(["Tear", "Instant", "Destroy target enchantment."])?.oracle.name, "Wear // Tear")
        XCTAssertEqual(m.match(["Boom", "Bust", "Sorcery", "Sorcery"])?.oracle.name, "Boom // Bust")
        XCTAssertEqual(m.match(["Memory", "Sorcery", "Aftermath (Cast this spell only from your graveyard.)"])?.oracle.name, "Commit // Memory")
        // The halves out of order, under their type lines (report 76cbcce6, an MH2 Fire // Ice held upright).
        XCTAssertEqual(m.match(["Tap target permanent.", "Draw a card.", "Ice", "Instant", "divided as you choose",
                                "Fire deals 2 damage", "among one or two", "Fire", "Instant", "targets."])?.oracle.name, "Fire // Ice")
        // One half alone, low down, is still nothing (it's often a word in rules text).
        XCTAssertNil(m.match(["Instant", "Tap target permanent.", "Draw a card.", "Ice"]))
        // Liberate, Chaos and Blood are cards (or tokens) of their own.
        XCTAssertEqual(m.match(["Liberate", "Instant", "Exile target creature you control."])?.oracle.name, "Liberate")
        XCTAssertNil(m.match(["Blood", "Token Artifact - Blood"]))
        XCTAssertEqual(m.match(["Bind", "Liberate", "Instant", "Instant"])?.oracle.name, "Bind // Liberate")
        XCTAssertTrue(ScanNames.split(name: "Fire // Ice", typeLine: "Instant // Instant"))
        XCTAssertTrue(ScanNames.split(name: "Commit // Memory", typeLine: "Instant // Sorcery"))
        XCTAssertTrue(ScanNames.split(name: "Bottomless Pool // Locker Room", typeLine: "Enchantment — Room // Enchantment — Room"))
        XCTAssertFalse(ScanNames.split(name: "Bonecrusher Giant // Stomp", typeLine: "Creature — Giant // Instant — Adventure"))
        XCTAssertFalse(ScanNames.split(name: "Spikefield Hazard // Spikefield Cave", typeLine: "Instant // Land"))
    }

    /// ScanOrder keeps mostly upright text as it came, and reads turned text in its own direction.
    func testScanOrder() {
        func line(_ t: String, _ x: Double, _ y: Double, _ turn: ScanOrder.Turn, len: Double = 100) -> ScanOrder.Line {
            let h = 20.0
            let q: [(Double, Double)] = switch turn {
            case .upright: [(x, y), (x + len, y), (x + len, y + h), (x, y + h)]
            case .clockwise: [(x, y), (x, y + len), (x - h, y + len), (x - h, y)]
            case .upsideDown: [(x, y), (x - len, y), (x - len, y - h), (x, y - h)]
            case .counterclockwise: [(x, y), (x, y - len), (x + h, y - len), (x + h, y)]
            }
            return .init(text: t, quad: q.map { CGPoint(x: $0.0, y: $0.1) })
        }
        // A card turned clockwise: its top faces the frame's right edge, so the title is the rightmost line.
        let cw = [line("Instant", 400, 100, .clockwise), line("Rules text here", 200, 100, .clockwise), line("Fire", 600, 100, .clockwise),
                  line("Ice", 600, 500, .clockwise)]
        XCTAssertEqual(ScanOrder.order(cw).lines, ["Fire", "Ice", "Instant", "Rules text here"])
        XCTAssertEqual(ScanOrder.order(cw).turn, .clockwise)
        let ccw = [line("Rules", 300, 900, .counterclockwise), line("Boom", 50, 900, .counterclockwise), line("Bust", 50, 400, .counterclockwise)]
        XCTAssertEqual(ScanOrder.order(ccw).lines, ["Boom", "Bust", "Rules"])
        let down = [line("Lightning Bolt deals 3", 700, 100, .upsideDown), line("Lightning Bolt", 700, 900, .upsideDown)]
        XCTAssertEqual(ScanOrder.order(down).lines, ["Lightning Bolt", "Lightning Bolt deals 3"])
        // Mostly upright: as it came, a sideways line beside it included.
        let up = [line("Shock", 10, 10, .upright), line("Noise", 500, 5, .clockwise, len: 30), line("Instant", 10, 400, .upright)]
        XCTAssertEqual(ScanOrder.order(up).lines, ["Shock", "Noise", "Instant"])
        XCTAssertEqual(ScanOrder.order(up).turn, .upright)
        XCTAssertEqual(ScanOrder.order([]).lines, [])
    }

    func testCollectorLanguage() {
        XCTAssertEqual(Collector(["154/264 M", "WAR • JP Artist"], sets: ["war"]).lang, "ja")
        XCTAssertEqual(Collector(["RIX • RU"], sets: ["rix"]).lang, "ru")
        XCTAssertEqual(Collector(["M21 • EN"], sets: ["m21"]).lang, "en")
        XCTAssertNil(Collector(["one IT • ES ate"], sets: ["war"]).lang, "not a set code")
        XCTAssertNil(Collector(["WAR • JP", "WAR • EN"], sets: ["war"]).lang, "two codes")
    }

    /// 1993–94 cards print no set, number or year, so nothing read tells Alpha, Beta, Unlimited and Revised apart.
    /// They went in as Alpha, the rarest (scan reports 2026-10-26: Channel, Tundra, Counterspell were Revised,
    /// Scrubland Unlimited, a French Sol Ring Foreign Black Border). Now: the most printed, the name's language on an
    /// old frame, and after a fix by hand the set picked (nearest its number: MH2's retro fetchlands, not the regular ones).
    func testOldPrintings() throws {
        let m = matcher()
        func got(_ lines: [String]) -> String {
            guard let r = m.match(lines) else { return "nothing" }
            return "\(r.printing.set) \(r.printing.cn)\(r.exact ? " exact" : "")"
        }
        XCTAssertEqual(got(["Channel", "Sorcery", "Until end of turn, you may add", "Illus. © Richard Thomas"]), "3ed 188")
        XCTAssertEqual(got(["Counterspell", "Counters target spell", "as it is being cast."]), "3ed 54", "no bottom read")
        XCTAssertEqual(got(["Black Lotus", "Mono Artifact", "Illus. Christopher Rush"]), "2ed 233", "not in Revised")
        XCTAssertEqual(got(["Anneau solaire", "Artefact", "Illus, Mark Tedin"]), "fbb 274", "French, old frame")
        XCTAssertEqual(got(["Channel", "Sorcery", "Illus. Richard Thomas", "© 1995 Wizards of the Coast, Inc."]), "4ed 236",
                       "4th Edition prints a year")

        let printings = { (name: String) in Self.db.printings(oracleIdx: Self.expectedIdx[CardName.norm(name)]!) }
        m.picked(printings("Tundra").first { $0.set == "leb" }!)
        XCTAssertEqual(got(["Scrubland", "Counts as both plains and swamp", "Illus. © Jesper Myrfors"]), "leb 282", "Beta, as picked")
        XCTAssertEqual(got(["Channel", "Sorcery", "Illus. Richard Thomas", "© 1995 Wizards of the Coast, Inc."]), "4ed 236",
                       "what's read still wins")

        XCTAssertEqual(got(["Marsh Flats", "Land", "Pay 1 life, Sacrifice Marsh Flats"]), "zen 219", "the original, before a fix")
        m.picked(printings("Marsh Flats").first { $0.set == "mh2" && $0.cn == "437" }!)
        XCTAssertEqual(got(["Scalding Tarn", "Land", "Pay 1 life, Sacrifice Scalding Tarn"]), "mh2 439", "retro, as picked")
        XCTAssertEqual(got(["Arid Mesa", "Land"]), "mh2 436")
    }

    /// The border colour read from the camera frame (2026-11-01; testdata/scan/border.json from
    /// testdata/scan/tools/border.swift): the rule over the luma samples of every photo with a border, as the iOS
    /// scanner samples around Vision's rectangle (`quad`) and as Android samples along the guide box (`g100`), each
    /// also on a dim, low-contrast copy (`dim.`). What counts is the 1993 frame (the only cards it picks between):
    /// most read right, almost none wrong; a wrong read is no worse than today's Revised guess.
    func testBorderRule() throws {
        struct Read: Decodable { let inside: [[Int]], outside: [[Int]], far: [[Int]], inner: [Int] }
        struct Photo: Decodable { let expected: String, reads: [String: Read] }
        let photos = try JSONDecoder().decode([String: Photo].self, from: Data(contentsOf: root.appending(path: "border.json")))
        let old = Set(try self.photos().filter { $0.tags.contains("frame93") }.map(\.id))
        var report = ["Border (\(photos.count) photos, \(old.filter { photos[$0] != nil }.count) old frame):"]
        var tallies: [String: (right: Int, wrong: Int, unknown: Int, oldRight: Int, oldWrong: Int, oldN: Int)] = [:]
        for read in ["quad", "dim.quad", "g100", "dim.g100"] {
            var t = (right: 0, wrong: 0, unknown: 0, oldRight: 0, oldWrong: 0, oldN: 0)
            for (file, p) in photos {
                guard let r = p.reads[read] else { continue }
                let got = ScanBorder.classify(.init(inside: r.inside, outside: r.outside, far: r.far, inner: r.inner))
                let isOld = old.contains(file)
                if isOld { t.oldN += 1 }
                if got.rawValue == p.expected { t.right += 1; if isOld { t.oldRight += 1 } }
                else if got == .unknown { t.unknown += 1 }
                else { t.wrong += 1; if isOld { t.oldWrong += 1; report.append("    WRONG \(read) \(file): \(got)") } }
            }
            tallies[read] = t
            report.append("  \(read): old frame right \(t.oldRight)/\(t.oldN), wrong \(t.oldWrong); all right \(t.right), wrong \(t.wrong), unknown \(t.unknown)")
        }
        print(report.joined(separator: "\n"))
        func oldRate(_ read: String) -> Double { Double(tallies[read]!.oldRight) / Double(tallies[read]!.oldN) }
        // What the set reached on 2026-11-01: quad 47/58 (1 wrong: a full-art basic), g100 31/58, dim 37/58 and 26/58.
        XCTAssertGreaterThanOrEqual(oldRate("quad"), 0.78); XCTAssertLessThanOrEqual(tallies["quad"]!.oldWrong, 1)
        XCTAssertGreaterThanOrEqual(oldRate("g100"), 0.5); XCTAssertLessThanOrEqual(tallies["g100"]!.oldWrong, 1)
        XCTAssertGreaterThanOrEqual(oldRate("dim.quad"), 0.6); XCTAssertEqual(tallies["dim.quad"]!.oldWrong, 0)
        XCTAssertGreaterThanOrEqual(oldRate("dim.g100"), 0.42); XCTAssertEqual(tallies["dim.g100"]!.oldWrong, 0)
        // Modern cards in sleeves read the sleeve's margin as a white border; harmless (the border only picks between
        // 1993–94 printings), but keep it from growing.
        XCTAssertLessThanOrEqual(tallies["quad"]!.wrong, 10)
        // Too few samples, or none, is unknown, never a crash.
        XCTAssertEqual(ScanBorder.classify(.init(inside: [], outside: [], far: [], inner: [])), .unknown)
        XCTAssertEqual(ScanBorder.classify(.init(inside: [[], [], [], []], outside: [[1], [1], [1], [1]], far: [[1], [1], [1], [1]], inner: [1])), .unknown)
    }

    /// The border breaks the Alpha / Beta / Unlimited / Revised tie (2026-11-01): black picks Beta (the commoner black
    /// border), white Revised, a French name with a black border Foreign Black Border; anything printed that was read
    /// still wins, and so does the set last picked by hand. The read is remembered over the card's frames, so a frame
    /// that couldn't tell still picks from an earlier one.
    func testBorderPicksPrinting() {
        let m = matcher()
        func got(_ lines: [String], _ border: ScanBorder) -> String {
            guard let r = m.match(lines, border: border) else { return "nothing" }
            return "\(r.printing.set) \(r.printing.cn)\(r.exact ? " exact" : "")"
        }
        let counterspell = ["Counterspell", "Interrupt", "Counter target spell.", "Illus. Mark Poole"]
        XCTAssertEqual(got(counterspell, .unknown), "3ed 54", "no border read: Revised, as before")
        XCTAssertEqual(got(counterspell, .black), "leb 55", "black: Beta over Alpha")
        m.took()
        XCTAssertEqual(got(counterspell, .white), "3ed 54", "white: Revised over Unlimited")
        m.took()
        XCTAssertEqual(got(["Counterspell", "Counters target spell", "as it is being cast."], .black), "leb 55", "no Illus. line read either")
        m.took()
        XCTAssertEqual(got(["Black Lotus", "Mono Artifact", "Illus. Christopher Rush"], .white), "2ed 233", "white, not in Revised")
        m.took()
        XCTAssertEqual(got(["Contresort", "Interruption", "Illus. Mark Poole"], .black), "fbb 54", "French, black: Foreign Black Border")
        m.took()
        XCTAssertEqual(got(["Contresort", "Interruption", "Illus. Mark Poole"], .white), "fbb 54", "the name's language beats the border")
        m.took()
        XCTAssertEqual(got(["Counterspell", "Interrupt", "Illus. Mark Poole", "© 1995 Wizards of the Coast, Inc."], .black), "4ed 65",
                       "a year read wins over the border")
        m.took()
        XCTAssertEqual(got(["Counterspell", "Instant", "ICE • EN"], .white), "ice 64 exact", "a set code read wins")
        m.took()
        // Remembered over the card's frames: a frame with no read still picks from the last one that had.
        XCTAssertEqual(got(counterspell, .black), "leb 55")
        XCTAssertEqual(got(counterspell, .unknown), "leb 55", "the border read two frames ago still counts")
        m.took()
        XCTAssertEqual(got(counterspell, .unknown), "3ed 54", "forgotten with the take")
        // A hand-picked set still carries to the next card, whatever the border says.
        let printings = { (name: String) in Self.db.printings(oracleIdx: Self.expectedIdx[CardName.norm(name)]!) }
        m.picked(printings("Tundra").first { $0.set == "lea" }!)
        XCTAssertEqual(got(counterspell, .white), "lea 54", "Alpha, as picked, over the white border")
    }

    /// Upright pixels of the portrait image in the camera's landscape buffer (read by Vision with orientation .right;
    /// checked against Vision in testdata/scan/tools/border.swift `check`): the top-left lands at the buffer's
    /// bottom-left. And what the sampling costs per frame.
    func testBorderSamplingCostAndMapping() {
        let upright = CGSize(width: 1080, height: 1920)
        func buffer(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let b = CardTextScanner.Coordinator.bufferPixel(CGPoint(x: x, y: y), upright: upright)
            return [b.x, b.y]
        }
        XCTAssertEqual(buffer(0, 0), [0, 1079])
        XCTAssertEqual(buffer(1079, 0), [0, 0])
        XCTAssertEqual(buffer(0, 1919), [1919, 1079])
        // A frame-sized luma plane with a white-bordered card in it; the samples and the rule per frame, both ways.
        var plane = [UInt8](repeating: 60, count: 1080 * 1920)
        for y in 400..<1500 { for x in 150..<930 { plane[y * 1080 + x] = (y < 450 || y >= 1450 || x < 200 || x >= 880) ? 230 : 120 } }
        for y in 1150..<1400 { for x in 240..<840 { plane[y * 1080 + x] = (x / 7 + y / 9) % 5 == 0 ? 20 : 215 } } // text box
        let luma: (CGPoint) -> Int = { p in Int(plane[max(0, min(1919, Int(p.y))) * 1080 + max(0, min(1079, Int(p.x)))]) }
        let quad = [CGPoint(x: 150, y: 400), CGPoint(x: 930, y: 400), CGPoint(x: 930, y: 1500), CGPoint(x: 150, y: 1500)]
        XCTAssertEqual(ScanBorder.classify(ScanBorder.samples(quad: quad, luma: luma)), .white)
        let guide = CGRect(x: 170, y: 430, width: 740, height: 1040) // the card a little bigger than the outline
        XCTAssertEqual(ScanBorder.classify(ScanBorder.samples(guide: guide, luma: luma)), .white)
        var t = Date()
        for _ in 0..<200 { _ = ScanBorder.classify(ScanBorder.samples(quad: quad, luma: luma)) }
        let quadMs = Date().timeIntervalSince(t) * 1000 / 200
        t = Date()
        for _ in 0..<200 { _ = ScanBorder.classify(ScanBorder.samples(guide: guide, luma: luma)) }
        let guideMs = Date().timeIntervalSince(t) * 1000 / 200
        print(String(format: "Border per frame (Debug): rectangle %.3f ms (120 reads), guide %.3f ms (624 reads)", quadMs, guideMs))
        XCTAssertLessThan(quadMs, 2); XCTAssertLessThan(guideMs, 5)
    }

    /// An old card whose name reads in every other frame or so (no printing to read, so the slow take): named 6 times
    /// in 2.4 s with gaps of 0.6 s, Crusade was never taken while a gap over 0.5 s started it over.
    func testOldFrameTaken() throws {
        let clips = try JSONDecoder().decode([String: [[String]]].self, from: Data(contentsOf: root.appending(path: "motion.json")))
        XCTAssertEqual(take(clips["016-crusade.jpg"]!)?.0.name, "Crusade")
        // Named twice, a second apart: not enough to take.
        let m = matcher()
        var steady = ScanSteadiness()
        let lines = ["Crusade", "Enchantment", "All white creatures get +1/+1."]
        XCTAssertNil(steady.feed(m.match(lines), at: Date(timeIntervalSince1970: 0)))
        XCTAssertNil(steady.feed(nil, at: Date(timeIntervalSince1970: 0.4)))
        XCTAssertNil(steady.feed(m.match(lines), at: Date(timeIntervalSince1970: 0.9)))
        XCTAssertNotNil(steady.feed(m.match(lines), at: Date(timeIntervalSince1970: 1.1)), "a third read takes it")
    }

    /// A card the scanner couldn't read between ones it could is a miss too (2026-10-26: old cards typed in by hand
    /// after scanning others sent nothing, since only a scan with no take was reported).
    func testMissAfterTake() {
        var f = ScanFrames()
        for _ in 0..<3 { f.add(["Scrubland", "Land"], named: true) }
        f.took()
        f.add([])
        for k in 0..<ScanFrames.missed { f.add(["D vamp \(k)", "Tap to add 4 to"]) }
        XCTAssertEqual(f.unnamed, ScanFrames.missed, "blank frames don't count")
        XCTAssertEqual(f.unnamedFrames.count, ScanFrames.keep)
        XCTAssertEqual(f.unnamedFrames.last?.first, "D vamp \(ScanFrames.missed - 1)")
        f.took()
        XCTAssertEqual(f.unnamed, 0)
    }

    /// Cards printed in other languages, read two ways: `accurate` is OCR in the phone's language (Cyrillic comes
    /// through, Chinese, Japanese and Korean don't), `multi` is OCR that detects the language, as the scanner reads
    /// since 2026-10-16. Names in other languages come from the catalog pack's N lines.
    func testForeignCards() throws {
        let ocr = try JSONDecoder().decode([String: [String: [String]]].self, from: Data(contentsOf: root.appending(path: "ocr.json")))
        let cases = try photos().filter { $0.lang != "en" }
        let cjk: Set<String> = ["ja", "ko", "zhs", "zht"]
        var report = ["Cards in other languages (\(cases.count)):"]
        var groups: [String: [String: Tally]] = [:]
        // Cards named right, and of those, put in their own language (as added with English picked for adds).
        var langs: [String: (named: Int, right: Int)] = [:]
        for mode in ["accurate", "multi", "title"] {
            var byLang: [String: Tally] = [:]
            var byGroup: [String: Tally] = [:]
            for c in cases {
                guard let lines = ocr[c.id]?[mode] else { continue }
                let m = matcher().match(lines)
                if let got = m?.oracle, got.idx != Self.expectedIdx[CardName.norm(c.name)] {
                    report.append("    WRONG \(mode) \(c.id): \(got.name)")
                }
                if let m, m.oracle.idx == Self.expectedIdx[CardName.norm(c.name)] {
                    let lang = Languages.forScan(m.printing, read: m.langs, picked: "en")
                    langs[mode, default: (0, 0)].named += 1
                    if lang == c.lang { langs[mode, default: (0, 0)].right += 1 }
                    else if mode != "title" { report.append("    LANGUAGE \(mode) \(c.id): \(lang), is \(c.lang)") }
                }
                let group = cjk.contains(c.lang) ? "Chinese, Japanese, Korean" : "Latin and Cyrillic"
                grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &byLang[c.lang, default: Tally()])
                grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &byGroup[group, default: Tally()])
            }
            groups[mode] = byGroup
            report.append("  \(mode):")
            report += byGroup.keys.sorted().map { "    \($0): \(byGroup[$0]!.line)" }
            report += byLang.keys.sorted().map { "      \($0): \(byLang[$0]!.line)" }
            if let l = langs[mode] { report.append("    language right \(l.right)/\(l.named) (\(pct(l.right, l.named)))") }
        }
        print(report.joined(separator: "\n"))
        // `title` (a second pass on the deskewed title bar) is measured, not yet read by the scanner: README.
        for (mode, byGroup) in groups where mode != "title" {
            for (group, t) in byGroup { XCTAssertEqual(t.wrong, 0, "a wrong card, \(group), \(mode)") }
        }
        let latin = groups["accurate"]!["Latin and Cyrillic"]!
        XCTAssertGreaterThanOrEqual(Double(latin.name) / Double(latin.n), Floor.foreignName)
        let cjkNames = groups["multi"]!["Chinese, Japanese, Korean"]!
        XCTAssertGreaterThanOrEqual(Double(cjkNames.name) / Double(cjkNames.n), Floor.cjkName)
        for mode in ["accurate", "multi"] {
            let l = langs[mode]!
            XCTAssertGreaterThanOrEqual(Double(l.right) / Double(l.named), Floor.language, "cards put in their own language, \(mode)")
        }
    }

    /// Each still photo as a steady 2.4 s clip (12 frames, 200 ms apart) through ScanLanguage and ScanSteadiness, as
    /// the scanner runs: frames read like `accurate` (the phone's language) until text names no card for 0.6 s, then
    /// like `multi` (language detection), and back after misses. Nobody picks a language; this measures what finding
    /// it costs: cards taken, wrong cards, and time to take.
    func testLanguageDetection() throws {
        let ocr = try JSONDecoder().decode([String: [String: [String]]].self, from: Data(contentsOf: root.appending(path: "ocr.json")))
        let cjk: Set<String> = ["ja", "ko", "zhs", "zht"]
        var groups: [String: Tally] = [:]
        var times: [String: [TimeInterval]] = [:]
        var report = ["Language detection (each photo held 2.4 s, starting in the phone's language):"]
        for c in try photos() {
            guard let reads = ocr[c.id], let latin = reads["accurate"], let any = reads["multi"] else { continue }
            let group = c.lang == "en" ? "English" : cjk.contains(c.lang) ? "Chinese, Japanese, Korean" : "Latin and Cyrillic"
            let matcher = matcher()
            var steady = ScanSteadiness(), language = ScanLanguage(readers: 1)
            var got: (CatalogOracle, CatalogPrinting, Bool, TimeInterval)?
            for k in 0..<12 {
                let at = Date(timeIntervalSince1970: Double(k) * 0.2)
                let lines = language.mode == .latin ? latin : any
                let m = matcher.match(lines)
                if let taken = steady.feed(m, at: at), let m { got = (m.oracle, taken.0, taken.1, Double(k) * 0.2); break }
                language.feed(matched: m != nil, text: !lines.isEmpty, at: at)
            }
            if let got, got.0.idx != Self.expectedIdx[CardName.norm(c.name)] { report.append("    WRONG \(c.id): \(got.0.name)") }
            grade(c, got?.0, got?.1, exact: got?.2 ?? false, into: &groups[group, default: Tally()])
            if let got { times[group, default: []].append(got.3) }
        }
        for g in groups.keys.sorted() {
            let ts = (times[g] ?? []).sorted()
            report.append("  \(g): taken \(groups[g]!.line), median \(ts.isEmpty ? 0 : (ts[ts.count / 2] * 10).rounded() / 10) s")
        }
        print(report.joined(separator: "\n"))
        for (g, t) in groups { XCTAssertEqual(t.wrong, 0, "a wrong card taken, \(g)") }
        let english = groups["English"]!, cjkCards = groups["Chinese, Japanese, Korean"]!
        XCTAssertGreaterThanOrEqual(Double(english.name) / Double(english.n), Floor.englishName)
        XCTAssertGreaterThanOrEqual(Double(cjkCards.name) / Double(cjkCards.n), Floor.cjkName)
    }

    /// Frames 200 ms apart, as the movement clips were made. Returns the first card taken and when.
    private func take(_ frames: [[String]]) -> (CatalogOracle, CatalogPrinting, Bool, TimeInterval)? {
        let matcher = matcher()
        var steady = ScanSteadiness()
        for (k, lines) in frames.enumerated() {
            let t = Double(k) * 0.2
            let m = matcher.match(lines)
            if let got = steady.feed(m, at: Date(timeIntervalSince1970: t)), let m { return (m.oracle, got.0, got.1, t) }
        }
        return nil
    }

    func testMovement() throws {
        let clips = try JSONDecoder().decode([String: [[String]]].self, from: Data(contentsOf: root.appending(path: "motion.json")))
        let cases = try photos()
        var report = ["Movement clips (2.4 s each, English cards):"]
        var byKind: [String: Tally] = [:]
        var times: [String: [TimeInterval]] = [:]
        for (i, c) in cases.enumerated() where !c.tags.contains("lang") {
            guard let frames = clips[c.id] else { continue }
            let kind = ["settle", "shake", "sweep"][i % 3] // as testdata/scan/tools/ocr.swift assigns them
            let got = take(frames)
            grade(c, got?.0, got?.1, exact: got?.2 ?? false, into: &byKind[kind, default: Tally()])
            if let got { times[kind, default: []].append(got.3) }
        }
        for kind in ["settle", "shake", "sweep"] {
            let ts = (times[kind] ?? []).sorted()
            report.append("  \(kind): taken \(byKind[kind]!.line), median \(ts.isEmpty ? 0 : ts[ts.count / 2]) s")
        }
        print(report.joined(separator: "\n"))
        for (kind, t) in byKind { XCTAssertEqual(t.wrong, 0, "a wrong card taken while moving (\(kind))") }
        XCTAssertGreaterThanOrEqual(Double(byKind["settle"]!.name) / Double(byKind["settle"]!.n), 0.9)
        XCTAssertGreaterThanOrEqual(Double(byKind["shake"]!.name) / Double(byKind["shake"]!.n), 0.88)
        XCTAssertEqual(byKind["sweep"]!.name, 0, "a card swept past is never taken")
    }

    /// Scan corrections people reported (testdata/scan/tools/export_reports.py): each is a clip of the frames
    /// that led to the wrong take, and the card it really was.
    func testReportedCorrections() throws {
        let dir = root.appending(path: "reports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        struct Report: Decodable { let id: String; let frames: [[String]]; let name: String?; let set: String?; let cn: String? }
        var t = Tally()
        var failures: [String] = []
        for file in files where file.pathExtension == "json" {
            let r = try JSONDecoder().decode(Report.self, from: Data(contentsOf: file))
            guard let name = r.name else { continue }
            let c = Case(id: r.id, name: name, set: r.set ?? "*", cn: r.cn ?? "*", tags: [])
            let before = t
            let got = take(r.frames)
            grade(c, got?.0, got?.1, exact: got?.2 ?? false, into: &t)
            let right = t.name > before.name && (c.set == "*" || t.printingOK > before.printingOK)
            if !right {
                failures.append("\(r.id): wanted \(name) \(c.set) \(c.cn), got \(got.map { "\($0.0.name) \($0.1.setLabel)\($0.2 ? " (sure)" : "")" } ?? "nothing")")
            }
        }
        print("Reported corrections (\(t.n)): \(t.line)" + failures.map { "\n  still wrong: \($0)" }.joined())
        // Reports are the cases that went wrong before. Since the frame and artist evidence of 2026-10-28, the
        // printing is right in most of them; the rest are what no text tells (The List, prerelease stamps the camera
        // can't read, Unlimited vs Revised), so the floor sits under what the set reached then.
        XCTAssertEqual(t.wrong, 0, "a reported clip named the wrong card")
        XCTAssertGreaterThanOrEqual(Double(t.printingOK) / Double(max(t.printingChecked, 1)), Floor.reportPrinting)
    }
}
