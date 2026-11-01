import SwiftUI
import XCTest
@testable import Table1

/* Performance budgets for the Library's hot paths, on the real catalog pack (testdata/scan/catalog.tsv.gz):
   building the local SQLite catalog from the pack, catalog search as you type, and the scanner matcher per camera
   frame. Budgets are for a Debug build in the Simulator on John's Mac, set ~3x above what it measured on
   2026-10-16 (pack 6.0 s, worst search 38 ms on "the", matcher mean 6.9 ms / p95 31 ms / max 198 ms over 1,455
   frames), so they catch regressions (a lost index, a per-frame allocation storm), not noise. Android's JVM test
   matches the same frames at 0.44 ms mean: the iOS Debug matcher is ~15x slower and worth a Release profile.
   The scanner reads a frame about every 200 ms; the matcher has to stay well inside that. */

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/scan").standardized

private enum Budget {
    static let packBuildMs = 18_000.0     // whole pack → SQLite, first launch / pack update
    static let searchMs = 120.0            // one catalog search, worst of the queries below
    static let matchMeanMs = 20.0          // matcher per frame, mean over every OCR read in the test set
    static let matchP95Ms = 90.0
}

final class ScannerPerfTests: XCTestCase {
    private static var db: CatalogDB!
    private static var names: ScanNames!
    private static var buildMs = 0.0

    override class func setUp() {
        super.setUp()
        let path = FileManager.default.temporaryDirectory.appending(path: "perf-test-catalog.sqlite").path
        try? FileManager.default.removeItem(atPath: path)
        let pack = try! CatalogPack.gunzip(Data(contentsOf: root.appending(path: "catalog.tsv.gz")))
        let t0 = CFAbsoluteTimeGetCurrent()
        let header = try! CatalogDB.build(pack: pack, at: path)
        buildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        db = try! CatalogDB(path: path, version: header.version)
        names = ScanNames(db)
    }

    func testPackBuild() {
        print("perf ios pack build: \(Int(Self.buildMs)) ms (budget \(Int(Budget.packBuildMs)))")
        XCTAssertLessThan(Self.buildMs, Budget.packBuildMs, "building the catalog from the pack got slower")
    }

    func testCatalogSearch() {
        let queries = ["li", "lig", "lightning bolt", "ligtning", "storm crow", "jace", "the", "æther", "fire // ice"]
        _ = Self.db.search("warm up")
        var worst = 0.0, worstQuery = ""
        for q in queries {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = Self.db.search(q)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if ms > worst { worst = ms; worstQuery = q }
        }
        print("perf ios catalog search: worst \(String(format: "%.1f", worst)) ms on \"\(worstQuery)\" (budget \(Budget.searchMs))")
        XCTAssertLessThan(worst, Budget.searchMs, "catalog search \"\(worstQuery)\"")
    }

    /// Every camera frame used to re-evaluate the scanner screen (builds up to 42: `frames` and `steady` were `@State`
    /// structs written about five times a second), and a re-evaluation costs more for every scanned row, so a frame
    /// got slower with every card taken. Since 2026-11-01 the per-frame state is a class (`CardScanView.Feed`) and a
    /// frame redraws nothing: this pins the type, and prints what one re-evaluation costs with no rows and with 60
    /// (what each frame paid before), as a Debug-Simulator number.
    @MainActor
    func testFrameRedrawsNothing() throws {
        func isClass<T>(_: T.Type) -> Bool { T.self is AnyObject.Type }
        XCTAssertTrue(isClass(CardScanView.Feed.self),
                      "the per-frame scanner state must stay a class: a @State struct redraws the screen, rows included, every frame")
        let matcher = CardMatcher(db: Self.db, owned: nil, names: Self.names)
        let m = try XCTUnwrap(matcher.match(["Lightning Bolt", "Instant", "Lightning Bolt deals 3 damage to any target.", "3ED • EN"]))
        func redrawMs(rows: Int) -> Double {
            let cards = (0..<rows).map { _ in
                ScannedCard(oracle: m.oracle, printing: m.printing, finish: "nonfoil", condition: "NM", exact: true)
            }
            func screen(_ i: Int) -> CardScanView {
                CardScanView(title: "Scan \(i)", doneLabel: "Add", scanned: cards, onDone: { _ in }, onCancel: {})
            }
            let host = UIHostingController(rootView: screen(0))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = host
            window.makeKeyAndVisible()
            /// Lays out and runs what SwiftUI left for the run loop, without waiting for anything new.
            func settle() -> Double {
                let t0 = CFAbsoluteTimeGetCurrent()
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
                return (CFAbsoluteTimeGetCurrent() - t0) * 1000
            }
            let first = settle()
            var times: [Double] = []
            for i in 1...20 {
                let t0 = CFAbsoluteTimeGetCurrent()
                host.rootView = screen(i)
                _ = settle()
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            window.isHidden = true
            print("perf ios scanner first layout with \(rows) rows: \(String(format: "%.1f", first)) ms")
            return times.sorted()[times.count / 2]
        }
        let none = redrawMs(rows: 0), sixty = redrawMs(rows: 60)
        print("perf ios scanner redraw: no rows \(String(format: "%.1f", none)) ms, 60 rows \(String(format: "%.1f", sixty)) ms per re-evaluation")
    }

    func testMatcherPerFrame() throws {
        let ocr = try JSONDecoder().decode([String: [String: [String]]].self,
                                           from: Data(contentsOf: root.appending(path: "ocr.json")))
        let frames = ocr.values.flatMap { $0.values }
        XCTAssertGreaterThan(frames.count, 500, "OCR fixture loaded")
        let matcher = CardMatcher(db: Self.db, owned: nil, names: Self.names)
        _ = matcher.match(frames[0])
        var times: [Double] = []
        times.reserveCapacity(frames.count)
        for lines in frames {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = matcher.match(lines)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        times.sort()
        let mean = times.reduce(0, +) / Double(times.count)
        let p95 = times[Int(Double(times.count) * 0.95)]
        print("perf ios matcher: \(times.count) frames, mean \(String(format: "%.2f", mean)) ms, p95 \(String(format: "%.2f", p95)) ms, max \(String(format: "%.1f", times.last!)) ms (budget mean \(Budget.matchMeanMs), p95 \(Budget.matchP95Ms))")
        XCTAssertLessThan(mean, Budget.matchMeanMs, "matcher mean per frame")
        XCTAssertLessThan(p95, Budget.matchP95Ms, "matcher p95 per frame")
    }
}
