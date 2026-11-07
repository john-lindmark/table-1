import XCTest
@testable import Table1

/* Deck photo size and Rotate left / right (contract/event-night-2026-10-16.md § 7) against
   testdata/deck-photos/cases.json (also web deckPhotos.test.ts and Android DeckPhotosTest). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/deck-photos/cases.json").standardized

private struct Cases: Decodable {
    struct Turn: Decodable { let turns, by, out: Int }
    struct Size: Decodable { let width, height: Double; let turns: Int; let out: [Double] }
    let turn: [Turn]
    let size: [Size]
}

final class DeckPhotoTests: XCTestCase {
    private func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testTurns() throws {
        for c in try cases().turn {
            XCTAssertEqual(DeckPhotoTurns.turn(c.turns, by: c.by), c.out, "\(c.turns) by \(c.by)")
        }
    }

    func testSizes() throws {
        for c in try cases().size {
            let out = DeckPhotoTurns.size(width: c.width, height: c.height, turns: c.turns)
            XCTAssertEqual([out.width, out.height], c.out, "\(c.width)x\(c.height) turned \(c.turns)")
        }
    }
}

/* Account → Deck photos (§ 7 On your account): the row's summary and the screen's headings, same cases. */
private struct MineCases: Decodable {
    struct Summary: Decodable { let total, events: Int; let out: String }
    struct Photo: Decodable { let id: String; let eventId: String; let eventName: String }
    struct Group: Decodable { let eventId: String; let title: String; let ids: [String] }
    struct Groups: Decodable { let photos: [Photo]; let out: [Group] }
    let summary: [Summary]
    let groups: [Groups]
}

final class MyDeckPhotoTests: XCTestCase {
    private func cases() throws -> MineCases {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(MineCases.self, from: Data(contentsOf: casesURL))
    }

    func testSummary() throws {
        for c in try cases().summary {
            XCTAssertEqual(MyDeckPhotoRules.summary(total: c.total, events: c.events), c.out)
        }
    }

    func testGroups() throws {
        for c in try cases().groups {
            let photos = c.photos.map {
                DeckPhoto(id: $0.id, participantId: "p", player: "", path: $0.id, note: "", createdAt: "", mine: true,
                          editable: true, turns: 0, eventId: $0.eventId, eventName: $0.eventName)
            }
            let out = MyDeckPhotoRules.groups(photos)
            XCTAssertEqual(out.map(\.eventId), c.out.map(\.eventId))
            XCTAssertEqual(out.map(\.title), c.out.map(\.title))
            XCTAssertEqual(out.map { $0.photos.map(\.id) }, c.out.map(\.ids))
        }
    }

    func testTheServersRowsDecode() throws {
        let json = #"{"total": 1, "events": 1, "photos": [{"id": "d1", "participant_id": "p1", "player": "Bea", "path": "e/d1.jpg", "note": "", "created_at": "2026-11-06T10:00:00.123456+00:00", "turns": 1, "mine": true, "editable": true, "event_id": "e1", "event_name": "Old", "event_status": "completed", "format_label": "Draft", "event_at": "2026-10-29T18:00:00+00:00"}]}"#
        let mine = try wireDecoder.decode(MyDeckPhotos.self, from: Data(json.utf8))
        XCTAssertEqual(mine.photos.first?.eventName, "Old")
        XCTAssertEqual(mine.photos.first?.eventStatus, "completed")
        XCTAssertTrue(MyDeckPhotoRules.detail(mine.photos[0]).hasSuffix("2026 · Draft"))
        var named = mine.photos[0]
        named.eventName = "Thursday Draft"
        XCTAssertTrue(MyDeckPhotoRules.detail(named).hasSuffix("2026"), "the format is left out when the name says it")
    }
}
