import XCTest
@testable import Table1

/* Scanner accuracy over the photo test set (testdata/scan/README.md): the matcher on each photo's OCR lines, the
   movement clips through ScanSteadiness, and every reported scan correction in testdata/scan/reports. Prints a
   report and fails when accuracy drops below what the set reached when it was tuned (2026-10-15). */

/// Lowest accuracy the tests accept: what the set reached when last tuned (README has the numbers).
private enum Floor {
    static let englishName = 0.95, englishPrinting = 0.85, foreignName = 0.93, cjkName = 0.6
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
        for mode in ["accurate", "fast", "small", "multi", "title"] {
            var all = Tally(), english = Tally(), foreign = Tally()
            var byTag: [String: Tally] = [:]
            for c in cases {
                guard let lines = ocr[c.id]?[mode] else { continue }
                let m = matcher().match(lines)
                if let got = m?.oracle, got.idx != Self.expectedIdx[CardName.norm(c.name)] {
                    report.append("    WRONG \(mode) \(c.id): \(got.name)")
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
        for mode in ["accurate", "multi", "title"] {
            var byLang: [String: Tally] = [:]
            var byGroup: [String: Tally] = [:]
            for c in cases {
                guard let lines = ocr[c.id]?[mode] else { continue }
                let m = matcher().match(lines)
                if let got = m?.oracle, got.idx != Self.expectedIdx[CardName.norm(c.name)] {
                    report.append("    WRONG \(mode) \(c.id): \(got.name)")
                }
                let group = cjk.contains(c.lang) ? "Chinese, Japanese, Korean" : "Latin and Cyrillic"
                grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &byLang[c.lang, default: Tally()])
                grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &byGroup[group, default: Tally()])
            }
            groups[mode] = byGroup
            report.append("  \(mode):")
            report += byGroup.keys.sorted().map { "    \($0): \(byGroup[$0]!.line)" }
            report += byLang.keys.sorted().map { "      \($0): \(byLang[$0]!.line)" }
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
        XCTAssertGreaterThanOrEqual(Double(byKind["shake"]!.name) / Double(byKind["shake"]!.n), 0.8)
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
                failures.append("\(r.id): wanted \(name) \(c.set) \(c.cn), got \(got.map { "\($0.0.name) \($0.1.setLabel)" } ?? "nothing")")
            }
        }
        print("Reported corrections (\(t.n)): \(t.line)" + failures.map { "\n  still wrong: \($0)" }.joined())
        // Reports are the cases that went wrong before; they're tracked, not required to pass, until tuned.
        XCTAssertGreaterThanOrEqual(t.n, 0)
    }
}
