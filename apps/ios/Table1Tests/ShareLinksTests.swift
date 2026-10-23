import XCTest
@testable import Table1

/* Share links (contract/share-links-2026-10-23.md) against testdata/share-links/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/share-links/cases.json").standardized

private struct Cases: Decodable {
    struct Target: Decodable { let part: String; let id: String?; let name: String?; let title: String; let what: String; let confirm: String; let profileUrl: String }
    struct LinkURL: Decodable { let token: String; let url: String }
    let me: String
    let linkUrl: LinkURL
    let targets: [Target]
}

final class ShareLinksTests: XCTestCase {
    private func load() throws -> (Cases, [String: Any]) {
        let data = try Data(contentsOf: casesURL)
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return (try d.decode(Cases.self, from: data), try JSONSerialization.jsonObject(with: data) as! [String: Any])
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func testTargets() throws {
        let (c, _) = try load()
        XCTAssertEqual(PartLink.url(c.linkUrl.token).absoluteString, c.linkUrl.url)
        for t in c.targets {
            let target = ShareTarget(part: t.part, id: t.id, name: t.name)
            XCTAssertEqual(target.title, t.title, t.part)
            XCTAssertEqual(target.what, t.what, t.part)
            XCTAssertEqual(target.confirmMessage, t.confirm, t.part)
            XCTAssertEqual(target.profileURL(c.me).absoluteString, t.profileUrl, t.part)
            XCTAssertEqual(target.sharePart != nil, t.id == nil, t.part)
        }
    }

    func testSharingGetLinks() throws {
        let (_, raw) = try load()
        let s = try decoder().decode(SharingSettings.self, from: JSONSerialization.data(withJSONObject: raw["sharing_get"]!))
        XCTAssertEqual(s.links?.count, 2)
        XCTAssertTrue(ShareTarget.item(kind: "deck", id: "D1", name: "Burn").matches(s.links![0]))
        XCTAssertTrue(ShareTarget.wants.matches(s.links![1]))
        XCTAssertFalse(ShareTarget.allCards.matches(s.links![1]))
        XCTAssertFalse(ShareTarget.item(kind: "cube", id: "D1", name: "Burn").matches(s.links![0]))
    }

    func testOlderServerWithoutLinks() throws {
        let s = try decoder().decode(SharingSettings.self, from: Data(#"{"profile":"friends","library":"private","record":"private","items":[]}"#.utf8))
        XCTAssertNil(s.links)
    }

    func testSharedView() throws {
        let (_, raw) = try load()
        for case let v as [String: Any] in raw["shared_view"] as! [Any] {
            let d = try decoder().decode(SharedLinkData.self, from: JSONSerialization.data(withJSONObject: v["json"]!))
            XCTAssertEqual(d.title, v["title"] as? String)
            XCTAssertEqual(d.byline, v["byline"] as? String)
        }
    }
}
