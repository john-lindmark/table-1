import XCTest
@testable import Table1

/* Deck finder jobs (contract/deck-finder-2026-10-15.md § Jobs) against testdata/deck-finder/cases.json (web
   deckFinder.test.ts, Android DeckFinderTest). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/deck-finder/cases.json").standardized

private struct Cases: Decodable {
    struct Resume: Decodable { let status: String; let finishedSecondsAgo: Double?; let show: Bool }
    struct Headline: Decodable { let placement: String; let event: String; let date: String; let text: String }
    let resume: [Resume]
    let headline: [Headline]
}

final class DeckFinderTests: XCTestCase {
    private func load() throws -> Cases {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Cases.self, from: Data(contentsOf: casesURL))
    }

    func testResumeAndHeadline() throws {
        let cases = try load()
        for c in cases.resume {
            XCTAssertEqual(DeckFinderJobs.resume(status: c.status, finishedSecondsAgo: c.finishedSecondsAgo), c.show, "\(c.status) \(String(describing: c.finishedSecondsAgo))")
        }
        for c in cases.headline {
            XCTAssertEqual(DeckFinderJobs.headline(placement: c.placement, event: c.event, date: c.date), c.text)
        }
    }

    func testDecodesAJob() throws {
        let json = #"{"job_id": "j1", "status": "done", "query": "boros energy", "format": "modern", "answers": [{"question": "Which?", "answer": "Boros"}], "result": {"status": "deck", "deck": {"name": "Boros Energy", "archetype": "Boros Energy", "format": "modern", "event": "Modern Challenge 32", "date": "2026-10-30", "placement": "1st", "player": "", "source_url": "https://www.mtgo.com/decklist/x", "notes": "", "from": "table1", "main": [{"qty": 4, "name": "Guide of Souls"}], "side": []}}, "created_at": "2026-11-01T16:11:02.042+00:00", "finished_at": "2026-11-01T16:12:10+00:00"}"#
        let j = try DeckFinderJobs.decoder.decode(DeckFinderJob.self, from: Data(json.utf8))
        XCTAssertEqual(j.jobId, "j1")
        XCTAssertTrue(j.finished)
        XCTAssertEqual(j.answers, [DeckFinderJob.Answer(question: "Which?", answer: "Boros")])
        XCTAssertEqual(j.result?.deck?.name, "Boros Energy")
        XCTAssertEqual(j.result?.deck?.from, "table1")
        XCTAssertEqual(j.finishedAt?.timeIntervalSince(j.createdAt) ?? 0, 67.958, accuracy: 0.01)
        XCTAssertTrue(DeckFinderJobs.resume(j, now: j.finishedAt!.addingTimeInterval(600)))
        XCTAssertFalse(DeckFinderJobs.resume(j, now: j.finishedAt!.addingTimeInterval(7200)))
        // Running, with no result yet.
        let running = try DeckFinderJobs.decoder.decode(DeckFinderJob.self,
            from: Data(#"{"job_id": "j2", "status": "running", "query": "x", "format": null, "answers": [], "result": null, "created_at": "2026-11-01T16:11:02Z", "finished_at": null}"#.utf8))
        XCTAssertFalse(running.finished)
        XCTAssertNil(running.result)
        XCTAssertTrue(DeckFinderJobs.resume(running, now: Date()))
    }

    func testPushOpensTheJob() {
        XCTAssertEqual(PushRoutes.library(["kind": "deck.found", "job_id": "j1", "status": "deck"]), [.lists(.deck), .findDeck("j1")])
        XCTAssertNil(PushRoutes.library(["kind": "deck.found", "job_id": ""]))
    }

    @MainActor func testTheWatchedJobIsQuiet() {
        PushController.shared.watchingDeckJob = "j1"
        XCTAssertTrue(PushController.shared.quiet(["kind": "deck.found", "job_id": "j1"]))
        XCTAssertFalse(PushController.shared.quiet(["kind": "deck.found", "job_id": "j2"]))
        XCTAssertFalse(PushController.shared.quiet(["kind": "want.price"]))
        PushController.shared.watchingDeckJob = nil
        XCTAssertFalse(PushController.shared.quiet(["kind": "deck.found", "job_id": "j1"]))
    }
}
