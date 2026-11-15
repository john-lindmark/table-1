import XCTest
@testable import Table1

/// PriceBook.load waits for a fetch another screen started instead of skipping its cards (a confirmed trade on
/// build 64 showed no prices: the Collection home's fetch of every card was cancelled or failed, and the trade
/// screen, which had asked meanwhile, was never told).
@MainActor
final class PriceBookTests: XCTestCase {
    private let kaldra = "a5a0ae99-d84a-4f27-bed8-889747c78529"

    private func row(_ id: String) -> PriceBook.Row { .init(id: id, values: [9.58, 12.5, nil, 5.3, 7.29, 0]) }

    /// The first fetch fails while a second screen waits on it: the second screen asks again and gets the price.
    func testAFailedFetchIsAskedAgainByTheScreenWaitingOnIt() async {
        let book = PriceBook()
        var calls = 0
        book.fetcher = { ids in
            calls += 1
            let n = calls
            try await Task.sleep(for: .milliseconds(50))
            if n == 1 { throw URLError(.networkConnectionLost) }
            return ids.map { self.row($0) }
        }
        let collection = Task { await book.load([kaldra, "other"]) }
        await Task.yield()
        await book.load([kaldra])
        XCTAssertEqual(book.usd(kaldra, "nonfoil", "LP"), 8.62)
        await collection.value
        XCTAssertEqual(calls, 2)
    }

    /// The screen that started a fetch goes away (its task is cancelled): the fetch carries on for the screen still
    /// waiting, and nothing is asked twice.
    func testACancelledScreenDoesNotCancelTheFetch() async {
        let book = PriceBook()
        var calls = 0
        book.fetcher = { ids in
            calls += 1
            try await Task.sleep(for: .milliseconds(50))
            return ids.map { self.row($0) }
        }
        let home = Task { await book.load([kaldra]) }
        await Task.yield()
        home.cancel()
        await book.load([kaldra])
        XCTAssertEqual(book.usd(kaldra, "nonfoil"), 9.58)
        XCTAssertEqual(calls, 1)
    }

    /// Cards with an answer (even "no price") aren't asked again; a card the server doesn't price reads nil.
    func testAnsweredCardsAreNotAskedAgain() async {
        let book = PriceBook()
        var asked: [[String]] = []
        book.fetcher = { ids in asked.append(ids.sorted()); return ids.filter { $0 == self.kaldra }.map { self.row($0) } }
        await book.load([kaldra, "unpriced"])
        await book.load([kaldra, "unpriced"])
        XCTAssertEqual(asked, [["a5a0ae99-d84a-4f27-bed8-889747c78529", "unpriced"]])
        XCTAssertNil(book.usd("unpriced", "nonfoil"))
    }
}
