import XCTest
@testable import Table1

/* Deck image layout (Library/DeckImage.swift): which cards, in what order, and how big they draw. Card sizes against
   testdata/deck-image/cases.json, which web deckImage.test.ts and Android DeckImageTest read too. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/deck-image/cases.json").standardized

private struct FitCases: Decodable {
    struct Case: Decodable { let main, side, cols: Int; let cw: CGFloat; let step: Double; let height: CGFloat }
    let fit: [Case]
}

final class DeckImageTests: XCTestCase {
    private func line(_ name: String, _ board: String, _ qty: Int, type: String, mv: Double, card: String? = nil) -> ListLine {
        let keys = GroupKeys(typeLine: type, manaCost: "", colors: "R", cmc: mv)
        return ListLine(id: "\(board)|\(card ?? name)", cardId: card ?? name, printing: nil, oracleId: name, name: name,
                        group: keys.type, board: board, qty: qty, keys: keys)
    }

    func testPlanOrdersMergesAndLeavesOutConsidering() {
        let lines = [
            line("Mountain", "main", 10, type: "Basic Land — Mountain", mv: 0),
            line("Lightning Bolt", "main", 2, type: "Instant", mv: 1, card: "bolt-a"),
            line("Lightning Bolt", "main", 2, type: "Instant", mv: 1, card: "bolt-b"),
            line("Goblin Guide", "main", 4, type: "Creature — Goblin", mv: 1),
            line("Fury", "main", 1, type: "Creature — Elemental", mv: 5),
            line("Atraxa", "commander", 1, type: "Legendary Creature — Phyrexian", mv: 7),
            line("Blood Moon", "side", 3, type: "Enchantment", mv: 3),
            line("Maybe card", "maybe", 1, type: "Sorcery", mv: 2),
        ]
        let plan = DeckImage.plan(lines, grouping: .type)
        XCTAssertEqual(plan.main.map(\.title), ["Commander", "Creatures", "Instants", "Lands"])
        XCTAssertEqual(plan.main[1].cards.map(\.name), ["Goblin Guide", "Fury"])
        XCTAssertEqual(plan.main[2].cards.map(\.qty), [4])
        XCTAssertEqual(plan.mainCount, 20) // the commander counts toward the deck
        XCTAssertEqual(plan.side.map(\.name), ["Blood Moon"])
        XCTAssertFalse(DeckImage.ordered(plan).contains { $0.name == "Maybe card" })

        let byMV = DeckImage.plan(lines, grouping: .manaValue)
        XCTAssertEqual(byMV.main.map(\.title), ["Commander", "Mana value 1", "Mana value 5", "Lands"])
    }

    func testFitKeepsATypicalDeckOnOneSixteenByNine() {
        let fit = DeckImage.fit(main: 21, side: 9)
        XCTAssertEqual(fit.height, (DeckImage.width * 9 / 16).rounded(.up))
        let rows = CGFloat((21 + fit.cols - 1) / fit.cols)
        XCTAssertLessThanOrEqual(DeckImage.header + rows * fit.cw * DeckImage.aspect + (rows - 1) * DeckImage.rowGap, fit.height)
        // The sideboard column fits under the same height.
        XCTAssertLessThanOrEqual(DeckImage.header + fit.cw * DeckImage.aspect + 8 * fit.step, fit.height)
        XCTAssertGreaterThan(fit.cw, 100)
    }

    func testFitGrowsTallForBigDecks() {
        let fit = DeckImage.fit(main: 100, side: 0)
        XCTAssertGreaterThanOrEqual(fit.cw, DeckImage.minWidth)
        let rows = CGFloat((100 + fit.cols - 1) / fit.cols)
        XCTAssertLessThanOrEqual(DeckImage.header + rows * fit.cw * DeckImage.aspect + (rows - 1) * DeckImage.rowGap, fit.height)
        XCTAssertLessThanOrEqual(CGFloat(fit.cols) * fit.cw + CGFloat(fit.cols - 1) * DeckImage.gap, DeckImage.width - 2 * DeckImage.pad)
    }

    func testColumnsSplitTallGroupsAndFileName() {
        let pile = DeckImage.Pile(title: "Lands", cards: (0..<12).map { DeckImage.Card(key: "\($0)", name: "L\($0)", qty: 1, printing: nil) })
        let cols = DeckImage.columns([pile], max: 9)
        XCTAssertEqual(cols.map(\.cards.count), [9, 3])
        XCTAssertEqual(cols.map(\.title), ["Lands · 12", nil])
        XCTAssertEqual(DeckImage.fileName("Izzet: Tempo!"), "Izzet Tempo.jpg")
    }

    func testFitSharedCases() throws {
        let cases = try JSONDecoder().decode(FitCases.self, from: Data(contentsOf: casesURL))
        XCTAssertGreaterThanOrEqual(cases.fit.count, 9)
        for c in cases.fit {
            let f = DeckImage.fit(main: c.main, side: c.side)
            let name = "\(c.main) + \(c.side)"
            XCTAssertEqual(f.cols, c.cols, name)
            XCTAssertEqual(f.cw, c.cw, name)
            XCTAssertEqual(f.height, c.height, name)
            XCTAssertEqual(Double(f.step), c.step, accuracy: 0.001, name)
        }
    }
}
