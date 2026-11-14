import XCTest
@testable import Table1

/* The decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md § Client rules) against
   testdata/deck-photo-lists/cases.json from make_cases.py (also web deckPhotoList.test.ts and Android DeckPhotoListTest). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/deck-photo-lists/cases.json").standardized

private struct Cases: Decodable {
    struct Row: Decodable { let brief: DeckListBrief?; let text: String }
    struct Target: Decodable { let eventType: String?; let format: String?; let target: Int? }
    struct Count: Decodable { let entries: [DeckListEntry]; let counts: [String: Int] }
    struct Size: Decodable { let main: Int; let target: Int?; let text: String }
    struct Card: Decodable { let cardId: String; let name: String }
    struct Edit: Decodable {
        let op: String
        let i: Int?
        let qty: Int?
        let board: String?
        let card: Card?
        let entries: [DeckListEntry]
        let out: [DeckListEntry]
    }
    struct DeckOut: Decodable { let entries: [[AnyValue]]; let skipped: Int }
    struct Deck: Decodable { let entries: [DeckListEntry]; let out: DeckOut }
    struct Name: Decodable { let event: String?; let player: String?; let mine: Bool; let name: String }
    struct Format: Decodable { let eventType: String?; let format: String?; let deck: String }
    let row: [Row]
    let target: [Target]
    let counts: [Count]
    let sizeLine: [Size]
    let edits: [Edit]
    let deckEntries: [Deck]
    let deckName: [Name]
    let deckFormat: [Format]
}

private enum AnyValue: Decodable {
    case string(String), int(Int)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
    }
    var text: String { switch self { case .string(let s): s; case .int(let i): String(i) } }
}

final class DeckPhotoListTests: XCTestCase {
    private func load() throws -> Cases {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Cases.self, from: Data(contentsOf: casesURL))
    }

    func testRowTargetCountsAndSizeLine() throws {
        let c = try load()
        XCTAssertFalse(c.row.isEmpty)
        for r in c.row { XCTAssertEqual(DeckPhotoList.row(r.brief), r.text) }
        for t in c.target { XCTAssertEqual(DeckPhotoList.target(eventType: t.eventType, format: t.format), t.target, "\(t.eventType ?? "-") \(t.format ?? "-")") }
        for k in c.counts {
            let got = DeckPhotoList.counts(k.entries)
            XCTAssertEqual(["main": got.main, "side": got.side, "out": got.out, "check": got.check], k.counts)
        }
        for s in c.sizeLine { XCTAssertEqual(DeckPhotoList.sizeLine(main: s.main, target: s.target), s.text) }
    }

    func testEdits() throws {
        let c = try load()
        XCTAssertGreaterThan(c.edits.count, 10)
        for e in c.edits {
            let card = e.card.map { DeckPhotoList.Card(cardId: $0.cardId, name: $0.name) }
            let got: [DeckListEntry]
            switch e.op {
            case "setQty": got = DeckPhotoList.setQty(e.entries, e.i!, e.qty!)
            case "move": got = DeckPhotoList.move(e.entries, e.i!, to: e.board!)
            case "replace": got = DeckPhotoList.replace(e.entries, e.i!, with: card!)
            case "confirm": got = DeckPhotoList.confirm(e.entries, e.i!)
            case "add": got = DeckPhotoList.add(e.entries, card!, to: e.board!)
            default: XCTFail("unknown op \(e.op)"); continue
            }
            XCTAssertEqual(got, e.out, "\(e.op) \(e.i ?? -1)")
        }
    }

    func testIntoADeck() throws {
        let c = try load()
        for d in c.deckEntries {
            let got = DeckPhotoList.deckEntries(d.entries)
            XCTAssertEqual(got.entries.map { [$0.cardId, $0.board, String($0.qty)] }, d.out.entries.map { $0.map(\.text) })
            XCTAssertEqual(got.skipped, d.out.skipped)
        }
        for n in c.deckName { XCTAssertEqual(DeckPhotoList.deckName(event: n.event, player: n.player, mine: n.mine), n.name) }
        for f in c.deckFormat { XCTAssertEqual(DeckPhotoList.deckFormat(eventType: f.eventType, format: f.format), f.deck) }
    }

    func testEntriesDecodeLeniently() throws {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let e = try d.decode([DeckListEntry].self, from: Data(#"[{"name": "Island", "qty": 3, "board": "weird"}, {"card_id": "x", "name": "Bolt", "qty": 1, "board": "out", "sure": false, "read": "blurred"}]"#.utf8))
        XCTAssertEqual(e, [DeckListEntry(cardId: nil, name: "Island", qty: 3, board: "main"), DeckListEntry(cardId: "x", name: "Bolt", qty: 1, board: "out", sure: false, read: "blurred")])
        // A push for a finished read opens Deck photos, then that photo's list.
        XCTAssertEqual(PushRoutes.library(["kind": "deck.read", "photo_id": "p1"]), [.myDeckPhotos, .deckPhotoList("p1")])
        XCTAssertNil(PushRoutes.library(["kind": "deck.read"]))
    }
}
