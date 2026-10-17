import Foundation

// Wire models. Server JSON is snake_case and decoded with .convertFromSnakeCase,
// so property names here are the camelCase form of the column names.

struct EventRow: Decodable, Identifiable, Hashable {
    let id: String
    let shortCode: String
    let name: String
    var format: String = "draft"
    var status: String = "setup"
    var numberOfRounds: Int = 3
    var currentRound: Int = 0
    var roundLengthSeconds: Int = 3000
    var allowPlayerReporting: Bool = true
    var venueName: String?
    var createdAt: String?
    var cancelReason: String?
    var isDemo = false
    // Typed formats (2026-10-13). Optional so rows from before the migration still decode.
    var formatName: String?
    var formatLabel: String?
    var eventType: String?
    var teamSize: Int?
    var setCode: String?
    var setName: String?
    var cubeName: String?
    var cubeUrl: String?
    var formatOther: String?
    /// nearby | link_only | private
    var visibility: String?
    var startsAt: String?
    var cancelledAt: String?
    var updatedAt: String?
    /// "Round timer" on: clocks are shown. Rounds always run 50 minutes either way.
    var showClock = true
    /// Named from its settings ("Draft · Duskmourn · Fri 17 Oct"); older events keep their typed names.
    var autoName = false
    /// Draft seating: players at the two ends of the table too (drawing only).
    var seatEnds = false
    /// swiss | round_robin (round robin is roto only for now).
    var pairing = "swiss"

    var isCancelled: Bool { status == "cancelled" }
    var isFinished: Bool { ["completed", "archived", "cancelled"].contains(status) }
    /// "Modern", "Draft · Duskmourn", "Team draft · Vintage Cube".
    var label: String { formatLabel ?? format.capitalized }
    var isDraft: Bool { ["draft", "team_draft"].contains(formatName ?? format) }
    var isTeamEvent: Bool { teamSize != nil || ["team_draft", "team_sealed"].contains(formatName ?? "") }
    /// Seats and teams can change until round 1 is paired.
    var isBeforeRound1: Bool { ["setup", "seated"].contains(status) && currentRound == 0 }

    enum CodingKeys: String, CodingKey {
        case id, shortCode, name, format, status, numberOfRounds, currentRound, roundLengthSeconds,
             allowPlayerReporting, venueName, createdAt, cancelReason, isDemo,
             formatName, formatLabel, eventType, teamSize, setCode, setName, cubeName, cubeUrl,
             formatOther, visibility, startsAt, cancelledAt, updatedAt, showClock, autoName, seatEnds, pairing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        shortCode = try c.decode(String.self, forKey: .shortCode)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "draft"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "setup"
        numberOfRounds = try c.decodeIfPresent(Int.self, forKey: .numberOfRounds) ?? 3
        currentRound = try c.decodeIfPresent(Int.self, forKey: .currentRound) ?? 0
        roundLengthSeconds = try c.decodeIfPresent(Int.self, forKey: .roundLengthSeconds) ?? 3000
        allowPlayerReporting = try c.decodeIfPresent(Bool.self, forKey: .allowPlayerReporting) ?? true
        venueName = try c.decodeIfPresent(String.self, forKey: .venueName)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        cancelReason = try c.decodeIfPresent(String.self, forKey: .cancelReason)
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
        formatName = try c.decodeIfPresent(String.self, forKey: .formatName)
        formatLabel = try c.decodeIfPresent(String.self, forKey: .formatLabel)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        teamSize = try c.decodeIfPresent(Int.self, forKey: .teamSize)
        setCode = try c.decodeIfPresent(String.self, forKey: .setCode)
        setName = try c.decodeIfPresent(String.self, forKey: .setName)
        cubeName = try c.decodeIfPresent(String.self, forKey: .cubeName)
        cubeUrl = try c.decodeIfPresent(String.self, forKey: .cubeUrl)
        formatOther = try c.decodeIfPresent(String.self, forKey: .formatOther)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        startsAt = try c.decodeIfPresent(String.self, forKey: .startsAt)
        cancelledAt = try c.decodeIfPresent(String.self, forKey: .cancelledAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        showClock = try c.decodeIfPresent(Bool.self, forKey: .showClock) ?? true
        autoName = try c.decodeIfPresent(Bool.self, forKey: .autoName) ?? false
        seatEnds = try c.decodeIfPresent(Bool.self, forKey: .seatEnds) ?? false
        pairing = try c.decodeIfPresent(String.self, forKey: .pairing) ?? "swiss"
    }
}

struct ParticipantRow: Decodable, Identifiable, Hashable {
    let id: String
    let eventId: String
    let displayName: String
    let seat: Int?
    let status: String
    let userId: String?
    var podId: String?
    var teamId: String?
    var teamSlot: Int?
    /// Set when the organizer drops the player; nil while active.
    var droppedInRound: Int?
}

/// Team slot 1 sits in seat A.
func slotLetter(_ slot: Int?) -> String {
    guard let slot, (1...26).contains(slot) else { return "–" }
    return String("ABCDEFGHIJKLMNOPQRSTUVWXYZ".dropFirst(slot - 1).prefix(1))
}

struct SideRow: Decodable, Hashable {
    let id: String
    let matchId: String
    let participantId: String?
    let side: Int
    let gameWins: Int
}

struct MatchRow: Decodable, Identifiable, Hashable {
    let id: String
    let eventId: String
    let roundId: String
    let tableNumber: Int?
    let isBye: Bool
    let gameDraws: Int
    let status: String
    let version: Int
    let disputed: Bool
    let reportedByUser: String?
    let matchSides: [SideRow]
    /// player | organizer (nil until a result exists).
    var resultSource: String?
    var reportedByParticipant: String?

    func side(_ n: Int) -> SideRow? { matchSides.first { $0.side == n } }
}

struct RoundRow: Decodable, Identifiable, Hashable {
    let id: String
    let eventId: String
    let number: Int
    let status: String
    let timerEndsAt: String?
    var matches: [MatchRow]
    /// running | paused
    var timerStatus: String?
    var timerDurationSeconds: Int?
    var timerRemainingAtChange: Int?
    var timerLastStartedAt: String?

    var clockPaused: Bool { timerStatus == "paused" }

    /// Running clock: ends at timer_last_started_at + timer_remaining_at_change (or timer_ends_at).
    var clockEnd: Date? {
        guard timerStatus != "paused" else { return nil }
        if let started = timerLastStartedAt.flatMap(T1Date.parse), let remaining = timerRemainingAtChange {
            return started.addingTimeInterval(TimeInterval(remaining))
        }
        return timerEndsAt.flatMap(T1Date.parse)
    }

    /// Seconds left on the clock at `date` (paused: what was left when it paused).
    func secondsLeft(at date: Date) -> Int {
        if let end = clockEnd { return max(0, Int(end.timeIntervalSince(date).rounded(.up))) }
        return max(0, timerRemainingAtChange ?? timerDurationSeconds ?? 0)
    }
}

/// update_event_details: the event's details as saved.
struct EventDetails: Decodable, Hashable {
    let eventId: String
    let name: String
    let formatName: String?
    let formatLabel: String?
    let numberOfRounds: Int
    let roundLengthSeconds: Int
    let setCode: String?
    let setName: String?
    let cubeName: String?
    let cubeUrl: String?
    let teamSize: Int?
    let formatOther: String?
    var pairing: String?
}

/// set_round_clock: the round's clock after the change.
struct RoundClockResult: Decodable, Hashable {
    let roundId: String
    let timerStatus: String
    let remainingSeconds: Int
    let durationSeconds: Int
    let endsAt: String?
}

struct Standing: Decodable, Identifiable, Hashable {
    var id: String { participantId }
    let rank: Int
    let participantId: String
    let displayName: String
    let status: String
    let matchPoints: Int
    let matchWins: Int
    let matchLosses: Int
    let matchDraws: Int
    let byes: Int
    let omw: Double
    let gw: Double
    let ogw: Double
}

/// events-engine `standings`: individual rows, plus team rows (team events) and seating (draft events).
struct StandingsResponse: Decodable {
    var standings: [Standing] = []
    var teams: [TeamStanding]?
    var seating: [SeatingPod]?
}
struct PairRoundResponse: Decodable { let roundNumber: Int?; let error: String? }

extension StandingsResponse {
    func teamOf(_ participantId: String?) -> TeamStanding? {
        guard let participantId else { return nil }
        return teams?.first { t in t.members.contains { $0.participantId == participantId } }
    }
}

struct TeamStanding: Decodable, Identifiable, Hashable {
    struct Member: Decodable, Identifiable, Hashable {
        var id: String { participantId }
        let participantId: String
        let displayName: String
        let slot: Int?
        var matchWins: Int?
        var status: String?
    }
    var id: String { teamId }
    let rank: Int
    let teamId: String
    let name: String
    var points: Int = 0
    var wins: Int = 0
    var losses: Int = 0
    var draws: Int = 0
    var byes: Int = 0
    var matchWins: Int = 0
    var gw: Double?
    var members: [Member] = []

    enum CodingKeys: String, CodingKey { case rank, teamId, name, points, wins, losses, draws, byes, matchWins, gw, members }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0
        teamId = try c.decode(String.self, forKey: .teamId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Team"
        points = try c.decodeIfPresent(Int.self, forKey: .points) ?? 0
        wins = try c.decodeIfPresent(Int.self, forKey: .wins) ?? 0
        losses = try c.decodeIfPresent(Int.self, forKey: .losses) ?? 0
        draws = try c.decodeIfPresent(Int.self, forKey: .draws) ?? 0
        byes = try c.decodeIfPresent(Int.self, forKey: .byes) ?? 0
        matchWins = try c.decodeIfPresent(Int.self, forKey: .matchWins) ?? 0
        gw = try? c.decodeIfPresent(Double.self, forKey: .gw)
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
    }
}

/// A draft pod: seats in passing order.
struct SeatingPod: Decodable, Identifiable, Hashable {
    struct Seat: Decodable, Identifiable, Hashable {
        var id: String { participantId }
        let seat: Int
        let participantId: String
        let displayName: String
        let team: String?
    }
    var id: String { podId }
    let podId: String
    let name: String?
    let seats: [Seat]
}

struct SeatPlayersResponse: Decodable { let pods: [SeatingPod] }

/// get_event_teams / set_teams / randomize_teams rows.
struct EventTeam: Decodable, Identifiable, Hashable {
    struct Member: Decodable, Identifiable, Hashable {
        var id: String { participantId }
        let participantId: String
        let displayName: String
        let slot: Int?
        let userId: String?
        let status: String?
    }
    let id: String
    let name: String
    let order: Int?
    let members: [Member]
}

/// draftable_sets rows (Scryfall), newest first.
struct DraftableSet: Decodable, Identifiable, Hashable {
    var id: String { code }
    let code: String
    let name: String
    let setType: String?
    let releasedAt: String?
    let iconSvgUri: String?
}

// MARK: Events tab (events_home)

struct HomeData: Decodable {
    var events: [HomeEvent] = []
    var invites: [HomeInvite] = []
}

struct HomeEvent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let shortCode: String
    let format: String
    let status: String
    /// live | upcoming | past
    let bucket: String
    let organizing: Bool
    let playing: Bool
    let venueName: String?
    let startsAt: String?
    let numberOfRounds: Int
    let currentRound: Int
    let isDemo: Bool
    let cancelReason: String?
    let players: Int
    let myStatus: String?
    let round: HomeRound?
    let formatName: String?
    let formatLabel: String?
    let eventType: String?
    let teamSize: Int?
    var showClock: Bool?

    var isCancelled: Bool { status == "cancelled" }
    var clockShown: Bool { showClock ?? true }
    var label: String { formatLabel ?? format.capitalized }
    /// A seat in a round that is running right now.
    var playingNow: Bool { playing && myStatus == "active" && round?.timerStatus == "running" }
}

struct HomeRound: Decodable, Hashable {
    let number: Int
    let timerStatus: String
    let durationSeconds: Int
    let endsAt: String?
    let remainingSeconds: Int?
    let resultsIn: Int
    let matches: Int
    let disputed: Int

    var endDate: Date? { endsAt.flatMap(T1Date.parse) }
}

struct HomeInvite: Decodable, Identifiable, Hashable {
    var id: String { eventId }
    let eventId: String
    let name: String
    let format: String
    let source: String
    let venueName: String?
    let startsAt: String?
    let invitedBy: String?
    let players: Int
    let formatLabel: String?
}

// MARK: Account tab (account_overview)

struct AccountOverview: Decodable {
    struct Profile: Decodable { let id: String; let displayName: String; let handle: String? }
    struct Record: Decodable {
        var matchWins = 0, matchLosses = 0, matchDraws = 0, byes = 0
        var gameWins = 0, gameLosses = 0, gameDraws = 0, eventsPlayed = 0
        var matches: Int { matchWins + matchLosses + matchDraws }
    }
    struct Rival: Decodable, Identifiable, Hashable {
        var id: String { opponentId }
        let opponentId: String
        let name: String
        let matchWins: Int
        let matchLosses: Int
        let matchDraws: Int
        let gameWins: Int
        let gameLosses: Int
        let played: Int
    }
    let profile: Profile?
    var record = Record()
    var headToHead: [Rival] = []

    var label: String { profile.map { ($0.handle?.isEmpty == false ? $0.handle : nil) ?? $0.displayName } ?? "Account" }
}

// MARK: Add players

struct SuggestedPlayer: Decodable, Identifiable, Hashable {
    var id: String { userId }
    let userId: String
    let displayName: String
    let handle: String?
    let sharedEvents: Int
    let invited: Bool
    var label: String { (handle?.isEmpty == false ? handle : nil) ?? displayName }
}

struct InviteResult: Decodable { let invited: Int? }

struct NearbyEvent: Decodable, Identifiable, Hashable {
    var id: String { eventId }
    let eventId: String
    let name: String
    let venueName: String?
    let format: String
    let status: String
    let players: Int
    let capacity: Int?
    let distanceM: Int
    let formatLabel: String?
    /// Already an active player here, or its organizer: open the event instead of joining.
    let joined: Bool?
    var label: String { formatLabel ?? format.capitalized }
}

struct JoinQr: Decodable { let shortCode: String; let secret: String; let url: String }
struct SeatResult: Decodable { let eventId: String; let participantId: String?; let alreadyJoined: Bool? }
struct ReportOutcome: Decodable { let ok: Bool?; let status: String?; let version: Int?; let conflict: Bool? }
struct CreateEventResult: Decodable { let eventId: String; let shortCode: String }
struct AddedPlayer: Decodable { let participantId: String; let displayName: String }

/// recent_cubes: cubes this account has run, newest first.
struct RecentCube: Decodable, Hashable, Identifiable {
    var id: String { "\(cubeName.lowercased())|\(cubeUrl ?? "")" }
    let cubeName: String
    let cubeUrl: String?
    let lastUsedAt: String?
}

/// cube-lookup: a Cube Cobra link → the cube's name.
struct CubeLookup: Decodable, Hashable {
    let cubeId: String
    let name: String
    let cardCount: Int?
    let url: String
}

/// The name the server gives a new event: "<format label> · <Tue 14 Oct>". Shown as a preview on Create.
enum EventNaming {
    static func label(format: String, formatOther: String?, setName: String?, cubeName: String?) -> String {
        let base: String
        switch format {
        case "other_constructed":
            let o = formatOther?.trimmingCharacters(in: .whitespaces) ?? ""
            base = o.isEmpty ? "Constructed" : o
        default: base = FormatOption(rawValue: format)?.label ?? "Event"
        }
        let product = [cubeName, setName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return product.map { "\(base) · \($0)" } ?? base
    }

    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    /// The device's calendar date, sent as p_local_date so the name says the day it is here.
    static func localDate(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// What the create form sends to create_event_v2 (and Setup → Details to update_event_details).
/// Rounds always run 50 minutes; `showClock` only decides whether clocks are shown.
struct NewEventDraft: Equatable {
    /// Only for older events with typed names; new events are named by the server.
    var name: String?
    var formatName: String
    var rounds: Int
    var showClock: Bool
    var setCode: String?
    var setName: String?
    var cubeName: String?
    var cubeUrl: String?
    var teamSize: Int?
    var formatOther: String?
    /// Roto only: swiss | round_robin (nil lets the server keep or default it).
    var pairing: String? = nil
}

/// Everything one event screen needs.
struct EventBundle {
    let event: EventRow
    let participants: [ParticipantRow]
    let rounds: [RoundRow]
    let isOrganizer: Bool

    var activeRound: RoundRow? { rounds.last { $0.status == "active" } }
    func name(_ participantId: String?) -> String {
        participants.first { $0.id == participantId }?.displayName ?? "—"
    }
}

/// The owner's QR: https://table-1.site/j/<code>?s=<secret>
struct JoinLink: Equatable {
    let code: String
    let secret: String

    init?(_ raw: String?) {
        guard let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "j",
              let s = comps.queryItems?.first(where: { $0.name == "s" })?.value, !s.isEmpty else { return nil }
        code = parts[2]
        secret = s
    }
}

func recordText(_ w: Int, _ l: Int, _ d: Int) -> String { d > 0 ? "\(w)-\(l)-\(d)" : "\(w)-\(l)" }

/// Postgres timestamps ("2026-10-12T01:47:38.449639+00:00"): microseconds are trimmed before parsing,
/// because ISO8601DateFormatter only reads milliseconds.
enum T1Date {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: trimmed)
    }

    static func short(_ s: String?) -> String? {
        guard let s, let d = parse(s) else { return nil }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}
