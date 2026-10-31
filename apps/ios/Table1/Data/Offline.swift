import Foundation

/// Offline rules shared with web and Android (contract/offline-2026-10-31.md, cases testdata/offline/cases.json):
/// how long ago a saved answer is, what a screen says when a call fails, and which failed collection batches wait in
/// the outbox.
enum Offline {
    /// "just now", "3 min ago", "2 h ago", "1 day ago".
    nonisolated static func ago(_ seconds: Int) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        let days = seconds / 86400
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// What a screen says after its call fails: nothing when it didn't; the saved answer's age as a plain notice when
    /// there is one; else the error itself.
    nonisolated static func notice(failed: Bool, savedAgo: Int?, error: String?) -> (text: String, isError: Bool)? {
        guard failed else { return nil }
        if let savedAgo { return ("Couldn't refresh · last updated \(ago(savedAgo))", false) }
        let e = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (e.isEmpty ? "Couldn't load. Check your connection." : e, true)
    }

    /// Seconds since `at`, for `notice`.
    nonisolated static func age(_ at: Date?, now: Date = .now) -> Int? {
        at.map { max(0, Int(now.timeIntervalSince($0))) }
    }

    /// A failure to reach the server (offline, timed out, connection dropped), as opposed to its answer.
    nonisolated static func isNetwork(_ error: Error) -> Bool {
        if error.isCancellation { return false }
        if error is URLError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        if ns.domain == NSPOSIXErrorDomain { return true }
        return false
    }

    /// A failed `collection_apply` batch waits in the outbox when the failure was the network and every op only adds.
    nonisolated static func queues(_ ops: [CollectionOp], network: Bool) -> Bool {
        network && !ops.isEmpty && ops.allSatisfy { ($0.delta ?? 0) > 0 && $0.qty == nil }
    }

    /// The copies the outbox will add per item key, so a sync row shows the server's count plus them.
    nonisolated static func deltas(_ batches: [[CollectionOp]]) -> [String: Int] {
        var out: [String: Int] = [:]
        for ops in batches { for op in ops { out[op.itemKey, default: 0] += op.delta ?? 0 } }
        return out.filter { $0.value != 0 }
    }
}

/// The last answers to a few calls, kept per account as they came off the wire (contract/offline-2026-10-31.md § 1),
/// so the Events tab, an event and Insights open on what was last seen when the server can't be reached. The file's
/// modification date is when it was fetched.
enum OfflineCache {
    nonisolated private static func dir(_ user: String) -> URL {
        let d = URL.applicationSupportDirectory.appending(path: "Offline", directoryHint: .isDirectory)
            .appending(path: user, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    nonisolated private static func file(_ user: String, _ key: String) -> URL {
        dir(user).appending(path: key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    nonisolated static func load(_ user: String, _ key: String) -> (data: Data, at: Date)? {
        let f = file(user, key)
        guard let data = try? Data(contentsOf: f),
              let at = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date else { return nil }
        return (data, at)
    }

    nonisolated static func save(_ user: String, _ key: String, _ data: Data) {
        let f = file(user, key)
        try? data.write(to: f, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
    }

    /// A decoded saved answer with its age.
    nonisolated static func load<T: Decodable>(_ user: String, _ key: String, as type: T.Type, decoder: JSONDecoder = wireDecoder) -> (value: T, at: Date)? {
        guard let (data, at) = load(user, key), let v = try? decoder.decode(T.self, from: data) else { return nil }
        return (v, at)
    }
}
