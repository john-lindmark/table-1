import Foundation
import Supabase

/* Friends, public profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md). Friendships are
   mutual; every part of the Library is private until its owner shares it (Account → Sharing). The server checks
   who may see what on every read, so this store only holds what came back. Trade matches put your wants next to
   friends' for-trade copies (and theirs next to yours) in trade_confirm's order. */

enum Visibility: String, Codable, CaseIterable, Sendable {
    case `private`, friends, `public`

    var label: String {
        switch self {
        case .private: "Private"
        case .friends: "Friends"
        case .public: "Public"
        }
    }

    /// What it asks of a viewer (the server's vis_ok): public 0, friends 1, private 3 (only you).
    var asks: Int {
        switch self {
        case .public: 0
        case .friends: 1
        case .private: 3
        }
    }
}

/// How you stand with an account. `requested`: you asked (a declined request still reads requested).
enum Relation: String, Codable, Sendable {
    case me = "self", friend, requested, incoming, blocked, none

    init(from decoder: Decoder) throws {
        self = Relation(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .none
    }
}

struct Person: Codable, Hashable, Identifiable, Sendable {
    let userId: String
    var displayName: String
    var handle: String?
    var avatarUrl: String?
    /// Friends: since when. Requests: when it was sent.
    var since: String?
    var at: String?
    /// Search rows only.
    var sharedEvents: Int?
    var relation: Relation?
    var id: String { userId }
    var label: String { displayName }
}

/// A request you sent: to an account (asked by id: a Person) or to an address (asked by email: `{email, at}`, no
/// user_id, account or not, so the server never says whose it is). Older servers sent email asks as a Person.
struct SentRequest: Codable, Hashable, Identifiable, Sendable {
    var person: Person?
    var email: String?
    var at: String?
    var id: String { person?.userId ?? "email:\(email ?? "")" }
    var label: String { person?.displayName ?? email ?? "" }

    init(person: Person) { self.person = person; at = person.at }
    init(email: String, at: String? = nil) { self.email = email; self.at = at }

    private enum Keys: String, CodingKey { case userId, email, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        at = try c.decodeIfPresent(String.self, forKey: .at)
        if c.contains(.userId), (try? c.decodeNil(forKey: .userId)) == false {
            person = try Person(from: decoder)
        } else {
            email = try c.decodeIfPresent(String.self, forKey: .email)
        }
    }

    func encode(to encoder: Encoder) throws {
        if let person { try person.encode(to: encoder); return }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(at, forKey: .at)
    }
}

struct FriendsList: Codable, Equatable, Sendable {
    var friends: [Person] = []
    var incoming: [Person] = []
    var outgoing: [SentRequest] = []
    var blocked: [Person] = []
}

// MARK: sharing

/// The parts of an account the owner shares. Children are `null` = "Same as Library".
enum SharePart: String, CaseIterable, Sendable {
    case profile, library, allCards = "all_cards", forTrade = "for_trade", wants, binders, decks, cubes, record

    var label: String {
        switch self {
        case .profile: "Profile"
        case .library: "Library"
        case .allCards: "All cards"
        case .forTrade: "For trade"
        case .wants: "Wants"
        case .binders: "Binders"
        case .decks: "Decks"
        case .cubes: "Cubes"
        case .record: "Record"
        }
    }

    var detail: String {
        switch self {
        case .profile: "Who can open your profile at all"
        case .library: "The default for everything in it"
        case .allCards: "Your whole collection"
        case .forTrade: "Copies in for-trade binders, as one list. Trade matches read this"
        case .wants: "Your wishlist, without max prices"
        case .binders: "The default for each binder"
        case .decks: "The default for each deck"
        case .cubes: "The default for each cube"
        case .record: "Lifetime wins, losses and draws"
        }
    }

    /// Library parts can be "Same as Library".
    var inherits: Bool { ![.profile, .library, .record].contains(self) }
    static let libraryParts: [SharePart] = [.allCards, .forTrade, .wants, .binders, .decks, .cubes]
}

struct ShareItem: Codable, Hashable, Identifiable, Sendable {
    /// binder / deck / cube
    let kind: String
    let id: String
    var name: String
    var forTrade: Bool?
    var visibility: Visibility?
    var group: SharePart { kind == "binder" ? .binders : kind == "cube" ? .cubes : .decks }
}

struct SharingSettings: Codable, Equatable, Sendable {
    var profile: Visibility = .friends
    var library: Visibility = .private
    var allCards: Visibility?
    var forTrade: Visibility?
    var wants: Visibility?
    var binders: Visibility?
    var decks: Visibility?
    var cubes: Visibility?
    var record: Visibility = .private
    var items: [ShareItem] = []

    /// A part's own setting (nil = same as the level above).
    func own(_ p: SharePart) -> Visibility? {
        switch p {
        case .profile: profile
        case .library: library
        case .allCards: allCards
        case .forTrade: forTrade
        case .wants: wants
        case .binders: binders
        case .decks: decks
        case .cubes: cubes
        case .record: record
        }
    }

    mutating func set(_ p: SharePart, _ v: Visibility?) {
        switch p {
        case .profile: profile = v ?? .friends
        case .library: library = v ?? .private
        case .allCards: allCards = v
        case .forTrade: forTrade = v
        case .wants: wants = v
        case .binders: binders = v
        case .decks: decks = v
        case .cubes: cubes = v
        case .record: record = v ?? .private
        }
    }
}

enum SharingRules {
    /// What a part is set to after following "Same as …" up the tree.
    static func effective(_ s: SharingSettings, _ p: SharePart) -> Visibility {
        s.own(p) ?? (p.inherits ? s.library : .private)
    }

    static func effective(_ s: SharingSettings, _ item: ShareItem) -> Visibility {
        item.visibility ?? effective(s, item.group)
    }

    /// Who it actually reaches: the profile caps every part (a public deck on a friends-only profile shows to friends).
    static func reach(_ s: SharingSettings, _ v: Visibility) -> Visibility {
        s.profile.asks >= v.asks ? s.profile : v
    }

    /// The part is set wider than the profile lets it go.
    static func capped(_ s: SharingSettings, _ v: Visibility) -> Bool { s.profile.asks > v.asks }

    /// The server's check: a viewer at `level` (3 you, 1 friend, 0 any other account, -1 blocked) sees it.
    static func sees(level: Int, profile: Visibility, part: Visibility) -> Bool {
        level >= 3 || (level >= 0 && level >= profile.asks && level >= part.asks)
    }

    /// How many parts, binders, decks and cubes reach someone besides you.
    static func sharedCount(_ s: SharingSettings) -> Int {
        let parts = (SharePart.libraryParts + [.record]).filter { reach(s, effective(s, $0)) != .private }.count
        let items = s.items.filter { $0.visibility != nil && reach(s, effective(s, $0)) != .private }.count
        return parts + items
    }

    /// The Account row: "Friends · 3 parts shared" / "Private · nothing shared".
    static func summary(_ s: SharingSettings) -> String {
        let n = sharedCount(s)
        return "Profile \(s.profile.label.lowercased()) · " + (n == 0 ? "nothing shared" : "\(n) shared")
    }

    /// p_settings for one change.
    static func change(_ p: SharePart, _ v: Visibility?) -> AnyJSON {
        .object([p.rawValue: v.map { .string($0.rawValue) } ?? .null])
    }

    static func change(_ item: ShareItem, _ v: Visibility?) -> AnyJSON {
        .object(["items": .array([.object(["kind": .string(item.kind), "id": .string(item.id),
                                           "visibility": v.map { .string($0.rawValue) } ?? .null])])])
    }
}

// MARK: profiles

struct ProfileData: Decodable, Sendable {
    let userId: String
    let displayName: String
    let handle: String?
    let avatarUrl: String?
    var relation: Relation
    let friendsSince: String?
    let visible: Bool
    let sections: Sections

    struct Counts: Decodable, Sendable { let cards: Int; var printings: Int?; var valueUsd: Double? }
    struct BinderSummary: Decodable, Identifiable, Sendable { let id: String; let name: String; let forTrade: Bool; let cards: Int }
    struct ListSummary: Decodable, Identifiable, Sendable { let id: String; let name: String; let format: String; let cards: Int }
    struct Record: Decodable, Sendable { let matchWins: Int; let matchLosses: Int; let matchDraws: Int; let eventsPlayed: Int }
    struct Sections: Decodable, Sendable {
        var allCards: Counts?
        var forTrade: Counts?
        var wants: Counts?
        var binders: [BinderSummary]?
        var decks: [ListSummary]?
        var cubes: [ListSummary]?
        var record: Record?
    }

    var person: Person { Person(userId: userId, displayName: displayName, handle: handle, avatarUrl: avatarUrl, relation: relation) }

    /// The collection's value, on your own profile only (the server sends it only there now; older servers sent it to
    /// anyone who saw All cards).
    var valueUsd: Double? { relation == .me ? sections.allCards?.valueUsd : nil }

    /// Sections that reach you (binders, decks and cubes count one each).
    var sectionCount: Int {
        [sections.allCards != nil, sections.forTrade != nil, sections.wants != nil, sections.record != nil].filter { $0 }.count
            + (sections.binders?.count ?? 0) + (sections.decks?.count ?? 0) + (sections.cubes?.count ?? 0)
    }
}

/// A section behind a profile: `all_cards`, `for_trade`, `wants`, or `binder` / `deck` / `cube` with an id.
struct ProfileSection: Hashable, Sendable {
    let kind: String
    var id: String?
}

/// One row of profile_cards, whatever the section's shape.
struct ProfileCard: Hashable, Sendable {
    var cardId: String?
    var oracleId: String?
    var finish: String?
    var condition: String?
    var lang: String?
    var board: String?
    var qty: Int
}

private struct ProfileCardsPage: Decodable { let rows: [[AnyJSON]]; let more: Bool }

extension ProfileCard {
    /// all_cards [card, finish, qty] · for_trade / binder [card, finish, condition, lang, qty] · deck / cube
    /// [card, board, qty] · wants [oracle, card?, finish?, qty]
    static func parse(_ section: String, _ r: [AnyJSON]) -> ProfileCard? {
        func s(_ i: Int) -> String? { if i < r.count, case .string(let v) = r[i] { v } else { nil } }
        func n(_ i: Int) -> Int? {
            guard i < r.count else { return nil }
            switch r[i] {
            case .integer(let v): return v
            case .double(let v): return Int(v)
            default: return nil
            }
        }
        switch section {
        case "all_cards": return n(2).map { ProfileCard(cardId: s(0), finish: s(1), qty: $0) }
        case "for_trade", "binder": return n(4).map { ProfileCard(cardId: s(0), finish: s(1), condition: s(2), lang: s(3), qty: $0) }
        case "deck", "cube": return n(2).map { ProfileCard(cardId: s(0), board: s(1), qty: $0) }
        case "wants": return n(3).map { ProfileCard(cardId: s(1), oracleId: s(0), finish: s(2), qty: $0) }
        default: return nil
        }
    }
}

// MARK: trade matches

struct WantKey: Codable, Hashable, Sendable {
    let oracleId: String
    var cardId: String?
    var finish: String?
    /// exact / printing / any
    var tier: String { finish != nil ? "exact" : cardId != nil ? "printing" : "any" }
}

struct MatchLine: Codable, Hashable, Identifiable, Sendable {
    let cardId: String
    let finish: String
    let condition: String
    let lang: String
    /// They want: your binder the copies are in.
    var binderId: String?
    let qty: Int
    let want: WantKey
    var usd: Double?
    /// They have: your want has a max and the price is above it.
    var overMax: Bool?
    var id: String { CollectionStore.key(cardId, finish, condition, lang) }
}

struct TradeMatch: Codable, Hashable, Identifiable, Sendable {
    let userId: String
    let displayName: String
    var handle: String?
    var avatarUrl: String?
    let friend: Bool
    var theyHave: [MatchLine]
    var theyWant: [MatchLine]
    var haveCopies: Int
    var wantCopies: Int
    var haveUsd: Double
    var wantUsd: Double
    var id: String { userId }
    var person: Person { Person(userId: userId, displayName: displayName, handle: handle, avatarUrl: avatarUrl) }

    /// The list row: "Has 3 · wants 2".
    var short: String {
        [haveCopies > 0 ? "Has \(haveCopies)" : nil, wantCopies > 0 ? "\(haveCopies > 0 ? "wants" : "Wants") \(wantCopies)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "Has 3 you want · Wants 2 you have"
    var summary: String {
        [haveCopies > 0 ? "Has \(haveCopies) you want" : nil, wantCopies > 0 ? "Wants \(wantCopies) you have" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct MatchesResult: Decodable { let people: [TradeMatch] }

/// The server's matching (t1_private.want_match) on the device, for the Debug demo and the shared test cases in
/// testdata/trade-matches. Per person: wants for that printing and finish take copies first, then wants for that
/// printing in any finish, then wants for any printing; within a want NM first, then cheaper (no price last), then
/// English. A copy is used once; a want up to its qty.
enum TradeMatcher {
    struct WantIn: Sendable {
        let oracleId: String
        var cardId: String?
        var finish: String?
        let qty: Int
        var maxUsd: Double?
        var key: WantKey { WantKey(oracleId: oracleId, cardId: cardId, finish: finish) }
    }

    struct CopyIn: Sendable {
        let oracleId: String
        let cardId: String
        let finish: String
        let condition: String
        let lang: String
        var binderId: String?
        let qty: Int
        var usd: Double?
    }

    static func lines(wants: [WantIn], copies: [CopyIn]) -> [MatchLine] {
        func crank(_ c: String) -> Int { ["NM": 0, "LP": 1, "MP": 2, "HP": 3][c] ?? 4 }
        let order = copies.indices.sorted { a, b in
            let x = copies[a], y = copies[b]
            if crank(x.condition) != crank(y.condition) { return crank(x.condition) < crank(y.condition) }
            switch (x.usd, y.usd) {
            case let (p?, q?) where p != q: return p < q
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if (x.lang == "en") != (y.lang == "en") { return x.lang == "en" }
            return a < b
        }
        var left = copies.map(\.qty)
        // copy index → (qty, tier, want) pieces
        var got: [Int: [(qty: Int, tier: Int, want: WantIn)]] = [:]
        let tiers: [(Int, (WantIn) -> Bool, (WantIn, CopyIn) -> Bool)] = [
            (0, { $0.cardId != nil && $0.finish != nil }, { w, c in c.cardId == w.cardId && c.finish == w.finish }),
            (1, { $0.cardId != nil && $0.finish == nil }, { w, c in c.cardId == w.cardId }),
            (2, { $0.cardId == nil }, { w, c in c.oracleId == w.oracleId }),
        ]
        for (tier, isTier, meets) in tiers {
            for w in wants where w.qty > 0 && isTier(w) {
                var need = w.qty
                for i in order where need > 0 && left[i] > 0 && meets(w, copies[i]) {
                    let n = min(need, left[i])
                    left[i] -= n
                    need -= n
                    got[i, default: []].append((n, tier, w))
                }
            }
        }
        return got.keys.sorted().map { i in
            let c = copies[i], parts = got[i]!
            let first = parts.min { $0.tier < $1.tier }!
            let over = parts.contains { p in p.want.maxUsd.map { m in (c.usd ?? 0) > m && c.usd != nil } ?? false }
            return MatchLine(cardId: c.cardId, finish: c.finish, condition: c.condition, lang: c.lang, binderId: c.binderId,
                             qty: parts.reduce(0) { $0 + $1.qty }, want: first.want.key, usd: c.usd, overMax: over)
        }
        .sorted { ($0.cardId, $0.finish, $0.condition, $0.lang) < ($1.cardId, $1.finish, $1.condition, $1.lang) }
    }

    /// The server's order for showing them: they have, under-max first, dearest first.
    static func shown(_ lines: [MatchLine]) -> [MatchLine] {
        lines.sorted { a, b in
            if (a.overMax ?? false) != (b.overMax ?? false) { return !(a.overMax ?? false) }
            if a.usd != b.usd { return (a.usd ?? -1) > (b.usd ?? -1) }
            return (a.cardId, a.finish) < (b.cardId, b.finish)
        }
    }

    static func value(_ lines: [MatchLine], skipOverMax: Bool) -> Double {
        lines.filter { !(skipOverMax && $0.overMax == true) }.reduce(0) { $0 + Double($1.qty) * ($1.usd ?? 0) }
    }
}

// MARK: store

@MainActor
@Observable
final class FriendsStore {
    static let shared = FriendsStore()
    private(set) var list: FriendsList?
    private(set) var sharing: SharingSettings?
    private(set) var matches: [TradeMatch]?
    var error: String?
    #if DEBUG
    @ObservationIgnored var demo: FriendsDemoBackend?
    #endif

    var requestsWaiting: Int { list?.incoming.count ?? 0 }

    func stop() {
        list = nil
        sharing = nil
        matches = nil
        error = nil
    }

    func load() async {
        do {
            #if DEBUG
            if let demo { list = demo.list; return }
            #endif
            list = try await supabase.rpc("friends_list").execute().value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Played-with suggestions (empty query) or a search that also finds public profiles.
    func search(_ query: String) async throws -> [Person] {
        #if DEBUG
        if let demo { return demo.search(query) }
        #endif
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await supabase.rpc("friend_search", params: [
            "p_query": q.isEmpty ? AnyJSON.null : .string(q), "p_limit": .integer(30),
        ]).execute().value
    }

    private struct Status: Decodable { let status: String?; let removed: Bool?; let blocked: Bool? }

    /// Asks them (or accepts, if they asked you). `via`: search / played_with / email / profile.
    @discardableResult
    func request(_ userId: String, via: String) async throws -> String {
        let status: String
        #if DEBUG
        if let demo { status = demo.request(userId) } else { status = try await remoteRequest(userId) }
        #else
        status = try await remoteRequest(userId)
        #endif
        Telemetry.capture("friend_request_sent", ["via": via])
        await load()
        return status
    }

    private func remoteRequest(_ userId: String) async throws -> String {
        let r: Status = try await supabase.rpc("friend_request", params: ["p_user_id": AnyJSON.string(userId)]).execute().value
        return r.status ?? "requested"
    }

    func requestByEmail(_ email: String) async throws {
        #if DEBUG
        if let demo { demo.requestByEmail(email) } else { try await remoteRequestByEmail(email) }
        #else
        try await remoteRequestByEmail(email)
        #endif
        Telemetry.capture("friend_request_sent", ["via": "email"])
        await load()
    }

    private func remoteRequestByEmail(_ email: String) async throws {
        try await supabase.rpc("friend_request_by_email", params: ["p_email": AnyJSON.string(email)]).execute()
    }

    func respond(_ userId: String, accept: Bool) async throws {
        #if DEBUG
        if let demo { demo.respond(userId, accept: accept) } else { try await remoteRespond(userId, accept) }
        #else
        try await remoteRespond(userId, accept)
        #endif
        Telemetry.capture("friend_request_responded", ["accepted": accept])
        await load()
    }

    private func remoteRespond(_ userId: String, _ accept: Bool) async throws {
        try await supabase.rpc("friend_respond", params: ["p_user_id": AnyJSON.string(userId), "p_accept": .bool(accept)]).execute()
    }

    /// Cancels your request, or unfriends.
    func remove(_ userId: String) async throws {
        let wasFriend = list?.friends.contains { $0.userId == userId } ?? false
        #if DEBUG
        if let demo { demo.remove(userId) } else { try await remoteRemove(userId) }
        #else
        try await remoteRemove(userId)
        #endif
        Telemetry.capture(wasFriend ? "friend_removed" : "friend_request_cancelled")
        await load()
        matches?.removeAll { $0.userId == userId }
    }

    private func remoteRemove(_ userId: String) async throws {
        try await supabase.rpc("friend_remove", params: ["p_user_id": AnyJSON.string(userId)]).execute()
    }

    /// Cancels a request you made by email (an `{email, at}` row in Sent).
    func cancelEmail(_ email: String) async throws {
        #if DEBUG
        if let demo { demo.cancelEmail(email) } else { try await remoteCancelEmail(email) }
        #else
        try await remoteCancelEmail(email)
        #endif
        Telemetry.capture("friend_request_cancelled", ["via": "email"])
        await load()
    }

    private func remoteCancelEmail(_ email: String) async throws {
        try await supabase.rpc("friend_cancel_email", params: ["p_email": AnyJSON.string(email)]).execute()
    }

    /// Cancels a row in Sent, whichever way it was asked.
    func cancel(_ r: SentRequest) async throws {
        if let p = r.person { try await remove(p.userId) } else if let e = r.email { try await cancelEmail(e) }
    }

    func block(_ userId: String, _ on: Bool) async throws {
        #if DEBUG
        if let demo { demo.block(userId, on) } else { try await remoteBlock(userId, on) }
        #else
        try await remoteBlock(userId, on)
        #endif
        Telemetry.capture("user_blocked", ["blocked": on])
        await load()
        if on { matches?.removeAll { $0.userId == userId } }
    }

    private func remoteBlock(_ userId: String, _ on: Bool) async throws {
        try await supabase.rpc("user_block", params: ["p_user_id": AnyJSON.string(userId), "p_blocked": .bool(on)]).execute()
    }

    // sharing

    func loadSharing() async {
        do {
            #if DEBUG
            if let demo { sharing = demo.sharing; return }
            #endif
            sharing = try await supabase.rpc("sharing_get").execute().value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func set(_ part: SharePart, _ v: Visibility?) async {
        guard var s = sharing, s.own(part) != v else { return }
        let before = s
        s.set(part, v)
        sharing = s   // shows at once; put back if the server refuses
        await save(SharingRules.change(part, v), before: before, part: part.rawValue, v)
    }

    func set(_ item: ShareItem, _ v: Visibility?) async {
        guard var s = sharing, let i = s.items.firstIndex(where: { $0.id == item.id }), s.items[i].visibility != v else { return }
        let before = s
        s.items[i].visibility = v
        sharing = s
        await save(SharingRules.change(item, v), before: before, part: item.kind, v)
    }

    private func save(_ change: AnyJSON, before: SharingSettings, part: String, _ v: Visibility?) async {
        do {
            #if DEBUG
            if let demo { demo.sharing = sharing ?? before } else { sharing = try await remoteSharing(change) }
            #else
            sharing = try await remoteSharing(change)
            #endif
            Telemetry.capture("sharing_changed", ["part": part, "visibility": v?.rawValue ?? "inherit"])
            error = nil
        } catch {
            sharing = before
            self.error = error.localizedDescription
        }
    }

    private func remoteSharing(_ change: AnyJSON) async throws -> SharingSettings {
        try await supabase.rpc("sharing_set", params: ["p_settings": change]).execute().value
    }

    // profiles

    func profile(_ userId: String) async throws -> ProfileData {
        #if DEBUG
        if let demo { return try demo.profile(userId) }
        #endif
        return try await supabase.rpc("profile_view", params: ["p_user_id": AnyJSON.string(userId)]).execute().value
    }

    /// Every row of a section, a page of 5000 at a time.
    func cards(_ userId: String, _ section: ProfileSection) async throws -> [ProfileCard] {
        #if DEBUG
        if let demo { return demo.cards(userId, section) }
        #endif
        var out: [ProfileCard] = [], after = 0
        while true {
            let page: ProfileCardsPage = try await supabase.rpc("profile_cards", params: [
                "p_user_id": AnyJSON.string(userId), "p_section": .string(section.kind),
                "p_id": section.id.map { .string($0) } ?? .null, "p_after": .integer(after), "p_limit": .integer(5000),
            ]).execute().value
            out += page.rows.compactMap { ProfileCard.parse(section.kind, $0) }
            after += page.rows.count
            if !page.more || page.rows.isEmpty { return out }
        }
    }

    // matches

    func loadMatches() async {
        do {
            matches = try await fetchMatches(nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func match(with userId: String) async throws -> TradeMatch? {
        let m = try await fetchMatches(userId).first
        if let m, var all = matches {
            if let i = all.firstIndex(where: { $0.userId == userId }) { all[i] = m } else { all.append(m) }
            matches = all
        }
        return m
    }

    private func fetchMatches(_ userId: String?) async throws -> [TradeMatch] {
        #if DEBUG
        if let demo { return await demo.matches(userId) }
        #endif
        let r: MatchesResult = try await supabase.rpc("trade_matches", params: [
            "p_user_id": userId.map { AnyJSON.string($0) } ?? .null,
        ]).execute().value
        return r.people
    }

    private struct Started: Decodable { let id: String }

    /// A trade draft from the match with that person; returns its id (it's in TradesStore once this returns).
    func startTrade(_ m: TradeMatch) async throws -> String {
        let id: String
        #if DEBUG
        if demo != nil {
            func line(_ l: MatchLine) -> TradeLine {
                TradeLine(cardId: l.cardId, finish: l.finish, condition: l.condition, lang: l.lang, qty: l.qty, binderId: l.binderId)
            }
            let t = try await TradesStore.shared.save(nil, partner: m.displayName, gives: m.theyWant.map(line),
                                                      gets: m.theyHave.map { var x = line($0); x.binderId = nil; return x })
            Telemetry.capture("trade_started_from_match", ["gives": m.wantCopies, "gets": m.haveCopies])
            return t.id
        }
        #endif
        let t: Started = try await supabase.rpc("trade_match_start", params: [
            "p_user_id": AnyJSON.string(m.userId), "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
        id = t.id
        await TradesStore.shared.load()
        Telemetry.capture("trade_started_from_match", ["gives": m.wantCopies, "gets": m.haveCopies])
        return id
    }
}
