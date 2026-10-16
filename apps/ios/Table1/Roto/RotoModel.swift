import Foundation

// Roto (rotisserie) cube drafts: wire shapes from roto_state and friends (contract/roto-2026-10-16.md), and the
// pure turn maths the screens need. The server decides whose turn it is; the client only predicts it for display
// ("YOU PICK IN 3") with the same formula as t1_private.roto_seat_index.

enum RotoPhase: String, Decodable, Sendable { case setup, drafting, done }

/// One range of the pick clock: from this round on, each pick gets `seconds`.
struct RotoClockRange: Codable, Hashable, Sendable {
    var fromRound: Int
    var seconds: Int
}

/// A JSON value inside the positional arrays (`picks`, `pool`).
enum RotoAtom: Decodable, Sendable {
    case int(Int), double(Double), text(String), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .text(try c.decode(String.self)) }
    }
    var int: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): Int(d)
        case .text(let s): Int(s)
        case .null: nil
        }
    }
    var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .text(let s): Double(s)
        case .null: nil
        }
    }
    var text: String? { if case .text(let s) = self { s } else { nil } }
}

/// `[pick_no, seat, slot, how, at]`. `seat` is 1-based pick order; `how` is player | auto | timeout | organizer.
struct RotoPick: Decodable, Hashable, Sendable {
    let pickNo: Int
    let seat: Int
    let slot: Int
    let how: String
    let at: Double

    init(pickNo: Int, seat: Int, slot: Int, how: String, at: Double) {
        self.pickNo = pickNo
        self.seat = seat
        self.slot = slot
        self.how = how
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let a = try [RotoAtom](from: decoder)
        guard a.count >= 3, let n = a[0].int, let seat = a[1].int, let slot = a[2].int else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "roto pick"))
        }
        pickNo = n
        self.seat = seat
        self.slot = slot
        how = a.count > 3 ? (a[3].text ?? "player") : "player"
        at = a.count > 4 ? (a[4].double ?? 0) : 0
    }

    /// Picked by the server from the player's list (their turn came, or their clock ran out).
    var automatic: Bool { how == "auto" || how == "timeout" }
}

/// `[slot, card_id, finish]`: one copy in the snapshot of the cube.
struct RotoPoolCard: Decodable, Hashable, Sendable {
    let slot: Int
    let cardId: String
    let finish: String

    init(slot: Int, cardId: String, finish: String = "nonfoil") {
        self.slot = slot
        self.cardId = cardId
        self.finish = finish
    }

    init(from decoder: Decoder) throws {
        let a = try [RotoAtom](from: decoder)
        guard a.count >= 2, let slot = a[0].int, let card = a[1].text else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "roto pool card"))
        }
        self.slot = slot
        cardId = card
        finish = a.count > 2 ? (a[2].text ?? "nonfoil") : "nonfoil"
    }
}

struct RotoDraftInfo: Decodable, Hashable, Sendable {
    var picksPerPlayer = 45
    /// snake | fixed
    var pickOrder = "snake"
    var players = 0
    var poolCount = 0
    var picksMade = 0
    var totalPicks: Int?
    var sourceListId: String?
    var clock: [RotoClockRange]?
    var clockPaused = false
    var startedAt: Double?
    var finishedAt: Double?

    init() {}

    enum CodingKeys: String, CodingKey {
        case picksPerPlayer, pickOrder, players, poolCount, picksMade, totalPicks, sourceListId, clock, clockPaused, startedAt, finishedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        picksPerPlayer = try c.decodeIfPresent(Int.self, forKey: .picksPerPlayer) ?? 45
        pickOrder = try c.decodeIfPresent(String.self, forKey: .pickOrder) ?? "snake"
        players = try c.decodeIfPresent(Int.self, forKey: .players) ?? 0
        poolCount = try c.decodeIfPresent(Int.self, forKey: .poolCount) ?? 0
        picksMade = try c.decodeIfPresent(Int.self, forKey: .picksMade) ?? 0
        totalPicks = try c.decodeIfPresent(Int.self, forKey: .totalPicks)
        sourceListId = try c.decodeIfPresent(String.self, forKey: .sourceListId)
        clock = try c.decodeIfPresent([RotoClockRange].self, forKey: .clock)
        clockPaused = try c.decodeIfPresent(Bool.self, forKey: .clockPaused) ?? false
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Double.self, forKey: .finishedAt)
    }

    var snake: Bool { pickOrder != "fixed" }
    var total: Int { totalPicks ?? players * picksPerPlayer }
}

struct RotoOnClock: Decodable, Hashable, Sendable {
    let participantId: String
    var seat: Int = 0
    var pickNo: Int = 0
    var round: Int = 1
    var turnStartedAt: Double?
    var turnSeconds: Int?
    var remainingSeconds: Int?
    var deadline: Double?
    var overdue = false

    init(participantId: String, seat: Int, pickNo: Int, round: Int, turnStartedAt: Double?, turnSeconds: Int?,
         remainingSeconds: Int?, deadline: Double?, overdue: Bool) {
        self.participantId = participantId
        self.seat = seat
        self.pickNo = pickNo
        self.round = round
        self.turnStartedAt = turnStartedAt
        self.turnSeconds = turnSeconds
        self.remainingSeconds = remainingSeconds
        self.deadline = deadline
        self.overdue = overdue
    }

    enum CodingKeys: String, CodingKey {
        case participantId, seat, pickNo, round, turnStartedAt, turnSeconds, remainingSeconds, deadline, overdue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participantId = try c.decode(String.self, forKey: .participantId)
        seat = try c.decodeIfPresent(Int.self, forKey: .seat) ?? 0
        pickNo = try c.decodeIfPresent(Int.self, forKey: .pickNo) ?? 0
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 1
        turnStartedAt = try c.decodeIfPresent(Double.self, forKey: .turnStartedAt)
        turnSeconds = try c.decodeIfPresent(Int.self, forKey: .turnSeconds)
        remainingSeconds = try c.decodeIfPresent(Int.self, forKey: .remainingSeconds)
        deadline = try c.decodeIfPresent(Double.self, forKey: .deadline)
        overdue = try c.decodeIfPresent(Bool.self, forKey: .overdue) ?? false
    }
}

struct RotoSeat: Decodable, Hashable, Sendable, Identifiable {
    var id: String { participantId }
    let seat: Int?
    let participantId: String
    let displayName: String
    var account = true
    var me = false

    init(seat: Int?, participantId: String, displayName: String, account: Bool, me: Bool) {
        self.seat = seat
        self.participantId = participantId
        self.displayName = displayName
        self.account = account
        self.me = me
    }

    enum CodingKeys: String, CodingKey { case seat, participantId, displayName, account, me }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seat = try c.decodeIfPresent(Int.self, forKey: .seat)
        participantId = try c.decode(String.self, forKey: .participantId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Player"
        account = try c.decodeIfPresent(Bool.self, forKey: .account) ?? true
        me = try c.decodeIfPresent(Bool.self, forKey: .me) ?? false
    }
}

struct RotoMe: Decodable, Hashable, Sendable {
    let participantId: String
    var seat: Int?
    var queue: [Int] = []
    var autoPick = true
    var deckListId: String?

    init(participantId: String, seat: Int?, queue: [Int], autoPick: Bool, deckListId: String?) {
        self.participantId = participantId
        self.seat = seat
        self.queue = queue
        self.autoPick = autoPick
        self.deckListId = deckListId
    }

    enum CodingKeys: String, CodingKey { case participantId, seat, queue, autoPick, deckListId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participantId = try c.decode(String.self, forKey: .participantId)
        seat = try c.decodeIfPresent(Int.self, forKey: .seat)
        queue = try c.decodeIfPresent([Int].self, forKey: .queue) ?? []
        autoPick = try c.decodeIfPresent(Bool.self, forKey: .autoPick) ?? true
        deckListId = try c.decodeIfPresent(String.self, forKey: .deckListId)
    }
}

/// roto_state (and the state inside roto_pick / roto_undo / roto_set_clock / roto_start answers).
struct RotoState: Decodable, Sendable {
    let eventId: String
    var phase: RotoPhase = .setup
    var draft = RotoDraftInfo()
    var onClock: RotoOnClock?
    var seats: [RotoSeat] = []
    var picks: [RotoPick] = []
    var pool: [RotoPoolCard]?
    var me: RotoMe?

    init(eventId: String, phase: RotoPhase, draft: RotoDraftInfo, onClock: RotoOnClock?, seats: [RotoSeat], picks: [RotoPick],
         pool: [RotoPoolCard]?, me: RotoMe?) {
        self.eventId = eventId
        self.phase = phase
        self.draft = draft
        self.onClock = onClock
        self.seats = seats
        self.picks = picks
        self.pool = pool
        self.me = me
    }

    enum CodingKeys: String, CodingKey { case eventId, phase, draft, onClock, seats, picks, pool, me }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(String.self, forKey: .eventId)
        phase = try c.decodeIfPresent(RotoPhase.self, forKey: .phase) ?? .setup
        draft = try c.decodeIfPresent(RotoDraftInfo.self, forKey: .draft) ?? RotoDraftInfo()
        onClock = try c.decodeIfPresent(RotoOnClock.self, forKey: .onClock)
        seats = try c.decodeIfPresent([RotoSeat].self, forKey: .seats) ?? []
        picks = try c.decodeIfPresent([RotoPick].self, forKey: .picks) ?? []
        pool = try c.decodeIfPresent([RotoPoolCard].self, forKey: .pool)
        me = try c.decodeIfPresent(RotoMe.self, forKey: .me)
    }
}

struct RotoPickResult: Decodable, Sendable {
    let ok: Bool
    var conflict: Bool?
    let state: RotoState
}

struct RotoQueueResult: Decodable, Sendable {
    let queue: [Int]
    let autoPick: Bool
    let picksMade: Int
}

struct RotoExpireResult: Decodable, Sendable {
    let picksMade: Int
    let overdue: Bool
}

struct RotoCubeResult: Decodable, Sendable {
    let eventId: String
    var sourceListId: String?
    var cubeName: String?
    let poolCount: Int
    let players: Int
    let maxPicksPerPlayer: Int
}

/// A realtime `roto_changed` message: started | pick | timeout | undo | clock.
struct RotoChange: Sendable {
    let kind: String
    let picksMade: Int?
}

// MARK: turn maths (mirrors t1_private.roto_seat_index / roto_round)

enum RotoMath {
    /// 1-based seat on the clock for a pick. Snake reverses every other round.
    static func seat(players: Int, pickNo: Int, snake: Bool) -> Int {
        guard players > 0, pickNo > 0 else { return 0 }
        let i = (pickNo - 1) % players
        let backwards = snake && ((pickNo - 1) / players) % 2 == 1
        return backwards ? players - i : i + 1
    }

    /// 1-based round of a pick.
    static func round(players: Int, pickNo: Int) -> Int {
        guard players > 0, pickNo > 0 else { return 1 }
        return (pickNo - 1) / players + 1
    }

    /// The pick number at (seat, round): the cell of the classic roto sheet.
    static func pickNo(seat: Int, round: Int, players: Int, snake: Bool) -> Int {
        let backwards = snake && (round - 1) % 2 == 1
        let index = backwards ? players - seat : seat - 1
        return (round - 1) * players + index + 1
    }

    /// Picks other people make before `seat` is next on the clock (0 = it's their pick); nil when they have no
    /// picks left.
    static func picksUntil(seat: Int, picksMade: Int, players: Int, total: Int, snake: Bool) -> Int? {
        guard players > 0, seat > 0 else { return nil }
        var n = picksMade + 1
        // At most one full lap (two in snake order) separates a seat from its next pick.
        while n <= total && n <= picksMade + 2 * players {
            if self.seat(players: players, pickNo: n, snake: snake) == seat { return n - picksMade - 1 }
            n += 1
        }
        return nil
    }

    /// Seconds per pick in a round from the schedule (the last range starting at or before it); nil = no clock.
    static func clockSeconds(_ clock: [RotoClockRange]?, round: Int) -> Int? {
        clock?.filter { $0.fromRound <= round }.max { $0.fromRound < $1.fromRound }?.seconds
    }

    /// "4 H", "1 H 30 MIN", "45 MIN", "30 S".
    static func durationText(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        if m > 0 { return s > 0 ? "\(m) min \(s) s" : "\(m) min" }
        return "\(s) s"
    }

    /// "1:42:10", "4:05", "0:09".
    static func countdownText(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    /// Round robin: rounds when everyone plays everyone once (n − 1, or n with a bye each round when odd).
    static func roundRobinRounds(players: Int) -> Int {
        guard players >= 2 else { return 1 }
        return players % 2 == 0 ? players - 1 : players
    }

    /// The pairing a roto prefills: round robin for 2–8 players, Swiss for 9 or more.
    static func defaultPairing(players: Int) -> String { players >= 9 ? "swiss" : "round_robin" }
}

// MARK: merging deltas

enum RotoMerge {
    /// Folds a `roto_state(p_after_pick = after)` answer into the picks held. Picks above the server's
    /// `picksMade` are dropped (an undo); new picks replace any held at the same number.
    /// `needsFull` is true when the delta can't be trusted to repair what's held: the server is behind what was
    /// held (an undo, possibly followed by new picks at the same numbers), a card shows up at two pick numbers,
    /// or numbers are missing. Fetch every pick again (`after = 0`, no pool) then; it's one small call.
    static func apply(held: [RotoPick], delta: [RotoPick], picksMade: Int) -> (picks: [RotoPick], needsFull: Bool) {
        var byNo: [Int: RotoPick] = [:]
        for p in held where p.pickNo <= picksMade { byNo[p.pickNo] = p }
        for p in delta where p.pickNo <= picksMade { byNo[p.pickNo] = p }
        let picks = byNo.values.sorted { $0.pickNo < $1.pickNo }
        let heldTop = held.map(\.pickNo).max() ?? 0
        let duplicateSlot = Set(picks.map(\.slot)).count != picks.count
        let gap = picks.count != (picks.last?.pickNo ?? 0)
        return (picks, picksMade < heldTop || duplicateSlot || gap)
    }
}
