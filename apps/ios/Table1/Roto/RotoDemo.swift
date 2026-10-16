#if DEBUG
import SwiftUI

// Debug only: `-T1RotoDemo [grid|cube|picks|list|schedule]` opens a roto draft without signing in. Eight players
// draft the demo Vintage cube (DebugResources/library-demo.json, 360 cards) 45 picks each; 114 picks are made
// and it's your pick (seat 3). The draft runs locally: after your pick the others pick every 0.7 s until your next
// turn, your list auto-picks, Undo and the pick clock work. Card names and colours come from the live catalog.

@MainActor
final class RotoDemoBackend: RotoBackend {
    static let eventId = "demo-roto"
    nonisolated static let names = ["Ann Ito", "Bo Lindqvist", "You", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Hal Brandt"]
    static let mySeat = 3

    private var pool: [RotoPoolCard] = []
    private var picks: [RotoPick] = []
    private var list: [Int] = []
    private var autoPick = true
    private var clock: [RotoClockRange]? = [RotoClockRange(fromRound: 1, seconds: 14400), RotoClockRange(fromRound: 11, seconds: 7200),
                                            RotoClockRange(fromRound: 31, seconds: 1800)]
    private var paused: Double?
    private var turnStarted = Date().timeIntervalSince1970 - 25 * 60
    private var rng = SplitMix(seed: 7)
    private var listeners: [AsyncStream<RotoChange>.Continuation] = []
    private var simulating: Task<Void, Never>?
    let players = 8
    let perPlayer = 45

    init() {
        let entries = LibraryDemoFixture.load()?.lists.first { $0.kind == "cube" }?.entries ?? []
        var slot = 0
        for e in entries where e[1].text == "main" {
            for _ in 0..<max(1, e[2].int) {
                slot += 1
                pool.append(RotoPoolCard(slot: slot, cardId: e[0].text))
            }
        }
        // A plausible first 114 picks: each seat takes from a shuffled ranking, now and then from its list.
        var ranking = pool.map(\.slot)
        ranking.shuffle(using: &rng)
        let start = Date().timeIntervalSince1970 - 3 * 86400
        for n in 1...114 {
            let slot = ranking.removeFirst()
            let how = n % 11 == 0 ? "auto" : n % 37 == 0 ? "timeout" : "player"
            picks.append(RotoPick(pickNo: n, seat: seatFor(n), slot: slot, how: how, at: start + Double(n) * 1800))
        }
        list = Array(ranking.prefix(12).reversed().prefix(5))
    }

    private var total: Int { players * perPlayer }
    private var made: Int { picks.count }
    private func seatFor(_ n: Int) -> Int { RotoMath.seat(players: players, pickNo: n, snake: true) }
    private func pid(_ seat: Int) -> String { "demo-p\(seat)" }

    private func snapshot(after: Int, pool includePool: Bool) -> RotoState {
        let n = made + 1
        let done = made >= total
        let round = RotoMath.round(players: players, pickNo: n)
        let seconds = RotoMath.clockSeconds(clock, round: round)
        let deadline = seconds.map { turnStarted + Double($0) }
        let onClock = done ? nil : RotoOnClock(
            participantId: pid(seatFor(n)), seat: seatFor(n), pickNo: n, round: round, turnStartedAt: turnStarted,
            turnSeconds: seconds, remainingSeconds: paused.flatMap { p in seconds.map { max(0, $0 - Int(p - turnStarted)) } },
            deadline: paused == nil ? deadline : nil,
            overdue: paused == nil && (deadline.map { Date().timeIntervalSince1970 > $0 } ?? false) && list.isEmpty)
        var draft = RotoDraftInfo()
        draft.picksPerPlayer = perPlayer
        draft.pickOrder = "snake"
        draft.players = players
        draft.poolCount = pool.count
        draft.picksMade = made
        draft.totalPicks = total
        draft.sourceListId = "demo-cube-vintage"
        draft.clock = clock
        draft.clockPaused = paused != nil
        draft.startedAt = picks.first?.at
        draft.finishedAt = done ? Date().timeIntervalSince1970 : nil
        let seats = (1...players).map { s in
            RotoSeat(seat: s, participantId: pid(s), displayName: Self.names[s - 1], account: s != 6, me: s == Self.mySeat)
        }
        return RotoState(eventId: Self.eventId, phase: done ? .done : .drafting, draft: draft, onClock: onClock, seats: seats,
                         picks: picks.filter { $0.pickNo > after }, pool: includePool ? pool : nil,
                         me: RotoMe(participantId: pid(Self.mySeat), seat: Self.mySeat, queue: list, autoPick: autoPick, deckListId: nil))
    }

    private func taken(_ slot: Int) -> Bool { picks.contains { $0.slot == slot } }

    private func record(_ slot: Int, how: String) {
        picks.append(RotoPick(pickNo: made + 1, seat: seatFor(made + 1), slot: slot, how: how, at: Date().timeIntervalSince1970))
        list.removeAll { $0 == slot }
        turnStarted = Date().timeIntervalSince1970
    }

    /// Your list picks for you when your turn comes (auto-pick on).
    private func runAutoPicks() {
        while made < total, seatFor(made + 1) == Self.mySeat, autoPick, let next = list.first(where: { !taken($0) }) {
            record(next, how: "auto")
        }
    }

    private func broadcast(_ kind: String) {
        for l in listeners { l.yield(RotoChange(kind: kind, picksMade: made)) }
    }

    /// The other seven pick one by one until it's your turn again.
    private func simulateOthers() {
        simulating?.cancel()
        simulating = Task { [weak self] in
            while let self, !Task.isCancelled, self.made < self.total, self.seatFor(self.made + 1) != Self.mySeat {
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled || self.paused != nil { return }
                let free = self.pool.map(\.slot).filter { !self.taken($0) }
                guard let slot = free.randomElement(using: &self.rng) else { return }
                self.record(slot, how: self.made % 5 == 0 ? "auto" : "player")
                self.runAutoPicks()
                self.broadcast("pick")
            }
        }
    }

    // MARK: RotoBackend

    func state(_ eventId: String, after: Int, pool: Bool) async throws -> RotoState { snapshot(after: after, pool: pool) }

    func pick(_ eventId: String, slot: Int, pickNo: Int) async throws -> RotoPickResult {
        try? await Task.sleep(for: .milliseconds(120))   // a normal round trip
        guard pickNo == made + 1 else { return RotoPickResult(ok: false, conflict: true, state: snapshot(after: pickNo - 1, pool: false)) }
        if taken(slot) { throw DemoError(message: "That card is already picked") }
        record(slot, how: seatFor(pickNo) == Self.mySeat ? "player" : "organizer")
        runAutoPicks()
        simulateOthers()
        return RotoPickResult(ok: true, conflict: false, state: snapshot(after: pickNo - 1, pool: false))
    }

    func undo(_ eventId: String) async throws -> RotoState {
        simulating?.cancel()
        guard let last = picks.lastIndex(where: { !$0.automatic }) else { throw DemoError(message: "Nothing to undo") }
        picks.removeSubrange(last...)
        turnStarted = Date().timeIntervalSince1970
        return snapshot(after: made, pool: false)
    }

    func queue(_ eventId: String, slots: [Int], autoPick: Bool?) async throws -> RotoQueueResult {
        var seen = Set<Int>()
        list = slots.filter { !taken($0) && seen.insert($0).inserted }
        if let autoPick { self.autoPick = autoPick }
        let before = made
        runAutoPicks()
        if made != before { simulateOthers() }
        return RotoQueueResult(queue: list, autoPick: self.autoPick, picksMade: made)
    }

    func setClock(_ eventId: String, clock: [RotoClockRange]?, paused: Bool?) async throws -> RotoState {
        if let clock { self.clock = clock.isEmpty ? nil : clock }
        if let paused {
            if paused, self.paused == nil { self.paused = Date().timeIntervalSince1970 }
            if !paused, let p = self.paused {
                turnStarted += Date().timeIntervalSince1970 - p
                self.paused = nil
                simulateOthers()
            }
        }
        return snapshot(after: made, pool: false)
    }

    func expire(_ eventId: String) async throws -> RotoExpireResult {
        RotoExpireResult(picksMade: made, overdue: true)
    }

    func changes(_ eventId: String) -> AsyncStream<RotoChange> {
        AsyncStream { c in listeners.append(c) }
    }
}

/// Deterministic shuffles for the demo.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The demo, full screen over the signed-out app: the Draft phase, or the round-robin Schedule.
struct RotoDemoRoot: View {
    @State private var store: RotoStore
    @State private var screen: String
    private let tab: RotoTab

    init() {
        let args = ProcessInfo.processInfo.arguments
        let pick = args.firstIndex(of: "-T1RotoDemo").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "grid"
        let s = RotoStore(eventId: RotoDemoBackend.eventId, backend: RotoDemoBackend())
        RotoStores.put(s)
        _store = State(initialValue: s)
        _screen = State(initialValue: pick == "schedule" ? "schedule" : "draft")
        tab = RotoTab(rawValue: pick) ?? .grid
    }

    var body: some View {
        VStack(spacing: 0) {
            T1Segmented(options: [(value: "draft", label: "Draft"), (value: "schedule", label: "Schedule")], selection: $screen)
            if screen == "schedule" {
                T1Screen {
                    Bar(title: "Roto · Vintage Cube", subtitle: "Round robin · round 3 of 7")
                    RotoScheduleView(b: RotoDemoSchedule.bundle)
                }
            } else {
                RotoDraftView(store: store, title: "Roto · Vintage Cube · Fri 17 Oct", isOrganizer: true, tab: tab)
            }
        }
        .background(T1.bg.ignoresSafeArea())
        .environment(SessionModel())
        .task {
            CatalogStore.shared.load(userInitiated: true)
            await store.load()
            await store.listen()
        }
    }
}

/// A round robin of 8 after the draft: rounds 1–2 played, round 3 running with two results in.
private enum RotoDemoSchedule {
    static let bundle: EventBundle = {
        let names = RotoDemoBackend.names.map { $0 == "You" ? "Cy Park" : $0 }
        let ids = (1...8).map { "demo-p\($0)" }
        func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T { try! wireDecoder.decode(T.self, from: Data(json.utf8)) }
        let event = decode(EventRow.self, """
        {"id": "demo-roto", "short_code": "R0T0", "name": "Roto · Vintage Cube · Fri 17 Oct", "format": "cube",
         "status": "in_progress", "number_of_rounds": 7, "current_round": 3, "format_name": "roto",
         "format_label": "Roto · Vintage Cube", "cube_name": "Vintage Cube", "pairing": "round_robin", "auto_name": true}
        """)
        let participants = (1...8).map { i in
            decode(ParticipantRow.self, """
            {"id": "\(ids[i - 1])", "event_id": "demo-roto", "display_name": "\(names[i - 1])", "seat": \(i), "status": "active",
             "user_id": \(i == 3 ? "null" : "\"u\(i)\"")}
            """)
        }
        let rounds = (1...3).map { r -> RoundRow in
            var table = 0
            var matches: [String] = []
            for a in ids {
                guard let b = RotoScheduleView.opponent(of: a, round: r, roster: ids), a < b else { continue }
                table += 1
                let done = r < 3 || table <= 2
                let (wa, wb) = done ? ((r + table) % 3 == 0 ? (1, 2) : (2, table % 2)) : (0, 0)
                matches.append("""
                {"id": "m\(r)-\(table)", "event_id": "demo-roto", "round_id": "r\(r)", "table_number": \(table), "is_bye": false,
                 "game_draws": 0, "status": "\(done ? "confirmed" : "pending")", "version": 1, "disputed": false,
                 "reported_by_user": null, "match_sides": [
                   {"id": "s\(r)-\(table)-0", "match_id": "m\(r)-\(table)", "participant_id": "\(a)", "side": 0, "game_wins": \(wa)},
                   {"id": "s\(r)-\(table)-1", "match_id": "m\(r)-\(table)", "participant_id": "\(b)", "side": 1, "game_wins": \(wb)}]}
                """)
            }
            return decode(RoundRow.self, """
            {"id": "r\(r)", "event_id": "demo-roto", "number": \(r), "status": "\(r < 3 ? "recorded" : "active")",
             "timer_ends_at": null, "matches": [\(matches.joined(separator: ","))]}
            """)
        }
        return EventBundle(event: event, participants: participants, rounds: rounds, isOrganizer: true)
    }()
}
#endif
