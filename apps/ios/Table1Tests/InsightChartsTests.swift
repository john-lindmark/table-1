import XCTest
@testable import Table1

/* Insights chart maths (contract/insights-2026-10-24.md). Every answer comes from testdata/insight-charts/cases.json,
   written by the Python reference there; the web's insightCharts.test.ts and Android's InsightChartsTest read the same
   file. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/insight-charts/cases.json").standardized

private struct Cases: Decodable {
    struct Ticks: Decodable { let `in`: [Double]; let out: [Double] }
    struct Segments: Decodable { let `in`: [Double?]; let out: [[[Double]]] }
    struct Wilson: Decodable { let `in`: [Int]; let out: [Double] }
    struct Fit: Decodable {
        struct AB: Decodable { let a: Double; let b: Double }
        let `in`: [[Double]]; let out: AB?
    }
    struct Spread: Decodable {
        let `in`: [Input]; let out: [Double]
        enum Input: Decodable {
            case list([Double]), number(Double)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let l = try? c.decode([Double].self) { self = .list(l) } else { self = .number(try c.decode(Double.self)) }
            }
            var list: [Double] { if case .list(let l) = self { l } else { [] } }
            var number: Double { if case .number(let n) = self { n } else { 0 } }
        }
    }
    struct Label: Decodable { let `in`: Double?; let out: String }
    struct Months: Decodable {
        let `in`: [Mixed]; let out: [[Mixed]]
        enum Mixed: Decodable {
            case s(String), i(Int)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let i = try? c.decode(Int.self) { self = .i(i) } else { self = .s(try c.decode(String.self)) }
            }
            var s: String { if case .s(let v) = self { v } else { "" } }
            var i: Int { if case .i(let v) = self { v } else { 0 } }
        }
    }
    let ticks: [Ticks]; let segments: [Segments]; let wilson: [Wilson]; let fit: [Fit]; let spread: [Spread]
    let pct: [Label]; let pct1: [Label]; let delta: [Label]; let months: [Months]
}

final class InsightChartsTests: XCTestCase {
    private var cases: Cases!

    override func setUpWithError() throws {
        cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
    }

    func testTicks() {
        for c in cases.ticks {
            let got = InsightCharts.ticks(c.in[0], c.in[1], count: Int(c.in[2]))
            XCTAssertEqual(got.count, c.out.count, "\(c.in)")
            for (a, b) in zip(got, c.out) { XCTAssertEqual(a, b, accuracy: 1e-9, "\(c.in)") }
        }
    }

    func testSegments() {
        for c in cases.segments {
            XCTAssertEqual(InsightCharts.segments(c.in).map { $0.map { [Double($0.0), $0.1] } }, c.out, "\(c.in)")
        }
    }

    func testWilson() {
        for c in cases.wilson {
            let w = InsightCharts.wilson(wins: c.in[0], n: c.in[1])
            XCTAssertEqual(w.lo, c.out[0], accuracy: 1e-6, "\(c.in)")
            XCTAssertEqual(w.hi, c.out[1], accuracy: 1e-6, "\(c.in)")
        }
    }

    func testFit() {
        for c in cases.fit {
            let f = InsightCharts.fit(c.in[0], c.in[1])
            if let o = c.out {
                XCTAssertEqual(f?.a ?? .nan, o.a, accuracy: 1e-7)
                XCTAssertEqual(f?.b ?? .nan, o.b, accuracy: 1e-7)
            } else { XCTAssertNil(f) }
        }
    }

    func testSpread() {
        for c in cases.spread {
            let got = InsightCharts.spread(c.in[0].list, gap: c.in[1].number, lo: c.in[2].number, hi: c.in[3].number)
            XCTAssertEqual(got.count, c.out.count)
            for (a, b) in zip(got, c.out) { XCTAssertEqual(a, b, accuracy: 1e-6, "\(c.in.map(\.list))") }
        }
    }

    func testLabels() {
        for c in cases.pct { XCTAssertEqual(InsightCharts.pct(c.in), c.out, "\(String(describing: c.in))") }
        for c in cases.pct1 { XCTAssertEqual(InsightCharts.pct1(c.in), c.out) }
        for c in cases.delta { XCTAssertEqual(InsightCharts.delta(c.in), c.out, "\(String(describing: c.in))") }
    }

    func testMonths() {
        for c in cases.months {
            let got = InsightCharts.months(from: c.in[0].s, days: c.in[1].i)
            XCTAssertEqual(got.map(\.0), c.out.map { $0[0].i })
            XCTAssertEqual(got.map(\.1), c.out.map { $0[1].s })
        }
    }
}
