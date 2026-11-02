import XCTest
@testable import Table1

/* Owning a card in any printing and Match collection (contract/owned-by-card-2026-10-31.md) against
   testdata/owned-by-card/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/owned-by-card/cases.json").standardized

private struct Cases: Decodable {
    struct Line: Decodable {
        let card_id, board, finish: String; let qty: Int; let lang: String?; let cond: String?
        var need: OwnedByCard.Need { OwnedByCard.Need(cardId: card_id, board: board, finish: finish, qty: qty, lang: lang ?? "en", cond: cond ?? "NM") }
        var entry: CardList.Entry { CardList.Entry(cardId: card_id, board: board, qty: qty, finish: finish, lang: lang ?? "en", cond: cond ?? "NM") }
    }
    struct Short: Decodable { let name: String; let lines: [Line]; let owned: [String: Int]; let oracles: [String: String]; let shorts: [Int] }
    struct List: Decodable { let name: String; let event: Bool?; let entries: [Line] }
    struct Missing: Decodable { let card_id, finish: String; let short: Int; let lists: [String] }
    struct Lines: Decodable { let lists: [List]; let owned: [String: Int]; let oracles: [String: String]; let expect: [Missing] }
    struct Op: Decodable { let card_id, finish: String; let delta: Int; let lang: String?; let cond: String? }
    struct Add: Decodable { let name, kind, mode: String; let entries: [Line]; let owned: [String: Int]; let ops: [Op] }
    struct Version: Decodable { let card_id, finish: String; let owned: Int }
    struct Pick: Decodable { let card_id, finish: String; let qty: Int }
    struct Move: Decodable { let card_id, finish: String; let lang: String?; let to_card_id, to_finish: String; let qty: Int }
    struct Match: Decodable { let name: String; let lines: [Line]; let versions: [Version]; let auto: [Pick]; let taps: [[String]]; let picks: [Pick]; let ops: [Move] }
    let basics: [String]
    let shorts: [Short]
    let lines: Lines
    let add: [Add]
    let match: [Match]
}

final class OwnedByCardTests: XCTestCase {
    private var cases: Cases!
    override func setUpWithError() throws { cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testShorts() {
        for c in cases.shorts {
            XCTAssertEqual(OwnedByCard.shorts(c.lines.map(\.need), Holdings(owned: c.owned, cardOf: c.oracles), basics: Set(cases.basics)), c.shorts, c.name)
        }
    }

    func testMissingLines() {
        let l = cases.lines
        let lists = l.lists.map { x in
            var list = CardList(id: x.name, kind: .deck, name: x.name, format: "modern",
                                versions: [CardList.Version(number: 1, at: .now, note: "", entries: x.entries.map(\.entry))])
            if x.event == true { list.eventId = "roto" }
            return list
        }
        let got = OwnedByCard.lines(lists, Holdings(owned: l.owned, cardOf: l.oracles), basics: Set(cases.basics))
        XCTAssertEqual(got.map { "\($0.cardId)|\($0.finish)|\($0.short)|\($0.lists)" }, l.expect.map { "\($0.card_id)|\($0.finish)|\($0.short)|\($0.lists)" })
    }

    func testAddToCollection() throws {
        for c in cases.add {
            let ops = ListToCollection.ops(c.entries.map(\.entry), kind: try XCTUnwrap(CardList.Kind(rawValue: c.kind)), owned: c.owned,
                                           mode: try XCTUnwrap(ListToCollection.Mode(rawValue: c.mode)))
            XCTAssertEqual(ops, c.ops.map { ListToCollection.Op(cardId: $0.card_id, finish: $0.finish, delta: $0.delta, lang: $0.lang ?? "en", cond: $0.cond ?? "NM") }, c.name)
        }
    }

    func testMatchCollection() {
        for c in cases.match {
            let lines = c.lines.map(\.need)
            let versions = c.versions.map { OwnedByCard.Version(cardId: $0.card_id, finish: $0.finish, owned: $0.owned) }
            let pick = { (p: Cases.Pick) in OwnedByCard.Pick(cardId: p.card_id, finish: p.finish, qty: p.qty) }
            var picks = OwnedByCard.autoMatch(lines, versions)
            XCTAssertEqual(picks, c.auto.map(pick), c.name)
            let total = lines.reduce(0) { $0 + $1.qty }
            for t in c.taps { picks = OwnedByCard.tap(picks, versions: versions, total: total, cardId: t[0], finish: t[1]) }
            XCTAssertEqual(picks, c.picks.map(pick), c.name)
            XCTAssertEqual(OwnedByCard.matchOps(lines, picks), c.ops.map {
                OwnedByCard.Move(cardId: $0.card_id, finish: $0.finish, lang: $0.lang ?? "en", toCardId: $0.to_card_id, toFinish: $0.to_finish, qty: $0.qty)
            }, c.name)
        }
    }
}
