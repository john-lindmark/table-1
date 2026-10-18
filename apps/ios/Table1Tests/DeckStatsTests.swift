import XCTest
@testable import Table1

/* Deck and cube stats (contract/lists-2026-10-15.md, "Stats"). Every number comes from testdata/deck-stats/cases.json,
   written by the Python reference there; table-1-events-web/src/lib/deckStats.test.ts and Android's DeckStatsTest
   read the same file, so all three clients give the same answers. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/deck-stats/cases.json").standardized

private struct Cases: Decodable {
    struct Card: Decodable {
        let name: String, qty: Int, board: String, type: String, cost: String, cmc: Double, colors: String, legal: String
        let rarity: String
        let usd: Double?
        let produced: String?
        let tokens: [Token]
        var stat: StatCard {
            StatCard(name: name, qty: qty, board: board, type: type, cost: cost, cmc: cmc, colors: colors, legal: legal, rarity: rarity,
                     usd: usd, produced: produced, tokens: tokens.map { StatToken(key: $0.key, name: $0.name, type: $0.type) })
        }
    }
    struct Token: Decodable { let key: String, name: String, type: String }
    struct Sources: Decodable { let colors: [Int]; let colorless: Int; let sources: Int; let nonLand: Int; let unread: Int }
    struct TokenUse: Decodable {
        struct Maker: Decodable { let name: String; let qty: Int }
        let key: String, name: String, type: String, makers: [Maker]
    }
    struct Issue: Decodable, Equatable { let name: String; let reason: String }
    struct DeckExpected: Decodable {
        struct Curve: Decodable { let creatures: [Int]; let other: [Int] }
        struct Price: Decodable { let total: Double; let unpriced: Int }
        let curve: Curve, types: [Int], averageWithLands: Double, averageWithoutLands: Double, pips: [Int]
        let sources: Sources, tokens: [TokenUse], price: Price, legality: [Issue], librarySize: Int
    }
    struct Deck: Decodable {
        let format: String, cards: [Card], expected: DeckExpected
        let legalityIn: [String: [Issue]]?
    }
    struct Prng: Decodable { let seed: UInt32; let first: [UInt32] }
    struct Bounded: Decodable { let seed: UInt32; let bound: Int; let first: [Int] }
    struct Shuffle: Decodable { let seed: UInt32; let n: Int; let order: [Int] }
    struct Pip: Decodable { let cost: String; let pips: [Int] }
    struct Hyper: Decodable { let N: Int; let K: Int; let n: Int; let k: Int; let p: Double }
    struct Turn: Decodable { let turn: Int; let onPlay: Bool; let draws: Int }
    struct Mulligan: Decodable {
        struct State: Decodable { let hand: [Int]; let library: Int; let toBottom: Int; let mulligans: Int }
        struct Step: Decodable { let `do`: String; let index: Int?; let expect: State }
        let size: Int, seed: UInt32, script: [Step]
    }
    struct Cube: Decodable {
        struct Pack: Decodable { let seed: UInt32; let size: Int; let cards: [Int] }
        struct Expected: Decodable {
            let size: Int, colorBalance: [Int], curveByColor: [[Int]], types: [Int], asfan: [String: [Double]], pack: Pack
        }
        let cards: [Card], expected: Expected
    }
    let prng: Prng, bounded: Bounded, shuffles: [Shuffle], pips: [Pip], hypergeometric: [Hyper], drawsByTurn: [Turn]
    struct OlderPack: Decodable { let cards: [Card]; let sources: Sources }
    let deck: Deck, commander: Deck, olderPack: OlderPack, mulligan: Mulligan, cube: Cube

    static let shared: Cases = try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
}

final class DeckStatsTests: XCTestCase {
    private let c = Cases.shared

    func testRandomNumbersMatchEveryPlatform() {
        var rng = StatsRNG(seed: c.prng.seed)
        XCTAssertEqual(c.prng.first.map { _ in rng.next() }, c.prng.first)
        var b = StatsRNG(seed: c.bounded.seed)
        XCTAssertEqual(c.bounded.first.map { _ in b.int(c.bounded.bound) }, c.bounded.first)
        for s in c.shuffles {
            var r = StatsRNG(seed: s.seed)
            XCTAssertEqual(r.shuffle(s.n), s.order, "seed \(s.seed)")
        }
    }

    func testPips() {
        for p in c.pips { XCTAssertEqual(DeckStats.pips(p.cost), p.pips, p.cost) }
    }

    func testHypergeometric() {
        for h in c.hypergeometric {
            XCTAssertEqual(DeckStats.hypergeometric(population: h.N, successes: h.K, draws: h.n, atLeast: h.k), h.p, accuracy: 1e-9,
                           "N\(h.N) K\(h.K) n\(h.n) k\(h.k)")
        }
        for t in c.drawsByTurn { XCTAssertEqual(DeckStats.drawsByTurn(t.turn, onPlay: t.onPlay), t.draws) }
    }

    private func checkDeck(_ d: Cases.Deck) {
        let cards = d.cards.map(\.stat), e = d.expected
        let curve = DeckStats.curve(cards)
        XCTAssertEqual(curve.creatures, e.curve.creatures)
        XCTAssertEqual(curve.other, e.curve.other)
        XCTAssertEqual(DeckStats.typeCounts(DeckStats.deck(cards)), e.types)
        XCTAssertEqual(DeckStats.averageMV(cards, withLands: true), e.averageWithLands, accuracy: 1e-9)
        XCTAssertEqual(DeckStats.averageMV(cards, withLands: false), e.averageWithoutLands, accuracy: 1e-9)
        XCTAssertEqual(DeckStats.pipTotals(cards), e.pips)
        checkSources(DeckStats.sources(cards), e.sources)
        let tokens = DeckStats.tokens(cards)
        XCTAssertEqual(tokens.map(\.token.key), e.tokens.map(\.key))
        XCTAssertEqual(tokens.map(\.token.name), e.tokens.map(\.name))
        XCTAssertEqual(tokens.map(\.token.type), e.tokens.map(\.type))
        XCTAssertEqual(tokens.map { $0.makers.map { "\($0.name)×\($0.qty)" } }, e.tokens.map { $0.makers.map { "\($0.name)×\($0.qty)" } })
        let price = DeckStats.price(cards)
        XCTAssertEqual(price.total, e.price.total, accuracy: 0.006)
        XCTAssertEqual(price.unpriced, e.price.unpriced)
        XCTAssertEqual(DeckStats.legality(cards, format: d.format).map { Cases.Issue(name: $0.name, reason: $0.reason) }, e.legality)
        XCTAssertEqual(DeckStats.librarySize(cards), e.librarySize)
        for (format, want) in d.legalityIn ?? [:] {
            XCTAssertEqual(DeckStats.legality(cards, format: format).map { Cases.Issue(name: $0.name, reason: $0.reason) }, want, format)
        }
    }

    private func checkSources(_ got: DeckStats.Sources, _ want: Cases.Sources, _ label: String = "") {
        XCTAssertEqual(got.colors, want.colors, label)
        XCTAssertEqual(got.colorless, want.colorless, label)
        XCTAssertEqual(got.total, want.sources, label)
        XCTAssertEqual(got.nonLand, want.nonLand, label)
        XCTAssertEqual(got.unread, want.unread, label)
    }

    func testDeck() { checkDeck(c.deck) }
    func testOlderPackReadsLandsByBasicType() { checkSources(DeckStats.sources(c.olderPack.cards.map(\.stat)), c.olderPack.sources, "older pack") }
    func testCommanderDeck() { checkDeck(c.commander) }

    func testLondonMulligan() {
        var hand = SampleHand(size: c.mulligan.size, seed: c.mulligan.seed)
        for step in c.mulligan.script {
            switch step.do {
            case "mulligan": hand.mulligan()
            case "bottom": hand.bottom(step.index!)
            case "draw": hand.draw()
            default: break
            }
            XCTAssertEqual(hand.hand, step.expect.hand, step.do)
            XCTAssertEqual(hand.library.count, step.expect.library, step.do)
            XCTAssertEqual(hand.toBottom, step.expect.toBottom, step.do)
            XCTAssertEqual(hand.mulligans, step.expect.mulligans, step.do)
        }
        // The library and hand always hold every card once.
        XCTAssertEqual((hand.hand + hand.library).sorted(), Array(0..<c.mulligan.size))
    }

    func testMulliganRules() {
        var hand = SampleHand(size: 60, seed: 1)
        XCTAssertTrue(hand.canMulligan)
        hand.mulligan()
        XCTAssertFalse(hand.canDraw, "keep first: bottom a card before drawing")
        hand.draw()
        XCTAssertEqual(hand.hand.count, 7)
        hand.bottom(0)
        XCTAssertTrue(hand.canDraw)
        for _ in 0..<10 { hand.mulligan() }
        XCTAssertEqual(hand.mulligans, 6, "down to one card at most")
        let small = SampleHand(size: 5, seed: 3)
        XCTAssertEqual(small.hand.count, 5)
        XCTAssertFalse(small.canDraw)
    }

    func testCube() {
        let all = c.cube.cards.map(\.stat), e = c.cube.expected
        let cards = all.filter { $0.board == "main" }
        XCTAssertEqual(cards.reduce(0) { $0 + $1.qty }, e.size)
        XCTAssertEqual(DeckStats.colorBalance(cards), e.colorBalance)
        XCTAssertEqual(DeckStats.curveByColor(cards), e.curveByColor)
        XCTAssertEqual(DeckStats.typeCounts(cards), e.types)
        for by in DeckStats.AsfanBy.allCases {
            let got = DeckStats.asfan(cards, pack: 15, by: by), want = e.asfan[by.rawValue]!
            XCTAssertEqual(got.count, want.count)
            for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 1e-9, by.rawValue) }
            XCTAssertEqual(got.count, DeckStats.asfanLabels(by).count)
        }
        var rng = StatsRNG(seed: e.pack.seed)
        XCTAssertEqual(Array(rng.shuffle(DeckStats.expand(cards).count).prefix(e.pack.size)), e.pack.cards)
    }

    /// Budget: every stat on a 540-card cube (and the same cards read as a deck) in well under a frame's worth of
    /// main-thread time. Measured 2026-10-17 in Debug on the Simulator.
    func testPerfCube540() {
        let base = c.cube.cards.map(\.stat).filter { $0.board == "main" }
        let cube = (0..<540).map { i in var s = base[i % base.count]; s.name += " \(i)"; return s }
        func all() {
            _ = DeckStats.colorBalance(cube)
            _ = DeckStats.curveByColor(cube)
            _ = DeckStats.typeCounts(cube)
            for by in DeckStats.AsfanBy.allCases { _ = DeckStats.asfan(cube, pack: 15, by: by) }
            _ = DeckStats.curve(cube)
            _ = DeckStats.pipTotals(cube)
            _ = DeckStats.sources(cube)
            _ = DeckStats.tokens(cube)
            _ = DeckStats.averageMV(cube, withLands: false)
            _ = DeckStats.legality(cube, format: "vintage")
            var rng = StatsRNG(seed: 5)
            _ = rng.shuffle(540)
        }
        all()
        let runs = 20
        let t0 = Date()
        for _ in 0..<runs { all() }
        let ms = Date().timeIntervalSince(t0) * 1000 / Double(runs)
        print(String(format: "perf ios cube stats 540 cards: %.1f ms (budget 30 ms)", ms))
        XCTAssertLessThan(ms, 30)
    }
}
