import XCTest
@testable import Table1

/* Following (contract/follows-2026-10-25.md) against testdata/follows/cases.json (make_cases.py). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/follows/cases.json").standardized

private struct Cases: Decodable {
    struct Ago: Decodable { let seconds: Double; let text: String }
    struct Change: Decodable { let added: Int; let removed: Int; let text: String }
    struct Detail: Decodable { let follow: Follow; let text: String }
    struct Home: Decodable { let items: [Follow]; let text: String }
    struct Row: Decodable { let cardId: String; let board: String?; let qty: Int }
    struct Sections: Decodable { let cards: [FollowUpdateCards]; let added: [Row]; let removed: [Row] }
    let now: String
    let ago: [Ago]
    let change: [Change]
    let detail: [Detail]
    let home: [Home]
    let sections: [Sections]
}

/// One [card_id, board | null, delta] row, decoded the way FollowUpdate does.
private struct FollowUpdateCards: Decodable {
    let card: FollowCard
    init(from decoder: Decoder) throws {
        var r = try decoder.unkeyedContainer()
        let id = try r.decode(String.self)
        let board = try r.decodeNil() ? nil : try r.decode(String.self)
        card = FollowCard(cardId: id, board: board, qty: try r.decode(Int.self))
    }
}

final class FollowsTests: XCTestCase {
    private func load() throws -> Cases {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Cases.self, from: Data(contentsOf: casesURL))
    }

    func testAgoAndChange() throws {
        let c = try load()
        for a in c.ago { XCTAssertEqual(Follows.ago(a.seconds), a.text, "\(a.seconds)") }
        for x in c.change { XCTAssertEqual(Follows.change(added: x.added, removed: x.removed), x.text) }
    }

    func testDetailAndHome() throws {
        let c = try load()
        let now = try XCTUnwrap(Follows.date(c.now))
        for x in c.detail { XCTAssertEqual(Follows.detail(x.follow, now: now), x.text) }
        for x in c.home { XCTAssertEqual(Follows.home(x.items), x.text) }
    }

    func testSections() throws {
        for x in try load().sections {
            let s = Follows.sections(x.cards.map(\.card))
            XCTAssertEqual(s.added.map { "\($0.cardId)|\($0.board ?? "-")|\($0.qty)" }, x.added.map { "\($0.cardId)|\($0.board ?? "-")|\($0.qty)" })
            XCTAssertEqual(s.removed.map { "\($0.cardId)|\($0.board ?? "-")|\($0.qty)" }, x.removed.map { "\($0.cardId)|\($0.board ?? "-")|\($0.qty)" })
        }
    }

    /// follow_changes as the server sends it: microsecond timestamps, null boards for binders.
    func testDecodesServerChanges() throws {
        let json = """
        {"kind": "binder", "id": "b1", "name": "Trades", "updates": [{"at": "2026-10-25T18:00:00.123456+00:00", "added": 2, "removed": 1,
          "cards": [["c1", null, 2], ["c2", null, -1]]}]}
        """
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let c = try d.decode(FollowChanges.self, from: Data(json.utf8))
        XCTAssertEqual(c.updates.first?.cards, [FollowCard(cardId: "c1", board: nil, qty: 2), FollowCard(cardId: "c2", board: nil, qty: -1)])
        XCTAssertNotNil(Follows.date(c.updates[0].at))
    }

    func testPushTapOpensChanges() {
        XCTAssertEqual(PushRoutes.library(["kind": "follow.updated", "follow_kind": "deck", "item_id": "d1"]),
                       [.social(.following), .social(.followChanges("deck", "d1"))])
        XCTAssertNil(PushRoutes.library(["kind": "follow.updated"]))
        XCTAssertEqual(PushRoutes.library(["kind": "trade.wants", "user_id": "u1"]), [.social(.matches), .social(.match("u1"))])
    }
}
