import XCTest
@testable import Table1

/* Command zone rules (contract/command-zone-2026-10-27.md) against testdata/command-zone/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/command-zone/cases.json").standardized

private struct Cases: Decodable {
    struct Fit: Decodable { let type: String; let roles: [String] }
    struct Slots: Decodable { let name, format: String; let lines: [[String]]; let slots: [[String?]] }
    struct Filling: Decodable { let name: String; let lines: [String]; let slot: String?; let card: String; let result: [String] }
    struct Role: Decodable { let format, type, role: String }
    let fits: [Fit]
    let slots: [Slots]
    let filling: [Filling]
    let role: [Role]
}

final class CommandZoneTests: XCTestCase {
    func testSharedCases() throws {
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        let all: [CommandZone.Role] = [.commander, .partner, .oathbreaker, .signature]
        for f in c.fits {
            XCTAssertEqual(all.filter { $0.fits(f.type) }.map(\.rawValue), f.roles, f.type)
        }
        for s in c.slots {
            let got = CommandZone.slots(format: s.format, lines: s.lines.map { .init(cardId: $0[0], typeLine: $0[1]) })
            XCTAssertEqual(got.map { [$0.role.rawValue, $0.cardId] }, s.slots, s.name)
        }
        for f in c.filling {
            let lines = f.lines.map { CommandZone.Line(cardId: $0, typeLine: "") }
            let slot = CommandZone.Slot(role: .commander, cardId: f.slot)
            XCTAssertEqual(CommandZone.filling(lines, slot: slot, with: .init(cardId: f.card, typeLine: "")).map(\.cardId), f.result, f.name)
        }
        for r in c.role {
            XCTAssertEqual(CommandZone.role(format: r.format, typeLine: r.type), r.role)
        }
    }
}
