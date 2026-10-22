import ActivityKit
import Foundation

/// The organizer's Live Activity (contract/widgets-2026-10-22.md). Field names match the live-activity edge function's
/// organizer.ts exactly: ActivityKit decodes pushed content with a plain JSONDecoder (camelCase, Unix seconds).
struct OrganizerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String              // live | between | complete | cancelled
        var round: Int
        var rounds: Int
        var roundSeconds: Int
        var endsAt: Double?
        var pausedRemaining: Int?
        var matches: Int               // non-bye matches this round
        var done: Int                  // settled
        var waiting: Int               // pending, or disputed and not decided
        var disputes: Int
        var guestWaiting: Int          // pending with no account on either side: the organizer enters these
        var players: Int
        var updatedAt: Double
    }

    var eventId: String
    var eventName: String
}

typealias OrgState = OrganizerActivityAttributes.ContentState

/// One event this account runs, as the `state` action returns it.
struct OrganizerSnapshot: Codable, Hashable, Identifiable {
    var eventId: String
    var eventName: String
    var state: OrgState
    var id: String { eventId }
    var attributes: OrganizerActivityAttributes { OrganizerActivityAttributes(eventId: eventId, eventName: eventName) }
}

extension OrgState {
    var isLive: Bool { phase == "live" }
    /// Every result is in and nothing is disputed: the organizer can move on.
    var isReady: Bool { isLive && matches > 0 && waiting == 0 }
    var endDate: Date? { endsAt.map { Date(timeIntervalSince1970: $0) } }
    var roundText: String { "R\(max(round, 1))/\(rounds)" }
    var resultsText: String { "\(done)/\(matches) in" }
    var pausedText: String? {
        guard let s = pausedRemaining else { return nil }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    /// What the organizer does when this round's results are all in.
    var nextAction: String { round < rounds ? "Pair round \(round + 1)" : "Finish event" }
    var staleDate: Date? { endDate.map { $0.addingTimeInterval(15 * 60) } }

    /// The one line that says what's next, for every surface.
    var nextStep: String {
        switch phase {
        case "complete": return "Event complete"
        case "cancelled": return "Event cancelled"
        case "between": return round == 0 ? "Pair round 1" : "Round \(round) recorded · \(nextAction)"
        default:
            if isReady { return "Ready: \(nextAction)" }
            if matches == 0 { return "No matches this round" }
            return "Waiting on \(waiting) result\(waiting == 1 ? "" : "s")"
        }
    }

    /// Extra flags under the next step: disputes first (they block pairing), then results only the organizer can enter.
    var flags: [String] {
        guard isLive else { return [] }
        var out: [String] = []
        if disputes > 0 { out.append("\(disputes) dispute\(disputes == 1 ? "" : "s") to decide") }
        if guestWaiting > 0 { out.append("\(guestWaiting) to enter yourself") }
        return out
    }
}

extension OrganizerSnapshot {
    static let sample = OrganizerSnapshot(
        eventId: "sample", eventName: "Friday Modern",
        state: OrgState(phase: "live", round: 2, rounds: 4, roundSeconds: 3000,
                        endsAt: Date().addingTimeInterval(23 * 60 + 41).timeIntervalSince1970, pausedRemaining: nil,
                        matches: 8, done: 5, waiting: 3, disputes: 1, guestWaiting: 1, players: 16,
                        updatedAt: Date().timeIntervalSince1970)
    )

    func deepLink(src: String) -> URL { URL(string: "table1://event/\(eventId)?src=\(src)")! }
}
