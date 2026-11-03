import Foundation
import Supabase

/* Following someone else's binder, deck or cube (contract/follows-2026-10-25.md). The server groups changes into
   updates (quiet 30 minutes, at most one every 6 hours) and pushes them; this keeps the Following list, each item's
   follow state and its Changes. Rules shared with web and Android in testdata/follows/cases.json. */

struct FollowUpdateSummary: Codable, Hashable, Sendable {
    let at: String
    let added: Int
    let removed: Int
}

/// follow_get / follow_set.
struct FollowState: Codable, Hashable, Sendable {
    var following = false
    var push = true
    var unseen = 0
    var lastUpdate: FollowUpdateSummary?
}

/// One row of follows_list. Unavailable rows carry only kind, id, push and followed_at.
struct Follow: Codable, Hashable, Identifiable, Sendable {
    struct Owner: Codable, Hashable, Sendable { let displayName: String; var avatarUrl: String? }
    let kind: String
    let id: String
    let available: Bool
    var push: Bool
    let followedAt: String
    var unseen: Int
    var name: String?
    var format: String?
    var forTrade: Bool?
    var cards: Int?
    var owner: Owner?
    /// Reaches you on their profile: open it there.
    var userId: String?
    /// Reaches you through the link you followed with: open the link.
    var token: String?
    /// The printing its tile shows: the owner's hero, else its first card by copies (nil when it holds nothing).
    var art: String?
    var lastUpdate: FollowUpdateSummary?

    var title: String { available ? name ?? "Untitled" : "A \(kind) you followed" }
    var kindLabel: String { ["binder": "Binder", "deck": "Deck", "cube": "Cube"][kind] ?? kind.capitalized }
    var subtitle: String { [kindLabel, owner?.displayName].compactMap { $0 }.joined(separator: " · ") }
}

/// One card in an update: `qty` > 0 added, < 0 taken out. `board` is the deck section (cubes "main", binders nil).
struct FollowCard: Hashable, Sendable {
    let cardId: String
    let board: String?
    let qty: Int
}

struct FollowUpdate: Decodable, Hashable, Identifiable, Sendable {
    let at: String
    let added: Int
    let removed: Int
    let cards: [FollowCard]
    var id: String { at }

    enum Keys: String, CodingKey { case at, added, removed, cards }

    init(at: String, added: Int, removed: Int, cards: [FollowCard]) {
        self.at = at; self.added = added; self.removed = removed; self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        at = try c.decode(String.self, forKey: .at)
        added = try c.decode(Int.self, forKey: .added)
        removed = try c.decode(Int.self, forKey: .removed)
        var rows = try c.nestedUnkeyedContainer(forKey: .cards)
        var out: [FollowCard] = []
        while !rows.isAtEnd {
            var r = try rows.nestedUnkeyedContainer()
            let id = try r.decode(String.self)
            let board = try r.decodeNil() ? nil : try r.decode(String.self)
            out.append(FollowCard(cardId: id, board: board, qty: try r.decode(Int.self)))
        }
        cards = out
    }
}

struct FollowChanges: Decodable, Sendable {
    let kind: String
    let id: String
    var name: String?
    let updates: [FollowUpdate]
}

enum Follows {
    static let minus = "\u{2212}"

    /// "just now" · "N min ago" · "N h ago" · "N d ago" (under 30 days) · "N mo ago".
    static func ago(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        let d = s / 86400
        return d < 30 ? "\(d) d ago" : "\(d / 30) mo ago"
    }

    /// "+12 −8", "+3", "−2".
    static func change(added: Int, removed: Int) -> String {
        [added > 0 ? "+\(added)" : nil, removed > 0 ? "\(minus)\(removed)" : nil].compactMap { $0 }.joined(separator: " ")
    }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func since(_ u: FollowUpdateSummary, now: Date) -> String {
        "\(change(added: u.added, removed: u.removed)) · \(ago(now.timeIntervalSince(date(u.at) ?? now)))"
    }

    /// A Following row's detail line.
    static func detail(_ f: Follow, now: Date) -> String {
        guard f.available else { return "This isn't available" }
        let line = f.lastUpdate.map { since($0, now: now) } ?? "No changes yet"
        return f.push ? line : "\(line) · pushes off"
    }

    /// The Library home row: "3 followed · 1 updated".
    static func home(_ items: [Follow]) -> String {
        let updated = items.filter { $0.available && $0.unseen > 0 }.count
        return "\(items.count) followed" + (updated > 0 ? " · \(updated) updated" : "")
    }

    /// An update's cards as Added and Taken out, biggest first, then by card id (`qty` positive in both).
    static func sections(_ cards: [FollowCard]) -> (added: [FollowCard], removed: [FollowCard]) {
        func sorted(_ x: [FollowCard]) -> [FollowCard] {
            x.sorted { ($1.qty, $0.cardId, $0.board ?? "") < ($0.qty, $1.cardId, $1.board ?? "") }
        }
        return (sorted(cards.filter { $0.qty > 0 }),
                sorted(cards.filter { $0.qty < 0 }.map { FollowCard(cardId: $0.cardId, board: $0.board, qty: -$0.qty) }))
    }
}

@MainActor
@Observable
final class FollowsStore {
    static let shared = FollowsStore()
    private(set) var items: [Follow]?
    /// follow_get answers by item id, kept so the Follow row shows at once on a second visit.
    private(set) var states: [String: FollowState] = [:]
    var error: String?
    #if DEBUG
    @ObservationIgnored var demo: FollowsDemo?
    #endif

    var isDemo: Bool {
        #if DEBUG
        demo != nil
        #else
        false
        #endif
    }

    /// The demo account's own profile is "me" without a signed-in id.
    func isMe(_ userId: String) -> Bool {
        #if DEBUG
        if demo != nil { return userId == FriendsDemoBackend.me }
        #endif
        return false
    }

    func stop() {
        items = nil
        states = [:]
        error = nil
    }

    func load() async {
        do {
            #if DEBUG
            if let demo { items = demo.list(); return }
            #endif
            struct List: Decodable { let items: [Follow] }
            let r: List = try await supabase.rpc("follows_list").execute().value
            items = r.items
            error = nil
        } catch where !error.isCancellation {
            self.error = error.localizedDescription
        } catch {}
    }

    func state(kind: String, id: String) async {
        do {
            #if DEBUG
            if let demo { states[id] = demo.state(id); return }
            #endif
            states[id] = try await supabase.rpc("follow_get", params: ["p_kind": AnyJSON.string(kind), "p_id": .string(id)]).execute().value
        } catch where !error.isCancellation {
            self.error = FriendsStore.message(error)
        } catch {}
    }

    /// Follow / unfollow, or pushes on / off (`push` nil keeps it). `token`: the link being looked through.
    func set(kind: String, id: String, follow: Bool, push: Bool? = nil, token: String? = nil, from: String) async throws {
        let s: FollowState
        #if DEBUG
        if let demo { s = demo.set(kind: kind, id: id, follow: follow, push: push) } else { s = try await remoteSet(kind, id, follow, push, token) }
        #else
        s = try await remoteSet(kind, id, follow, push, token)
        #endif
        states[id] = s
        Telemetry.capture("follow_changed", ["kind": kind, "following": s.following, "push": s.push, "from": from])
        await load()
    }

    private func remoteSet(_ kind: String, _ id: String, _ follow: Bool, _ push: Bool?, _ token: String?) async throws -> FollowState {
        try await supabase.rpc("follow_set", params: [
            "p_kind": AnyJSON.string(kind), "p_id": .string(id), "p_follow": .bool(follow),
            "p_push": push.map { .bool($0) } ?? .null, "p_token": token.map { .string($0) } ?? .null,
        ]).execute().value
    }

    /// The updates since you followed; opening them marks them seen.
    func changes(kind: String, id: String) async throws -> FollowChanges {
        let c: FollowChanges
        #if DEBUG
        if let demo { c = try demo.changes(id) } else { c = try await remoteChanges(kind, id) }
        #else
        c = try await remoteChanges(kind, id)
        #endif
        states[id]?.unseen = 0
        if let i = items?.firstIndex(where: { $0.id == id }) { items?[i].unseen = 0 }
        Telemetry.capture("follow_changes_viewed", ["kind": kind, "updates": c.updates.count])
        return c
    }

    private func remoteChanges(_ kind: String, _ id: String) async throws -> FollowChanges {
        try await supabase.rpc("follow_changes", params: ["p_kind": AnyJSON.string(kind), "p_id": .string(id)]).execute().value
    }

    /// Where a followed item opens: its profile section, or the link it was followed through.
    static func route(_ f: Follow) -> SocialRoute? {
        guard f.available else { return nil }
        if let token = f.token { return .sharedLink(token) }
        guard let userId = f.userId else { return nil }
        return .profileCards(userId, f.kind, f.id, f.title, f.kind == "binder" ? nil : SharedList(format: f.format ?? "", owner: f.owner?.displayName))
    }
}

#if DEBUG
/// Following on demo data (`-T1LibraryDemo following|followchanges|followdeck`): Mara's deck with two updates (one
/// unseen), her trade binder with none, and one item that's no longer shared. Updates are made from the demo deck's
/// own cards, so names and art come from the catalog.
@MainActor
final class FollowsDemo {
    private var follows: [String: Follow] = [:]
    private var updates: [String: [FollowUpdate]] = [:]
    nonisolated static let deck = "d0000000-0000-0000-0000-0000000fd001", binder = "d0000000-0000-0000-0000-0000000fb001"

    init() {
        let iso = ISO8601DateFormatter()
        func at(_ hoursAgo: Double) -> String { iso.string(from: Date().addingTimeInterval(-hoursAgo * 3600)) }
        let entries = ListsStore.shared.lists.first { $0.kind == .deck }?.entries ?? []
        let main = entries.filter { $0.board == "main" }, side = entries.filter { $0.board == "side" }
        var recent: [FollowCard] = main.prefix(2).map { FollowCard(cardId: $0.cardId, board: "main", qty: 2) }
        recent += side.prefix(1).map { FollowCard(cardId: $0.cardId, board: "side", qty: 1) }
        recent += main.dropFirst(2).prefix(2).map { FollowCard(cardId: $0.cardId, board: "main", qty: -1) }
        let older = side.dropFirst().prefix(2).map { FollowCard(cardId: $0.cardId, board: "side", qty: -1) }
        func update(_ h: Double, _ cards: [FollowCard]) -> FollowUpdate {
            FollowUpdate(at: at(h), added: cards.filter { $0.qty > 0 }.reduce(0) { $0 + $1.qty },
                         removed: cards.filter { $0.qty < 0 }.reduce(0) { $0 - $1.qty }, cards: cards)
        }
        updates[Self.deck] = [update(2, recent), update(50, older)].filter { !$0.cards.isEmpty }
        let mara = Follow.Owner(displayName: "Mara Quinn")
        let last = updates[Self.deck]?.first.map { FollowUpdateSummary(at: $0.at, added: $0.added, removed: $0.removed) }
        follows[Self.deck] = Follow(kind: "deck", id: Self.deck, available: true, push: true, followedAt: at(200), unseen: last == nil ? 0 : 1,
                                    name: "Mono-red prowess", format: ListsStore.shared.lists.first { $0.kind == .deck }?.format ?? "modern",
                                    cards: entries.filter { $0.board != "maybe" }.reduce(0) { $0 + $1.qty }, owner: mara,
                                    userId: FriendsDemoBackend.mara, art: main.max { $0.qty < $1.qty }?.cardId, lastUpdate: last)
        follows[Self.binder] = Follow(kind: "binder", id: Self.binder, available: true, push: false, followedAt: at(30), unseen: 0,
                                      name: "Trade binder", forTrade: true, cards: 12, owner: mara, userId: FriendsDemoBackend.mara)
        let gone = "d0000000-0000-0000-0000-0000000fc009"
        follows[gone] = Follow(kind: "cube", id: gone, available: false, push: true, followedAt: at(400), unseen: 0)
    }

    func list() -> [Follow] {
        follows.values.sorted {
            ($0.unseen > 0 ? 0 : 1, -(Follows.date($0.lastUpdate?.at ?? "")?.timeIntervalSince1970 ?? 0), $0.name ?? "~", $0.id)
                < ($1.unseen > 0 ? 0 : 1, -(Follows.date($1.lastUpdate?.at ?? "")?.timeIntervalSince1970 ?? 0), $1.name ?? "~", $1.id)
        }
    }

    func state(_ id: String) -> FollowState {
        guard let f = follows[id] else { return FollowState() }
        return FollowState(following: true, push: f.push, unseen: f.unseen, lastUpdate: f.lastUpdate)
    }

    func set(kind: String, id: String, follow: Bool, push: Bool?) -> FollowState {
        if !follow { follows[id] = nil; return FollowState() }
        if var f = follows[id] {
            f.push = push ?? f.push
            follows[id] = f
        } else {
            follows[id] = Follow(kind: kind, id: id, available: true, push: push ?? true, followedAt: ISO8601DateFormatter().string(from: Date()),
                                 unseen: 0, owner: .init(displayName: "Mara Quinn"), userId: FriendsDemoBackend.mara)
        }
        return state(id)
    }

    func changes(_ id: String) throws -> FollowChanges {
        guard let f = follows[id], f.available else { throw FriendsDemoBackend.Unavailable() }
        follows[id]?.unseen = 0
        return FollowChanges(kind: f.kind, id: id, name: f.name, updates: updates[id] ?? [])
    }
}
#endif
