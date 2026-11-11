import XCTest
@testable import Table1

/* The life tracker follows its player into the next round (contract/life-tracker-options-2026-10-20.md § Next round),
   against testdata/tracker-next/cases.json. */
private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/tracker-next/cases.json").standardized

final class TrackerNextTests: XCTestCase {
    private struct File: Decodable { let cases: [Case] }
    private struct Case: Decodable {
        let name: String
        let current: String?
        let answer: TrackerNextAnswer?
        let want: Want
    }
    private struct Want: Decodable {
        let `do`: String
        let matchId: String?
        let text: String?
    }

    func testSharedCases() throws {
        let file = try wireDecoder.decode(File.self, from: Data(contentsOf: casesURL))
        XCTAssertFalse(file.cases.isEmpty)
        for c in file.cases {
            let want: TrackerNext
            switch c.want.do {
            case "stay": want = .stay
            case "soon": want = .soon
            case "move": want = .move(c.want.matchId ?? "")
            case "notice": want = .notice(c.want.text ?? "")
            default: XCTFail("unknown \(c.want.do)"); continue
            }
            XCTAssertEqual(TrackerNext.decide(current: c.current, answer: c.answer), want, c.name)
        }
    }

    /// The server answers null when there is nothing newer.
    func testNullAnswerDecodesAsNothing() throws {
        XCTAssertEqual(TrackerNext.decide(current: "m1", answer: nil), .stay)
        let answer = try wireDecoder.decode(TrackerNextAnswer.self,
                                            from: Data(#"{"round": 2, "match_id": "m2", "bye": false}"#.utf8))
        XCTAssertEqual(TrackerNext.decide(current: "m1", answer: answer), .move("m2"))
    }
}
