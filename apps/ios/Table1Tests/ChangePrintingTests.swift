import XCTest
@testable import Table1

/* Change printing (contract/change-printing-2026-10-18.md): the collection ops that move owned copies to another
   printing in the same place, and a trade get pointed at another printing merging into an existing line. Deck and
   cube lines use ListsStore.shift, covered by the list_edit swap op on the server. */

final class ChangePrintingTests: XCTestCase {
    private let item = CollectionItem(cardId: "old", finish: "nonfoil", condition: "LP", lang: "en", qty: 4, seq: 1)

    func testOwnedCopiesMoveInTheSamePlace() {
        let ops = PrintingChange.ops(item, place: "binder-1", toCardId: "new", toFinish: "foil", qty: 2)
        XCTAssertEqual(ops?.count, 2)
        XCTAssertEqual(ops?[0].itemKey, item.key)
        XCTAssertEqual(ops?[0].delta, -2)
        XCTAssertEqual(ops?[0].binderId, "binder-1")
        XCTAssertEqual(ops?[1].itemKey, CollectionStore.key("new", "foil", "LP", "en"))
        XCTAssertEqual(ops?[1].delta, 2)
        XCTAssertEqual(ops?[1].binderId, "binder-1")
    }

    func testUnsortedNamesNoBinder() {
        let ops = PrintingChange.ops(item, place: BinderRoute.unsorted, toCardId: "new", toFinish: "nonfoil", qty: 1)
        XCTAssertNil(ops?[0].binderId)
        XCTAssertNil(ops?[1].binderId)
    }

    func testFinishOnlyIsAChange() {
        let ops = PrintingChange.ops(item, place: nil, toCardId: "old", toFinish: "foil", qty: 4)
        XCTAssertEqual(ops?[1].itemKey, CollectionStore.key("old", "foil", "LP", "en"))
    }

    func testLanguageFollowsANonEnglishPrinting() {
        XCTAssertEqual(PrintingChange.ops(item, place: nil, toCardId: "ja", toFinish: "nonfoil", toLang: "ja", qty: 1)?[1].lang, "ja")
        let jp = CollectionItem(cardId: "old", finish: "nonfoil", condition: "NM", lang: "ja", qty: 1, seq: 1)
        // An English printing keeps the copy's own language.
        XCTAssertEqual(PrintingChange.ops(jp, place: nil, toCardId: "new", toFinish: "nonfoil", toLang: "en", qty: 1)?[1].lang, "ja")
    }

    func testNothingToChange() {
        XCTAssertNil(PrintingChange.ops(item, place: nil, toCardId: "old", toFinish: "nonfoil", qty: 1))
        XCTAssertNil(PrintingChange.ops(item, place: nil, toCardId: "new", toFinish: "nonfoil", qty: 0))
        XCTAssertNil(PrintingChange.ops(item, place: nil, toCardId: "new", toFinish: "nonfoil", qty: 5))
    }

    func testTradeGetRepoints() {
        let a = TradeLine(cardId: "a", finish: "nonfoil", condition: "NM", lang: "en", qty: 2)
        let b = TradeLine(cardId: "b", finish: "nonfoil", condition: "NM", lang: "en", qty: 1)
        let out = TradeLine.repoint([a, b], id: a.id, cardId: "c", finish: "foil")
        XCTAssertEqual(out.map(\.cardId), ["c", "b"])
        XCTAssertEqual(out[0].finish, "foil")
        XCTAssertEqual(out[0].qty, 2)
    }

    func testTradeGetMergesIntoAnExistingLine() {
        let a = TradeLine(cardId: "a", finish: "nonfoil", condition: "NM", lang: "en", qty: 2)
        let b = TradeLine(cardId: "b", finish: "foil", condition: "NM", lang: "en", qty: 1)
        let out = TradeLine.repoint([a, b], id: a.id, cardId: "b", finish: "foil")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, b.id)
        XCTAssertEqual(out[0].qty, 3)
        XCTAssertEqual(TradeLine.repoint([a, b], id: a.id, cardId: "a", finish: "nonfoil"), [a, b])
    }

    /// Through the demo backend (same allocation rules as collection_apply): copies changed in a binder stay in it,
    /// the other place keeps its copies, and Undo puts them back.
    @MainActor
    func testBinderCopiesStayInTheBinderAndUndo() throws {
        let json = #"{"summary":{"total_qty":3,"unique_printings":1,"unique_cards":1,"value_usd":0,"value_eur":0,"seq":0},"items":[["old","nonfoil","NM","en",3]],"lists":[],"prices":{}}"#
        let demo = LibraryDemoBackend(try JSONDecoder().decode(LibraryDemoFixture.self, from: Data(json.utf8)))
        _ = try demo.saveBinder(id: "box", name: "Box", forTrade: false)
        let it = demo.items[CollectionStore.key("old", "nonfoil", "NM", "en")]!
        // Box 2, Unsorted 1.
        _ = try demo.apply([CollectionOp(cardId: "old", delta: -2), CollectionOp(cardId: "old", delta: 2, binderId: "box")], source: "binder")
        let ops = try XCTUnwrap(PrintingChange.ops(it, place: "box", toCardId: "new", toFinish: "foil", qty: 2))
        let res = try demo.apply(ops, source: "manual")
        let newKey = CollectionStore.key("new", "foil", "NM", "en")
        XCTAssertEqual(demo.items[it.key]?.qty, 1)
        XCTAssertEqual(demo.items[newKey]?.qty, 2)
        XCTAssertEqual(demo.allocs["box|\(newKey)"]?.qty, 2)
        XCTAssertEqual(demo.allocs["box|\(it.key)"]?.qty ?? 0, 0)
        _ = try demo.undo(batchId: res.batchId)
        XCTAssertEqual(demo.items[it.key]?.qty, 3)
        XCTAssertEqual(demo.items[newKey]?.qty ?? 0, 0)
        XCTAssertEqual(demo.allocs["box|\(it.key)"]?.qty, 2)
    }
}
