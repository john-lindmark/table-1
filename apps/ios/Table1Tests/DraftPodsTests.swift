import XCTest
@testable import Table1

/* Drafts with several pods (contract/draft-pods-2026-11-09.md) against testdata/draft-pods/cases.json: pod plans,
   automatic rounds, the pick's label, the Automatic rounds detail, round 1 across every pod and its notes. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata").standardized

private struct Cases: Decodable {
    struct Plan: Decodable { let players: Int; let pods: Int?; let want: [Int] }
    struct Rounds: Decodable { let sizes: [Int]; let pod_pairing: String; let want: Int }
    struct Label: Decodable { let players: Int; let pods: Int?; let want: String }
    struct Auto: Decodable { let players: Int; let pods: Int?; let pod_pairing: String; let want: String }
    struct Note: Decodable { let sizes: [Int]; let pod: Int; let want: String }
    struct RoundOne: Decodable {
        struct Pod: Decodable { let pairs: [[String]]; let left: String? }
        struct Want: Decodable { let pods: [Pod]; let across: [[String]]; let bye: String? }
        let sizes: [Int]; let want: Want
    }
    let plan: [Plan]
    let rounds: [Rounds]
    let label: [Label]
    let auto_label: [Auto]
    let note: [Note]
    let round1: [RoundOne]
}

final class DraftPodsTests: XCTestCase {
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: dir.appending(path: "draft-pods/cases.json")))
    }

    func testPlansRoundsAndLabels() throws {
        let c = try cases()
        for p in c.plan {
            XCTAssertEqual(DraftPods.plan(players: p.players, pods: p.pods), p.want, "\(p.players) players, pods \(String(describing: p.pods))")
            XCTAssertEqual(DraftPods.count(players: p.players, pods: p.pods), p.want.count)
        }
        for r in c.rounds { XCTAssertEqual(DraftPods.rounds(sizes: r.sizes, pairing: r.pod_pairing), r.want, "\(r.sizes) \(r.pod_pairing)") }
        for l in c.label { XCTAssertEqual(DraftPods.label(players: l.players, pods: l.pods), l.want) }
        for a in c.auto_label {
            XCTAssertEqual(DraftPods.autoLabel(players: a.players, pods: a.pods, pairing: a.pod_pairing), a.want,
                           "\(a.players) \(String(describing: a.pods)) \(a.pod_pairing)")
        }
    }

    func testRoundOneAcrossEveryPod() throws {
        let c = try cases()
        func seat(_ id: String) -> (pod: Int, seat: Int) {
            let parts = id.dropFirst().split(separator: "S")
            return (Int(parts[0])! - 1, Int(parts[1])!)
        }
        for r in c.round1 {
            let plan = DraftPods.roundOne(r.sizes.map { Array(1...max($0, 1)).prefix($0).map { $0 } })
            XCTAssertEqual(plan.pods.count, r.want.pods.count)
            for (got, want) in zip(plan.pods, r.want.pods) {
                XCTAssertEqual(got.pairs.map { [$0.0, $0.1] }, want.pairs.map { $0.map { seat($0).seat } }, "\(r.sizes)")
                XCTAssertEqual(got.left, want.left.map { seat($0).seat })
            }
            XCTAssertEqual(plan.across.map { [$0.0.pod, $0.0.seat, $0.1.pod, $0.1.seat] },
                           r.want.across.map { [seat($0[0]).pod, seat($0[0]).seat, seat($0[1]).pod, seat($0[1]).seat] }, "\(r.sizes)")
            XCTAssertEqual(plan.bye.map { [$0.pod, $0.seat] }, r.want.bye.map { [seat($0).pod, seat($0).seat] })
        }
        for n in c.note {
            let seats = n.sizes.map { Array(1...max($0, 1)).prefix($0).map { $0 } }
            XCTAssertEqual(DraftPods.note(seats, pod: n.pod) { "Pod \($0 + 1)" }, n.want, "\(n.sizes) pod \(n.pod)")
        }
    }

    func testPodCodes() {
        XCTAssertEqual(DraftPods.code("Pod 3", index: 0), "P3")
        XCTAssertEqual(DraftPods.code("Main", index: 1), "P2")
        XCTAssertEqual(DraftPods.code(nil, index: 0), "P1")
    }

    func testEventDecodesPods() throws {
        let json = #"{"id":"e","short_code":"ABCD","name":"Draft","pods":2,"pod_pairing":"pod"}"#
        let e = try wireDecoder.decode(EventRow.self, from: Data(json.utf8))
        XCTAssertEqual(e.pods, 2)
        XCTAssertEqual(e.podPairing, "pod")
        let old = try wireDecoder.decode(EventRow.self, from: Data(#"{"id":"e","short_code":"ABCD","name":"Draft"}"#.utf8))
        XCTAssertNil(old.pods)
        XCTAssertEqual(old.podPairing, "cross", "a server without the column paired across pods")
    }
}
