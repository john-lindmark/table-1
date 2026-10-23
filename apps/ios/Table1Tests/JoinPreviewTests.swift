import XCTest
@testable import Table1

/* The header over sign-in for a scanned join QR (JoinPreview in Data/Models.swift) against testdata/join-preview/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/join-preview/cases.json").standardized

private struct Cases: Decodable {
    struct Want: Decodable { let title: String; let facts: String }
    struct Case: Decodable { let name: String; let wire: JoinPreview.Wire; let want: Want? }
    let cases: [Case]
}

final class JoinPreviewTests: XCTestCase {
    func testSharedCases() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let cases = try decoder.decode(Cases.self, from: Data(contentsOf: casesURL)).cases
        XCTAssertGreaterThan(cases.count, 5)
        for c in cases {
            let got = JoinPreview(c.wire)
            XCTAssertEqual(got?.title, c.want?.title, c.name)
            XCTAssertEqual(got?.facts, c.want?.facts, c.name)
        }
    }
}
