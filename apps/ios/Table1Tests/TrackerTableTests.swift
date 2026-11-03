import XCTest
@testable import Table1

/* The life tracker's table setup, seats and commander damage (contract/life-tracker-commander-2026-11-03.md)
   against testdata/tracker-table/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/tracker-table/cases.json").standardized

private struct Op: Decodable {
    let at: Double?
    let side: Int
    let counter: String
    let delta: Int
}

private struct Cases: Decodable {
    struct Setup: Decodable {
        struct Default: Decodable { let players: Int; let life: Int }
        let players: [Int]
        let lives: [Int]
        let `default`: Default
        let commanderFrom: Int
        let commanderLoss: Int
    }
    struct Names: Decodable { let players: Int; let names: [String] }
    struct Place: Decodable { let side: Int; let seat: String }
    enum Row: Decodable {
        case strip
        case seats([Place])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), s == "strip" { self = .strip } else { self = .seats(try c.decode([Place].self)) }
        }
    }
    struct Layout: Decodable { let players: Int; let rows: [Row] }
    struct Picker: Decodable { let players: Int; let life: Int; let side: Int; let rows: [String] }
    struct Label: Decodable { let players: Int; let counter: String; let label: String; let short: String }
    struct Value: Decodable { let side: Int; let counter: String; let value: Int }
    struct Totals: Decodable { let players: Int; let life: Int; let ops: [Op]; let lifeTotals: [Int]; let counters: [Value] }
    struct Losing: Decodable { let players: Int; let life: Int; let ops: [Op]; let lost: [Int]; let winner: Int? }
    struct Group: Decodable { let side: Int; let counter: String; let delta: Int; let after: Int }
    struct Groups: Decodable { let players: Int; let life: Int; let ops: [Op]; let groups: [Group]; let lifeTotals: [Int] }
    struct Score: Decodable { let players: Int; let winners: [Int]; let text: String }
    let setup: Setup
    let names: [Names]
    let layouts: [Layout]
    let picker: [Picker]
    let labels: [Label]
    let totals: [Totals]
    let losing: [Losing]
    let groups: [Groups]
    let score: [Score]
}

private let cases = try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))

@MainActor
final class TrackerTableTests: XCTestCase {
    private var saved: [String: Data?] = [:]
    private let keys = ["tracker.local.v1", "tracker.counters.local"]

    override func setUp() async throws {
        for key in keys {
            saved[key] = UserDefaults.standard.data(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in keys { UserDefaults.standard.set(saved[key] ?? nil, forKey: key) }
    }

    private func table(_ players: Int, life: Int, ops: [Op] = []) async -> TrackerModel {
        let model = TrackerModel(matchId: nil)
        await model.start()
        model.configure(players: players, life: life)
        for op in ops { model.tap(side: op.side, counter: TrackerCounter(rawValue: op.counter)!, delta: op.delta) }
        return model
    }

    func testSetupChoices() {
        XCTAssertEqual(TrackerTable.playerChoices, cases.setup.players)
        XCTAssertEqual(TrackerTable.lifeChoices, cases.setup.lives)
        XCTAssertEqual(TrackerTable.commanderFrom, cases.setup.commanderFrom)
        XCTAssertEqual(TrackerTable.commanderLoss, cases.setup.commanderLoss)
    }

    func testNamesAndLayouts() {
        for c in cases.names { XCTAssertEqual(TrackerTable.names(c.players), c.names) }
        for c in cases.layouts {
            let expected: [TrackerTable.Row] = c.rows.map {
                switch $0 {
                case .strip: .strip
                case .seats(let places): .seats(places.map { TrackerTable.Place(side: $0.side, seat: TrackerSeat(rawValue: $0.seat)!) })
                }
            }
            XCTAssertEqual(TrackerTable.layout(c.players), expected, "\(c.players) players")
        }
    }

    func testCounterKeysRoundTrip() {
        for key in ["life", "poison", "speed", "cmd:0", "cmd:4"] { XCTAssertEqual(TrackerCounter(rawValue: key)?.rawValue, key) }
        XCTAssertNil(TrackerCounter(rawValue: "cmd:"))
        XCTAssertNil(TrackerCounter(rawValue: "cmd:-1"))
        XCTAssertNil(TrackerCounter(rawValue: "mana"))
    }

    func testPickerRows() async {
        for c in cases.picker {
            let model = await table(c.players, life: c.life)
            XCTAssertEqual(model.pickerCounters(c.side).map(\.rawValue), c.rows, "\(c.players) players at \(c.life)")
        }
    }

    func testLabels() async {
        for c in cases.labels {
            let model = await table(c.players, life: 40)
            let counter = TrackerCounter(rawValue: c.counter)!
            XCTAssertEqual(model.label(counter), c.label)
            XCTAssertEqual(model.shortLabel(counter), c.short)
        }
    }

    func testCommanderDamageComesOffLife() async {
        for c in cases.totals {
            let model = await table(c.players, life: c.life, ops: c.ops)
            XCTAssertEqual(model.sides.map { model.total($0, .life) }, c.lifeTotals)
            for v in c.counters { XCTAssertEqual(model.total(v.side, TrackerCounter(rawValue: v.counter)!), v.value) }
        }
    }

    func testLosingAndTheSettledWinner() async {
        for c in cases.losing {
            let model = await table(c.players, life: c.life, ops: c.ops)
            XCTAssertEqual(model.sides.filter { model.hasLost($0) }, c.lost, "\(c.players) players: \(c.ops.map(\.counter))")
            XCTAssertEqual(model.settledWinner, c.winner)
        }
    }

    func testLifeGroupsCountCommanderDamage() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for c in cases.groups {
            let model = await table(c.players, life: c.life)
            model.ops = c.ops.enumerated().map { i, op in
                TrackerOp(clientOpId: "op-\(i)", gameNo: 1, side: op.side, counter: op.counter, delta: op.delta,
                          at: t0.addingTimeInterval((op.at ?? 0) / 1000), mine: nil)
            }
            let groups = model.visibleGroups(game: 1)
            XCTAssertEqual(groups.map(\.side), c.groups.map(\.side))
            XCTAssertEqual(groups.map(\.counter.rawValue), c.groups.map(\.counter))
            XCTAssertEqual(groups.map(\.delta), c.groups.map(\.delta))
            XCTAssertEqual(groups.map(\.result), c.groups.map(\.after))
            XCTAssertEqual(model.sides.map { model.total($0, .life) }, c.lifeTotals)
        }
    }

    func testScoreText() async {
        for c in cases.score {
            let model = await table(c.players, life: 20)
            model.games = c.winners.enumerated().map { TrackerGame(gameNo: $0 + 1, winnerSide: $1, isDraw: false, recordedAt: nil) }
            XCTAssertEqual(model.scoreText, c.text)
        }
    }

    func testCommanderDamageOnlyForLocalTablesFrom30() async {
        let twenty = await table(4, life: 20)
        XCTAssertFalse(twenty.commanderDamage)
        let thirty = await table(4, life: 30)
        XCTAssertTrue(thirty.commanderDamage)
        XCTAssertFalse(TrackerModel(matchId: "m").commanderDamage, "a synced match never tracks it")
    }

    func testSetupKeepsAcrossALaunchAndNewMatchKeepsTheTable() async {
        let model = await table(5, life: 40, ops: [Op(at: nil, side: 3, counter: "cmd:1", delta: 4)])
        let again = TrackerModel(matchId: nil)
        await again.start()
        XCTAssertEqual(again.players, 5)
        XCTAssertEqual(again.startingLife, 40)
        XCTAssertEqual(again.total(3, .life), 36)
        XCTAssertEqual(again.counterPrefs.count, 5)
        model.newMatch()
        XCTAssertEqual(model.players, 5)
        XCTAssertEqual(model.total(3, .life), 40)
    }
}
