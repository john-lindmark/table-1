import Foundation
import Supabase

/* Moderation (contract/moderation-2026-10-18.md): what Table 1 changed on your content and why, with one appeal per
   change; and, for moderators, the review queue. The server decides everything; this store only shows it and sends
   answers back. */

struct ModerationMe: Decodable, Sendable {
    var moderator: Bool
    var unseen: Int
    var restrictedUntil: String?
}

struct ModerationNotice: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let subjectKind: String
    let label: String
    let action: String
    var category: String?
    let reasonText: String
    let at: String
    var seen: Bool
    /// none / open / upheld / reverted
    var appeal: String
    var canAppeal: Bool

    /// "Stopped sharing it" / "Changed it to a neutral name" …
    var whatChanged: String {
        switch action {
        case "reset_name": "Changed to a neutral name"
        case "clear_handle": "Removed"
        case "remove_avatar": "Removed"
        case "unshare": "No longer shared"
        case "rename_event": "Renamed with the event code"
        case "rename_guest": "Renamed by seat"
        case "hide_photo": "Hidden from other players"
        case "clear_note": "Cleared"
        default: "Changed"
        }
    }
}

struct ReviewCheck: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let subjectKind: String
    var text: String?
    var bucket: String?
    var path: String?
    let status: String
    var category: String?
    var reason: String?
    let source: String
    let enforced: Bool
    var owner: Person?
    var strikes: Int
    var reports: Int
}

struct ReviewAppeal: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let label: String
    let action: String
    var category: String?
    var note: String?
    var owner: Person?
    var text: String?
    var path: String?
    var bucket: String?
}

struct FlaggedAccount: Decodable, Identifiable, Hashable, Sendable {
    let userId: String
    let displayName: String
    var handle: String?
    var strikes: Int
    var reporters: Int
    var restrictedUntil: String?
    var id: String { userId }
}

struct ReviewQueue: Decodable, Sendable {
    var mode: String
    var checks: [ReviewCheck]
    var appeals: [ReviewAppeal]
    var flagged: [FlaggedAccount]
    var waiting: Int { checks.count + appeals.count + flagged.count }
}

enum ModerationWords {
    static func subject(_ kind: String) -> String {
        switch kind {
        case "display_name": "Display name"
        case "handle": "Handle"
        case "avatar": "Profile photo"
        case "list_name": "Deck or cube name"
        case "binder_name": "Binder name"
        case "event_name": "Event name"
        case "guest_name": "Guest name"
        case "deck_photo": "Deck photo"
        case "deck_photo_note": "Deck photo note"
        default: kind
        }
    }

    static func category(_ c: String?) -> String {
        switch c ?? "" {
        case "hate": "Hate"
        case "harassment": "Harassment"
        case "sexual": "Sexual"
        case "child_safety": "Child safety"
        case "violence": "Violence"
        case "self_harm": "Self-harm"
        case "spam": "Spam"
        case "personal_info": "Personal info"
        case "impersonation": "Impersonation"
        case "": "Unclear"
        default: "Other"
        }
    }

    static func date(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return d?.formatted(date: .abbreviated, time: .omitted)
    }
}

@MainActor
@Observable
final class ModerationStore {
    static let shared = ModerationStore()
    private(set) var me: ModerationMe?
    private(set) var notices: [ModerationNotice]?
    private(set) var queue: ReviewQueue?
    var error: String?
    #if DEBUG
    @ObservationIgnored var demo: ModerationDemo?
    #endif

    func stop() {
        me = nil
        notices = nil
        queue = nil
        error = nil
    }

    func loadMe() async {
        #if DEBUG
        if let demo { me = demo.me; return }
        #endif
        me = try? await supabase.rpc("moderation_me").execute().value
    }

    func loadNotices() async {
        do {
            #if DEBUG
            if let demo { notices = demo.notices; return }
            #endif
            notices = try await supabase.rpc("moderation_notices").execute().value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markSeen() async {
        guard (me?.unseen ?? 0) > 0 || notices?.contains(where: { !$0.seen }) == true else { return }
        #if DEBUG
        if let demo { demo.markSeen(); me = demo.me; notices = demo.notices; return }
        #endif
        try? await supabase.rpc("moderation_notices_seen").execute()
        await loadMe()
    }

    func appeal(_ id: Int, note: String) async throws {
        let trimmed = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        #if DEBUG
        if let demo { demo.appeal(id); await loadNotices(); Telemetry.capture("moderation_appealed"); return }
        #endif
        try await supabase.rpc("moderation_appeal", params: [
            "p_action_id": AnyJSON.integer(id), "p_note": trimmed.isEmpty ? .null : .string(trimmed),
        ]).execute()
        Telemetry.capture("moderation_appealed")
        await loadNotices()
    }

    // moderators

    func loadQueue() async {
        do {
            #if DEBUG
            if let demo { queue = demo.queue; return }
            #endif
            queue = try await supabase.rpc("moderation_queue", params: ["p_limit": AnyJSON.integer(100)]).execute().value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// allow / block a check.
    func resolve(_ check: ReviewCheck, _ decision: String) async throws {
        #if DEBUG
        if let demo { demo.resolve(check.id); await loadQueue(); return }
        #endif
        try await supabase.rpc("moderation_resolve", params: [
            "p_check_id": AnyJSON.integer(check.id), "p_decision": .string(decision),
        ]).execute()
        Telemetry.capture("moderation_resolved", ["decision": decision, "subject": check.subjectKind])
        await loadQueue()
    }

    private struct AppealResolved: Decodable { let deletePath: String? }

    /// uphold / revert an appeal; an upheld profile photo is then deleted from storage.
    func resolveAppeal(_ appeal: ReviewAppeal, _ decision: String) async throws {
        #if DEBUG
        if let demo { demo.resolveAppeal(appeal.id); await loadQueue(); return }
        #endif
        let r: AppealResolved = try await supabase.rpc("moderation_appeal_resolve", params: [
            "p_action_id": AnyJSON.integer(appeal.id), "p_decision": .string(decision),
        ]).execute().value
        if let path = r.deletePath {
            let _: Bool? = try? await supabase.functions.invoke("moderate", options: FunctionInvokeOptions(body: ["purge": path])) { _, _ in true }
        }
        Telemetry.capture("moderation_resolved", ["decision": decision, "subject": "appeal"])
        await loadQueue()
    }

    func restrict(_ userId: String, days: Int, reason: String) async throws {
        #if DEBUG
        if let demo { demo.restrict(userId, days: days); await loadQueue(); return }
        #endif
        try await supabase.rpc("moderation_restrict", params: [
            "p_user_id": AnyJSON.string(userId), "p_days": .integer(days), "p_reason": reason.isEmpty ? .null : .string(reason),
        ]).execute()
        Telemetry.capture("moderation_resolved", ["decision": days == 0 ? "lift" : "restrict", "subject": "account"])
        await loadQueue()
    }

    func setMode(_ mode: String) async throws {
        #if DEBUG
        if let demo { demo.queue.mode = mode; await loadQueue(); return }
        #endif
        try await supabase.rpc("moderation_set_mode", params: ["p_mode": AnyJSON.string(mode)]).execute()
        await loadQueue()
    }

    private struct Signed: Decodable { let urls: [String: String] }

    /// Short-lived links to the photos under review (the `moderate` function signs them for moderators).
    func photoURLs(_ items: [(bucket: String, path: String)]) async -> [String: URL] {
        guard !items.isEmpty else { return [:] }
        #if DEBUG
        if demo != nil { return [:] }
        #endif
        let body: [String: [[String: String]]] = ["sign": items.map { ["bucket": $0.bucket, "path": $0.path] }]
        guard let r: Signed = try? await supabase.functions.invoke("moderate", options: FunctionInvokeOptions(body: body), decode: { data, _ in
            try JSONDecoder().decode(Signed.self, from: data)
        }) else { return [:] }
        return r.urls.compactMapValues(URL.init(string:))
    }
}

#if DEBUG
/// Moderation on demo data (`-T1LibraryDemo notices|review`): two notices (one appealable) and a review queue with a
/// held name, a report, an appeal and a flagged account.
@MainActor
final class ModerationDemo {
    var me = ModerationMe(moderator: true, unseen: 2)
    var notices: [ModerationNotice] = [
        ModerationNotice(id: 2, subjectKind: "list_name", label: "Deck Slur Burn", action: "unshare", category: "hate",
                         reasonText: "It looks like hate speech.", at: "2026-10-18T19:02:00Z", seen: false, appeal: "none", canAppeal: true),
        ModerationNotice(id: 1, subjectKind: "deck_photo_note", label: "Your deck photo note", action: "clear_note", category: "personal_info",
                         reasonText: "It shares personal contact details.", at: "2026-10-12T21:40:00Z", seen: false, appeal: "reverted", canAppeal: false),
    ]
    var queue = ReviewQueue(mode: "shadow", checks: [
        ReviewCheck(id: 31, subjectKind: "display_name", text: "Table 1 Admin", status: "block", category: "impersonation",
                    reason: "Poses as Table 1 staff", source: "write", enforced: false,
                    owner: Person(userId: FriendsDemoBackend.kai, displayName: "Table 1 Admin"), strikes: 0, reports: 0),
        ReviewCheck(id: 32, subjectKind: "list_name", text: "Hymn to Tourach Pox", status: "review", category: "other",
                    reason: "Card name; probably fine", source: "report", enforced: false,
                    owner: Person(userId: FriendsDemoBackend.ines, displayName: "Ines Ruiz"), strikes: 0, reports: 1),
    ], appeals: [
        ReviewAppeal(id: 7, label: "Deck Mono-Black Suicide", action: "unshare", category: "self_harm",
                     note: "Suicide is the archetype name (Suicide Black).", owner: Person(userId: FriendsDemoBackend.theo, displayName: "Theo Vance"),
                     text: "Mono-Black Suicide"),
    ], flagged: [
        FlaggedAccount(userId: FriendsDemoBackend.lee, displayName: "Lee Park", strikes: 1, reporters: 3),
    ])

    func markSeen() {
        me.unseen = 0
        for i in notices.indices { notices[i].seen = true }
    }

    func appeal(_ id: Int) {
        if let i = notices.firstIndex(where: { $0.id == id }) { notices[i].appeal = "open"; notices[i].canAppeal = false }
    }

    func resolve(_ id: Int) { queue.checks.removeAll { $0.id == id } }
    func resolveAppeal(_ id: Int) { queue.appeals.removeAll { $0.id == id } }

    func restrict(_ userId: String, days: Int) {
        if let i = queue.flagged.firstIndex(where: { $0.userId == userId }) {
            queue.flagged[i].restrictedUntil = days == 0 ? nil : ISO8601DateFormatter().string(from: .now.addingTimeInterval(Double(days) * 86400))
        }
    }
}
#endif
