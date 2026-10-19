import XCTest
import Supabase
@testable import Table1

/* Friends, sharing and trade matches (contract/friends-sharing-2026-10-18.md). The matcher runs the shared cases in
   testdata/trade-matches/cases.json (the same as the server's 80_friends_sharing_test.sql); web friends.test.ts and
   Android FriendsTest read the same file. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/trade-matches/cases.json").standardized
private let sharingCasesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/sharing/cases.json").standardized

/// testdata/sharing/cases.json (contract § UX rules): widening, the Sharing summary lines, view as.
private struct SharingCases: Decodable {
    struct W: Decodable {
        let name: String, before: SharingSettings, after: SharingSettings
        let friends: [String], anyone: [String]
        let allCardsToAnyone: Bool, profileToAnyone: Bool
    }
    struct S: Decodable { let name: String; let settings: SharingSettings; let friends: String; let anyone: String }
    struct Want: Decodable, Equatable {
        let visible: Bool
        let allCards: Int?, value: Double?, forTrade: Int?, wants: Int?
        let binders: [String], decks: [String], cubes: [String]
        let record: Bool
    }
    struct V: Decodable { let name: String; let settings: SharingSettings; let level: Int; let want: Want }
    let widening: [W]
    let sees: [S]
    let viewAsProfile: ProfileData
    let viewAs: [V]
}

private struct Cases: Decodable {
    struct W: Decodable { let oracleId: String; let cardId: String?; let finish: String?; let qty: Int; let maxUsd: Double? }
    struct C: Decodable {
        let oracleId: String, cardId: String, finish: String, condition: String, lang: String
        let binderId: String?
        let qty: Int
        let usd: Double?
    }
    struct L: Decodable, Equatable {
        let cardId: String, finish: String, condition: String, lang: String
        let qty: Int
        let want: String
        let overMax: Bool
    }
    struct Case: Decodable { let name: String; let wants: [W]; let copies: [C]; let lines: [L] }
    let cases: [Case]
}

final class FriendsTests: XCTestCase {
    func testMatcherSharedCases() throws {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let cases = try d.decode(Cases.self, from: Data(contentsOf: casesURL)).cases
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        for c in cases {
            let got = TradeMatcher.lines(
                wants: c.wants.map { TradeMatcher.WantIn(oracleId: $0.oracleId, cardId: $0.cardId, finish: $0.finish, qty: $0.qty, maxUsd: $0.maxUsd) },
                copies: c.copies.map { TradeMatcher.CopyIn(oracleId: $0.oracleId, cardId: $0.cardId, finish: $0.finish, condition: $0.condition,
                                                            lang: $0.lang, binderId: $0.binderId, qty: $0.qty, usd: $0.usd) })
            let lines = got.map { Cases.L(cardId: $0.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, qty: $0.qty,
                                          want: $0.want.tier, overMax: $0.overMax ?? false) }
            XCTAssertEqual(lines, c.lines, c.name)
        }
    }

    func testShownOrderPutsOverMaxLast() {
        let w = WantKey(oracleId: "o")
        let lines = [MatchLine(cardId: "a", finish: "nonfoil", condition: "NM", lang: "en", qty: 1, want: w, usd: 50, overMax: true),
                     MatchLine(cardId: "b", finish: "nonfoil", condition: "NM", lang: "en", qty: 1, want: w, usd: 1, overMax: false),
                     MatchLine(cardId: "c", finish: "nonfoil", condition: "NM", lang: "en", qty: 2, want: w, usd: 3, overMax: false)]
        XCTAssertEqual(TradeMatcher.shown(lines).map(\.cardId), ["c", "b", "a"])
        XCTAssertEqual(TradeMatcher.value(lines, skipOverMax: true), 7)
        XCTAssertEqual(TradeMatcher.value(lines, skipOverMax: false), 57)
    }

    func testSharingDefaultsArePrivate() {
        let s = SharingSettings()
        XCTAssertEqual(s.profile, .friends)
        for p in SharePart.libraryParts + [.record] { XCTAssertEqual(SharingRules.effective(s, p), .private, p.rawValue) }
        XCTAssertEqual(SharingRules.sharedCount(s), 0)
        XCTAssertEqual(SharingRules.summary(s), "Profile friends · nothing shared")
    }

    func testInheritChainAndItems() {
        var s = SharingSettings()
        s.library = .friends
        XCTAssertEqual(SharingRules.effective(s, .decks), .friends)
        s.decks = .private
        let deck = ShareItem(kind: "deck", id: "d", name: "Burn")
        XCTAssertEqual(SharingRules.effective(s, deck), .private)
        var own = deck
        own.visibility = .public
        XCTAssertEqual(SharingRules.effective(s, own), .public)
        s.items = [own]
        // all_cards, for_trade, wants, binders, cubes follow Library (friends); decks private; the deck counts on its own.
        XCTAssertEqual(SharingRules.sharedCount(s), 6)
    }

    func testProfileCapsParts() {
        var s = SharingSettings()
        s.forTrade = .public
        XCTAssertTrue(SharingRules.capped(s, .public))
        XCTAssertEqual(SharingRules.reach(s, .public), .friends)
        s.profile = .public
        XCTAssertFalse(SharingRules.capped(s, .public))
        XCTAssertEqual(SharingRules.reach(s, .public), .public)
        s.profile = .private
        XCTAssertEqual(SharingRules.reach(s, .public), .private)
        XCTAssertEqual(SharingRules.sharedCount(s), 0)
    }

    /// The same check as the server's vis_ok: owner / friend / anyone / blocked against profile × part.
    func testSeesMatchesServer() {
        let cases: [(Int, Visibility, Visibility, Bool)] = [
            (3, .private, .private, true),
            (1, .friends, .friends, true), (1, .friends, .private, false), (1, .private, .public, false),
            (0, .public, .public, true), (0, .friends, .public, false), (0, .public, .friends, false),
            (-1, .public, .public, false),
        ]
        for (level, profile, part, want) in cases {
            XCTAssertEqual(SharingRules.sees(level: level, profile: profile, part: part), want, "\(level) \(profile) \(part)")
        }
    }

    func testSettingsChangeJSON() {
        XCTAssertEqual(SharingRules.change(.wants, nil), .object(["wants": .null]))
        XCTAssertEqual(SharingRules.change(.profile, .public), .object(["profile": .string("public")]))
        let item = ShareItem(kind: "binder", id: "b1", name: "Trades", forTrade: true)
        XCTAssertEqual(SharingRules.change(item, .friends),
                       .object(["items": .array([.object(["kind": .string("binder"), "id": .string("b1"), "visibility": .string("friends")])])]))
    }

    func testDecodesServerShapes() throws {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let s = try d.decode(SharingSettings.self, from: Data("""
            {"profile":"public","library":"private","all_cards":null,"for_trade":"friends","wants":null,"binders":null,
             "decks":null,"cubes":null,"record":"friends","items":[{"kind":"binder","id":"b","name":"T","for_trade":true,"visibility":null}]}
            """.utf8))
        XCTAssertEqual(s.forTrade, .friends)
        XCTAssertEqual(s.items.first?.group, .binders)
        let p = try d.decode(ProfileData.self, from: Data("""
            {"user_id":"u","display_name":"Ben","handle":null,"avatar_url":null,"relation":"friend","friends_since":"2026-10-18",
             "visible":true,"sections":{"for_trade":{"cards":7},"binders":[{"id":"b","name":"T","for_trade":true,"cards":7}],
             "decks":[],"cubes":[],"record":{"match_wins":1,"match_losses":2,"match_draws":0,"events_played":1}}}
            """.utf8))
        XCTAssertEqual(p.relation, .friend)
        XCTAssertEqual(p.sectionCount, 3)
        let unknown = try d.decode(Person.self, from: Data(#"{"user_id":"u","display_name":"A","relation":"something_new"}"#.utf8))
        XCTAssertEqual(unknown.relation, Relation.none)
        let m = try d.decode(TradeMatch.self, from: Data("""
            {"user_id":"u","display_name":"Ben","handle":null,"avatar_url":null,"friend":true,"have_copies":1,"want_copies":0,
             "have_usd":2.0,"want_usd":0,"they_want":[],
             "they_have":[{"card_id":"c","finish":"foil","condition":"NM","lang":"en","qty":1,"usd":2.0,"over_max":false,
                           "want":{"oracle_id":"o","card_id":"c","finish":"foil"}}]}
            """.utf8))
        XCTAssertEqual(m.theyHave.first?.want.tier, "exact")
        XCTAssertEqual(m.summary, "Has 1 you want")
    }

    func testParsesProfileCardRows() {
        XCTAssertEqual(ProfileCard.parse("all_cards", [.string("c"), .string("foil"), .integer(3)]),
                       ProfileCard(cardId: "c", finish: "foil", qty: 3))
        XCTAssertEqual(ProfileCard.parse("binder", [.string("c"), .string("nonfoil"), .string("LP"), .string("ja"), .integer(2)]),
                       ProfileCard(cardId: "c", finish: "nonfoil", condition: "LP", lang: "ja", qty: 2))
        XCTAssertEqual(ProfileCard.parse("deck", [.string("c"), .string("side"), .integer(4)]),
                       ProfileCard(cardId: "c", board: "side", qty: 4))
        XCTAssertEqual(ProfileCard.parse("wants", [.string("o"), .null, .null, .integer(1)]),
                       ProfileCard(oracleId: "o", qty: 1))
        XCTAssertNil(ProfileCard.parse("wants", [.string("o")]))
    }

    private func sharingCases() throws -> SharingCases {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SharingCases.self, from: Data(contentsOf: sharingCasesURL))
    }

    func testWideningSharedCases() throws {
        let cases = try sharingCases().widening
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for c in cases {
            let w = SharingRules.widening(c.before, c.after)
            XCTAssertEqual(w.friends, c.friends, c.name)
            XCTAssertEqual(w.anyone, c.anyone, c.name)
            XCTAssertEqual(w.allCardsToAnyone, c.allCardsToAnyone, c.name)
            XCTAssertEqual(w.profileToAnyone, c.profileToAnyone, c.name)
            // Undoing a widening never asks (no case both widens and narrows).
            if !w.isEmpty { XCTAssertTrue(SharingRules.widening(c.after, c.before).isEmpty, c.name) }
        }
    }

    func testSeesLineSharedCases() throws {
        for c in try sharingCases().sees {
            XCTAssertEqual(SharingRules.seesLine(c.settings, level: 1), c.friends, c.name)
            XCTAssertEqual(SharingRules.seesLine(c.settings, level: 0), c.anyone, c.name)
        }
    }

    func testViewAsSharedCases() throws {
        let all = try sharingCases()
        XCTAssertEqual(all.viewAsProfile.relation, .me)
        for c in all.viewAs {
            let v = SharingRules.viewAs(all.viewAsProfile, c.settings, level: c.level)
            let got = SharingCases.Want(visible: v.visible, allCards: v.sections.allCards?.cards, value: v.sections.allCards?.valueUsd,
                                        forTrade: v.sections.forTrade?.cards, wants: v.sections.wants?.cards,
                                        binders: (v.sections.binders ?? []).map(\.name), decks: (v.sections.decks ?? []).map(\.name),
                                        cubes: (v.sections.cubes ?? []).map(\.name), record: v.sections.record != nil)
            XCTAssertEqual(got, c.want, c.name)
            XCTAssertEqual(v.relation, c.level >= 1 ? .friend : Relation.none, c.name)
        }
    }

    func testWideningMessage() {
        var w = SharingRules.Widening(friends: ["Wants"], anyone: ["All cards", "Burn"], allCardsToAnyone: true)
        XCTAssertEqual(w.title, "Show to anyone on Table 1?")
        XCTAssertEqual(w.message, "Anyone on Table 1 will see: All cards, Burn.\n\nFriends will see: Wants.\n\nEvery card you own. Your total value is never shown.")
        w = SharingRules.Widening(friends: ["your record"])
        XCTAssertEqual(w.title, "Show to friends?")
        XCTAssertEqual(Visibility.public.label, "Anyone")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(type, from: Data(json.utf8))
    }

    /// Privacy fixes: an email ask comes back as {email, at} with no user_id; asks by id stay a Person.
    func testDecodesSentByIdAndByEmail() throws {
        let l = try decode(FriendsList.self, """
            {"friends":[],"incoming":[],"blocked":[],"outgoing":[
              {"email":"jo@example.com","at":"2026-10-18T10:00:00Z"},
              {"user_id":"u1","display_name":"Lee Park","handle":null,"avatar_url":null,"at":"2026-10-17T10:00:00Z"}]}
            """)
        XCTAssertEqual(l.outgoing.count, 2)
        XCTAssertNil(l.outgoing[0].person)
        XCTAssertEqual(l.outgoing[0].email, "jo@example.com")
        XCTAssertEqual(l.outgoing[0].at, "2026-10-18T10:00:00Z")
        XCTAssertEqual(l.outgoing[0].label, "jo@example.com")
        XCTAssertEqual(l.outgoing[1].person?.userId, "u1")
        XCTAssertEqual(l.outgoing[1].label, "Lee Park")
        XCTAssertEqual(l.outgoing[1].at, "2026-10-17T10:00:00Z")
        XCTAssertNotEqual(l.outgoing[0].id, l.outgoing[1].id)
        // Round trip (the store keeps it as is).
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        XCTAssertEqual(try decode(FriendsList.self, String(decoding: try e.encode(l), as: UTF8.self)), l)
    }

    /// Older servers sent only Person rows (an email ask that found an account as that Person); a null user_id reads as an address.
    func testDecodesOldSentShape() throws {
        let l = try decode(FriendsList.self, """
            {"friends":[],"incoming":[],"blocked":[],"outgoing":[
              {"user_id":"u2","display_name":"Kai","at":"2026-10-16T10:00:00Z"},
              {"user_id":null,"email":"x@example.com","at":"2026-10-15T10:00:00Z"}]}
            """)
        XCTAssertEqual(l.outgoing.map(\.person?.userId), ["u2", nil])
        XCTAssertEqual(l.outgoing[1].email, "x@example.com")
    }

    /// value_usd is on your own profile only now; an older server's value on someone else's profile isn't shown.
    func testCollectionValueOnlyOnYourOwnProfile() throws {
        func profile(_ relation: String, _ allCards: String) throws -> ProfileData {
            try decode(ProfileData.self, """
                {"user_id":"u","display_name":"A","handle":null,"avatar_url":null,"relation":"\(relation)","friends_since":null,
                 "visible":true,"sections":{"all_cards":\(allCards)}}
                """)
        }
        let mine = try profile("self", #"{"cards":10,"printings":8,"value_usd":42.5}"#)
        XCTAssertEqual(mine.valueUsd, 42.5)
        let theirs = try profile("friend", #"{"cards":10,"printings":8}"#)
        XCTAssertEqual(theirs.sections.allCards?.cards, 10)
        XCTAssertNil(theirs.sections.allCards?.valueUsd)
        XCTAssertNil(theirs.valueUsd)
        XCTAssertNil(try profile("friend", #"{"cards":10,"printings":8,"value_usd":42.5}"#).valueUsd)
    }
}
