import XCTest
@testable import Table1

/* Support (contract/support-2026-11-10.md): the bundled FAQ and guide decode, and search follows
   testdata/support-search/cases.json from its Python reference (make_cases.py) over the same files. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/support-search/cases.json").standardized

private struct Cases: Decodable {
    struct Norm: Decodable { let text: String; let words: [String] }
    struct Case: Decodable { let query: String; let words: [String]; let partial: Bool; let count: Int; let top: [String] }
    let stop: [String]
    let limit: Int
    let normalize: [Norm]
    let cases: [Case]
}

final class SupportTests: XCTestCase {
    private func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testBundledFilesDecode() throws {
        let faq = try XCTUnwrap(Support.faq, "support/faq.json isn't in the bundle (project.yml resources)")
        let guide = try XCTUnwrap(Support.guide, "support/guide.json isn't in the bundle")
        XCTAssertFalse(faq.faqs.isEmpty)
        XCTAssertFalse(guide.entries.isEmpty)
        let sections = Set(guide.sections.map(\.id))
        for f in faq.faqs { if let g = f.guide { XCTAssertTrue(sections.contains(g), f.id) } }
    }

    func testSharedRule() throws {
        let c = try cases()
        XCTAssertEqual(Support.stop.sorted(), c.stop)
        XCTAssertEqual(Support.limit, c.limit)
        for n in c.normalize { XCTAssertEqual(Support.words(n.text), n.words, n.text) }
    }

    func testSearchCases() throws {
        for c in try cases().cases {
            let r = Support.search(c.query)
            XCTAssertEqual(Support.queryWords(c.query), c.words, c.query)
            XCTAssertEqual(r.partial, c.partial, c.query)
            XCTAssertEqual(r.hits.count, c.count, c.query)
            XCTAssertEqual(r.hits.prefix(8).map { "\($0.doc.kind):\($0.doc.id):\($0.score)" }, c.top, c.query)
        }
    }

    func testGroupsKeepOrder() {
        let groups = Support.groups("scanning")
        XCTAssertFalse(groups.isEmpty)
        XCTAssertEqual(groups.flatMap(\.entries).map(\.id), Support.guide?.entries.filter { $0.s == "scanning" }.map(\.id))
    }
}
