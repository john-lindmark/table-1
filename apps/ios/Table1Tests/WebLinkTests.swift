import XCTest
@testable import Table1

/* Universal links (App/WebLink.swift) against the shared cases in testdata/universal-links/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/universal-links/cases.json").standardized

private struct Cases: Decodable {
    struct Case: Decodable { let url: String; let to: String? }
    let cases: [Case]
}

final class WebLinkTests: XCTestCase {
    func testSharedCases() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)).cases
        XCTAssertGreaterThan(cases.count, 50)
        for c in cases {
            let url = try XCTUnwrap(URL(string: c.url), c.url)
            XCTAssertEqual(WebLink.parse(url).map(describe), c.to, c.url)
        }
    }

    /// The cases' neutral form: "tab > screen arg > screen arg".
    private func describe(_ link: WebLink) -> String {
        switch link {
        case .signIn: "auth"
        case .joinQr(let j): "join-qr \(j.code) \(j.secret)"
        case .joinCode(let c): "join-code \(c)"
        case .standings(let id): "standings \(id)"
        case .shared(let t): "shared \(t)"
        case .tracker(let m): m.map { "tracker \($0)" } ?? "tracker"
        case .web: "web"
        case .events(let s): (["events"] + s.map(screen)).joined(separator: " > ")
        case .collection(let s): (["collection"] + s.map(screen)).joined(separator: " > ")
        case .account(let s): (["account"] + s.map(screen)).joined(separator: " > ")
        }
    }

    private func screen(_ r: Route) -> String {
        switch r {
        case .event(let id): "event \(id)"
        case .addPlayers(let id): "add-players \(id)"
        default: "\(r)"
        }
    }

    private func screen(_ r: LibraryRoute) -> String {
        switch r {
        case .allCards: "all-cards"
        case .add: "add"
        case .card(let o): "card \(o)"
        case .lists(let k): k == .deck ? "decks" : "cubes"
        case .findDeck: "find-deck"
        case .collectionImport: "import"
        case .importList(let k): "import-list \(k == .deck ? "deck" : "cube")"
        case .list(let id): "list \(id)"
        case .listAdd(let id): "list-add \(id)"
        case .listStats(let id): "stats \(id)"
        case .sampleHand(let id): "hand \(id)"
        case .drawOdds(let id): "odds \(id)"
        case .samplePack(let id): "pack \(id)"
        case .versions(let id): "versions \(id)"
        case .version(let id, let n): "version \(id) \(n)"
        case .rankings(let id): id.map { "rankings \($0)" } ?? "rankings"
        case .ranking(let id): "ranking \(id)"
        case .rankingPick(let id, let j): "ranking-pick \(id) \(j)"
        case .rankingLists(let id, let j): "ranking-lists \(id) \(j)"
        case .rankingCard(let id, let o, let j): "ranking-card \(id) \(o) \(j)"
        case .rankingCompare(let id, let o, let j): "ranking-compare \(id) \(o) \(j)"
        case .rankingPack(let id): "ranking-pack \(id)"
        case .rankingChanges(let id): "ranking-changes \(id)"
        case .trades: "trades"
        case .trade(let id): "trade \(id ?? "new")"
        case .binders: "binders"
        case .binder(let id): "binder \(id)"
        case .wants: "wants"
        case .social(.matches): "matches"
        case .social(.match(let u)): "match \(u)"
        case .social(.friends): "friends"
        case .social(.sharing): "sharing"
        case .social(.profile(let u)): "profile \(u)"
        default: "\(r)"
        }
    }
}
