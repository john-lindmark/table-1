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

    enum CodingKeys: String, CodingKey {
        case id, shortCode, name, format, status, numberOfRounds, currentRound, roundLengthSeconds,
             allowPlayerReporting, venueName, createdAt
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
    }
}

struct ParticipantRow: Decodable, Identifiable, Hashable {
    let id: String
    let eventId: String
    let displayName: String
    let seat: Int?
    let status: String
    let userId: String?
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

    func side(_ n: Int) -> SideRow? { matchSides.first { $0.side == n } }
}

struct RoundRow: Decodable, Identifiable, Hashable {
    let id: String
    let eventId: String
    let number: Int
    let status: String
    let timerEndsAt: String?
    let matches: [MatchRow]
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

struct StandingsResponse: Decodable { let standings: [Standing] }
struct PairRoundResponse: Decodable { let roundNumber: Int?; let error: String? }

struct PlayerRecord: Decodable {
    var matchWins = 0, matchLosses = 0, matchDraws = 0, byes = 0
    var gameWins = 0, gameLosses = 0, gameDraws = 0
}

struct HeadToHeadRow: Decodable, Hashable {
    let opponentId: String
    let matchWins: Int
    let matchLosses: Int
    let matchDraws: Int
    let gameWins: Int
    let gameLosses: Int
    let gameDraws: Int
}

struct ProfileRow: Decodable {
    let id: String
    let handle: String?
    let displayName: String
    var label: String { (handle?.isEmpty == false ? handle : nil) ?? displayName }
}

struct EventLite: Decodable, Hashable { let name: String; let venueName: String?; let status: String }

struct InviteRow: Decodable, Identifiable, Hashable {
    var id: String { eventId }
    let eventId: String
    let source: String
    let events: EventLite?
}

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
}

struct JoinQr: Decodable { let shortCode: String; let secret: String; let url: String }
struct SeatResult: Decodable { let eventId: String; let participantId: String?; let alreadyJoined: Bool? }
struct ReportOutcome: Decodable { let ok: Bool?; let status: String?; let version: Int?; let conflict: Bool? }
struct CreateEventResult: Decodable { let eventId: String; let shortCode: String }

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
