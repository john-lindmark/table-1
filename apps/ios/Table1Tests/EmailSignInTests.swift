import XCTest
@testable import Table1

/* A refused email send and the kept code step (contract/email-sign-in-2026-10-15.md § Already sent) and the review account against
   testdata/email-sign-in/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/email-sign-in/cases.json").standardized

private struct Cases: Decodable {
    struct Send: Decodable { let name, code, message, outcome: String; let status, wait: Int }
    struct Restore: Decodable {
        let name, email: String
        let sent_at, resend_at, now, resend_at_out: Double
        let restored: Bool
    }
    struct Review: Decodable { let name, email: String; let review: Bool }
    let send: [Send]
    let restore: [Restore]
    let review: [Review]
}

final class EmailSignInTests: XCTestCase {
    private let cases = try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))

    func testSendOutcomes() {
        for c in cases.send {
            let expected: EmailSignIn.SendOutcome = switch c.outcome {
            case "already_sent": .alreadySent(wait: c.wait)
            case "too_many": .tooMany
            default: .failed
            }
            XCTAssertEqual(EmailSignIn.outcome(status: c.status, code: c.code, message: c.message), expected, c.name)
        }
    }

    func testRestore() {
        for c in cases.restore {
            let saved = EmailSignIn.Pending(email: c.email, sentAt: Date(timeIntervalSince1970: c.sent_at),
                                            resendAt: Date(timeIntervalSince1970: c.resend_at))
            let out = EmailSignIn.restore(saved, now: Date(timeIntervalSince1970: c.now))
            XCTAssertEqual(out != nil, c.restored, c.name)
            if let out { XCTAssertEqual(out.resendAt.timeIntervalSince1970, c.resend_at_out, c.name) }
        }
    }

    /// An already-sent restores with the countdown it was given.
    func testAlreadySentRoundTrip() {
        let now = Date(timeIntervalSince1970: 5000)
        let p = EmailSignIn.pending(email: "a@b.co", now: now, wait: 19)
        XCTAssertEqual(p.resendAt, now.addingTimeInterval(19))
        XCTAssertEqual(EmailSignIn.restore(p, now: now.addingTimeInterval(5))?.resendAt, p.resendAt)
    }

    func testReviewAddress() {
        for c in cases.review { XCTAssertEqual(EmailSignIn.isReview(c.email), c.review, c.name) }
    }

    func testSaveLoadClear() {
        EmailSignIn.save(EmailSignIn.pending(email: "a@b.co", now: .now))
        XCTAssertEqual(EmailSignIn.load()?.email, "a@b.co")
        EmailSignIn.clear()
        XCTAssertNil(EmailSignIn.load())
        EmailSignIn.save(EmailSignIn.pending(email: "a@b.co", now: Date(timeIntervalSinceNow: -4000)))
        XCTAssertNil(EmailSignIn.load(), "an expired code step is dropped")
    }
}
