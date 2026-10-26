import XCTest
@testable import Table1

/* Card detail's rules (Library/CardDetail.swift) against testdata/card-detail/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/card-detail/cases.json").standardized

private struct Cases: Decodable {
    struct Printing: Decodable { let card_id, set, lang, finishes, released_at: String; let original: Bool }
    struct Version: Decodable {
        let card_id, finish: String
        let condition, lang, board: String?
        let qty: Int?
        var version: CardVersion {
            CardVersion(cardId: card_id, finish: finish, condition: condition ?? "NM", lang: lang ?? "en", board: board, qty: qty ?? 0)
        }
    }
    struct Repoint: Decodable { let name, attribute, value: String; let from, to: Version }
    struct Place: Decodable { let place: String; let qty: Int }
    struct Op: Decodable { let card_id, finish, condition, lang: String; let delta: Int; let binder_id: String? }
    struct Ops: Decodable {
        let name: String
        let item: Version
        let places: [Place]
        let from: String?
        let to: Version
        let qty: Int
        let ops: [Op]?
    }
    struct View: Decodable {
        let name: String
        let versions: [Version]
        let shared: [String: String?]
        let main: String
        let shows_finish: Bool
        let order: [String]
    }
    struct Fresh: Decodable { let condition, lang: String; let version: Version }
    struct NewEdition: Decodable { let from, edition: Version }
    struct Edition: Decodable { let name, attribute, value: String; let versions: [Version]; let edition, to: Version; let is_new: Bool }
    struct AddLines: Decodable { let name: String; let in_view: [Version]; let current: Version; let all: Bool; let lines: [Version] }
    let printings: [Printing]
    let repoint: [Repoint]
    let ops: [Ops]
    let views: [View]
    let fresh: Fresh
    let new_edition: NewEdition
    let editions: [Edition]
    let add_lines: [AddLines]
}

final class CardDetailTests: XCTestCase {
    private func load() throws -> (Cases, [CatalogPrinting]) {
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        let printings = c.printings.enumerated().map { i, p in
            CatalogPrinting(cardId: p.card_id, oracleIdx: 0, ord: c.printings.count - i, set: p.set, cn: "\(i + 1)", lang: p.lang,
                            rarity: "c", finishes: p.finishes, releasedAt: p.released_at, imageTs: "", imageFaces: 1, printedName: "",
                            original: p.original)
        }
        return (c, printings)
    }

    func testRepoint() throws {
        let (c, printings) = try load()
        for r in c.repoint {
            let attribute = try XCTUnwrap(CardAttribute(rawValue: r.attribute))
            let got = CardDetailRules.repoint(r.from.version, attribute, to: r.value, printing: printings.first { $0.cardId == r.value })
            XCTAssertEqual(got, r.to.version, r.name)
        }
    }

    func testOps() throws {
        let (c, _) = try load()
        for o in c.ops {
            let v = o.item.version
            let item = CollectionItem(cardId: v.cardId, finish: v.finish, condition: v.condition, lang: v.lang, qty: v.qty, seq: 0)
            let got = CardDetailRules.ops(item, places: o.places.map { ($0.place, $0.qty) }, to: o.to.version, qty: o.qty, from: o.from)
            let want = o.ops?.map { CollectionOp(cardId: $0.card_id, finish: $0.finish, condition: $0.condition, lang: $0.lang, delta: $0.delta, binderId: $0.binder_id) }
            XCTAssertEqual(got.map { $0.map(Self.text) }, want.map { $0.map(Self.text) }, o.name)
        }
    }

    func testViews() throws {
        let (c, printings) = try load()
        let byId = Dictionary(uniqueKeysWithValues: printings.map { ($0.cardId, $0) })
        for v in c.views {
            let versions = CardDetailRules.ordered(v.versions.map(\.version), printings: printings)
            XCTAssertEqual(versions.map(\.id), v.order, v.name)
            XCTAssertEqual(CardDetailRules.main(versions)?.id, v.main, v.name)
            XCTAssertEqual(CardDetailRules.showsFinish(versions, printings: byId), v.shows_finish, v.name)
            XCTAssertEqual(CardDetailRules.shared(versions, \.cardId), v.shared["set"] ?? nil, "\(v.name): set")
            XCTAssertEqual(CardDetailRules.shared(versions, \.lang), v.shared["language"] ?? nil, "\(v.name): language")
            XCTAssertEqual(CardDetailRules.shared(versions, \.condition), v.shared["condition"] ?? nil, "\(v.name): condition")
            XCTAssertEqual(CardDetailRules.shared(versions, \.finish), v.shared["finish"] ?? nil, "\(v.name): finish")
        }
    }

    func testFresh() throws {
        let (c, printings) = try load()
        XCTAssertEqual(CardDetailRules.fresh(printings, condition: c.fresh.condition, lang: c.fresh.lang), c.fresh.version.version)
    }

    func testNewEdition() throws {
        let (c, printings) = try load()
        XCTAssertEqual(CardDetailRules.newEdition(from: c.new_edition.from.version), c.new_edition.edition.version)
        for e in c.editions {
            let attribute = try XCTUnwrap(CardAttribute(rawValue: e.attribute))
            let to = CardDetailRules.repoint(e.edition.version, attribute, to: e.value, printing: printings.first { $0.cardId == e.value })
            XCTAssertEqual(to, e.to.version, e.name)
            XCTAssertEqual(CardDetailRules.isNew(to, among: e.versions.map(\.version)), e.is_new, e.name)
        }
    }

    func testAddLines() throws {
        let (c, _) = try load()
        for a in c.add_lines {
            let got = CardDetailRules.addLines(a.in_view.map(\.version), current: a.current.version, all: a.all)
            XCTAssertEqual(got, a.lines.map(\.version), a.name)
        }
    }

    func testStepIntoUnsortedHasNoBinder() {
        let v = CardVersion(cardId: "lea", finish: "nonfoil")
        XCTAssertNil(CardDetailRules.step(v, delta: 1, binderId: BinderRoute.unsorted).binderId)
        XCTAssertEqual(CardDetailRules.step(v, delta: -1, binderId: "b1").binderId, "b1")
    }

    private static func text(_ o: CollectionOp) -> String {
        "\(o.cardId) \(o.finish) \(o.condition) \(o.lang) \(o.delta ?? 0) \(o.binderId ?? "-")"
    }
}
