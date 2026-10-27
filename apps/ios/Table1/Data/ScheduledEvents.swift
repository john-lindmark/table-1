import Foundation

// Scheduled events, the sign-up link, the waitlist, top 8, automatic rounds and decklists
// (contract/scheduled-events-2026-10-27.md). The rules here are checked against testdata/scheduled-events/cases.json
// (ScheduledEventsTests); the web and Android carry the same ones.

enum EventRules {
    /// Swiss rounds for a number of players (t1_private.swiss_rounds; above 128 the MTR Appendix E bands).
    static func swissRounds(_ players: Int) -> Int {
        for (top, rounds) in [(2, 1), (4, 2), (8, 3), (16, 4), (32, 5), (64, 6), (128, 7), (226, 8), (409, 9)] where players <= top {
            return rounds
        }
        return 10
    }

    enum NextStep: String { case start, waiting, pair, cut, semifinals, final, finish }

    /// What the organizer does next. `stages` are the paired rounds in order; `waiting` is true while the open round
    /// still has a match without a result or with a dispute.
    static func nextStep(stages: [String], waiting: Bool, numberOfRounds: Int, topCut: Int, activePlayers: Int) -> NextStep {
        guard let last = stages.last else { return .start }
        if waiting { return .waiting }
        switch last {
        case "quarterfinal": return .semifinals
        case "semifinal": return .final
        case "final": return .finish
        default:
            if stages.filter({ $0 == "swiss" }).count < numberOfRounds { return .pair }
            return topCut == 8 && activePlayers > 8 ? .cut : .finish
        }
    }

    /// "Round 2 of 5", "Quarterfinals", "Semifinals", "Final".
    static func roundName(stage: String?, number: Int, of: Int) -> String {
        switch stage {
        case "quarterfinal": "Quarterfinals"
        case "semifinal": "Semifinals"
        case "final": "Final"
        default: "Round \(number) of \(of)"
        }
    }

    static func playersText(_ n: Int) -> String { n == 1 ? "1 player" : "\(n) players" }

    /// "12 players signed up", "12/16 players", "16/16 players · 3 on the waitlist".
    static func signUpLine(players: Int, capacity: Int?, waitlist: Int) -> String {
        guard let capacity else { return "\(playersText(players)) signed up" }
        return "\(players)/\(capacity) players" + (waitlist > 0 ? " · \(waitlist) on the waitlist" : "")
    }

    /// The Rounds row when Auto is on.
    static func autoLabel(players: Int) -> String {
        guard players >= 2 else { return "Auto · set when round 1 is paired" }
        let n = swissRounds(players)
        return "Auto · \(n) round\(n == 1 ? "" : "s") for \(players) players"
    }

    /// "Auto rounds · Top 8", "4 rounds".
    static func roundsLine(auto: Bool, rounds: Int, topCut: Int, open: Bool) -> String {
        (auto && open ? "Auto rounds" : "\(rounds) round\(rounds == 1 ? "" : "s")") + (topCut == 8 ? " · Top 8" : "")
    }

    enum PageButton: String { case organizer, `in`, waitlisted, closed, signIn = "sign_in", waitlist, signUp = "sign_up" }

    /// The event page's state from its sign_up and me fields.
    static func button(signedIn: Bool, signUp: String?, me: String?) -> PageButton {
        switch me {
        case "organizer": return .organizer
        case "player": return .in
        case "waitlisted": return .waitlisted
        default: break
        }
        if signUp == "closed" { return .closed }
        if !signedIn { return .signIn }
        return signUp == "full" ? .waitlist : .signUp
    }

    struct Counts: Equatable { var main = 0, side = 0 }

    private static let line = try! NSRegularExpression(pattern: #"^(sb:\s*)?(\d{1,3})\s*x?\s+\S"#, options: .caseInsensitive)
    private static let headTail = try! NSRegularExpression(pattern: #"[:\s]*(\(\d+\))?[:\s]*$"#)

    /// Card counts in a pasted list (t1_private.decklist_counts): "4 Lightning Bolt" lines, Deck / Sideboard headers,
    /// "SB:" lines, and a blank line before the sideboard in lists without headers.
    static func decklistCounts(_ body: String) -> Counts {
        var c = Counts()
        var section = "main", headers = false, seen = false
        for raw in body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty {
                if !headers && seen && section == "main" { section = "side" }
                continue
            }
            let ns = s as NSString
            let head = headTail.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "").lowercased()
            if ["deck", "main", "mainboard", "main deck", "commander"].contains(head) { section = "main"; headers = true; continue }
            if ["sideboard", "side", "side board"].contains(head) { section = "side"; headers = true; continue }
            if ["considering", "maybeboard", "maybe", "tokens", "about", "companion"].contains(head) { section = "skip"; headers = true; continue }
            guard let m = line.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 2))) else { continue }
            if m.range(at: 1).location != NSNotFound { c.side += n }
            else if section == "main" { c.main += n; seen = true }
            else if section == "side" { c.side += n }
        }
        return c
    }

    /// The deck format that fits an event's format; nil = any deck (Other constructed).
    static func deckFormat(_ eventFormat: String?) -> String? {
        switch eventFormat {
        case "canadian_highlander": "canlander"
        case "other_constructed", nil: nil
        case let f?: f
        }
    }

    static func decklistsLine(sent: Int, players: Int) -> String { "\(sent)/\(players) decklists in" }

    /// "60 main · 15 sideboard".
    static func countsText(main: Int, side: Int) -> String {
        side > 0 ? "\(main) main · \(side) sideboard" : "\(main) main"
    }

    /// "Sat 8 Nov · 18:30" in the device's time zone.
    static func when(_ iso: String?) -> String? {
        guard let iso, let d = T1Date.parse(iso) else { return nil }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · "
            + d.formatted(date: .omitted, time: .shortened)
    }

    static let constructedFormats: Set = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern",
                                          "canadian_highlander", "other_constructed"]
}

// MARK: wire

/// event_preview / event_public: what the event page shows (contract §4).
struct EventPage: Decodable, Equatable {
    let eventId: String?
    var access: String?
    var shortCode: String?
    var name: String?
    var formatLabel: String?
    var status: String?
    var startsAt: String?
    var venueName: String?
    var capacity: Int?
    var players: Int?
    var organizerName: String?
    var topCut: Int?
    var autoRounds: Bool?
    var numberOfRounds: Int?
    var waitlist: Int?
    var signUp: String?
    var me: String?
    var position: Int?
    var decklists: String?

    var available: Bool { eventId != nil && access != "none" }
    var signUpLine: String { EventRules.signUpLine(players: players ?? 0, capacity: capacity, waitlist: waitlist ?? 0) }
    var roundsLine: String {
        EventRules.roundsLine(auto: autoRounds ?? false, rounds: numberOfRounds ?? 3, topCut: topCut ?? 0, open: signUp != "closed")
    }
    /// "Sat 8 Nov · 18:30 · The Shop · Modern · Run by Ana".
    var facts: String {
        [EventRules.when(startsAt), venueName, formatLabel, organizerName.map { "Run by \($0)" }]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SignUpResult: Decodable { let eventId: String; let status: String; var participantId: String?; var position: Int? }

struct WaitlistEntry: Decodable, Identifiable, Hashable {
    var id: String { userId }
    let userId: String
    let displayName: String
    let position: Int
}

/// event_bundle `decklists`: which players have sent one (all for organizers, your own otherwise).
struct DecklistInfo: Decodable, Hashable {
    let participantId: String
    let mainCount: Int
    let sideCount: Int
    var listName: String?
    var source: String?
}

/// decklist_get.
struct Decklist: Decodable, Hashable {
    let participantId: String
    let displayName: String?
    let body: String
    let mainCount: Int
    let sideCount: Int
    var listId: String?
    var listName: String?
}

/// events-engine standings `bracket`.
struct BracketStage: Decodable, Hashable {
    struct Side: Decodable, Hashable { var seed: Int?; var participantId: String?; var displayName: String?; var gameWins: Int }
    struct Match: Decodable, Hashable, Identifiable {
        var id: String { matchId }
        let matchId: String
        var tableNumber: Int?
        let status: String
        var winner: String?
        let sides: [Side]
    }
    let stage: String
    let matches: [Match]

    var title: String { EventRules.roundName(stage: stage, number: 0, of: 0) }
}

/// events_home `waitlist`: events you're waiting for.
struct HomeWaitlist: Decodable, Identifiable, Hashable {
    var id: String { eventId }
    let eventId: String
    let name: String
    var formatLabel: String?
    var startsAt: String?
    var venueName: String?
    var position: Int?
    var players: Int
    var capacity: Int?
}
