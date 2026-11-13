import CryptoKit
import Foundation
import JavaScriptCore

/* The cube ranking engine as a file the server publishes (contract/cube-rankings-2026-10-21.md § The engine as a file;
   John, 2026-11-13: "updates to the cube logic don't require new builds and just require a server update").

   The app's own engine (CubeRanking.swift) carries `CubeRanking.rules`, the date its rules last changed. The server
   publishes the TypeScript engine (table-1-events-web/src/lib/rankEngine.ts, built by tools/rank-engine/build.mjs) with a
   manifest naming its rules. When those are newer rules than the app's, rankings opened from then on decide their lists,
   next screens and estimates in that file, run here in JavaScriptCore; knowledge, why-chains, picks and comparisons stay
   native (they don't change with the rules). Otherwise, or when the file is missing, fails its hash or self test, or
   speaks another `api`, the app uses its own engine: nothing changes for a build that's current.

   The file and manifest are kept in Application Support/RankEngine and loaded at launch, so it works offline; the
   manifest is checked again at most hourly when Rankings opens. */
final class RankEngine: @unchecked Sendable {
    static let shared = RankEngine()
    /// The interface this build speaks (rankEngine.ts `API`).
    static let api = 1

    struct Manifest: Codable, Equatable {
        var api: Int
        var rules: String
        var version: String
        var file: String
        var sha256: String
        var bytes: Int?
    }

    private let lock = NSLock()
    private var context: JSContext?
    private var engine: JSValue?
    private(set) var version: String?
    private var checkedAt: Date?

    nonisolated(unsafe) static var directory = URL.applicationSupportDirectory.appending(path: "RankEngine", directoryHint: .isDirectory)
    static var base: URL { Config.supabaseURL.appending(path: "storage/v1/object/public/catalog/engines/rank") }

    /// True while rankings opened now run in the downloaded file.
    var active: Bool { lock.withLock { engine != nil } }

    /// Loads the kept file at launch when its rules are newer than the app's own.
    func start() {
        guard let m = Self.keptManifest(), Self.newer(m), let file = try? Data(contentsOf: Self.directory.appending(path: m.file)),
              Self.hex(SHA256.hash(data: file)) == m.sha256.lowercased(), let code = String(data: file, encoding: .utf8) else { return }
        _ = use(m, code: code, from: "kept")
    }

    /// Asks for the manifest (at most hourly unless `force`), downloads a new file, checks its hash and keeps it.
    func refresh(force: Bool = false) async {
        if !force, let at = lock.withLock({ checkedAt }), Date().timeIntervalSince(at) < 3600 { return }
        lock.withLock { checkedAt = Date() }
        do {
            var req = URLRequest(url: Self.base.appending(path: "manifest.json"))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, res) = try await URLSession.shared.data(for: req)
            guard (res as? HTTPURLResponse)?.statusCode == 200 else { return }
            let m = try JSONDecoder().decode(Manifest.self, from: data)
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            guard Self.newer(m) else {
                // The app's own rules are current (or the server pulled the file back): keep the manifest so a relaunch
                // doesn't load an older kept file, and stop using one now.
                try data.write(to: Self.directory.appending(path: "manifest.json"), options: .atomic)
                unload()
                return
            }
            if lock.withLock({ version }) == m.version { return }
            let path = Self.directory.appending(path: m.file)
            var file = (try? Data(contentsOf: path)) ?? Data()
            if Self.hex(SHA256.hash(data: file)) != m.sha256.lowercased() {
                let (got, fres) = try await URLSession.shared.data(from: Self.base.appending(path: m.file))
                guard (fres as? HTTPURLResponse)?.statusCode == 200 else { return }
                guard Self.hex(SHA256.hash(data: got)) == m.sha256.lowercased() else {
                    Telemetry.capture("rank_engine_failed", ["why": "hash", "version": m.version])
                    return
                }
                file = got
                try file.write(to: path, options: .atomic)
            }
            try data.write(to: Self.directory.appending(path: "manifest.json"), options: .atomic)
            guard let code = String(data: file, encoding: .utf8) else { return }
            _ = use(m, code: code, from: "downloaded")
        } catch {
            // Offline or the bucket answered oddly: keep what's loaded (or the app's own engine).
        }
    }

    /// Runs `code` as the engine when the manifest's rules are newer than the app's own and it passes its checks.
    /// `force` (tests) loads it whatever its rules.
    @discardableResult
    func use(_ m: Manifest, code: String, from: String, force: Bool = false) -> Bool {
        guard force || Self.newer(m) else { unload(); return false }
        guard m.api == Self.api else {
            Telemetry.capture("rank_engine_failed", ["why": "api", "version": m.version])
            unload(); return false
        }
        guard let ctx = JSContext() else { return false }
        var failed: String?
        ctx.exceptionHandler = { _, e in failed = e?.toString() ?? "exception" }
        ctx.evaluateScript(code, withSourceURL: URL(string: "rank-engine://\(m.version).js"))
        let t = ctx.objectForKeyedSubscript("T1Rank")
        guard failed == nil, let t, !t.isUndefined, t.forProperty("api").toInt32() == Int32(Self.api),
              t.forProperty("rules").toString() == m.rules, t.invokeMethod("selfTest", withArguments: []).toBool() else {
            Telemetry.capture("rank_engine_failed", ["why": failed == nil ? "self_test" : "load", "version": m.version])
            unload(); return false
        }
        ctx.exceptionHandler = { _, e in Telemetry.capture("rank_engine_failed", ["why": "call", "message": String((e?.toString() ?? "").prefix(200))]) }
        lock.withLock { context = ctx; engine = t; version = m.version }
        Telemetry.capture("rank_engine_used", ["version": m.version, "rules": m.rules, "from": from])
        return true
    }

    func unload() { lock.withLock { context = nil; engine = nil; version = nil } }

    /// The file's rules are other (newer) rules than the app's own. Dates compare as strings.
    static func newer(_ m: Manifest) -> Bool { m.rules > CubeRanking.rules }

    private static func keptManifest() -> Manifest? {
        guard let d = try? Data(contentsOf: directory.appending(path: "manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: d)
    }

    private static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // MARK: calls (all under the lock: one JSContext)

    fileprivate func call(_ method: String, _ args: [Any]) -> JSValue? {
        lock.withLock {
            guard let engine else { return nil }
            let v = engine.invokeMethod(method, withArguments: args)
            return v.map { $0.isUndefined || $0.isNull ? nil : $0 } ?? nil
        }
    }

    /// A ranking in the file, or nil when the app's own engine decides.
    func open(rankingId: String, category: [String: RankJob], log: [RankScreen], depth: String, top: Int, fresh: Set<String>) -> RankEngineState? {
        guard active else { return nil }
        struct Args: Encodable { var id: String; var cards: [String: String]; var log: [RankScreen]; var depth: String; var top: Int; var fresh: [String] }
        let args = Args(id: rankingId, cards: category.mapValues(\.rawValue), log: log, depth: depth, top: top, fresh: fresh.sorted())
        guard let json = try? String(data: JSONEncoder().encode(args), encoding: .utf8),
              let h = call("open", [json]), h.isNumber else { return nil }
        return RankEngineState(handle: h.toInt32(), version: version ?? "")
    }
}

/// One ranking state inside the file: its handle, freed with it, and the sessions already asked for.
final class RankEngineState: @unchecked Sendable {
    let handle: Int32
    let version: String
    private let lock = NSLock()
    private var sessions: [String: RankSession] = [:]

    init(handle: Int32, version: String) { self.handle = handle; self.version = version }
    deinit { _ = RankEngine.shared.call("free", [handle]) }

    func appending(_ screen: RankScreen) -> RankEngineState? {
        guard let json = try? String(data: JSONEncoder().encode(screen), encoding: .utf8),
              let h = RankEngine.shared.call("append", [handle, json]), h.isNumber else { return nil }
        return RankEngineState(handle: h.toInt32(), version: version)
    }

    struct Wire: Decodable {
        var top: [String]; var done: Bool; var target: Int; var size: Int; var question: [String]?; var pinned: [String]
        var open: [String]; var waiting: [String]; var check: Bool; var checked: Int
    }

    /// The file's session mapped onto the native knowledge's indexes (both index cards by sorted oracle id).
    func session(_ job: RankJob, _ K: RankKnowledge) -> RankSession? {
        if let s = lock.withLock({ sessions[job.rawValue] }) { return s }
        guard let v = RankEngine.shared.call("session", [handle, job.rawValue]), let text = v.toString(),
              let w = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)) else { return nil }
        func ix(_ ids: [String]) -> [Int]? {
            var out: [Int] = []
            for id in ids { guard let i = K.index[id] else { return nil }; out.append(i) }
            return out
        }
        guard let top = ix(w.top), let pinned = ix(w.pinned), let openIx = ix(w.open), let waiting = ix(w.waiting) else { return nil }
        var question: [Int]?
        if let q = w.question { guard let qi = ix(q) else { return nil }; question = qi }
        var open = RankBits(count: K.count)
        for i in openIx { open.insert(i) }
        let s = RankSession(top: top, done: w.done, target: w.target, size: w.size, question: question, pinned: pinned, open: open,
                            waiting: waiting, check: w.check, checked: w.checked)
        lock.withLock { sessions[job.rawValue] = s }
        return s
    }

    func expected(_ job: RankJob) -> Int? {
        guard let v = RankEngine.shared.call("expected", [handle, job.rawValue]), v.isNumber else { return nil }
        return Int(v.toInt32())
    }
}
