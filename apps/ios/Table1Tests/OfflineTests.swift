import XCTest
@testable import Table1

/* Offline rules (contract/offline-2026-10-31.md): the age of a saved answer, what a screen says when a call fails,
   and which failed collection batches wait in the outbox. Shared cases testdata/offline/cases.json (also web
   offline.test.ts and Android OfflineTest.kt). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/offline/cases.json").standardized

private struct Cases: Decodable {
    struct Op: Decodable {
        let card_id: String
        var finish: String?
        var condition: String?
        var lang: String?
        var delta: Int?
        var qty: Int?
        var binder_id: String?
        var op: CollectionOp {
            CollectionOp(cardId: card_id, finish: finish ?? "nonfoil", condition: condition ?? "NM", lang: lang ?? "en",
                         delta: delta, qty: qty, binderId: binder_id)
        }
    }
    struct Ago: Decodable { let seconds: Int; let label: String }
    struct Notice: Decodable { let name: String; let failed: Bool; let savedAgo: Int?; let error: String?; let text: String?; let isError: Bool }
    struct Queues: Decodable { let name: String; let ops: [Op]; let network: Bool; let queued: Bool }
    struct Deltas: Decodable { let name: String; let batches: [[Op]]; let deltas: [String: Int] }
    struct Shown: Decodable { let name: String; let key: String; let serverQty: Int; let deltas: [String: Int]; let qty: Int }
    let ago: [Ago]
    let notice: [Notice]
    let queues: [Queues]
    let deltas: [Deltas]
    let shown: [Shown]
}

final class OfflineTests: XCTestCase {
    private func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    /// Bug #39 (seen on Android): an offline call (no DNS) went to Sentry as an error.
    func testOfflineIsNotReported() throws {
        XCTAssertFalse(Telemetry.reports(URLError(.cannotFindHost)))
        XCTAssertFalse(Telemetry.reports(URLError(.notConnectedToInternet)))
        XCTAssertFalse(Telemetry.reports(CancellationError()))
        XCTAssertTrue(Telemetry.reports(NSError(domain: "T1", code: 1)))
    }

    func testAgo() throws {
        for c in try cases().ago { XCTAssertEqual(Offline.ago(c.seconds), c.label, "\(c.seconds) s") }
    }

    func testNotice() throws {
        for c in try cases().notice {
            let n = Offline.notice(failed: c.failed, savedAgo: c.savedAgo, error: c.error)
            XCTAssertEqual(n?.text, c.text, c.name)
            XCTAssertEqual(n?.isError ?? false, c.isError, c.name)
        }
    }

    func testQueues() throws {
        for c in try cases().queues { XCTAssertEqual(Offline.queues(c.ops.map(\.op), network: c.network), c.queued, c.name) }
    }

    func testDeltasAndShown() throws {
        let all = try cases()
        for c in all.deltas { XCTAssertEqual(Offline.deltas(c.batches.map { $0.map(\.op) }), c.deltas, c.name) }
        for c in all.shown { XCTAssertEqual(c.serverQty + (c.deltas[c.key] ?? 0), c.qty, c.name) }
    }

    func testNetworkErrors() {
        XCTAssertTrue(Offline.isNetwork(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Offline.isNetwork(URLError(.timedOut)))
        XCTAssertFalse(Offline.isNetwork(URLError(.cancelled)))
        XCTAssertFalse(Offline.isNetwork(CancellationError()))
        XCTAssertFalse(Offline.isNetwork(NSError(domain: "Table1", code: 1)))
    }

    func testOutboxBatchRoundTrips() throws {
        let b = OutboxBatch(key: "k1", source: "scan", ops: [CollectionOp(cardId: "a", delta: 2, binderId: "x")])
        let data = try JSONEncoder().encode([b])
        let back = try JSONDecoder().decode([OutboxBatch].self, from: data)
        XCTAssertEqual(back.first?.key, "k1")
        XCTAssertEqual(back.first?.ops.first?.binderId, "x")
        XCTAssertEqual(back.first?.ops.first?.delta, 2)
    }

    func testSavedAnswerKeepsItsTime() {
        let user = "test-\(UUID().uuidString)"
        OfflineCache.save(user, "home", Data("{\"events\":[]}".utf8))
        let saved = OfflineCache.load(user, "home", as: HomeData.self)
        XCTAssertNotNil(saved)
        XCTAssertLessThan(abs(saved!.at.timeIntervalSinceNow), 5)
        XCTAssertNil(OfflineCache.load(user, "event-x", as: HomeData.self))
    }

    func testPendingListChangesRoundTrip() throws {
        let p = ListsStore.PendingCall(fn: "list_edit", params: ["p_list_id": .string("l1"), "p_ops": .array([.object(["delta": .integer(1)])])])
        let c = ListsStore.Cache(cursor: 3, lists: [], unsaved: [:], pending: [p])
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(ListsStore.decodePending(data).first?.fn, "list_edit")
        XCTAssertEqual(ListsStore.decodeCache(data).cursor, 3)
        // Caches written before the queue existed read as none pending.
        XCTAssertTrue(ListsStore.decodePending(Data("{\"cursor\":1,\"lists\":[],\"unsaved\":{}}".utf8)).isEmpty)
    }
}
