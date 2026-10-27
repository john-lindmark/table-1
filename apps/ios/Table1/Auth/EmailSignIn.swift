import Foundation
import Supabase

/// What a refused email send means, and the code step kept across leaving the app
/// (contract/email-sign-in-2026-10-15.md § Already sent; cases testdata/email-sign-in/cases.json).
enum EmailSignIn {
    enum SendOutcome: Equatable {
        /// A code went out moments ago (Supabase's minute per address): show the code step, resend in `wait` s.
        case alreadySent(wait: Int)
        /// The project's hourly cap or this network's request limit: no code is on its way.
        case tooMany
        case failed
    }

    /// A code lives an hour; Supabase sends at most one a minute per address.
    static let codeLife: TimeInterval = 3600
    static let resendGap: TimeInterval = 60

    static func outcome(status: Int?, code: String, message: String) -> SendOutcome {
        let limited = code == "over_email_send_rate_limit" || code == "over_request_rate_limit" || status == 429
        guard limited else { return .failed }
        if code != "over_request_rate_limit", let wait = secondsLeft(message) { return .alreadySent(wait: min(max(wait, 1), 60)) }
        return .tooMany
    }

    static func outcome(_ error: Error) -> SendOutcome {
        guard let auth = error as? AuthError else { return .failed }
        if case let .api(message, code, _, response) = auth {
            return outcome(status: response.statusCode, code: code.rawValue, message: message)
        }
        return .failed
    }

    /// "…only request this after 19 seconds." → 19
    private static func secondsLeft(_ message: String) -> Int? {
        guard let match = message.firstMatch(of: #/after (\d+) seconds?/#) else { return nil }
        return Int(match.1)
    }

    // MARK: the store review account

    /// App Store and Play reviewers can't read a code from our email, so this one address signs in with a fixed
    /// code (its password, in John's Keychain) and no email is sent (contract § Review account).
    static let reviewAddress = "appreview@table-1.site"

    static func isReview(_ email: String) -> Bool {
        email.trimmingCharacters(in: .whitespaces).lowercased() == reviewAddress
    }

    // MARK: the code step, kept on the device

    struct Pending: Codable, Equatable {
        var email: String
        var sentAt: Date
        var resendAt: Date
    }

    /// The saved code step if its code can still be used at `now`, with Resend never before send + 60 s.
    static func restore(_ saved: Pending?, now: Date) -> Pending? {
        guard var p = saved, !p.email.isEmpty else { return nil }
        let age = now.timeIntervalSince(p.sentAt)
        guard age >= 0, age < codeLife else { return nil }
        p.resendAt = max(p.resendAt, p.sentAt.addingTimeInterval(resendGap))
        return p
    }

    /// After a send, or an already-sent whose code went out `resendGap - wait` seconds ago.
    static func pending(email: String, now: Date, wait: Int? = nil) -> Pending {
        let resendAt = now.addingTimeInterval(TimeInterval(wait ?? Int(resendGap)))
        return Pending(email: email, sentAt: resendAt.addingTimeInterval(-resendGap), resendAt: resendAt)
    }

    private static let key = "t1.signin.pending"

    static func save(_ p: Pending) {
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load(now: Date = .now) -> Pending? {
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
        let p = restore(saved, now: now)
        if p == nil { clear() }
        return p
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
