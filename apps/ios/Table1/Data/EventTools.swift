import Foundation

/* Teams with captains, Team Trios, top 4, a season's final and alerts (contract/teams-finals-alerts-2026-11-13.md),
   entry fees and prizes (contract/entry-fees-2026-11-13.md) and the organizer's room tools
   (contract/room-tools-2026-11-13.md): the wire models and every small rule and wording the three clients share.
   Change a rule in testdata/leagues/make_cases.py first, then make this pass testdata/leagues/cases.json
   (EventToolsTests). Foundation only. */

// MARK: money (wire)

/// One prize bracket: each place up to `through` takes `percent` of the pool.
struct PayoutBracket: Codable, Hashable {
    var through: Int
    var percent: Double
}

struct HostKeep: Codable, Hashable {
    /// none | flat (cents) | percent
    var kind: String = "none"
    var value: Double = 0
}

struct EventFee: Codable, Hashable {
    var amountCents: Int
    var currency: String?
    /// door | app | either
    var payMode: String
    var refundHours: Int?
    var hostKeep: HostKeep?
    var addedCents: Int?
    var payout: [PayoutBracket]?
    var leagueCutCents: Int?

    var takesApp: Bool { payMode == "app" || payMode == "either" }
}

struct MoneyPool: Codable, Hashable {
    var entries: Int
    var grossCents: Int
    var leagueCutCents: Int
    var hostKeepCents: Int
    var addedCents: Int
    var poolCents: Int
}

/// `event_money.me`: your own entry.
struct MyPayment: Codable, Hashable {
    var participantId: String?
    /// unpaid | pending | paid | refunded
    var status: String
    /// app | door | comp | nil
    var method: String?
    var amountCents: Int?
    var canPay: Bool?
    var canRefund: Bool?
}

struct Prize: Codable, Hashable, Identifiable {
    let participantId: String
    var userId: String?
    var name: String
    var place: Int
    var amountCents: Int
    var custom: Bool?
    var paid: Bool?
    var paidHow: String?
    var id: String { participantId }
}

/// One player's payment, as the organizer sees it.
struct PlayerPayment: Codable, Hashable, Identifiable {
    let participantId: String
    var userId: String?
    var name: String?
    var status: String
    var method: String?
    var amountCents: Int?
    var id: String { participantId }
    var tag: String { Money.payTag(status: status, method: method) }
    var isPaid: Bool { status == "paid" }
}

struct MoneyOrganizer: Codable, Hashable {
    struct Stripe: Codable, Hashable { var connected: Bool?; var ready: Bool? }
    var stripe: Stripe?
    var players: [PlayerPayment]?
    var unpaid: Int?
}

/// event_money: `fee` nil = no fee, and nothing else is sent.
struct EventMoney: Codable, Hashable {
    var fee: EventFee?
    var appReady: Bool?
    var pool: MoneyPool?
    var me: MyPayment?
    var prizes: [Prize]?
    var organizer: MoneyOrganizer?

    func payment(_ participantId: String) -> PlayerPayment? { organizer?.players?.first { $0.participantId == participantId } }
}

/// payments_account and the payments function's connect_status.
struct PaymentsAccount: Codable, Hashable {
    var connected = false
    var ready = false
    var payouts: Bool?
    var detailsSubmitted: Bool?
    var disabledReason: String?
    /// payments_account only: payments are open to this account (entry-fees § 1 "Hidden for now"). Absent = false.
    var enabled: Bool?

    /// What an organizer could act on (Account → Payments, Entry fee, Cut per entry, Dues) shows only for an answer
    /// that says `enabled`: false, a missing key and a failed call all hide it.
    static func shows(_ account: PaymentsAccount?) -> Bool { account?.enabled == true }

    /// `NOT CONNECTED` / `FINISH SETTING UP` / `READY`.
    var state: String { ready ? "Ready" : connected ? "Finish setting up" : "Not connected" }
}

struct LeagueMoney: Codable, Hashable {
    struct Due: Codable, Hashable, Identifiable {
        let eventId: String
        var name: String
        var entries: Int?
        var owedCents: Int
        var receivedCents: Int
        var id: String { eventId }
    }
    var entryCutCents: Int
    var poolCents: Int
    /// The league's organizers only.
    var receivedCents: Int?
    var events: [Due]?
}

// MARK: teams (wire)

/// A team as team_mine sends it: in full (yours, and every team for organizers) or as a count.
struct TeamInfo: Decodable, Hashable, Identifiable {
    struct Member: Decodable, Hashable, Identifiable {
        let participantId: String
        var userId: String?
        var name: String
        var slot: Int?
        var id: String { participantId }
    }
    let id: String
    var name: String
    var captainId: String?
    var joinCode: String?
    /// Empty when only the count was sent.
    var members: [Member]
    var count: Int
    var complete: Bool

    enum CodingKeys: String, CodingKey { case id, name, captainId, joinCode, members, complete }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Team"
        captainId = try c.decodeIfPresent(String.self, forKey: .captainId)
        joinCode = try c.decodeIfPresent(String.self, forKey: .joinCode)
        if let n = try? c.decode(Int.self, forKey: .members) {
            members = []; count = n
        } else {
            members = (try c.decodeIfPresent([Member].self, forKey: .members) ?? []).sorted { ($0.slot ?? 99) < ($1.slot ?? 99) }
            count = members.count
        }
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
    }
}

struct TeamMine: Decodable, Hashable {
    var teamSignup = false
    var teamSize: Int?
    var seatFormats: [String]?
    var team: TeamInfo?
    var captain: Bool?
    var canCreate: Bool?
    var teams: [TeamInfo] = []

    enum CodingKeys: String, CodingKey { case teamSignup, teamSize, seatFormats, team, captain, canCreate, teams }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamSignup = try c.decodeIfPresent(Bool.self, forKey: .teamSignup) ?? false
        teamSize = try c.decodeIfPresent(Int.self, forKey: .teamSize)
        seatFormats = try c.decodeIfPresent([String].self, forKey: .seatFormats)
        team = try c.decodeIfPresent(TeamInfo.self, forKey: .team)
        captain = try c.decodeIfPresent(Bool.self, forKey: .captain)
        canCreate = try c.decodeIfPresent(Bool.self, forKey: .canCreate)
        teams = try c.decodeIfPresent([TeamInfo].self, forKey: .teams) ?? []
    }
}

/// events-engine standings `team_bracket`: the team semifinals and final, each with its seats' matches.
struct TeamBracketStage: Decodable, Hashable {
    struct Side: Decodable, Hashable {
        var seed: Int?
        var teamId: String?
        var name: String?
        var matchWins: Int?
    }
    struct Seat: Decodable, Hashable, Identifiable {
        struct Side: Decodable, Hashable {
            var participantId: String?
            var displayName: String?
            var slot: Int?
            var gameWins: Int?
        }
        let matchId: String
        var tableNumber: Int?
        var isBye: Bool?
        var status: String?
        var winner: String?
        var sides: [Side]
        var id: String { matchId }
    }
    struct Match: Decodable, Hashable {
        var tableNumber: Int?
        var status: String?
        var winner: String?
        var sides: [Side]
        var matches: [Seat]?
    }
    let stage: String
    var matches: [Match]
}

// MARK: a season's final and alerts (wire)

struct FinalRow: Decodable, Hashable, Identifiable {
    let key: String
    var userId: String?
    var name: String
    var rank: Int?
    var points: Int?
    /// winner | points | nil
    var how: String?
    /// in | invited | declined | guest | none
    var state: String
    var id: String { key }
}

struct FinalStatus: Decodable, Hashable {
    var seasonId: String?
    var qualified: [FinalRow]
    var next: [FinalRow]

    var inCount: Int { qualified.filter { $0.state == "in" }.count }
    /// `3 of 23 in`.
    var line: String { "\(inCount) of \(qualified.count) in" }
    /// Who Invite the qualified would reach.
    var toInvite: Int { qualified.filter { $0.state == "none" }.count }
}

struct EventAlerts: Codable, Hashable {
    var on = false
    var formats: [String] = []
    var km: Int?
    var lat: Double?
    var lng: Double?

    var hasArea: Bool { lat != nil && lng != nil }

    init(on: Bool = false, formats: [String] = [], km: Int? = nil, lat: Double? = nil, lng: Double? = nil) {
        self.on = on; self.formats = formats; self.km = km; self.lat = lat; self.lng = lng
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
        formats = try c.decodeIfPresent([String].self, forKey: .formats) ?? []
        km = try c.decodeIfPresent(Int.self, forKey: .km)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lng = try c.decodeIfPresent(Double.self, forKey: .lng)
    }
}

// MARK: the room (wire)

struct EventRoom: Decodable, Hashable {
    struct Display: Codable, Hashable {
        /// auto | clock | pairings | standings
        var show: String = "auto"
        var message: String?
    }
    struct Extension: Decodable, Hashable {
        let matchId: String
        var tableNumber: Int?
        var extraSeconds: Int
    }
    struct Call: Decodable, Hashable, Identifiable {
        let callId: String
        var matchId: String
        var tableNumber: Int?
        var calledAt: String
        var by: String?
        var id: String { callId }
    }
    struct Mine: Decodable, Hashable {
        let matchId: String
        var tableNumber: Int?
        var extraSeconds: Int?
        var callOpen: Bool?
    }
    var display: Display?
    var extensions: [Extension]?
    /// Organizers: every open call, oldest first; nil for everyone else.
    var calls: [Call]?
    var myMatch: Mine?

    func extra(_ matchId: String) -> Int { extensions?.first { $0.matchId == matchId }?.extraSeconds ?? 0 }
}

// MARK: rules and wording

enum Money {
    /// `$25`, `$7.50`, `$1,400`: whole dollars lose their cents.
    static func text(_ cents: Int) -> String {
        let n = abs(cents)
        let whole = (n / 100).formatted(.number.locale(Locale(identifier: "en_US")))
        let part = n % 100
        return (cents < 0 ? "-" : "") + "$" + whole + (part > 0 ? String(format: ".%02d", part) : "")
    }

    /// "7.5" or "$7.50" typed into an amount box, as cents; nil when it isn't an amount.
    static func cents(_ typed: String) -> Int? {
        let t = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard !t.isEmpty, let v = Double(t), v >= 0, v.isFinite else { return t.isEmpty ? 0 : nil }
        return Int((v * 100).rounded())
    }

    /// An amount as it's typed: `25`, `7.50`.
    static func typed(_ cents: Int) -> String {
        cents % 100 == 0 ? "\(cents / 100)" : String(format: "%d.%02d", cents / 100, cents % 100)
    }

    static let payModes: [(key: String, label: String, code: String)] = [
        ("door", "At the door", "DOOR"), ("app", "In the app", "APP"), ("either", "Either", "APP OR DOOR"),
    ]

    /// `NONE`, `FREE`, `$25 · APP OR DOOR`.
    static func feeLine(amountCents: Int?, payMode: String?) -> String {
        guard let amountCents else { return "NONE" }
        if amountCents == 0 { return "FREE" }
        return "\(text(amountCents)) · \(payModes.first { $0.key == payMode }?.code ?? "DOOR")"
    }

    static func feeLine(_ fee: EventFee?) -> String { feeLine(amountCents: fee?.amountCents, payMode: fee?.payMode) }

    /// `PAID · APP`, `PAID · DOOR`, `COMP`, `UNPAID`, `PENDING`, `REFUNDED`.
    static func payTag(status: String, method: String?) -> String {
        switch status {
        case "paid": return method == "comp" ? "COMP" : "PAID · \(method == "door" ? "DOOR" : "APP")"
        case "pending": return "PENDING"
        case "refunded": return "REFUNDED"
        default: return "UNPAID"
        }
    }

    /// The player's own state line: `PAID`, `PAID AT THE DOOR`, `COMP`.
    static func paidText(method: String?) -> String {
        method == "door" ? "PAID AT THE DOOR" : method == "comp" ? "COMP" : "PAID"
    }

    static let payoutPresets: [(key: String, label: String, payout: [PayoutBracket])] = [
        ("winner", "Winner takes all", [.init(through: 1, percent: 100)]),
        ("top2", "Top 2", [.init(through: 1, percent: 65), .init(through: 2, percent: 35)]),
        ("top4", "Top 4", [.init(through: 1, percent: 40), .init(through: 2, percent: 25), .init(through: 4, percent: 17.5)]),
        ("top8", "Top 8", [.init(through: 1, percent: 30), .init(through: 2, percent: 20), .init(through: 4, percent: 12.5),
                           .init(through: 8, percent: 6.25)]),
    ]

    /// winner | top2 | top4 | top8 | custom.
    static func preset(_ payout: [PayoutBracket]) -> String { payoutPresets.first { $0.payout == payout }?.key ?? "custom" }

    static func percentText(_ v: Double) -> String { String(format: "%g", v) + "%" }

    /// "1st 40% · 2nd 25% · 3rd to 4th 17.5% each"; "No prizes set".
    static func payoutWords(_ payout: [PayoutBracket]) -> String {
        var parts: [String] = []
        var last = 0
        for b in payout {
            let range = b.through == last + 1 ? Leagues.ordinal(b.through) : "\(Leagues.ordinal(last + 1)) to \(Leagues.ordinal(b.through))"
            parts.append("\(range) \(percentText(b.percent))\(b.through > last + 1 ? " each" : "")")
            last = b.through
        }
        return parts.isEmpty ? "No prizes set" : parts.joined(separator: " · ")
    }

    /// What the brackets hand out in all: can't pass 100.
    static func payoutTotal(_ payout: [PayoutBracket]) -> Double {
        var total = 0.0, last = 0
        for b in payout {
            total += b.percent * Double(b.through - last)
            last = b.through
        }
        return total
    }

    /// Brackets rise and the total stays within the pool (the server's checks).
    static func payoutValid(_ payout: [PayoutBracket]) -> Bool {
        var last = 0
        for b in payout {
            if b.through <= last || b.percent < 0 || b.percent > 100 { return false }
            last = b.through
        }
        return payoutTotal(payout) <= 100.0001
    }

    /// A place's prize at a pool; `share` is how many take that place together (a team's members).
    static func prizeAt(_ payout: [PayoutBracket], poolCents: Int, place: Int, share: Int = 1) -> Int {
        guard let b = payout.first(where: { $0.through >= place }) else { return 0 }
        return Int(Double(poolCents) * b.percent / 100 / Double(max(1, share)))
    }

    /// The pool: paid entries less the league's cut and what the host keeps, plus added money.
    static func pool(entries: Int, amountCents: Int, cutCents: Int, keepKind: String, keepValue: Double, addedCents: Int) -> MoneyPool {
        let gross = entries * amountCents
        let league = entries * min(cutCents, amountCents)
        let keep: Int
        switch keepKind {
        case "flat": keep = min(Int(keepValue), gross - league)
        case "percent": keep = Int(Double(gross - league) * keepValue / 100)
        default: keep = 0
        }
        return MoneyPool(entries: entries, grossCents: gross, leagueCutCents: league, hostKeepCents: keep, addedCents: addedCents,
                         poolCents: max(0, gross - league - keep) + addedCents)
    }

    /// Refund choices: hours before the start a player can still take their own refund (nil = Ask me).
    static let refunds: [(hours: Int?, label: String)] = [(48, "Until 48 h before"), (24, "24 h before"), (0, "Until it starts"), (nil, "Ask me")]
    static let paidHows: [(key: String, label: String)] = [("cash", "Cash"), ("store credit", "Store credit"), ("other", "Other")]

    /// `PAID · CASH`.
    static func prizeTag(paidHow: String?) -> String {
        // `p_how` is cash | store credit | other; other (or nothing) reads plain PAID.
        switch paidHow {
        case "cash": return "PAID · CASH"
        case "store credit": return "PAID · STORE CREDIT"
        default: return "PAID"
        }
    }
}

enum TeamRules {
    /// The formats a Team Trios seat can play, in the picker's order.
    static let seatFormats: [(key: String, label: String)] = [
        ("standard", "Standard"), ("pioneer", "Pioneer"), ("modern", "Modern"), ("legacy", "Legacy"), ("vintage", "Vintage"),
        ("pauper", "Pauper"), ("premodern", "Premodern"), ("canadian_highlander", "Canadian Highlander"),
        ("duel_commander", "Duel Commander"), ("other", "Other"),
    ]
    static let defaultSeats = ["modern", "standard", "pioneer"]

    static func seatFormatLabel(_ key: String) -> String { seatFormats.first { $0.key == key }?.label ?? "Other" }

    /// The top cuts a format can have: 8 for Swiss events of players, 4 for those and for team sealed and Team Trios.
    static func cutChoices(formatName: String, pairing: String = "swiss") -> [Int] {
        if pairing != "swiss" || formatName == "team_draft" || formatName == "roto" { return [0] }
        return formatName == "team_sealed" || formatName == "team_trios" ? [0, 4] : [0, 4, 8]
    }

    static func cutLabel(_ cut: Int) -> String { cut == 0 ? "No top cut" : "Top \(cut)" }

    /// `A · MODERN` (Team Trios), else the seat's letter.
    static func seatLabel(slot: Int?, seatFormats: [String]?) -> String {
        guard let slot else { return "?" }
        let letter = (1...4).contains(slot) ? String(Array("ABCD")[slot - 1]) : "\(slot)"
        guard let seatFormats, slot >= 1, slot <= seatFormats.count else { return letter }
        return "\(letter) · \(seatFormatLabel(seatFormats[slot - 1]).uppercased())"
    }

    /// `2/3`, or `COMPLETE`.
    static func teamLine(members: Int, complete: Bool, teamSize: Int) -> String {
        complete ? "COMPLETE" : "\(members)/\(teamSize)"
    }

    /// The team's link: the event page with the code filled in.
    static func link(eventId: String, code: String) -> URL {
        URL(string: "https://table-1.site/s/\(eventId)?team=\(code)")!
    }

    /// The code in `…/s/<event>?team=<CODE>`.
    static func code(in url: URL) -> String? {
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "team" }?.value
        return code.flatMap(clean)
    }

    /// A typed or pasted code: 8 letters and digits, upper case (a pasted link gives its code).
    static func clean(_ typed: String) -> String? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("http"), let url = URL(string: t),
           let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "team" })?.value {
            return clean(c)
        }
        let code = t.uppercased().filter { $0.isLetter || $0.isNumber }
        return code.isEmpty || code.count > 12 ? nil : code
    }
}

enum AlertRules {
    /// Distance choices (km); nil = Anywhere.
    static let distances = [25, 50, 100, 250]

    /// `OFF`, `MODERN, LIMITED · 50 KM`, `EVERY FORMAT · ANYWHERE`.
    static func line(_ a: EventAlerts) -> String {
        guard a.on else { return "OFF" }
        let formats = a.formats.isEmpty ? "EVERY FORMAT" : a.formats.map { Leagues.label($0).uppercased() }.joined(separator: ", ")
        if let km = a.km, km > 0 { return "\(formats) · \(km) KM" }
        return "\(formats) · ANYWHERE"
    }
}

enum RoomRules {
    static let shows: [(key: String, label: String)] = [("auto", "Auto"), ("clock", "Clock"), ("pairings", "Pairings"), ("standings", "Standings")]
    static let rels: [(key: String, label: String)] = [("", "Not said"), ("casual", "Casual"), ("competitive", "Competitive")]
    /// Extra time choices, in seconds.
    static let extras = [180, 300, 600]
    static let messageLimit = 140

    /// The display page a TV opens (and the second screen shows).
    static func displayURL(_ eventId: String) -> URL { URL(string: "https://table-1.site/d/\(eventId)")! }

    /// `+5:00`; nothing at 0.
    static func extensionText(_ seconds: Int) -> String {
        seconds > 0 ? String(format: "+%d:%02d", seconds / 60, seconds % 60) : ""
    }

    /// `JUDGE · TABLE 7 · BEA · 2 MIN` (`NOW` in the first minute).
    static func judgeLine(table: Int?, by: String?, calledAt: Date?, now: Date = .now) -> String {
        let mins = max(0, Int((calledAt.map { now.timeIntervalSince($0) } ?? 0) / 60))
        let name = (by ?? "").uppercased()
        return ["JUDGE", table.map { "TABLE \($0)" }, name.isEmpty ? nil : name, mins == 0 ? "NOW" : "\(mins) MIN"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// `COMPETITIVE · DECKLISTS DUE SAT 14 NOV 09:30`. `due` is the deadline already in the device's zone.
    static func rulesLine(rel: String?, due: String?) -> String {
        [rel.flatMap { $0.isEmpty ? nil : $0.uppercased() }, due.flatMap { $0.isEmpty ? nil : "DECKLISTS DUE \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// `SAT 14 NOV 09:30` in the zone.
    static func dueText(_ date: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = "EEE d MMM"
        return f.string(from: date).uppercased().replacingOccurrences(of: ".", with: "") + " " + Leagues.timeText(date, zone: zone, locale: locale)
    }

    /// `24 / 140`.
    static func count(_ message: String) -> String { "\(message.count) / \(messageLimit)" }
}
