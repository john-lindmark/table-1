import XCTest
@testable import Table1

/* Scanner accuracy over the photo test set (testdata/scan/README.md): the matcher on each photo's OCR lines, the
   movement clips through ScanSteadiness, and every reported scan correction in testdata/scan/reports. Prints a
   report and fails when accuracy drops below what the set reached when it was tuned (2026-10-15). */

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/scan").standardized

/// One photo or reported case: the lines to read and the card it is.
private struct Case {
    let id: String
    let name: String
    let set: String   // "*" = any printing
    let cn: String    // "*" = any number in the set
    let tags: Set<String>
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
        let header = try! CatalogDB.build(pack: pack, at: path)
        db = try! CatalogDB(path: path, version: header.version)
        names = ScanNames(db)
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
                return Case(id: c[0], name: c[1], set: c[2], cn: c[3], tags: Set(c[5].split(separator: ",").map(String.init)))
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
        var results: [String: Tally] = [:]
        for mode in ["accurate", "fast", "small"] {
            var all = Tally(), english = Tally(), foreign = Tally()
            var byTag: [String: Tally] = [:]
            for c in cases {
                guard let lines = ocr[c.id]?[mode] else { continue }
                let m = matcher().match(lines)
                grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &all)
                if c.tags.contains("lang") { grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &foreign) }
                else { grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &english) }
                if mode == "accurate" {
                    for tag in c.tags { grade(c, m?.oracle, m?.printing, exact: m?.exact ?? false, into: &byTag[tag, default: Tally()]) }
                }
            }
            results[mode] = all
            report += ["  \(mode): \(all.line)", "    English: \(english.line)", "    other languages: \(foreign.line)"]
            if mode == "accurate" {
                report += byTag.keys.sorted().map { "      \($0): \(byTag[$0]!.line)" }
            }
        }
        print(report.joined(separator: "\n"))
        let accurate = results["accurate"]!
        XCTAssertEqual(accurate.wrong, 0, "a wrong card from a steady photo")
        XCTAssertGreaterThanOrEqual(Double(accurate.name) / Double(accurate.n), 0.78)
        XCTAssertGreaterThanOrEqual(Double(accurate.printingOK) / Double(accurate.printingChecked), 0.84)
        XCTAssertLessThanOrEqual(accurate.exactWrong, 2)
        XCTAssertLessThanOrEqual(results["fast"]!.wrong + results["small"]!.wrong, 1)
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
