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
    struct InDeck: Decodable { let name, role: String; let lines: [[String]]; let result: [String] }
    struct MoveIn: Decodable { let name: String; let slot: String?; let card: [Item]; let ops: [[Item]] }
    /// A string or a number in a case's array.
    enum Item: Decodable, Equatable {
        case s(String), n(Int)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .n(n) } else { self = .s(try c.decode(String.self)) }
        }
        var str: String { if case .s(let v) = self { v } else { "" } }
        var int: Int { if case .n(let v) = self { v } else { 0 } }
    }
    let fits: [Fit]
    let slots: [Slots]
    let filling: [Filling]
    let role: [Role]
    let in_deck: [InDeck]
    let move_in: [MoveIn]
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
        for d in c.in_deck {
            let role = try XCTUnwrap(CommandZone.Role(rawValue: d.role))
            let got = CommandZone.inDeck(role, d.lines.map { .init(cardId: $0[0], board: $0[1], typeLine: $0[2]) })
            XCTAssertEqual(got.map(\.cardId), d.result, d.name)
        }
        for m in c.move_in {
            let line = CommandZone.DeckLine(cardId: m.card[0].str, board: m.card[1].str, typeLine: "", qty: m.card[2].int)
            let got: [[Cases.Item]] = CommandZone.movingIn(line, slot: .init(role: .commander, cardId: m.slot)).map {
                switch $0 {
                case let .move(id, _, _, from, to): [.s("move"), .s(id), .s(from), .s(to)]
                case let .delta(id, _, _, board, by): [.s("delta"), .s(id), .s(board), .n(by)]
                }
            }
            XCTAssertEqual(got, m.ops, m.name)
        }
    }
}
