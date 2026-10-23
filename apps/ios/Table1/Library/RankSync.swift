import Foundation

// Saving a cube ranking (contract/cube-rankings-2026-10-21.md, "Saving"; reference testdata/ranking-save/make_cases.py,
// shared cases in testdata/ranking-save/cases.json). Twice on 2026-10-23 an iPhone wiped a 500-screen ranking: overlapping
// saves hit a conflict, the recovery cleared the app's copy of the server's log, and a save still waiting worked out
// "keep 0, add 1" from it. Now nothing is worked out by comparing logs: the app keeps the server's log as it last said it
// is, plus what was done here and not yet saved (lock-ins and picks to add, undone or redone screens to drop), and
// everything shown and sent comes from plan(). Removals are only ever ones the person made.

enum RankSync {
    /// What makes two screens the same screen: session, cards in order and time in whole ms (the server's rule too).
    static func key(_ s: RankScreen) -> String {
        "\(s.s)|\(s.o.joined(separator: ",").lowercased())|\(s.t.map { String(Int64($0.rounded())) } ?? "")"
    }

    struct Plan: Equatable {
        /// The log to show: the server's, then the adds it doesn't hold yet, less the drops.
        var log: [RankScreen]
        var add: [RankScreen]
        /// Server screens to take out (a drop of a screen only added here cancels that add; one already gone is skipped).
        var drop: [RankScreen]
        /// p_keep and p_count: the whole log as the server last said it is.
        var keep: Int
        var removed: Int { drop.count }
        var isEmpty: Bool { add.isEmpty && drop.isEmpty }
    }

    static func plan(server: [RankScreen], adds: [RankScreen], drops: [RankScreen]) -> Plan {
        var log = server.map { (screen: $0, added: false) }
        var have = Set(server.map(key))
        for a in adds where !have.contains(key(a)) {
            log.append((a, true))
            have.insert(key(a))
        }
        var drop: [RankScreen] = []
        for d in drops {
            let k = key(d)
            guard let i = log.firstIndex(where: { key($0.screen) == k }) else { continue }
            if !log.remove(at: i).added { drop.append(d) }
        }
        return Plan(log: log.map(\.screen), add: log.filter(\.added).map(\.screen), drop: drop, keep: server.count)
    }
}

/// What's waiting to be saved for one ranking, kept on the device so a crash, a force-quit or no signal loses nothing.
struct RankPending: Codable, Equatable, Sendable {
    var adds: [RankScreen] = []
    var drops: [RankScreen] = []
    var changes: [RankChange] = []
    /// The push being sent: retried with the same op id, so one that landed isn't applied twice.
    var op: Op?

    struct Op: Codable, Equatable, Sendable {
        var id: String
        var rev: Int
        var count: Int
        var adds: Int
        var drops: Int
        var changes: Int
    }

    var isEmpty: Bool { adds.isEmpty && drops.isEmpty && changes.isEmpty }

    /// After a save: what it sent is no longer waiting (anything done meanwhile stays, in order).
    mutating func settle(_ op: Op) {
        adds.removeFirst(min(op.adds, adds.count))
        drops.removeFirst(min(op.drops, drops.count))
        changes.removeFirst(min(op.changes, changes.count))
        self.op = nil
    }
}

enum RankPendingStore {
    nonisolated(unsafe) static var directory = URL.applicationSupportDirectory.appending(path: "Rankings", directoryHint: .isDirectory)

    private static func url(_ id: String) -> URL { directory.appending(path: "pending-\(id.lowercased()).json") }

    static func load(_ id: String) -> RankPending {
        guard let data = try? Data(contentsOf: url(id)), let p = try? JSONDecoder().decode(RankPending.self, from: data) else { return RankPending() }
        return p
    }

    static func save(_ id: String, _ p: RankPending) {
        if p.isEmpty {
            try? FileManager.default.removeItem(at: url(id))
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: url(id), options: .atomic) }
    }
}
