import XCTest

// Same cases as table-1-events-web/src/lib/catalog.test.ts.

/// Header, three cards (sorted by name_norm) and four printings, in pack format 1.
private let PACK = [
    "#t1catalog\t1\tv1-test\t3\t4",
    "O\t0\tae92942b-919c-4ea9-b693-85fcef765d5a\tFire // Ice\tfire ice\tInstant // Instant\t{1}{R} // {1}{U}\t4\tRU\tFire // Ice",
    "O\t1\t4457ed35-7c10-48c8-9776-456485fdf070\tLightning Bolt\tlightning bolt\tInstant\t{R}\t1\tR\t",
    "O\t2\t11111111-1111-1111-1111-111111111111\tLightning Bolt Token\tlightning bolt token\tToken Creature — Elemental\t\t0\tR\t",
    "P\t04cb4e4e-8275-4132-8f1a-84b486725400\t0\tf06\t12a\ten\tr\tf\t2006-01-01\t1783943569\t1\t",
    "P\tf29ba16f-c8fb-42fe-aabf-87089cb214a7\t1\t2x2\t117\ten\tu\tfn\t2022-07-08\t1783930000\t1\t",
    "P\t310de1ef-f1b6-4b61-9d6c-6b70382a7f95\t1\t4bb\t208\tes\tc\tn\t1995-04-01\t\t1\tRelámpago",
    "P\t22222222-2222-2222-2222-222222222222\t2\ttfoo\t1\ten\tc\tn\t2020-01-01\t\t0\t",
    "X\tfuture line type is ignored",
    "",
].joined(separator: "\n")

/// PACK gzipped by Python's gzip module (with a file name in the header, so FNAME is exercised).
private let PACK_GZ = "H4sICAAAAAAC/3BhY2sudHN2AG2SXWocMQzHn7WnGOiziO3x52tDC4FCy9JAX22PPBk6mQm73tISFnqIXqBn6U16ksq7m1BChDGybP8k/e03VeZY47yOIOGbxEr7Cj3ozUcQECmooFXCIENGTTFgsqFHb0qm4qwZTIT30466q6vuJhOU5k/s3Cz7Gpd6ip9deJTHx+2xRZp3ewQN29v/b3NKCVobR0Nv0GUpUPvsMThnURurOe1QhBPwYRrv6jItY/d2nSvMz8vUls8Jt0cGboG5CuTF8JXpyV5wu8/rV1pe0Lt6Cp62uusdxXrgBv7+/NW9m+meFpYSWDnO+gmEzkmTJvTKGdSyV+iLjOh10t46ZbQQfLYIC1JFYOwOCighLArJA6TzfdC9sYEbYWBRIUVpC2ZfEmpVCGNMBb0TPuSkpI6OT6rvrV/XgAcoCxOVQuFQ+DOxF2xnYi/FQJIKFplY5GQlhsFmtMmJ3qvoSjDtVVJiigfaQ4YFZAgGhW4lNoVp/vP7/iGOKwPVxfCV6cn4OWpZV77KFTYeFyguLbMemy9QDidZ52mhrv544D+176ZxWXc0bP4BnNHEvLICAAA="

private struct Parsed {
    var header: PackHeader
    var oracles: [PackOracle] = []
    var printings: [PackPrinting] = []

    init(_ data: Data) throws {
        var o: [PackOracle] = [], p: [PackPrinting] = []
        header = try CatalogPack.parse(data, oracle: { o.append($0) }, printing: { p.append($0) })
        oracles = o
        printings = p
    }

    func count(_ idx: Int) -> Int { printings.filter { $0.oracleIdx == idx }.count }

    func names(_ q: String) -> [String] {
        let candidates = oracles.map { CatalogPack.SearchCandidate(idx: $0.idx, norm: $0.nameNorm, type: $0.typeLine, printings: count($0.idx)) }
        return CatalogPack.rank(candidates, query: q).map { i in oracles.first { $0.idx == i }!.name }
    }
}

final class CardNameTests: XCTestCase {
    func testMatchesCardNameNorm() {
        let cases = [
            ("Æther Vial", "aether vial"),
            ("Lim-Dûl the Necromancer", "lim dul the necromancer"),
            ("Urza's Saga", "urzas saga"),
            ("Fire // Ice", "fire ice"),
            ("  Jötun   Grunt ", "jotun grunt"),
        ]
        for (input, out) in cases { XCTAssertEqual(CardName.norm(input), out, input) }
    }
}

final class CatalogPackTests: XCTestCase {
    func testReadsCardsAndPrintings() throws {
        let c = try Parsed(Data(PACK.utf8))
        XCTAssertEqual(c.header, PackHeader(version: "v1-test", oracles: 3, printings: 4))
        XCTAssertEqual(c.oracles.count, 3)
        XCTAssertEqual(c.printings.count, 4)
        XCTAssertEqual(c.oracles[1].name, "Lightning Bolt")
        XCTAssertEqual(c.oracles[0].faceNames, "Fire // Ice")
        XCTAssertEqual(c.oracles[0].cmc, 4)
        // Printings of card 1 start at position 1 and there are two of them, newest first.
        XCTAssertEqual(c.printings.firstIndex { $0.oracleIdx == 1 }, 1)
        XCTAssertEqual(c.count(1), 2)
        XCTAssertEqual(c.printings[2].printedName, "Relámpago")
        XCTAssertEqual(c.printings[1].cardId, "f29ba16f-c8fb-42fe-aabf-87089cb214a7")
        XCTAssertEqual(c.printings[1].finishes, "fn")
        XCTAssertEqual(c.printings[3].imageFaces, 0)
    }

    func testRejectsAnUnknownFormat() {
        XCTAssertThrowsError(try CatalogPack.parse(Data("#t1catalog\t2\tv\t0\t0".utf8), oracle: { _ in }, printing: { _ in }))
    }

    func testGunzipsThePack() throws {
        let raw = try CatalogPack.gunzip(Data(base64Encoded: PACK_GZ)!)
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), PACK)
        XCTAssertEqual(try Parsed(raw).printings.count, 4)
    }

    func testRejectsDamagedGzip() {
        XCTAssertThrowsError(try CatalogPack.gunzip(Data(PACK.utf8)))
    }

    func testBuildsScryfallImageUrls() {
        XCTAssertEqual(
            CatalogPack.imageURL(cardId: "f29ba16f-c8fb-42fe-aabf-87089cb214a7", imageTs: "1783930000")?.absoluteString,
            "https://cards.scryfall.io/normal/front/f/2/f29ba16f-c8fb-42fe-aabf-87089cb214a7.jpg?1783930000")
    }
}

final class CatalogSearchTests: XCTestCase {
    private var c: Parsed!
    override func setUpWithError() throws { c = try Parsed(Data(PACK.utf8)) }

    func testExactNameFirst() {
        XCTAssertEqual(c.names("lightning bolt"), ["Lightning Bolt", "Lightning Bolt Token"])
    }

    func testPrefixFirstTokensLast() {
        XCTAssertEqual(c.names("light"), ["Lightning Bolt", "Lightning Bolt Token"])
    }

    func testWordInsideNameIgnoringAccentsAndPunctuation() {
        XCTAssertEqual(c.names("bolt"), ["Lightning Bolt", "Lightning Bolt Token"])
        XCTAssertEqual(c.names("ice"), ["Fire // Ice"])
    }

    func testNeedsTwoCharacters() {
        XCTAssertEqual(c.names("l"), [])
    }
}

final class CatalogPackFieldsTests: XCTestCase {
    /// Legality code (O field 10) and the original-printing flag (P field 12); older packs leave both empty.
    func testReadsLegalityAndOriginal() throws {
        let pack = [
            "#t1catalog\t1\tv1-test\t2\t2",
            "O\t0\t5089ec1a-f881-4d55-af14-5d996171203b\tBlack Lotus\tblack lotus\tArtifact\t{0}\t0\t\t\t---BR-B-",
            "O\t1\t4457ed35-7c10-48c8-9776-456485fdf070\tLightning Bolt\tlightning bolt\tInstant\t{R}\t1\tR\t",
            "P\tbd8fa327-dd41-4737-8f19-2cf5eb1f7cdd\t0\tlea\t232\ten\tr\tn\t1993-08-05\t1\t1\t\t1",
            "P\tf29ba16f-c8fb-42fe-aabf-87089cb214a7\t1\t2x2\t117\ten\tu\tfn\t2022-07-08\t1\t1\t",
        ].joined(separator: "\n")
        var o: [PackOracle] = [], p: [PackPrinting] = []
        try CatalogPack.parse(Data(pack.utf8), oracle: { o.append($0) }, printing: { p.append($0) })
        XCTAssertEqual(o.map(\.legal), ["---BR-B-", ""])
        XCTAssertEqual(p.map(\.original), [true, false])
        XCTAssertEqual(CatalogPack.legality(o[0].legal, "vintage"), "restricted")
        XCTAssertEqual(CatalogPack.legality(o[0].legal, "legacy"), "banned")
        XCTAssertEqual(CatalogPack.legality(o[0].legal, "modern"), "not_legal")
        XCTAssertNil(CatalogPack.legality(o[0].legal, "other"))
        XCTAssertNil(CatalogPack.legality(o[1].legal, "modern"))
    }
}
