import XCTest
@testable import Table1

/// Bug pushes open the right screen, and the inbox / bug JSON (bugs_inbox, bugs_detail) decodes and groups.
@MainActor
final class BugsTests: XCTestCase {
    func testPushRoutes() {
        XCTAssertEqual(PushRoutes.route(["kind": "ops.bug", "bug_id": 12]), .bug(12))
        XCTAssertEqual(PushRoutes.route(["kind": "ops.bug", "bug_id": NSNumber(value: 7)]), .bug(7))
        XCTAssertEqual(PushRoutes.route(["kind": "ops.bug", "bug_id": "9"]), .bug(9))
        XCTAssertEqual(PushRoutes.route(["kind": "ops.bug"]), .bugs, "an older push without the id still opens Bugs")
        XCTAssertEqual(PushRoutes.route(["kind": "ops.build"]), .bugs)
        XCTAssertEqual(PushRoutes.route(["kind": "moderation.notice"]), .notices)
        XCTAssertEqual(PushRoutes.route(["kind": "moderation.review"]), .review)
        XCTAssertEqual(PushRoutes.route(["kind": "friend.request"]), .friends)
        XCTAssertNil(PushRoutes.route(["kind": "round.paired", "event_id": "e"]), "event pushes open the event")
        XCTAssertNil(PushRoutes.route([:]))
    }

    func testRankingPushOpensTheRanking() {
        XCTAssertEqual(PushRoutes.library(["kind": "ranking.started", "ranking_id": "r1"]), [.ranking("r1")])
        XCTAssertNil(PushRoutes.library(["kind": "ranking.started"]))
        XCTAssertNil(PushRoutes.library(["kind": "ops.bug", "bug_id": 1]))
        XCTAssertNil(PushRoutes.route(["kind": "ranking.started", "ranking_id": "r1"]))
    }

    func testBugOpensAboveTheInbox() {
        XCTAssertEqual(PushRoutes.path(.bug(3)), [.social(.bugs), .social(.bug(3))])
        XCTAssertEqual(PushRoutes.path(.review), [.social(.review)])
    }

    func testInboxDecodesAndGroups() throws {
        let json = """
        {"bugs": [
          {"id": 6, "severity": "S2", "status": "fixed", "platform": "ios", "title": "Fixed, waiting", "events": 1, "users": 0,
           "regressed": false, "last_seen": "2026-10-22T10:00:00Z", "fixed_at": "2026-10-22T11:00:00Z",
           "fix_platforms": ["ios", "server"], "shipped": ["server"], "last_note": null, "my_notes": 0},
          {"id": 1, "severity": "S1", "status": "open", "platform": "server", "title": "Results won't save", "events": 9, "users": 6,
           "regressed": true, "last_seen": "2026-10-22T12:00:00Z", "fixed_at": null, "fix_platforms": [], "shipped": [],
           "last_note": null, "my_notes": 2},
          {"id": 2, "severity": "S4", "status": "needs_john", "platform": "ios", "title": "Hang", "events": 1, "users": 1,
           "regressed": false, "last_seen": "2026-10-21T12:00:00Z", "fixed_at": null, "fix_platforms": [], "shipped": [],
           "last_note": "Question: upload dSYMs?", "my_notes": 0},
          {"id": 3, "severity": "S4", "status": "wontfix", "platform": "web", "title": "Noise", "events": 40, "users": 9,
           "regressed": false, "last_seen": "2026-10-19T12:00:00Z", "fixed_at": null, "fix_platforms": [], "shipped": [],
           "last_note": null, "my_notes": 0}
        ],
        "pending": [{"platform": "ios", "fixes": 1, "worst": "S2", "oldest": "2026-10-22T11:00:00Z", "ids": [6], "due": true}]}
        """
        let inbox = try T1Shared.snakeDecoder.decode(BugsInbox.self, from: Data(json.utf8))
        XCTAssertEqual(inbox.needsYou.map(\.id), [2])
        XCTAssertEqual(inbox.needsYou.first?.lastNote, "Question: upload dSYMs?")
        XCTAssertEqual(inbox.open.map(\.id), [1])
        XCTAssertEqual(inbox.closed.map(\.id), [3])
        XCTAssertEqual(inbox.toShip("ios").map(\.id), [6])
        XCTAssertEqual(inbox.bugs.first?.waitingToShip, ["ios"], "the server half already shipped")
        XCTAssertEqual(BugWords.line(inbox.bugs[1]), "S1 · Server · 6 people · 9× · came back")
        XCTAssertEqual(BugWords.line(inbox.bugs[0]), "S2 · iOS · 1× · ship iOS")
    }

    func testDetailDecodesSample() throws {
        let json = """
        {"id": 10, "severity": null, "severity_reason": null, "severity_by": null, "status": "needs_john", "platform": "ios",
         "title": "Hang", "culprit": "?", "level": "error", "link": null, "releases": ["site.table1.events@0.1.0+15"],
         "environments": ["production"], "events": 1, "users": 1, "spikes": 0, "first_seen": "2026-10-22T09:00:00.123+00:00",
         "last_seen": "2026-10-22T09:12:00+00:00", "regressed": false, "attempts": 0, "claimed_at": null, "claimed_by": null,
         "notes": "Found nothing.\\nQuestion: upload dSYMs?", "fix_commit": null, "fix_summary": null, "fix_test": null,
         "fix_platforms": [], "fixed_at": null, "shipped": [], "duplicate_of": null, "duplicate_title": null, "source": "sentry",
         "created_at": "2026-10-22T09:00:00+00:00", "updated_at": "2026-10-22T09:12:00+00:00",
         "detail": {"kind": "sentry", "app": {"build": "15", "version": "0.1.0"}, "link": "https://table-1.sentry.io/issues/1/",
                    "tags": {"os": "iOS 27.0.1", "device": "iPhone16,2"},
                    "exception": [{"type": "App Hang", "value": "2.8 s", "mechanism": "AppHang", "handled": null,
                                   "frames": [{"file": "DeckStats.swift", "fn": "sampleHand", "module": "Table1", "line": 214, "col": null, "in_app": true}]}],
                    "breadcrumbs": [{"category": "http", "url": "https://us.i.posthog.com/batch", "status": 200, "level": "info"}]},
         "log": [{"kind": "change", "body": "Severity none → S2", "at": "2026-10-22T10:00:00+00:00"},
                 {"kind": "note", "body": "Yes, add it", "at": "2026-10-22T10:00:01+00:00"}]}
        """
        let d = try T1Shared.snakeDecoder.decode(BugDetail.self, from: Data(json.utf8))
        XCTAssertNil(d.severity)
        XCTAssertEqual(d.detail?.exception?.first?.frames?.first?.inApp, true)
        XCTAssertEqual(d.detail?.breadcrumbs?.first?.status, 200)
        XCTAssertEqual(d.detail?.tags?["device"], "iPhone16,2")
        XCTAssertEqual(d.sentryURL?.absoluteString, "https://table-1.sentry.io/issues/1/", "the sample's link when the bug has none")
        XCTAssertEqual(d.log.map(\.kind), ["change", "note"])
        XCTAssertNotNil(BugWords.when(d.firstSeen))

        let server = try T1Shared.snakeDecoder.decode(BugSample.self, from: Data(#"{"kind": "pg_net", "status": 504, "timed_out": true, "message": "upstream"}"#.utf8))
        XCTAssertEqual(server.status, 504)
        XCTAssertEqual(server.timedOut, true)
    }

    func testRefusalsInPlainWords() {
        struct E: Error, CustomStringConvertible { let description: String }
        XCTAssertEqual(BugsStore.words(E(description: "PostgrestError(code: 42501, message: Bug watchers only)")),
                       "Bugs are only for the people who get bug alerts.")
        XCTAssertEqual(BugsStore.words(E(description: "PostgrestError(code: PT409)")),
                       "The fix runner is working on this one. Try again when it's done.")
    }
}
