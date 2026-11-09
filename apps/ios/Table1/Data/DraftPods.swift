import Foundation

/// Drafts with several pods (contract/draft-pods-2026-11-09.md): the same rules as the engine's seating.ts and
/// playoffs.ts, checked against testdata/draft-pods/cases.json.
enum DraftPods {
    /// Pairing after round 1: inside each pod, or Swiss across every pod.
    static let inside = "pod"
    static let across = "cross"

    /// How many pods a pick makes: nil = automatic (pods of up to 8), never a pod under 2.
    static func count(players: Int, pods: Int?) -> Int {
        guard players > 0 else { return 0 }
        guard let pods else { return (players + 7) / 8 }
        return max(1, min(pods, players / 2))
    }

    /// Pod sizes, largest first: 14 in 2 → [7, 7].
    static func plan(players: Int, pods: Int?) -> [Int] {
        let c = count(players: players, pods: pods)
        guard c > 0 else { return [] }
        return (0..<c).map { players / c + ($0 < players % c ? 1 : 0) }
    }

    /// "2 pods · 9, 8", "1 pod · 6", "No players yet".
    static func label(players: Int, pods: Int?) -> String {
        let sizes = plan(players: players, pods: pods)
        if sizes.isEmpty { return "No players yet" }
        if sizes.count == 1 { return "1 pod · \(sizes[0])" }
        return "\(sizes.count) pods · " + sizes.map(String.init).joined(separator: ", ")
    }

    /// Automatic Swiss rounds: inside pods, enough for the largest pod; across pods, enough for everyone.
    static func rounds(sizes: [Int], pairing: String) -> Int {
        let s = sizes.filter { $0 > 0 }
        guard let largest = s.max() else { return EventRules.swissRounds(0) }
        return EventRules.swissRounds(pairing == inside ? largest : s.reduce(0, +))
    }

    /// The Automatic rounds switch's detail for a draft.
    static func autoLabel(players: Int, pods: Int?, pairing: String) -> String {
        guard players >= 2 else { return "Auto · set when round 1 is paired" }
        let sizes = plan(players: players, pods: pods)
        let n = rounds(sizes: sizes, pairing: pairing)
        let rs = "\(n) round\(n == 1 ? "" : "s")"
        if pairing == inside, sizes.count > 1, let largest = sizes.max() { return "Auto · \(rs) for pods of \(largest)" }
        return "Auto · \(rs) for \(players) players"
    }

    /// Round 1 of a seated draft, by seat numbers: each pod across its table, then the seats odd pods leave over
    /// against each other in pod order, the last one a bye when the event is odd.
    struct RoundOne: Equatable {
        struct Seat: Equatable { let pod: Int; let seat: Int }
        var pods: [(pairs: [(Int, Int)], left: Int?)]
        var across: [(Seat, Seat)]
        var bye: Seat?

        static func == (a: RoundOne, b: RoundOne) -> Bool {
            a.pods.count == b.pods.count
                && zip(a.pods, b.pods).allSatisfy { x, y in x.left == y.left && x.pairs.map { [$0.0, $0.1] } == y.pairs.map { [$0.0, $0.1] } }
                && a.across.map { [$0.0.pod, $0.0.seat, $0.1.pod, $0.1.seat] } == b.across.map { [$0.0.pod, $0.0.seat, $0.1.pod, $0.1.seat] }
                && a.bye == b.bye
        }
    }

    /// `seats`: each pod's seat numbers (any order).
    static func roundOne(_ seats: [[Int]]) -> RoundOne {
        var pods: [(pairs: [(Int, Int)], left: Int?)] = []
        var left: [RoundOne.Seat] = []
        for (p, podSeats) in seats.enumerated() {
            var s = podSeats.sorted()
            let extra = s.count % 2 == 1 ? s.removeLast() : nil
            let half = s.count / 2
            pods.append((pairs: (0..<half).map { (s[$0], s[$0 + half]) }, left: extra))
            if let extra { left.append(.init(pod: p, seat: extra)) }
        }
        let across = stride(from: 0, to: left.count - 1, by: 2).map { (left[$0], left[$0 + 1]) }
        return RoundOne(pods: pods, across: across, bye: left.count % 2 == 1 ? left.last : nil)
    }

    /// The note under pod `index`: "Round 1 pairs across the table: 1 v 4, 2 v 5, 3 v 6. Seat 7 plays Pod 2's seat 7."
    static func note(_ seats: [[Int]], pod index: Int, podName: (Int) -> String) -> String {
        let plan = roundOne(seats)
        let pod = plan.pods[index]
        let pairs = pod.pairs.map { "\($0.0) v \($0.1)" }.joined(separator: ", ")
        var text = pairs.isEmpty ? "Round 1 pairs across the table." : "Round 1 pairs across the table: \(pairs)."
        if let left = pod.left {
            let me = RoundOne.Seat(pod: index, seat: left)
            if plan.bye == me {
                text += " Seat \(left) has the bye."
            } else if let pair = plan.across.first(where: { $0.0 == me || $0.1 == me }) {
                let other = pair.0 == me ? pair.1 : pair.0
                text += " Seat \(left) plays \(podName(other.pod))'s seat \(other.seat)."
            }
        }
        return text
    }

    /// The seat whose player sits out round 1 (the bye), if this pod has it.
    static func byeSeat(_ seats: [[Int]], pod index: Int) -> Int? {
        let plan = roundOne(seats)
        return plan.bye?.pod == index ? plan.bye?.seat : nil
    }

    /// Short pod code for a standings row: "P1" from "Pod 1", else the pod's place.
    static func code(_ name: String?, index: Int) -> String {
        if let name, let n = name.split(separator: " ").last, Int(n) != nil { return "P\(n)" }
        return "P\(index + 1)"
    }
}
