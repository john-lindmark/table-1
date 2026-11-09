import XCTest
@testable import Table1

/* Re-pair a round (contract/repair-round-2026-11-09.md) against testdata/repair-round/cases.json. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata").standardized

private struct Cases: Decodable {
    struct M: Decodable { let is_bye: Bool; let status: String; let result_source: String?; let updated_at: String? }
    struct R: Decodable { let number: Int; let status: String; let pairings_published_at: String?; let matches: [M] }
    struct Want: Decodable { let round: Int; let changed: [Int]; let text: String }
    struct Prompt: Decodable { let name: String; let rounds: [R]; let want: Want? }
    struct CM: Decodable { let is_bye: Bool; let status: String }
    struct ConfirmWant: Decodable { let title, message: String; let results: Int }
    struct Confirm: Decodable { let name, label: String; let matches: [CM]; let want: ConfirmWant }
    struct Label: Decodable { let stage: String; let number: Int; let want: String }
    let prompt: [Prompt]
    let confirm: [Confirm]
    let labels: [Label]
}

final class RepairRoundTests: XCTestCase {
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: dir.appending(path: "repair-round/cases.json")))
    }

    private func round(_ r: Cases.R, _ i: Int) -> RoundRow {
        RoundRow(id: "r\(i)", eventId: "e", number: r.number, status: r.status, timerEndsAt: nil,
                 matches: r.matches.enumerated().map { j, m in
                     MatchRow(id: "m\(i)-\(j)", eventId: "e", roundId: "r\(i)", tableNumber: j + 1, isBye: m.is_bye, gameDraws: 0,
                              status: m.status, version: 0, disputed: false, reportedByUser: nil, matchSides: [],
                              resultSource: m.result_source, updatedAt: m.updated_at)
                 },
                 pairingsPublishedAt: r.pairings_published_at)
    }

    func testPrompt() throws {
        for c in try cases().prompt {
            let got = RepairRound.prompt(c.rounds.enumerated().map { round($1, $0) })
            XCTAssertEqual(got?.round, c.want?.round, c.name)
            XCTAssertEqual(got?.changed, c.want?.changed, c.name)
            XCTAssertEqual(got?.text, c.want?.text, c.name)
        }
    }

    func testConfirm() throws {
        for c in try cases().confirm {
            let got = RepairRound.confirm(label: c.label, matches: c.matches.map { (isBye: $0.is_bye, status: $0.status) })
            XCTAssertEqual(got.title, c.want.title, c.name)
            XCTAssertEqual(got.message, c.want.message, c.name)
            XCTAssertEqual(got.results, c.want.results, c.name)
        }
    }

    func testLabels() throws {
        for c in try cases().labels { XCTAssertEqual(RepairRound.label(stage: c.stage, number: c.number), c.want) }
    }
}
