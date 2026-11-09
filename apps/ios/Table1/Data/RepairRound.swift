import Foundation

/// Re-pair a round (contract/repair-round-2026-11-09.md): the Live notice that an earlier result changed after the
/// current round was paired, the confirm alert, and how a round is named. Cases: testdata/repair-round/cases.json.
enum RepairRound {
    struct Prompt: Equatable {
        let round: Int
        let changed: [Int]
        let text: String
    }

    /// The current round, if it may be re-paired: the latest round, still active.
    static func repairable(_ rounds: [RoundRow]) -> RoundRow? {
        guard let latest = rounds.max(by: { $0.number < $1.number }), latest.status == "active" else { return nil }
        return latest
    }

    /// "A round 2 result changed after round 3 was paired." when the organizer corrected an earlier round since.
    static func prompt(_ rounds: [RoundRow]) -> Prompt? {
        guard let current = repairable(rounds),
              let paired = current.pairingsPublishedAt.flatMap(T1Date.parse) else { return nil }
        let changed = rounds
            .filter { $0.number < current.number }
            .filter { r in
                r.matches.contains { m in
                    !m.isBye && m.resultSource == "organizer" && (m.updatedAt.flatMap(T1Date.parse).map { $0 > paired } ?? false)
                }
            }
            .map(\.number)
            .sorted()
        guard !changed.isEmpty else { return nil }
        let text = changed.count == 1
            ? "A round \(changed[0]) result changed after round \(current.number) was paired."
            : "Results in rounds \(andList(changed.map(String.init))) changed after round \(current.number) was paired."
        return Prompt(round: current.number, changed: changed, text: text)
    }

    private static func andList(_ xs: [String]) -> String {
        xs.count <= 1 ? xs.joined() : xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }

    /// "round 3", or "the quarterfinals" / "the semifinals" / "the final" in a top 8.
    static func label(stage: String?, number: Int) -> String {
        switch stage {
        case "quarterfinal": "the quarterfinals"
        case "semifinal": "the semifinals"
        case "final": "the final"
        default: "round \(number)"
        }
    }

    /// Results already in (byes and unreported matches don't count).
    static func resultsIn(_ matches: [(isBye: Bool, status: String)]) -> Int {
        matches.filter { !$0.isBye && $0.status != "pending" }.count
    }

    static func confirm(label: String, matches: [(isBye: Bool, status: String)]) -> (title: String, message: String, results: Int) {
        let results = resultsIn(matches)
        let base = "New pairings from the standings as they are now. Players get their new tables and the clock starts again."
        let cleared = results == 0 ? ""
            : results == 1 ? " The 1 result already in for \(label) is cleared."
            : " The \(results) results already in for \(label) are cleared."
        return ("Re-pair \(label)?", base + cleared, results)
    }
}
