import ActivityKit
import Foundation

/// The player's Live Activity. Field names match the live-activity edge function exactly, because
/// ActivityKit decodes pushed content with a plain JSONDecoder (camelCase keys, no date strategy):
/// times travel as Unix seconds.
struct PlayerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String              // playing | bye | waiting | complete | dropped
        var round: Int
        var rounds: Int
        var roundSeconds: Int
        var endsAt: Double?            // clock running: ends at (Unix seconds)
        var pausedRemaining: Int?      // clock paused: seconds left
        var table: Int?
        var myName: String
        var myRank: Int?
        var myRecord: String
        var players: Int
        var oppName: String?
        var oppRank: Int?
        var oppRecord: String?
        var matchId: String?
        var matchVersion: Int?
        var mySide: Int?
        var status: String?            // pending | reported_me | reported_them | disputed | confirmed
        var myWins: Int?
        var theirWins: Int?
        var draws: Int?
        var canReport: Bool
        var updatedAt: Double
    }

    var eventId: String
    var eventName: String
    var participantId: String
}

typealias LiveState = PlayerActivityAttributes.ContentState

/// What the widgets and the app cache: one player seat in a live event.
struct LiveSnapshot: Codable, Hashable, Identifiable {
    var eventId: String
    var eventName: String
    var participantId: String
    var state: LiveState
    var id: String { participantId }

    var attributes: PlayerActivityAttributes {
        PlayerActivityAttributes(eventId: eventId, eventName: eventName, participantId: participantId)
    }
}

extension LiveState {
    var isPlaying: Bool { phase == "playing" }
    var endDate: Date? { endsAt.map { Date(timeIntervalSince1970: $0) } }
    /// Whole-round window, for gauges that fill as the round runs.
    var roundWindow: ClosedRange<Date>? {
        guard let end = endDate else { return nil }
        let start = end.addingTimeInterval(-Double(max(roundSeconds, 60)))
        return min(start, end)...end
    }
    var canReportNow: Bool { isPlaying && canReport && status == "pending" }
    var needsMyAnswer: Bool { isPlaying && status == "reported_them" }
    var pausedText: String? {
        guard let s = pausedRemaining else { return nil }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    var tableText: String { table.map { "T\($0)" } ?? "T–" }
    var roundText: String { "R\(max(round, 1))/\(rounds)" }
    var myRankText: String { myRank.map { "#\($0)" } ?? "#–" }
    var oppRankText: String { oppRank.map { "#\($0)" } ?? "#–" }
    var scoreText: String { "\(myWins ?? 0)–\(theirWins ?? 0)" }

    /// One line describing where the match stands, for every surface.
    var statusLine: String {
        switch phase {
        case "bye": return "Bye this round"
        case "waiting": return "Waiting for round \(round + 1)"
        case "complete": return "Event complete · \(myRankText) of \(players)"
        case "dropped": return "Dropped"
        default:
            switch status {
            case "reported_me": return "Reported \(scoreText) · waiting on \(oppName ?? "opponent")"
            case "reported_them": return "\(oppName ?? "Opponent") reported \(scoreText)"
            case "disputed": return "Disputed · organizer deciding"
            case "confirmed": return "Confirmed \(scoreText)"
            default: return canReport ? "Report when you're done" : "Organizer records results"
            }
        }
    }

    /// Stale after the round ends plus a grace period; the system dims stale activities.
    var staleDate: Date? { endDate.map { $0.addingTimeInterval(15 * 60) } }
}

/// The five results a player can report, as (my wins, their wins).
enum MatchOutcome: CaseIterable {
    case won20, won21, draw11, lost12, lost02
    var wins: (my: Int, their: Int) {
        switch self {
        case .won20: (2, 0)
        case .won21: (2, 1)
        case .draw11: (1, 1)
        case .lost12: (1, 2)
        case .lost02: (0, 2)
        }
    }
    var label: String { "\(wins.my)-\(wins.their)" }
}

extension LiveSnapshot {
    static let sample = LiveSnapshot(
        eventId: "sample", eventName: "Thursday Draft", participantId: "sample",
        state: LiveState(phase: "playing", round: 2, rounds: 3, roundSeconds: 3000,
                         endsAt: Date().addingTimeInterval(42 * 60 + 17).timeIntervalSince1970, pausedRemaining: nil,
                         table: 4, myName: "Alex Kim", myRank: 3, myRecord: "1-0", players: 8,
                         oppName: "Brit Osei", oppRank: 4, oppRecord: "1-0", matchId: nil, matchVersion: 1, mySide: 0,
                         status: "pending", myWins: 0, theirWins: 0, draws: 0, canReport: true,
                         updatedAt: Date().timeIntervalSince1970)
    )
}
