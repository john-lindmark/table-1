import Foundation
import Supabase

/* Bugs (contract/bug-pipeline-2026-10-18.md § Inbox): for the bug watchers only (John). A bug push opens the bug, a
   build push opens what's waiting to ship. The register lives on the server; this store shows it and sends John's
   changes back (severity, status, notes the fix runner reads, a platform shipped). Everyone else is refused by the
   server and never sees the Account row. */

struct BugsMe: Decodable, Sendable {
    var watcher: Bool
    var needsYou: Int?
    var open: Int?
    var toShip: Int?
}

struct BugRow: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var severity: String?
    var status: String
    let platform: String
    let title: String
    var events: Int
    var users: Int
    var regressed: Bool
    var lastSeen: String?
    var fixedAt: String?
    var fixPlatforms: [String]
    var shipped: [String]
    /// The fix runner's last note line: its question when it needs John.
    var lastNote: String?
    var myNotes: Int

    var waitingToShip: [String] { status == "fixed" ? fixPlatforms.filter { !shipped.contains($0) } : [] }
}

struct BugPending: Decodable, Identifiable, Hashable, Sendable {
    let platform: String
    var fixes: Int
    var worst: String
    var oldest: String?
    var ids: [Int]
    var due: Bool
    var id: String { platform }
}

struct BugsInbox: Decodable, Sendable {
    var bugs: [BugRow]
    var pending: [BugPending]

    /// The runner asked John something, or three tries didn't land.
    var needsYou: [BugRow] { bugs.filter { $0.status == "needs_john" } }
    /// Waiting for a severity, waiting for the runner, or being fixed.
    var open: [BugRow] { bugs.filter { ["new", "open", "fixing"].contains($0.status) } }
    var closed: [BugRow] {
        bugs.filter { ["wontfix", "duplicate"].contains($0.status) || ($0.status == "fixed" && $0.waitingToShip.isEmpty) }
    }
    /// The fixes merged but not yet shipped on a platform, in the server's order.
    func toShip(_ platform: String) -> [BugRow] {
        let ids = pending.first { $0.platform == platform }?.ids ?? []
        return ids.compactMap { id in bugs.first { $0.id == id } }
    }
}

struct BugLogEntry: Decodable, Hashable, Sendable {
    /// note (John's words, read by the fix runner) / change (what John changed)
    let kind: String
    let body: String
    let at: String
}

/// The latest occurrence, as the bugs edge function keeps it: a Sentry event (exception, frames, breadcrumbs,
/// tags), a Sentry issue, or the server's own failure (cron job, pg_net call). Never user data.
struct BugSample: Decodable, Hashable, Sendable {
    struct Frame: Decodable, Hashable, Sendable {
        var file: String?
        var fn: String?
        var module: String?
        var line: Int?
        var inApp: Bool?
    }
    struct Exception: Decodable, Hashable, Sendable {
        var type: String?
        var value: String?
        var mechanism: String?
        var frames: [Frame]?
    }
    struct Crumb: Decodable, Hashable, Sendable {
        var category: String?
        var message: String?
        var level: String?
        var url: String?
        var status: Int?
    }
    struct Issue: Decodable, Hashable, Sendable {
        var type: String?
        var value: String?
        var filename: String?
        var function: String?
    }
    struct App: Decodable, Hashable, Sendable {
        var version: String?
        var build: String?
    }
    var kind: String?
    var exception: [Exception]?
    var breadcrumbs: [Crumb]?
    var tags: [String: String]?
    var app: App?
    var issue: Issue?
    var link: String?
    var job: String?
    var message: String?
    var status: Int?
    var timedOut: Bool?
}

struct BugDetail: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var severity: String?
    var severityReason: String?
    var severityBy: String?
    var status: String
    let platform: String
    let title: String
    var culprit: String?
    var level: String?
    var link: String?
    var releases: [String]
    var events: Int
    var users: Int
    var spikes: Int
    var firstSeen: String?
    var lastSeen: String?
    var regressed: Bool
    var attempts: Int
    var claimedAt: String?
    /// The fix runner's notes: what it found, or its question for John.
    var notes: String?
    var fixCommit: String?
    var fixSummary: String?
    var fixTest: String?
    var fixPlatforms: [String]
    var fixedAt: String?
    var shipped: [String]
    var duplicateOf: Int?
    var duplicateTitle: String?
    var detail: BugSample?
    var log: [BugLogEntry]

    /// Sentry's issue page, from the bug or its sample.
    var sentryURL: URL? { (link ?? detail?.link).flatMap(URL.init(string:)) }
}

enum BugWords {
    static func platform(_ p: String) -> String {
        ["ios": "iOS", "android": "Android", "web": "Web", "server": "Server"][p] ?? "App"
    }

    static func status(_ s: String) -> String {
        switch s {
        case "new": "Waiting for a severity"
        case "open": "Waiting for the fix runner"
        case "fixing": "Fix runner on it"
        case "fixed": "Fixed"
        case "needs_john": "Needs you"
        case "wontfix": "Won't fix"
        case "duplicate": "Duplicate"
        default: s
        }
    }

    /// "Oct 22, 14:05": recent enough to need the time.
    static func when(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        return d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// One line under a bug's title: severity, platform, reach, and what it's waiting on.
    static func line(_ b: BugRow) -> String {
        var parts = [b.severity ?? "Untriaged", platform(b.platform)]
        if b.users > 0 { parts.append("\(b.users) \(b.users == 1 ? "person" : "people")") }
        parts.append("\(b.events)×")
        if b.regressed { parts.append("came back") }
        if b.status == "fixing" { parts.append("fixing") }
        if !b.waitingToShip.isEmpty { parts.append("ship " + b.waitingToShip.map(platform).joined(separator: " + ")) }
        return parts.joined(separator: " · ")
    }
}

/// Where a tapped push with no event goes.
/// What a tapped "New in Insights" push opens (contract/insights-2026-10-24.md § New in Insights).
struct InsightsPush: Equatable {
    /// constructed or limited
    let section: String
    /// a format (modern) or a set / cube version (FRA, PWR-2510)
    let key: String
    /// data: the format or set; rank: the set's Rankings
    let what: String
}

enum PushRoutes {
    static func insights(_ info: [AnyHashable: Any]) -> InsightsPush? {
        guard info["kind"] as? String == "insights.new", let section = info["insights_section"] as? String,
              section == "constructed" || section == "limited", let key = info["insights_key"] as? String, !key.isEmpty else { return nil }
        return InsightsPush(section: section, key: key, what: info["what"] as? String == "rank" ? "rank" : "data")
    }

    /// The Collection stack a tapped push opens: someone started ranking your cube (contract/cube-rankings-2026-10-21.md).
    /// Or a round of changes to something you follow (contract/follows-2026-10-25.md): its Changes.
    static func library(_ info: [AnyHashable: Any]) -> [LibraryRoute]? {
        // Wants got cheaper or fell to their max (contract/want-prices-2026-10-26.md): Wants.
        if info["kind"] as? String == "want.price" { return [.wants] }
        // A deck search finished (contract/deck-finder-2026-10-15.md § Jobs): Find a deck on that job.
        if info["kind"] as? String == "deck.found", let job = info["job_id"] as? String, !job.isEmpty {
            return [.lists(.deck), .findDeck(job)]
        }
        // A friend put cards you want up for trade: your match with them.
        if info["kind"] as? String == "trade.wants", let user = info["user_id"] as? String, !user.isEmpty {
            return [.social(.matches), .social(.match(user))]
        }
        if info["kind"] as? String == "follow.updated", let kind = info["follow_kind"] as? String, let id = info["item_id"] as? String, !id.isEmpty {
            return [.social(.following), .social(.followChanges(kind, id))]
        }
        guard info["kind"] as? String == "ranking.started", let id = info["ranking_id"] as? String, !id.isEmpty else { return nil }
        return [.ranking(id)]
    }

    /// The Account screen a tapped push with no event opens: friends, moderation, or (watchers) bugs.
    static func route(_ info: [AnyHashable: Any]) -> SocialRoute? {
        guard let kind = info["kind"] as? String else { return nil }
        switch kind {
        case "moderation.notice": return .notices
        case "moderation.review": return .review
        case "ops.bug":
            let id = (info["bug_id"] as? Int) ?? (info["bug_id"] as? NSNumber)?.intValue ?? (info["bug_id"] as? String).flatMap(Int.init)
            return id.map { .bug($0) } ?? .bugs
        case "ops.build": return .bugs
        default: return kind.hasPrefix("friend.") ? .friends : nil
        }
    }

    /// The Account stack for a route: a bug opens above the inbox, so back lands on the rest.
    static func path(_ route: SocialRoute) -> [LibraryRoute] {
        if case .bug = route { return [.social(.bugs), .social(route)] }
        return [.social(route)]
    }
}

@MainActor
@Observable
final class BugsStore {
    static let shared = BugsStore()
    private(set) var me: BugsMe?
    private(set) var inbox: BugsInbox?
    private(set) var details: [Int: BugDetail] = [:]
    private(set) var showClosed = false
    var error: String?
    #if DEBUG
    @ObservationIgnored var demo: BugsDemo?
    #endif

    func stop() {
        me = nil
        inbox = nil
        details = [:]
        error = nil
    }

    func loadMe() async {
        #if DEBUG
        if let demo { me = demo.me; return }
        #endif
        me = try? await supabase.rpc("bugs_me").execute().value
    }

    func loadInbox() async {
        do {
            #if DEBUG
            if let demo { inbox = demo.inbox(closed: showClosed); me = demo.me; return }
            #endif
            inbox = try await supabase.rpc("bugs_inbox", params: ["p_closed": AnyJSON.bool(showClosed)]).execute().value
            error = nil
        } catch {
            self.error = Self.words(error)
        }
    }

    func setShowClosed(_ on: Bool) async {
        showClosed = on
        await loadInbox()
    }

    func loadDetail(_ id: Int) async {
        do {
            #if DEBUG
            if let demo { details[id] = demo.detail(id); return }
            #endif
            details[id] = try await supabase.rpc("bugs_detail", params: ["p_id": AnyJSON.integer(id)]).execute().value
            error = nil
        } catch {
            self.error = Self.words(error)
        }
    }

    /// Severity, status and/or a note in one call. `key` makes a retried send land once.
    func update(_ id: Int, severity: String? = nil, status: String? = nil, note: String? = nil, key: UUID = UUID()) async throws {
        var p: [String: AnyJSON] = ["key": .string(key.uuidString)]
        if let severity { p["severity"] = .string(severity) }
        if let status { p["status"] = .string(status) }
        let trimmed = note.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)) } ?? ""
        if !trimmed.isEmpty { p["note"] = .string(trimmed) }
        #if DEBUG
        if let demo {
            details[id] = demo.update(id, severity: severity, status: status, note: trimmed.isEmpty ? nil : trimmed)
            inbox = demo.inbox(closed: showClosed)
            me = demo.me
            return
        }
        #endif
        let d: BugDetail = try await supabase.rpc("bugs_update", params: [
            "p_id": AnyJSON.integer(id), "p": .object(p),
        ]).execute().value
        details[id] = d
        Telemetry.capture("bug_updated", ["severity": severity != nil, "status": status ?? "", "note": !trimmed.isEmpty])
        await loadInbox()
        await loadMe()
    }

    private struct Shipped: Decodable { let shipped: [Int] }

    /// A build or deploy went out: every pending fix on that platform counts as shipped. Returns how many.
    @discardableResult
    func ship(_ platform: String) async throws -> Int {
        #if DEBUG
        if let demo { let n = demo.ship(platform); inbox = demo.inbox(closed: showClosed); me = demo.me; return n }
        #endif
        let r: Shipped = try await supabase.rpc("bugs_ship", params: ["p_platform": AnyJSON.string(platform)]).execute().value
        Telemetry.capture("bugs_shipped", ["platform": platform, "fixes": r.shipped.count])
        details = [:]
        await loadInbox()
        await loadMe()
        return r.shipped.count
    }

    /// The server's refusals in plain words.
    static func words(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("42501") || text.contains("Bug watchers only") { return "Bugs are only for the people who get bug alerts." }
        if text.contains("PT409") { return "The fix runner is working on this one. Try again when it's done." }
        if text.contains("Pick a severity") { return "Pick a severity first." }
        return error.localizedDescription
    }
}

#if DEBUG
/// Bugs on demo data (`-T1LibraryDemo bugs|bug`): one question from the runner, an S1 and an S3 open, a fix waiting
/// to ship on iOS + server, and a closed one. Changes stay in memory.
@MainActor
final class BugsDemo {
    private var rows: [BugRow] = [
        BugRow(id: 10, severity: "S4", status: "needs_john", platform: "ios", title: "App Hang Non Fully Blocked: App hanging between 2.8 and 3.6 seconds.",
               events: 1, users: 1, regressed: false, lastSeen: "2026-10-22T09:12:00Z", fixPlatforms: [], shipped: [],
               lastNote: "Question: should I add a Release-only build phase that uploads dSYMs to Sentry?", myNotes: 0),
        BugRow(id: 12, severity: "S1", status: "open", platform: "server", title: "http:POST /rest/v1/rpc/report_result answered 500",
               events: 14, users: 6, regressed: true, lastSeen: "2026-10-22T13:40:00Z", fixPlatforms: [], shipped: [], myNotes: 0),
        BugRow(id: 11, severity: "S3", status: "fixing", platform: "ios", title: "Sample hand: index out of range on a 7-card deck",
               events: 3, users: 2, regressed: false, lastSeen: "2026-10-21T20:02:00Z", fixPlatforms: [], shipped: [], myNotes: 0),
        BugRow(id: 9, severity: "S4", status: "fixed", platform: "ios", title: "com.google.GIDSignIn: Unable to open Safari.",
               events: 2, users: 1, regressed: false, lastSeen: "2026-10-20T18:00:00Z", fixedAt: "2026-10-21T08:10:00Z",
               fixPlatforms: ["ios"], shipped: [], myNotes: 0),
        BugRow(id: 7, severity: "S2", status: "fixed", platform: "server", title: "cards-sync names step timed out",
               events: 4, users: 0, regressed: false, lastSeen: "2026-10-20T03:00:00Z", fixedAt: "2026-10-20T08:30:00Z",
               fixPlatforms: ["server"], shipped: [], myNotes: 0),
        BugRow(id: 3, severity: "S4", status: "wontfix", platform: "web", title: "ResizeObserver loop limit exceeded",
               events: 40, users: 9, regressed: false, lastSeen: "2026-10-19T12:00:00Z", fixPlatforms: [], shipped: [], myNotes: 0),
    ]
    private var logs: [Int: [BugLogEntry]] = [:]

    var me: BugsMe {
        BugsMe(watcher: true, needsYou: rows.filter { $0.status == "needs_john" }.count,
               open: rows.filter { ["new", "open", "fixing"].contains($0.status) }.count,
               toShip: pending.filter(\.due).count)
    }

    private var pending: [BugPending] {
        ["ios", "web", "android", "server"].compactMap { p in
            let waiting = rows.filter { $0.waitingToShip.contains(p) }
            guard !waiting.isEmpty else { return nil }
            let worst = waiting.compactMap(\.severity).min() ?? "S4"
            return BugPending(platform: p, fixes: waiting.count, worst: worst, oldest: waiting.compactMap(\.fixedAt).min(),
                              ids: waiting.map(\.id).sorted(), due: worst <= "S2" || waiting.count >= 5)
        }
    }

    func inbox(closed: Bool) -> BugsInbox {
        let shown = rows.filter { closed || !(["wontfix", "duplicate"].contains($0.status) || ($0.status == "fixed" && $0.waitingToShip.isEmpty)) }
        return BugsInbox(bugs: shown.sorted { ($0.severity ?? "S5", $1.lastSeen ?? "") < ($1.severity ?? "S5", $0.lastSeen ?? "") }, pending: pending)
    }

    func detail(_ id: Int) -> BugDetail? {
        guard let r = rows.first(where: { $0.id == id }) else { return nil }
        let sample = BugSample(kind: "sentry", exception: [
            BugSample.Exception(type: id == 12 ? "PostgrestError" : "App Hang", value: r.title, mechanism: id == 12 ? "http" : "AppHang", frames: [
                BugSample.Frame(file: "DeckStats.swift", fn: "sampleHand(from:)", module: "Table1", line: 214, inApp: true),
                BugSample.Frame(file: "DeckStatsView.swift", fn: "body", module: "Table1", line: 88, inApp: true),
            ]),
        ], breadcrumbs: [
            BugSample.Crumb(category: "ui.lifecycle", level: "info"),
            BugSample.Crumb(category: "http", level: "info", url: "https://us.i.posthog.com/batch", status: 200),
            BugSample.Crumb(category: "navigation", message: "deck_stats", level: "info"),
        ], tags: ["os": "iOS 27.0.1", "device": "iPhone16,2", "release": "site.table1.events@0.1.0+15"],
            app: BugSample.App(version: "0.1.0", build: "15"))
        let notes: String? = switch id {
        case 10: "One 2.8–3.6 s hang on build 15, right after launch. The in-app frame has no symbol because the app doesn't upload dSYMs to Sentry.\nQuestion: should I add a Release-only build phase that uploads dSYMs to Sentry?"
        case 11: "Reproduced with a 7-card deck in DeckStatsTests."
        default: nil
        }
        return BugDetail(id: r.id, severity: r.severity, severityReason: r.regressed ? "Came back after a shipped fix. Results won't save." : "Rated by Claude",
                         severityBy: "claude", status: r.status, platform: r.platform, title: r.title, releases: ["site.table1.events@0.1.0+15"],
                         events: r.events, users: r.users, spikes: 0, firstSeen: "2026-10-19T10:00:00Z", lastSeen: r.lastSeen,
                         regressed: r.regressed, attempts: r.status == "fixing" ? 1 : 0, claimedAt: r.status == "fixing" ? "2026-10-22T13:00:00Z" : nil,
                         notes: notes, fixCommit: r.status == "fixed" ? "5b625cf" : nil,
                         fixSummary: r.status == "fixed" ? "Google's 'Unable to open Safari.' now shows 'Google sign-in didn't open' instead of an error report." : nil,
                         fixTest: r.status == "fixed" ? "SignInFailureTests.testSafariUnavailable" : nil,
                         fixPlatforms: r.fixPlatforms, fixedAt: r.fixedAt, shipped: r.shipped,
                         detail: sample, log: logs[id] ?? [])
    }

    func update(_ id: Int, severity: String?, status: String?, note: String?) -> BugDetail? {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let now = ISO8601DateFormatter().string(from: .now)
        var changes: [String] = []
        if let severity, severity != rows[i].severity { changes.append("Severity \(rows[i].severity ?? "none") → \(severity)"); rows[i].severity = severity }
        if let status, status != rows[i].status {
            changes.append(status == "open" ? "Sent to the fix runner" : status == "wontfix" ? "Won't fix" : "Kept for John")
            rows[i].status = status
        }
        if !changes.isEmpty { logs[id, default: []].append(BugLogEntry(kind: "change", body: changes.joined(separator: " · "), at: now)) }
        if let note { logs[id, default: []].append(BugLogEntry(kind: "note", body: note, at: now)); rows[i].myNotes += 1 }
        return detail(id)
    }

    func ship(_ platform: String) -> Int {
        var n = 0
        for i in rows.indices where rows[i].waitingToShip.contains(platform) { rows[i].shipped.append(platform); n += 1 }
        return n
    }
}
#endif
