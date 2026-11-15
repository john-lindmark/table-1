import XCTest
@testable import Table1

/* The main navigation (contract/main-nav-2026-11-14.md) against testdata/main-nav/cases.json: tabs, sub-tabs and their
   labels in order, defaults, what a tab opens on for a stored value, and paths that start on a sub-tab's own screen. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata").standardized

private struct Cases: Decodable {
    struct Sub: Decodable { let id: String; let label: String; let fullScreen: Bool? }
    struct T: Decodable { let id: String; let label: String; let `default`: String; let subs: [Sub] }
    struct R: Decodable { let tab: String; let stored: String?; let want: String }
    let tabs: [T]
    let remembered: [R]
}

final class MainNavTests: XCTestCase {
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: dir.appending(path: "main-nav/cases.json")))
    }

    func testTabsAndSubTabs() throws {
        let c = try cases()
        XCTAssertEqual(Tab.allCases.map(\.rawValue), c.tabs.map(\.id))
        XCTAssertEqual(SignedInView.tabs.map(\.label), c.tabs.map(\.label))
        for t in c.tabs {
            let tab = try XCTUnwrap(Tab(rawValue: t.id))
            XCTAssertEqual(MainNav.label(tab), t.label)
            XCTAssertEqual(MainNav.defaultSub(tab).rawValue, t.default, t.id)
            XCTAssertEqual(MainNav.subs(tab).map(\.id.rawValue), t.subs.map(\.id), t.id)
            XCTAssertEqual(MainNav.subs(tab).map(\.label), t.subs.map(\.label), t.id)
            XCTAssertEqual(MainNav.subs(tab).map(\.fullScreen), t.subs.map { $0.fullScreen ?? false }, t.id)
        }
    }

    func testRemembered() throws {
        for r in try cases().remembered {
            let tab = try XCTUnwrap(Tab(rawValue: r.tab))
            XCTAssertEqual(MainNav.remembered(tab, r.stored).rawValue, r.want, "\(r.tab) \(r.stored ?? "nil")")
        }
    }

    func testSaveKeepsOnlyPlaces() {
        let d = UserDefaults(suiteName: "MainNavTests")!
        d.removePersistentDomain(forName: "MainNavTests")
        MainNav.save(.wants, for: .collection, d)
        XCTAssertEqual(MainNav.load(.collection, d), .wants)
        MainNav.save(.tracker, for: .events, d)   // full screen: never kept
        XCTAssertNil(d.string(forKey: MainNav.key(.events)))
        MainNav.save(.rankings, for: .collection, d)   // not one of Cards' sub-tabs
        XCTAssertEqual(MainNav.load(.collection, d), .wants)
    }

    func testPathsOntoSubTabs() {
        XCTAssertEqual(MainNav.cards([.trades, .trade("t1")]).sub, .trade)
        XCTAssertEqual(MainNav.cards([.trades, .trade("t1")]).rest, [.trade("t1")])
        XCTAssertEqual(MainNav.cards([.wants]).sub, .wants)
        XCTAssertNil(MainNav.cards([.list("x")]).sub)
        XCTAssertEqual(MainNav.cards([.list("x")]).rest, [.list("x")])
        XCTAssertEqual(MainNav.rankingsIn([.lists(.cube), .rankings(nil), .ranking("r")]), [.ranking("r")])
        XCTAssertNil(MainNav.rankingsIn([.rankings("cube")]))
        XCTAssertEqual(MainNav.insights([.library(.rankings(nil))]).sub, .rankings)
        XCTAssertNil(MainNav.insights([.library(.rankings("set:FRA"))]).sub)
    }
}
