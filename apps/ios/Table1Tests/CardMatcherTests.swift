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
        for mode in ["accurate", "fast", "small", "multi", "title", "bottom"] {
            var all = Tally(), english = Tally(), foreign = Tally()
            var byTag: [String: Tally] = [:]
            for c in cases {
                guard let lines = ocr[c.id]?[mode] else { continue }
                let m = matcher().match(lines)
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
        print(report.joined(separator: "\n"))
        // Other languages have their own test (testForeignCards).
        let accurate = results["accurate"]!, english = englishResults["accurate"]!
        XCTAssertEqual(accurate.wrong, 0, "a wrong card from a steady photo")
        XCTAssertGreaterThanOrEqual(Double(english.name) / Double(english.n), Floor.englishName)
        XCTAssertGreaterThanOrEqual(Double(english.printingOK) / Double(english.printingChecked), Floor.englishPrinting)
        XCTAssertLessThanOrEqual(accurate.exactWrong, 2)
        XCTAssertLessThanOrEqual(results["fast"]!.wrong + results["small"]!.wrong, 1)
        XCTAssertEqual(results["multi"]!.wrong, 0, "a wrong card from a steady photo read as the scanner reads")
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
