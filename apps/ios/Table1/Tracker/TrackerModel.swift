import Foundation
import Observation

// MARK: wire

/// The counters a player can track. Life starts at the session's starting life, everything else at 0.
enum TrackerCounter: Hashable, Identifiable {
    case life, poison, energy, experience, rad, speed
    /// Commander damage this side has taken from side `from`'s commander (wire `cmd:<from>`; local sessions
    /// only). It comes off life: see `TrackerModel.total`.
    case commander(Int)

    init?(rawValue: String) {
        switch rawValue {
        case "life": self = .life
        case "poison": self = .poison
        case "energy": self = .energy
        case "experience": self = .experience
        case "rad": self = .rad
        case "speed": self = .speed
        default:
            guard rawValue.hasPrefix("cmd:"), let from = Int(rawValue.dropFirst(4)), from >= 0 else { return nil }
            self = .commander(from)
        }
    }

    var rawValue: String {
        switch self {
        case .life: "life"
        case .poison: "poison"
        case .energy: "energy"
        case .experience: "experience"
        case .rad: "rad"
        case .speed: "speed"
        case .commander(let from): "cmd:\(from)"
        }
    }

    var id: String { rawValue }
    /// Commander damage needs the players' names: `TrackerModel.label(_:)`.
    var label: String {
        switch self {
        case .life: "Life"
        case .poison: "Poison"
        case .energy: "Energy"
        case .experience: "Experience"
        case .rad: "Rad"
        case .speed: "Speed"
        case .commander: "Commander"
        }
    }
    var range: ClosedRange<Int> {
        switch self {
        case .life: -999...999
        case .speed: 0...4
        default: 0...999
        }
    }
    /// Column label; "Experience" doesn't fit a narrow column.
    var shortLabel: String {
        switch self {
        case .experience: "Exp"
        case .commander: "Cmd"
        default: label
        }
    }
    var commanderFrom: Int? {
        if case .commander(let from) = self { return from }
        return nil
    }
    /// Counters that can be shown as columns next to life.
    static let extras: [TrackerCounter] = [.poison, .energy, .experience, .rad, .speed]
}

/// The match's round timer, as tracker_state returns it and a rounds UPDATE carries it.
/// Running: remaining = remaining_at_change − (now − last_started_at), negative in overtime.
/// Paused: remaining_at_change (nil = the full duration).
struct TrackerClock: Decodable, Equatable {
    var roundId: String
    var timerStatus: String
    var timerLastStartedAt: String?
    var timerRemainingAtChange: Int?
    var timerDurationSeconds: Int

    enum Tone { case normal, warning, overtime }
    /// Amber for the last 10 minutes (the organizer screen keeps its own threshold).
    static let warnSeconds = 600

    func remaining(at now: Date) -> Int {
        let base = timerRemainingAtChange ?? timerDurationSeconds
        guard timerStatus == "running", let s = timerLastStartedAt, let started = TrackerTime.parse(s) else { return base }
        return base - Int(floor(now.timeIntervalSince(started)))
    }

    static func tone(_ remaining: Int) -> Tone {
        remaining < 0 ? .overtime : remaining <= warnSeconds ? .warning : .normal
    }

    /// "42:52", "6:12", "+0:42" in overtime.
    static func format(_ remaining: Int) -> String {
        let a = abs(remaining)
        let text = "\(a / 60):" + String(format: "%02d", a % 60)
        return remaining < 0 ? "+" + text : text
    }

    /// Share of the bar to fill: time left over the round length; full in overtime.
    func progress(_ remaining: Int) -> Double {
        if remaining < 0 { return 1 }
        return timerDurationSeconds > 0 ? min(1, Double(remaining) / Double(timerDurationSeconds)) : 0
    }
}

/// A rounds row from Realtime, reduced to the clock.
struct RoundClockRecord: Decodable {
    let id: String
    let timerStatus: String
    let timerLastStartedAt: String?
    let timerRemainingAtChange: Int?
    let timerDurationSeconds: Int?

    func clock(previous: TrackerClock?) -> TrackerClock {
        TrackerClock(roundId: id, timerStatus: timerStatus, timerLastStartedAt: timerLastStartedAt,
                     timerRemainingAtChange: timerRemainingAtChange,
                     timerDurationSeconds: timerDurationSeconds ?? previous?.timerDurationSeconds ?? 0)
    }
}

/// One tap. Groups ("Life −5") are derived for display and never stored.
struct TrackerOp: Codable, Hashable, Identifiable {
    var clientOpId: String
    var gameNo: Int
    var side: Int
    var counter: String
    var delta: Int
    var tappedAt: String
    var mine: Bool?
    /// Parsed `tappedAt` (kept to the millisecond, so 2-second grouping is exact).
    var at: Date

    var id: String { clientOpId }
    var kind: TrackerCounter? { TrackerCounter(rawValue: counter) }

    enum CodingKeys: String, CodingKey { case clientOpId, gameNo, side, counter, delta, tappedAt, mine }

    /// `tappedAt` overrides the stamp (an undo reuses the undone group's last tap time verbatim).
    init(clientOpId: String, gameNo: Int, side: Int, counter: String, delta: Int, at: Date, mine: Bool?,
         tappedAt: String? = nil) {
        self.clientOpId = clientOpId.lowercased()
        self.gameNo = gameNo
        self.side = side
        self.counter = counter
        self.delta = delta
        self.tappedAt = tappedAt ?? TrackerTime.string(at)
        self.mine = mine
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientOpId = try c.decode(String.self, forKey: .clientOpId).lowercased()
        gameNo = try c.decode(Int.self, forKey: .gameNo)
        side = try c.decode(Int.self, forKey: .side)
        counter = try c.decode(String.self, forKey: .counter)
        delta = try c.decode(Int.self, forKey: .delta)
        tappedAt = try c.decodeIfPresent(String.self, forKey: .tappedAt) ?? TrackerTime.string(Date())
        mine = try c.decodeIfPresent(Bool.self, forKey: .mine)
        at = TrackerTime.parse(tappedAt) ?? Date()
    }
}

/// A tracker_ops row as Realtime delivers it (actor instead of `mine`).
struct TrackerOpRecord: Decodable {
    let clientOpId: String
    let gameNo: Int
    let side: Int
    let counter: String
    let delta: Int
    let tappedAt: String?
    let actor: String?

    func op(me: String?) -> TrackerOp {
        let at = tappedAt.flatMap(TrackerTime.parse) ?? Date()
        let mine = me != nil && actor?.lowercased() == me
        return TrackerOp(clientOpId: clientOpId, gameNo: gameNo, side: side, counter: counter, delta: delta, at: at, mine: mine)
    }
}

struct TrackerGame: Codable, Hashable, Identifiable {
    var gameNo: Int
    var winnerSide: Int?
    var isDraw: Bool
    var recordedAt: String?
    var id: Int { gameNo }

    enum CodingKeys: String, CodingKey { case gameNo, winnerSide, isDraw, recordedAt }

    init(gameNo: Int, winnerSide: Int?, isDraw: Bool, recordedAt: String?) {
        self.gameNo = gameNo
        self.winnerSide = winnerSide
        self.isDraw = isDraw
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameNo = try c.decode(Int.self, forKey: .gameNo)
        winnerSide = try c.decodeIfPresent(Int.self, forKey: .winnerSide)
        isDraw = try c.decodeIfPresent(Bool.self, forKey: .isDraw) ?? false
        recordedAt = try c.decodeIfPresent(String.self, forKey: .recordedAt)
    }
}

/// tracker_open / tracker_state / tracker_record_game.
struct TrackerState: Decodable {
    let sessionId: String
    let matchId: String?
    let eventId: String?
    let startingLife: Int?
    let mySide: Int?
    /// The organizer keeping score for a match with no accounts (guests only); they report as organizer.
    let keeper: Bool?
    /// The match's result is in (reported, confirmed or disputed): no more games can be recorded.
    let resultIn: Bool?
    let names: [String]?
    let eventName: String?
    let round: Int?
    let table: Int?
    let clock: TrackerClock?
    let games: [TrackerGame]?
    let ops: [TrackerOp]?
}

struct TrackerPushResult: Decodable { let inserted: Int?; let gameNo: Int? }

enum TrackerTime {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func string(_ date: Date) -> String { fractional.string(from: date) }

    /// Postgres prints microseconds; ISO8601DateFormatter reads milliseconds, so the fraction is cut to 3 digits.
    static func parse(_ s: String) -> Date? {
        var trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "T")
        // "+00" (Postgres text output) → "+00:00"
        if trimmed.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil { trimmed += ":00" }
        return fractional.date(from: trimmed) ?? T1Date.parse(trimmed)
    }
}

// MARK: model

/// One life-tracking session: local (no event, kept on this device) or synced to a match.
///
/// Every tap is an op; totals are starting value + the sum of a game's deltas. Synced sessions push
/// ops in batches every 300 ms from a persisted queue (retried with backoff) and merge the other
/// phone's ops from Realtime by client_op_id.
@MainActor
@Observable
final class TrackerModel {
    enum Phase { case loading, ready, failed(String) }

    /// A run of taps on one side + counter, each < 2 s after the previous one.
    struct ChangeGroup: Identifiable {
        let id: String
        let game: Int
        let side: Int
        let counter: TrackerCounter
        var delta: Int
        var result: Int
        var start: Date
        var end: Date
        /// The last tap's tapped_at exactly as stored, so an inverse op sorts and groups right after it.
        var lastTappedAt: String
        var opIds: [String]
        var mine: Bool?
    }

    static let groupGap: TimeInterval = 2.0

    let matchId: String?
    var phase: Phase = .loading
    var sessionId: String?
    /// The match's result is in, so Record is off (contract/life-tracker-options-2026-10-20.md § After the result is in).
    var resultIn = false
    var eventName: String?
    var round: Int?
    var table: Int?
    /// The round clock; nil for local sessions and matches without a round.
    var clock: TrackerClock?
    var startingLife = 20
    /// Which side this phone plays. Local sessions: 0 ("You"). Organizer watching: nil (read-only).
    var mySide: Int? = 0
    var keeper = false
    var names = ["You", "Opponent"]
    var games: [TrackerGame] = []
    var ops: [TrackerOp] = []
    /// Which counters each side shows as columns: turned on, or turned off (hides a non-zero one).
    /// A per-device display choice, kept per match.
    struct CounterPrefs: Codable { var on: [String] = []; var off: [String] = [] }
    var counterPrefs: [CounterPrefs] = [CounterPrefs(), CounterPrefs()]
    static let maxCounters = 3
    /// Bumped whenever a recorded game decides the match (so the screen can prompt once).
    var decidedSignal = 0
    var offline = false

    @ObservationIgnored private var queue: [TrackerOp] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pushing = false
    @ObservationIgnored private var backoff: Double = 0

    init(matchId: String?) {
        self.matchId = matchId
        loadCounterPrefs()
    }

    var isSynced: Bool { matchId != nil }
    var readOnly: Bool { isSynced && mySide == nil }
    /// Record is offered while the match is still open: never once its result has been submitted.
    var canRecord: Bool { !readOnly && !(isSynced && resultIn) }
    /// My half sits at the bottom; the organizer watching sees side 0 at the bottom.
    var bottomSide: Int { mySide ?? 0 }
    var topSide: Int { 1 - bottomSide }
    var currentGame: Int { games.count + 1 }

    func name(_ side: Int) -> String { names.indices.contains(side) ? names[side] : (side == bottomSide ? "You" : "Opponent") }

    /// 2 for every synced match; 2–5 for a local table.
    var players: Int { names.count }
    var sides: Range<Int> { 0..<players }

    /// Local tables starting at 30 or more life track commander damage (contract/life-tracker-commander-2026-11-03.md).
    var commanderDamage: Bool { !isSynced && startingLife >= TrackerTable.commanderFrom }

    /// "Commander P3", "Cmd P3"; just "Commander" / "Cmd" when there's one opponent.
    func label(_ counter: TrackerCounter) -> String {
        guard let from = counter.commanderFrom, players > 2 else { return counter.label }
        return "\(counter.label) \(name(from))"
    }

    func shortLabel(_ counter: TrackerCounter) -> String {
        guard let from = counter.commanderFrom, players > 2 else { return counter.shortLabel }
        return "\(counter.shortLabel) \(name(from))"
    }

    // MARK: totals

    /// Life also loses every point of commander damage the side has taken.
    func total(_ side: Int, _ counter: TrackerCounter, game: Int? = nil) -> Int {
        let g = game ?? currentGame
        let base = counter == .life ? startingLife : 0
        let key = counter.rawValue
        return ops.reduce(base) { sum, op in
            guard op.gameNo == g, op.side == side else { return sum }
            if op.counter == key { return sum + op.delta }
            if counter == .life, op.counter.hasPrefix("cmd:") { return sum - op.delta }
            return sum
        }
    }

    func wins(_ side: Int) -> Int { games.filter { !$0.isDraw && $0.winnerSide == side }.count }
    var draws: Int { games.filter(\.isDraw).count }
    /// My game wins first; with three or more, every player's ("P1 1 · P2 0 · P3 2").
    var scoreText: String {
        guard players > 2 else { return "\(wins(bottomSide))–\(wins(topSide))" }
        return sides.map { "\(name($0)) \(wins($0))" }.joined(separator: " · ")
    }
    /// Best of three with two players; a multiplayer table just plays game after game.
    var matchDecided: Bool { players == 2 && (wins(0) >= 2 || wins(1) >= 2 || games.count >= 3) }
    var reportText: String {
        let base = "\(wins(bottomSide))–\(wins(topSide))"
        return draws > 0 ? "\(base)–\(draws)" : base
    }

    /// What the counter picker lists: commander damage from each opponent first (when it counts), then the rest.
    func pickerCounters(_ side: Int) -> [TrackerCounter] {
        let commander = commanderDamage ? sides.filter { $0 != side }.map(TrackerCounter.commander) : []
        return commander + TrackerCounter.extras
    }

    /// Columns next to life: counters turned on, plus any that aren't zero (so poison you dealt shows
    /// on the other phone) unless turned off. Three at most.
    func visibleCounters(_ side: Int) -> [TrackerCounter] {
        guard counterPrefs.indices.contains(side) else { return [] }
        let p = counterPrefs[side]
        return Array(pickerCounters(side).filter {
            p.on.contains($0.rawValue) || (total(side, $0) != 0 && !p.off.contains($0.rawValue))
        }.prefix(Self.maxCounters))
    }

    func toggleCounter(_ counter: TrackerCounter, side: Int) {
        var p = counterPrefs[side]
        let key = counter.rawValue
        if visibleCounters(side).contains(counter) {
            p.on.removeAll { $0 == key }
            p.off.removeAll { $0 == key }
            p.off.append(key)
        } else {
            guard visibleCounters(side).count < Self.maxCounters else { return }
            p.off.removeAll { $0 == key }
            p.on.removeAll { $0 == key }
            p.on.append(key)
        }
        counterPrefs[side] = p
        saveCounterPrefs()
    }

    private var counterPrefsKey: String { "tracker.counters.\(matchId ?? "local")" }

    private func loadCounterPrefs() {
        guard let data = UserDefaults.standard.data(forKey: counterPrefsKey),
              let prefs = try? JSONDecoder().decode([CounterPrefs].self, from: data), prefs.count == players else {
            counterPrefs = Array(repeating: CounterPrefs(), count: players)
            return
        }
        counterPrefs = prefs
    }

    private func saveCounterPrefs() {
        if let data = try? JSONEncoder().encode(counterPrefs) { UserDefaults.standard.set(data, forKey: counterPrefsKey) }
    }

    /// This game is over for the side: life ≤ 0, poison ≥ 10, or 21 commander damage from one opponent.
    func hasLost(_ side: Int) -> Bool {
        if total(side, .life) <= 0 || total(side, .poison) >= 10 { return true }
        return commanderDamage && sides.contains { $0 != side && total(side, .commander($0)) >= TrackerTable.commanderLoss }
    }

    /// Who has won this game, once it's settled: the other side when one of two has lost, or the last player
    /// standing at a bigger table. Record turns accent and is pre-filled.
    var settledWinner: Int? {
        if players == 2 {
            // The opponent's half is checked first, as before.
            if hasLost(topSide) { return bottomSide }
            if hasLost(bottomSide) { return topSide }
            return nil
        }
        let left = sides.filter { !hasLost($0) }
        return left.count == 1 ? left[0] : nil
    }

    // MARK: history

    /// One entry per change group, oldest first, including groups an undo brought to a net 0
    /// (history hides those; see `visibleGroups`). Ops are sorted by tapped_at, then arrival order,
    /// so every device groups the same way.
    func groups(game: Int) -> [ChangeGroup] {
        let list = ops.enumerated()
            .filter { $0.element.gameNo == game && $0.element.kind != nil }
            .sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at }
            .map { $0.element }
        var running: [String: Int] = [:]
        var out: [ChangeGroup] = []
        for op in list {
            guard let kind = op.kind else { continue }
            let key = "\(op.side)-\(op.counter)"
            let value = (running[key] ?? (kind == .life ? startingLife : 0)) + op.delta
            running[key] = value
            if kind.commanderFrom != nil {
                // Commander damage comes off life, so a later life group's result counts it.
                let life = "\(op.side)-life"
                running[life] = (running[life] ?? startingLife) - op.delta
            }
            if var last = out.last, last.side == op.side, last.counter == kind,
               op.at.timeIntervalSince(last.end) < Self.groupGap {
                last.delta += op.delta
                last.result = value
                last.end = max(last.end, op.at)
                last.lastTappedAt = op.tappedAt
                last.opIds.append(op.clientOpId)
                out[out.count - 1] = last
            } else {
                out.append(ChangeGroup(id: op.clientOpId, game: game, side: op.side, counter: kind, delta: op.delta,
                                 result: value, start: op.at, end: op.at, lastTappedAt: op.tappedAt,
                                 opIds: [op.clientOpId], mine: op.mine))
            }
        }
        return out
    }

    /// Groups with a non-zero net change (an undone group nets to 0 and drops out on every device).
    func visibleGroups(game: Int) -> [ChangeGroup] { groups(game: game).filter { $0.delta != 0 } }

    var canUndo: Bool { !readOnly && !visibleGroups(game: currentGame).isEmpty }
    var hasHistory: Bool { (1...currentGame).contains { !visibleGroups(game: $0).isEmpty } }

    // MARK: changes

    /// One tap (or one hold-repeat step). Clamped to the counter's range. Returns the change's id (nil when
    /// nothing changed) so a touch that turns into a swipe can take it back.
    @discardableResult
    func tap(side: Int, counter: TrackerCounter, delta: Int) -> String? {
        guard !readOnly, case .ready = phase else { return nil }
        let current = total(side, counter)
        let next = min(max(current + delta, counter.range.lowerBound), counter.range.upperBound)
        guard next != current else { return nil }
        return add(side: side, counter: counter, delta: next - current).clientOpId
    }

    /// Takes back one tap: dropped outright while it hasn't left this phone, otherwise cancelled by an
    /// inverse op stamped like it (the group nets to 0 and drops out of history, as with undo).
    func retract(_ opId: String) {
        guard let i = ops.lastIndex(where: { $0.clientOpId == opId }) else { return }
        let op = ops[i]
        if !isSynced {
            ops.remove(at: i)
            saveLocal()
        } else if !pushing, let q = queue.firstIndex(where: { $0.clientOpId == opId }) {
            queue.remove(at: q)
            ops.remove(at: i)
            saveQueue()
        } else if let kind = op.kind {
            let stamp = ChangeGroup(id: op.clientOpId, game: op.gameNo, side: op.side, counter: kind, delta: op.delta,
                                    result: 0, start: op.at, end: op.at, lastTappedAt: op.tappedAt,
                                    opIds: [op.clientOpId], mine: op.mine)
            add(side: op.side, counter: kind, delta: -op.delta, stampedLike: stamp)
        }
    }

    @discardableResult
    private func add(side: Int, counter: TrackerCounter, delta: Int, stampedLike group: ChangeGroup? = nil) -> TrackerOp {
        let op = TrackerOp(clientOpId: UUID().uuidString, gameNo: group?.game ?? currentGame, side: side,
                           counter: counter.rawValue, delta: delta, at: group?.end ?? Date(),
                           mine: isSynced ? true : nil, tappedAt: group?.lastTappedAt)
        ops.append(op)
        if isSynced {
            queue.append(op)
            saveQueue()
            scheduleFlush(after: 0.3)
        } else {
            saveLocal()
        }
        return op
    }

    /// Undoes the newest group with a non-zero net: one inverse op stamped with that group's last tap
    /// time, so on every device it sorts right after the group, merges into it and nets it to 0.
    func undoLast() {
        guard !readOnly, let last = visibleGroups(game: currentGame).last else { return }
        add(side: last.side, counter: last.counter, delta: -last.delta, stampedLike: last)
    }

    /// Back to starting values for the current game.
    func resetGame() {
        guard !readOnly else { return }
        let game = currentGame
        if isSynced {
            // One inverse per non-zero group, each stamped like the group it cancels.
            for group in visibleGroups(game: game) {
                add(side: group.side, counter: group.counter, delta: -group.delta, stampedLike: group)
            }
        } else {
            ops.removeAll { $0.gameNo == game }
            saveLocal()
        }
    }

    /// Reset can also clear the games: only on this device's own (local) games, never an event's recorded ones.
    var canResetMatch: Bool { !isSynced && !games.isEmpty }

    /// Local only: games and every game's totals back to the start; names, starting life and columns stay.
    func resetMatch() {
        guard !isSynced else { return resetGame() }
        games = []
        ops = []
        saveLocal()
    }

    /// Local only: a new table from Setup. Clears games, history and counter columns, names the players.
    func configure(players: Int, life: Int) {
        guard !isSynced else { return }
        names = TrackerTable.names(min(max(players, 2), 5))
        startingLife = life
        games = []
        ops = []
        counterPrefs = Array(repeating: CounterPrefs(), count: self.players)
        saveCounterPrefs()
        saveLocal()
    }

    /// Local only: clears games and history, keeps names and starting life.
    func newMatch() {
        guard !isSynced else { return }
        games = []
        ops = []
        counterPrefs = Array(repeating: CounterPrefs(), count: players)
        saveCounterPrefs()
        saveLocal()
    }

    /// Called only after the player confirmed. Synced: pushes pending taps first, then the server records.
    func record(winner: Int?, draw: Bool) async throws {
        guard canRecord else { return }
        let game = currentGame
        let before = games.count
        if let sid = sessionId, isSynced {
            await flushNow()
            let state: TrackerState
            do {
                state = try await Repo.trackerRecordGame(sid, gameNo: game, winnerSide: draw ? nil : winner, draw: draw)
            } catch {
                // Refused because the result came in meanwhile (from the other phone or the event screen):
                // read the state so Record turns off, then say why.
                await refetch()
                throw error
            }
            apply(state)
        } else {
            games.append(TrackerGame(gameNo: game, winnerSide: draw ? nil : winner, isDraw: draw,
                                     recordedAt: TrackerTime.string(Date())))
            saveLocal()
        }
        gamesChanged(from: before)
    }

    /// Reports the tracked match through the usual report_match path (side-oriented scores).
    func report() async throws {
        guard let matchId, let side = mySide else { return }
        if keeper {
            try await Repo.setMatchResult(matchId, side0: wins(0), side1: wins(1), draws: draws, reason: "Life tracker")
            resultIn = true
            return
        }
        try await LiveAPI.report(matchId: matchId, mySide: side, my: wins(side), their: wins(1 - side),
                                 draws: draws, version: nil)
        resultIn = true
    }

    private func gamesChanged(from before: Int) {
        guard games.count > before else { return }
        if matchDecided { decidedSignal += 1 }
    }

    // MARK: lifecycle

    /// Loads the session; synced sessions then follow the other phone until the view goes away.
    func start() async {
        guard let matchId else {
            loadLocal()
            phase = .ready
            return
        }
        do {
            let state = try await Repo.trackerOpen(matchId: matchId)
            apply(state, initial: true)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        scheduleFlush(after: 0)
        guard let sid = sessionId else { return }
        for await change in Repo.trackerChanges(sid, roundId: clock?.roundId) {
            switch change {
            case .op(let op):
                if !ops.contains(where: { $0.clientOpId == op.clientOpId }) { ops.append(op) }
            case .game(let game):
                if !games.contains(where: { $0.gameNo == game.gameNo }) {
                    let before = games.count
                    games.append(game)
                    games.sort { $0.gameNo < $1.gameNo }
                    gamesChanged(from: before)
                }
            case .clock(let record):
                clock = record.clock(previous: clock)
            case .subscribed:
                await refetch()
            }
        }
    }

    func refetch() async {
        guard let sid = sessionId, let state = try? await Repo.trackerState(sid) else { return }
        let before = games.count
        apply(state)
        gamesChanged(from: before)
    }

    /// Server state plus anything still waiting in the queue.
    private func apply(_ state: TrackerState, initial: Bool = false) {
        if initial || sessionId != state.sessionId {
            sessionId = state.sessionId
            queue = loadQueue(state.sessionId)
        }
        startingLife = state.startingLife ?? 20
        mySide = state.mySide
        keeper = state.keeper ?? false
        resultIn = state.resultIn ?? false
        if let n = state.names, n.count == 2 { names = n }
        eventName = state.eventName
        round = state.round
        table = state.table
        clock = state.clock
        games = (state.games ?? []).sorted { $0.gameNo < $1.gameNo }
        var merged = state.ops ?? []
        var known = Set(merged.map(\.clientOpId))
        for op in queue where !known.contains(op.clientOpId) {
            merged.append(op)
            known.insert(op.clientOpId)
        }
        ops = merged
    }

    // MARK: sync

    private func scheduleFlush(after delay: Double) {
        guard isSynced, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    /// Sends what's queued now (before recording a game, on background, on close).
    func flushNow() async {
        guard isSynced else { return }
        flushTask?.cancel()
        flushTask = nil
        var waited = 0
        while pushing && waited < 60 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        await flush()
    }

    private func flush() async {
        guard !pushing, let sid = sessionId, !readOnly, !queue.isEmpty else { return }
        pushing = true
        let batch = Array(queue.prefix(200))
        do {
            let result = try await Repo.trackerPush(sid, ops: batch)
            pushing = false
            let sent = Set(batch.map(\.clientOpId))
            queue.removeAll { sent.contains($0.clientOpId) }
            saveQueue()
            backoff = 0
            offline = false
            if let serverGame = result.gameNo, serverGame > currentGame { await refetch() }
            if !queue.isEmpty { scheduleFlush(after: 0.05) }
        } catch {
            pushing = false
            backoff = min(max(backoff * 2, 1), 30)
            offline = true
            scheduleFlush(after: backoff)
        }
    }

    // MARK: storage (this device)

    private struct LocalSave: Codable {
        var startingLife: Int
        var names: [String]
        var games: [TrackerGame]
        var ops: [TrackerOp]
    }

    private static let localKey = "tracker.local.v1"
    private var defaults: UserDefaults { .standard }

    private func saveLocal() {
        guard !isSynced else { return }
        let save = LocalSave(startingLife: startingLife, names: names, games: games, ops: ops)
        if let data = try? JSONEncoder().encode(save) { defaults.set(data, forKey: Self.localKey) }
    }

    private func loadLocal() {
        guard let data = defaults.data(forKey: Self.localKey),
              let save = try? JSONDecoder().decode(LocalSave.self, from: data) else { return }
        startingLife = save.startingLife
        if TrackerTable.playerChoices.contains(save.names.count) { names = save.names }
        games = save.games
        ops = save.ops
        loadCounterPrefs()
    }

    private func saveQueue() {
        guard let sid = sessionId else { return }
        if queue.isEmpty {
            defaults.removeObject(forKey: "tracker.queue.\(sid)")
        } else if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: "tracker.queue.\(sid)")
        }
    }

    private func loadQueue(_ sid: String) -> [TrackerOp] {
        guard let data = defaults.data(forKey: "tracker.queue.\(sid)") else { return [] }
        return (try? JSONDecoder().decode([TrackerOp].self, from: data)) ?? []
    }
}
