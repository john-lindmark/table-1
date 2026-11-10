#if DEBUG
import Foundation

/// Friends, profiles, sharing and matches on demo data (Debug only, `-T1LibraryDemo friends|profile|sharing|matches|
/// match|me`). Two friends hold for-trade copies of the demo account's wants and want some of its for-trade copies, so
/// Trade matches has something to show; one player from an event shares For trade publicly. Built once the card
/// data is in; matching runs TradeMatcher, the same rules as the server. Sent holds one request by id and one by
/// email (an address only, as the server shows every email ask).
@MainActor
final class FriendsDemoBackend {
    struct Someone {
        var person: Person
        /// 1 friend, 0 played with (sees only what's public).
        var level: Int
        var profile: Visibility
        var forTrade: Visibility
        var wants: Visibility
        var copies: [TradeMatcher.CopyIn]
        var wanted: [TradeMatcher.WantIn]
        var decks: [ProfileData.ListSummary] = []
        var deckEntries: [String: [CardList.Entry]] = [:]
        var record: ProfileData.Record?
    }

    var list: FriendsList
    var sharing: SharingSettings
    private(set) var people: [String: Someone] = [:]
    /// Played with: suggestions in Add a friend.
    private var playedWith: [Person]

    nonisolated static func id(_ n: Int) -> String { String(format: "d0000000-0000-0000-0000-0000000f%04d", n) }
    nonisolated static let mara = id(1), theo = id(2), ines = id(3), sam = id(4), lee = id(5), kai = id(6)
    /// The demo account itself: Your profile, View as (`-T1LibraryDemo me|myprofile`).
    nonisolated static let me = id(0)

    init() {
        func p(_ id: String, _ name: String, _ handle: String? = nil) -> Person { Person(userId: id, displayName: name, handle: handle) }
        list = FriendsList(friends: [p(Self.mara, "Mara Quinn", "maraq"), p(Self.theo, "Theo Vance")],
                           incoming: [p(Self.sam, "Sam Okafor")], outgoing: [SentRequest(email: "jo.ng@example.com", at: "2026-10-18T09:30:00Z"),
                                                                                .init(person: p(Self.lee, "Lee Park"))])
        playedWith = [Person(userId: Self.ines, displayName: "Ines Ruiz", sharedEvents: 3, relation: Rel.none),
                      Person(userId: Self.kai, displayName: "Kai Brandt", sharedEvents: 2, relation: Rel.none),
                      Person(userId: Self.sam, displayName: "Sam Okafor", sharedEvents: 1, relation: .incoming)]
        sharing = SharingSettings(forTrade: .friends, wants: .friends)
    }

    private typealias Rel = Relation

    /// Fills everyone's cards from the demo collection: what you want, they have; some of what you trade, they want.
    func build(_ db: CatalogDB) {
        guard people.isEmpty else { return }
        let binders = BindersStore.shared
        sharing.items = binders.binders.map { ShareItem(kind: "binder", id: $0.id, name: $0.name, forTrade: $0.forTrade) }
            + ListsStore.shared.lists.map { ShareItem(kind: $0.kind == .cube ? "cube" : "deck", id: $0.id, name: $0.name) }
        let wants = binders.liveWants
        let wantPrintings = db.printings(ids: wants.compactMap(\.cardId))
        let wantOracles = wants.compactMap { db.oracle(id: $0.oracleId) }
        let covers = db.covers(oracleIdxs: wantOracles.map(\.idx))
        func copy(_ cardId: String, _ oracleId: String, _ qty: Int, _ condition: String = "NM") -> TradeMatcher.CopyIn {
            TradeMatcher.CopyIn(oracleId: oracleId, cardId: cardId, finish: "nonfoil", condition: condition, lang: "en", qty: qty,
                                usd: PriceBook.shared.usd(cardId, "nonfoil", condition))
        }
        var maraCopies: [TradeMatcher.CopyIn] = [], theoCopies: [TradeMatcher.CopyIn] = []
        for (i, w) in wants.enumerated() {
            guard let o = db.oracle(id: w.oracleId), let card = w.cardId.flatMap({ wantPrintings[$0] }) ?? covers[o.idx] else { continue }
            if i % 2 == 0 { maraCopies.append(copy(card.cardId, o.oracleId, w.qty + 1)) } else { theoCopies.append(copy(card.cardId, o.oracleId, 1, "LP")) }
        }
        // Their wants: the cards in your for-trade binders (Mara the first two, Ines none, Theo the third).
        let trade = binders.allocs.values.filter { binders.binder($0.binderId)?.forTrade == true }.sorted { $0.key < $1.key }
        let tp = db.printings(ids: trade.map(\.cardId))
        let to = db.oracles(idxs: Array(Set(tp.values.map(\.oracleIdx))))
        let tradeOracles = trade.compactMap { a in tp[a.cardId].flatMap { to[$0.oracleIdx] }?.oracleId }
        let maraWants = tradeOracles.prefix(2).map { TradeMatcher.WantIn(oracleId: $0, qty: 1) }
        let theoWants = tradeOracles.dropFirst(2).prefix(1).map { TradeMatcher.WantIn(oracleId: $0, qty: 2) }
        let deck = ListsStore.shared.lists.first { $0.kind == .deck }
        var mara = Someone(person: list.friends[0], level: 1, profile: .friends, forTrade: .friends, wants: .friends,
                           copies: maraCopies, wanted: maraWants,
                           record: ProfileData.Record(matchWins: 23, matchLosses: 14, matchDraws: 2, eventsPlayed: 11))
        if let deck {
            mara.decks = [ProfileData.ListSummary(id: "d0000000-0000-0000-0000-0000000fd001", name: "Mono-red prowess", format: deck.format,
                                                   cards: deck.entries.filter { $0.board != "maybe" }.reduce(0) { $0 + $1.qty })]
            mara.deckEntries["d0000000-0000-0000-0000-0000000fd001"] = deck.entries
        }
        people[Self.mara] = mara
        people[Self.theo] = Someone(person: list.friends[1], level: 1, profile: .friends, forTrade: .friends, wants: .friends,
                                    copies: theoCopies, wanted: theoWants)
        people[Self.ines] = Someone(person: playedWith[0], level: 0, profile: .public, forTrade: .public, wants: .private,
                                    copies: maraCopies.prefix(1).map { copy($0.cardId, $0.oracleId, 1, "MP") }, wanted: [])
    }

    func search(_ q: String) -> [Person] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        var hits = playedWith
        if t.count >= 2 { hits += [Person(userId: Self.id(7), displayName: "Nadia Stone", handle: "nstone", sharedEvents: 0, relation: Rel.none)] }
        return hits.filter { t.isEmpty || $0.displayName.lowercased().contains(t) || ($0.handle ?? "").lowercased().hasPrefix(t) }
            .map { var p = $0; p.relation = relation($0.userId); return p }
    }

    func relation(_ id: String) -> Relation {
        if list.friends.contains(where: { $0.userId == id }) { return .friend }
        if list.incoming.contains(where: { $0.userId == id }) { return .incoming }
        if list.outgoing.contains(where: { $0.person?.userId == id }) { return .requested }
        if list.blocked.contains(where: { $0.userId == id }) { return .blocked }
        return .none
    }

    private func person(_ id: String) -> Person {
        people[id]?.person ?? (list.incoming + list.outgoing.compactMap(\.person) + list.blocked + playedWith).first { $0.userId == id }
            ?? Person(userId: id, displayName: "Nadia Stone")
    }

    func request(_ id: String) -> String {
        if let i = list.incoming.firstIndex(where: { $0.userId == id }) {
            list.friends.append(list.incoming.remove(at: i))
            return "friends"
        }
        if relation(id) == .friend { return "friends" }
        if relation(id) == .none { list.outgoing.insert(.init(person: person(id)), at: 0) }
        return "requested"
    }

    func respond(_ id: String, accept: Bool) {
        guard let i = list.incoming.firstIndex(where: { $0.userId == id }) else { return }
        let p = list.incoming.remove(at: i)
        if accept { list.friends.append(p) }
    }

    func remove(_ id: String) {
        list.friends.removeAll { $0.userId == id }
        list.outgoing.removeAll { $0.person?.userId == id }
        people[id]?.level = 0
    }

    /// An email ask shows as the address, account or not.
    func requestByEmail(_ email: String) {
        let e = email.lowercased()
        guard !list.outgoing.contains(where: { $0.email == e }) else { return }
        list.outgoing.insert(SentRequest(email: e, at: ISO8601DateFormatter().string(from: Date())), at: 0)
    }

    func cancelEmail(_ email: String) {
        list.outgoing.removeAll { $0.email == email.lowercased() }
    }

    func block(_ id: String, _ on: Bool) {
        if on {
            let p = person(id)
            remove(id)
            list.incoming.removeAll { $0.userId == id }
            list.blocked.insert(p, at: 0)
        } else {
            list.blocked.removeAll { $0.userId == id }
        }
    }

    private func level(_ id: String) -> Int {
        relation(id) == .blocked ? -1 : relation(id) == .friend ? 1 : 0
    }

    func profile(_ id: String) throws -> ProfileData {
        if id == Self.me { return mine() }
        let p = person(id)
        let lv = level(id)
        guard let s = people[id] else {
            return ProfileData(userId: id, displayName: p.displayName, handle: p.handle, avatarUrl: nil, relation: relation(id),
                               friendsSince: nil, visible: false, sections: .init())
        }
        let visible = SharingRules.sees(level: lv, profile: s.profile, part: .public)
        var sec = ProfileData.Sections()
        if visible {
            if SharingRules.sees(level: lv, profile: s.profile, part: s.forTrade) {
                sec.forTrade = .init(cards: s.copies.reduce(0) { $0 + $1.qty })
                sec.binders = [.init(id: "d0000000-0000-0000-0000-0000000fb001", name: "Trade binder", forTrade: true, cards: sec.forTrade!.cards)]
            }
            if SharingRules.sees(level: lv, profile: s.profile, part: s.wants) {
                sec.wants = .init(cards: s.wanted.reduce(0) { $0 + $1.qty })
            }
            if lv >= 1 {
                sec.decks = s.decks
                sec.record = s.record
                // Older servers sent value_usd to everyone who sees All cards: the profile must still hide it.
                if id == Self.mara {
                    sec.allCards = .init(cards: s.copies.reduce(0) { $0 + $1.qty }, printings: s.copies.count,
                                         valueUsd: TradeMatcher.CopyIn.value(s.copies))
                }
            }
            if id == Self.mara, lv >= 1 { sec.friends = .init(mutual: friends(of: id).filter { $0.mutual == true }.count) }
            // Mara's rankings in the rankings demo: a Limited set's and her own cube's.
            if id == Self.mara, lv >= 1 {
                sec.rankings = [
                    .init(id: "d0000000-0000-0000-0000-0000000aa005", name: RankingName.unnamed, sharing: "cube", mine: false, top: 100, ranked: 0,
                          subject: .init(id: "set:FRA", kind: "set", name: "Foundations Remastered", set: "FRA")),
                    .init(id: "d0000000-0000-0000-0000-0000000aa004", name: "Mara's own order", sharing: "cube", mine: false, top: 100, ranked: 0,
                          subject: .init(id: "d0000000-0000-0000-0000-0000000fc001", kind: "list", name: "Mara's Legacy Cube")),
                ]
            }
            sec.decks = sec.decks ?? []
            sec.cubes = []
            sec.binders = sec.binders ?? []
        }
        return ProfileData(userId: id, displayName: p.displayName, handle: p.handle, avatarUrl: nil, relation: relation(id),
                           friendsSince: lv == 1 ? "2026-09-12T19:00:00Z" : nil, visible: visible, sections: sec)
    }

    /// Your own profile as profile_view returns it to you: everything, from the demo Library.
    private func mine() -> ProfileData {
        let col = CollectionStore.shared, b = BindersStore.shared
        var sec = ProfileData.Sections()
        let total = col.items.values.reduce(0) { $0 + $1.qty }
        sec.allCards = .init(cards: total, printings: col.items.count, valueUsd: col.summary?.valueUsd)
        sec.binders = b.binders.map { x in
            ProfileData.BinderSummary(id: x.id, name: x.name, forTrade: x.forTrade, cards: b.items(in: x.id, col.items).reduce(0) { $0 + $1.qty })
        }
        let trade = (sec.binders ?? []).filter(\.forTrade).reduce(0) { $0 + $1.cards }
        if trade > 0 { sec.forTrade = .init(cards: trade) }
        sec.wants = .init(cards: b.liveWants.reduce(0) { $0 + $1.qty })
        func summary(_ l: CardList) -> ProfileData.ListSummary {
            .init(id: l.id, name: l.name, format: l.format, cards: l.entries.filter { $0.board != "maybe" }.reduce(0) { $0 + $1.qty })
        }
        sec.decks = ListsStore.shared.lists.filter { $0.kind == .deck }.map(summary)
        sec.cubes = ListsStore.shared.lists.filter { $0.kind == .cube }.map(summary)
        sec.record = .init(matchWins: 12, matchLosses: 7, matchDraws: 1, eventsPlayed: 5)
        sec.friends = .init(mutual: 0)
        return ProfileData(userId: Self.me, displayName: "You", handle: "demo", avatarUrl: nil, relation: .me,
                           friendsSince: nil, visible: true, sections: sec)
    }

    /// Friends lists: yours (everyone), and Mara's to her friends (Theo is yours too); nobody else shares theirs.
    func friends(of id: String) -> [Person] {
        if id == Self.me { return list.friends.map { var p = $0; p.relation = .friend; p.mutual = false; return p } }
        guard id == Self.mara, level(id) >= 1 else { return [] }
        let rows = [Person(userId: Self.theo, displayName: "Theo Vance"), Person(userId: Self.ines, displayName: "Ines Ruiz"),
                    Person(userId: Self.me, displayName: "You", handle: "demo"),
                    Person(userId: Self.id(7), displayName: "Nadia Stone", handle: "nstone")]
            .map { p -> Person in
                var p = p
                p.relation = p.userId == Self.me ? .me : relation(p.userId)
                p.mutual = p.relation == .friend
                return p
            }
        return rows.filter { $0.mutual == true } + rows.filter { $0.mutual != true }.sorted { $0.displayName < $1.displayName }
    }

    func cards(_ id: String, _ section: ProfileSection) -> [ProfileCard] {
        guard let s = people[id] else { return [] }
        switch section.kind {
        case "all_cards":
            return s.copies.map { ProfileCard(cardId: $0.cardId, finish: $0.finish, qty: $0.qty) }
        case "for_trade", "binder":
            return s.copies.map { ProfileCard(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, qty: $0.qty) }
        case "wants":
            return s.wanted.map { ProfileCard(cardId: $0.cardId, oracleId: $0.oracleId, finish: $0.finish, qty: $0.qty) }
        case "deck":
            return (s.deckEntries[section.id ?? ""] ?? []).map { ProfileCard(cardId: $0.cardId, board: $0.board, qty: $0.qty) }
        default:
            return []
        }
    }

    // share links: your own links show your parts; `maraLink` is Mara's deck, as a stranger would open it.

    nonisolated static let maraLink = "demoMaraPublicDeckLink"
    struct Unavailable: LocalizedError { var errorDescription: String? { "This isn't available." } }

    func shared(_ token: String) throws -> SharedLinkData {
        if token == Self.maraLink, let d = people[Self.mara]?.decks.first {
            return SharedLinkData(part: "deck", id: d.id, name: d.name, format: d.format, cards: d.cards,
                                  owner: .init(displayName: "Mara Quinn"), mine: false)
        }
        guard let l = sharing.links?.first(where: { $0.token == token }) else { throw Unavailable() }
        let sec = mine().sections
        let you = SharedLinkData.Owner(displayName: "You")
        switch l.part {
        case "all_cards": return SharedLinkData(part: l.part, cards: sec.allCards?.cards ?? 0, owner: you, mine: true)
        case "for_trade": return SharedLinkData(part: l.part, cards: sec.forTrade?.cards ?? 0, owner: you, mine: true)
        case "wants": return SharedLinkData(part: l.part, cards: sec.wants?.cards ?? 0, owner: you, mine: true)
        case "binder":
            guard let b = sec.binders?.first(where: { $0.id == l.id }) else { throw Unavailable() }
            return SharedLinkData(part: l.part, id: b.id, name: b.name, forTrade: b.forTrade, cards: b.cards, owner: you, mine: true)
        default:
            guard let d = ((sec.decks ?? []) + (sec.cubes ?? [])).first(where: { $0.id == l.id }) else { throw Unavailable() }
            return SharedLinkData(part: l.part, id: d.id, name: d.name, format: d.format, cards: d.cards, owner: you, mine: true)
        }
    }

    func sharedCards(_ token: String) -> [ProfileCard] {
        if token == Self.maraLink {
            return cards(Self.mara, ProfileSection(kind: "deck", id: people[Self.mara]?.decks.first?.id))
        }
        guard let l = sharing.links?.first(where: { $0.token == token }) else { return [] }
        let col = CollectionStore.shared, b = BindersStore.shared
        switch l.part {
        case "all_cards":
            return col.items.values.map { ProfileCard(cardId: $0.cardId, finish: $0.finish, qty: $0.qty) }
        case "for_trade", "binder":
            let ids = l.part == "binder" ? [l.id ?? ""] : b.binders.filter(\.forTrade).map(\.id)
            return ids.flatMap { b.items(in: $0, col.items) }
                .map { ProfileCard(cardId: $0.item.cardId, finish: $0.item.finish, condition: $0.item.condition, lang: $0.item.lang, qty: $0.qty) }
        case "wants":
            return b.liveWants.map { ProfileCard(cardId: $0.cardId, oracleId: $0.oracleId, finish: $0.finish, qty: $0.qty) }
        default:
            return (ListsStore.shared.list(id: l.id ?? "")?.entries ?? []).map { ProfileCard(cardId: $0.cardId, board: $0.board, qty: $0.qty) }
        }
    }

    /// Your for-trade copies, one per item (in the binder holding most of them).
    private func myCopies(_ db: CatalogDB) -> [TradeMatcher.CopyIn] {
        let b = BindersStore.shared
        let trade = b.allocs.values.filter { b.binder($0.binderId)?.forTrade == true }
        let p = db.printings(ids: Array(Set(trade.map(\.cardId))))
        let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
        return Dictionary(grouping: trade, by: \.itemKey).values.compactMap { allocs in
            let a = allocs.max { $0.qty < $1.qty }!
            guard let oracle = p[a.cardId].flatMap({ o[$0.oracleIdx] }) else { return nil }
            return TradeMatcher.CopyIn(oracleId: oracle.oracleId, cardId: a.cardId, finish: a.finish, condition: a.condition, lang: a.lang,
                                       binderId: a.binderId, qty: allocs.reduce(0) { $0 + $1.qty }, usd: PriceBook.shared.usd(a.cardId, a.finish, a.condition))
        }
        .sorted { $0.cardId < $1.cardId }
    }

    func matches(_ only: String?) async -> [TradeMatch] {
        guard let db = CatalogStore.shared.db else { return [] }
        let mine = BindersStore.shared.liveWants.map {
            TradeMatcher.WantIn(oracleId: $0.oracleId, cardId: $0.cardId, finish: $0.finish, qty: $0.qty, maxUsd: $0.maxUsd)
        }
        let myCopies = myCopies(db)
        return people.values.compactMap { s -> TradeMatch? in
            let lv = level(s.person.userId)
            guard lv >= 0, only == nil || only == s.person.userId else { return nil }
            let seesTrade = SharingRules.sees(level: lv, profile: s.profile, part: s.forTrade)
            let seesWants = SharingRules.sees(level: lv, profile: s.profile, part: s.wants)
            let have: [MatchLine] = TradeMatcher.shown(seesTrade ? TradeMatcher.lines(wants: mine, copies: s.copies.map { var c = $0; c.binderId = nil; return c }) : [])
            let want: [MatchLine] = seesWants ? TradeMatcher.lines(wants: s.wanted.map { var w = $0; w.maxUsd = nil; return w }, copies: myCopies)
                .map { var l = $0; l.overMax = nil; return l } : []
            let hc = have.reduce(0) { $0 + $1.qty }, wc = want.reduce(0) { $0 + $1.qty }
            guard hc + wc > 0 else { return nil }
            return TradeMatch(userId: s.person.userId, displayName: s.person.displayName, handle: s.person.handle, friend: lv == 1,
                              theyHave: have, theyWant: want, haveCopies: hc, wantCopies: wc,
                              haveUsd: TradeMatcher.value(have, skipOverMax: true), wantUsd: TradeMatcher.value(want, skipOverMax: false))
        }
        .sorted { ($0.haveCopies + $0.wantCopies, $0.friend ? 1 : 0, $1.userId) > ($1.haveCopies + $1.wantCopies, $1.friend ? 1 : 0, $0.userId) }
    }
}

private extension TradeMatcher.CopyIn {
    static func value(_ copies: [Self]) -> Double { copies.reduce(0) { $0 + Double($1.qty) * ($1.usd ?? 0) } }
}

enum FriendsDemo {
    /// Turns the demo on (called when the Library demo starts) and fills it once the card data is in.
    @MainActor
    static func start() {
        if FriendsStore.shared.demo == nil { FriendsStore.shared.demo = FriendsDemoBackend() }
        if ModerationStore.shared.demo == nil { ModerationStore.shared.demo = ModerationDemo() }
        if BugsStore.shared.demo == nil { BugsStore.shared.demo = BugsDemo() }
        if FollowsStore.shared.demo == nil { FollowsStore.shared.demo = FollowsDemo() }
    }

    @MainActor
    static func seed() async {
        guard let demo = FriendsStore.shared.demo, let db = CatalogStore.shared.db else { return }
        let b = BindersStore.shared
        await PriceBook.shared.load(Array(Set(b.allocs.values.map(\.cardId) + b.liveWants.compactMap(\.cardId))))
        demo.build(db)
        // Screens that loaded before the card data was in show the demo people now.
        await FriendsStore.shared.loadMatches()
        await FriendsStore.shared.load()
        await FriendsStore.shared.loadSharing()
        // Following's demo updates are made from the demo deck, which is in by now.
        FollowsStore.shared.demo = FollowsDemo()
        await FollowsStore.shared.load()
    }

    /// `-T1LibraryDemo friends|profile|profilefriends|profiledeck|sharing|share|shareall|shareon|sharedlink|badlink|matches|match|me|myprofile|notices|review|bugs|bug|following|followchanges|followdeck`.
    @MainActor
    static func route(_ arg: String) -> [LibraryRoute]? {
        if arg == "shareon" {
            // All cards with a live link, its setting widened to Friends so Send profile link shows too.
            FriendsStore.shared.demo?.sharing.links = [PartLink(part: "all_cards", token: "demoAllCardsLinkToken0")]
            FriendsStore.shared.demo?.sharing.allCards = .friends
        }
        return switch arg {
        case "friends": [.social(.friends)]
        case "profile": [.social(.friends), .social(.profile(FriendsDemoBackend.mara))]
        case "profilefriends": [.social(.profile(FriendsDemoBackend.mara)), .social(.profileFriends(FriendsDemoBackend.mara, "Mara Quinn"))]
        case "profiledeck": [.social(.profile(FriendsDemoBackend.mara)),
                             .social(.profileCards(FriendsDemoBackend.mara, "deck", "d0000000-0000-0000-0000-0000000fd001", "Mono-red prowess",
                                                   SharedList(format: "modern", owner: "Mara")))]
        case "sharing": [.social(.sharing)]
        case "share": ListsStore.shared.lists.first { $0.kind == .deck && $0.eventId == nil }.map { d in
            [.lists(.deck), .list(d.id), .social(.share(.item(kind: "deck", id: d.id, name: d.name)))]
        } ?? [.social(.share(.allCards))]
        case "shareall": [.allCards, .social(.share(.allCards))]
        case "shareon": [.allCards, .social(.share(.allCards))]
        case "sharedlink": [.social(.sharedLink(FriendsDemoBackend.maraLink))]
        case "badlink": [.social(.sharedLink("nope"))]
        case "matches": [.social(.matches)]
        case "match": [.social(.matches), .social(.match(FriendsDemoBackend.mara))]
        case "me": [.social(.profile(FriendsDemoBackend.me))]
        case "myprofile": [.social(.sharing), .social(.profile(FriendsDemoBackend.me))]
        case "notices": [.social(.notices)]
        case "review": [.social(.review)]
        case "bugs": [.social(.bugs)]
        case "bug": PushRoutes.path(.bug(10))
        case "following": [.social(.following)]
        case "followchanges": [.social(.following), .social(.followChanges("deck", FollowsDemo.deck))]
        case "followdeck": [.social(.profile(FriendsDemoBackend.mara)),
                            .social(.profileCards(FriendsDemoBackend.mara, "deck", FollowsDemo.deck, "Mono-red prowess",
                                                  SharedList(format: "modern", owner: "Mara Quinn")))]
        default: nil
        }
    }
}
#endif
