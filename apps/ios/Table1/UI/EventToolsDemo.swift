#if DEBUG
import Foundation
import Supabase

/// Stand-in answers for entry fees, teams, a season's final, alerts and the room tools while a signed-out design demo
/// is up (`-T1EventsDemo payments|fee|pool|pay|paysetup|prizes|dues|triosteams|teampage|myteam|teamcut|teambracket|
/// display|room|judge|final|alerts`). Debug only; `Repo`'s calls answer from here instead of the server, and what the
/// screens change sticks here until relaunch. With nothing set an event has no fee, an empty room and no team sign-up,
/// so the older demos draw as before.
enum ToolsDemo {
    static var on = false
    static let eventId = "demo-event"
    static let names = ["Ann Ito", "Bo Lindqvist", "Cy Park", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Hal Brandt"]

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        do { return try wireDecoder.decode(T.self, from: Data(json.utf8)) } catch { fatalError("Tools demo \(T.self): \(error)") }
    }

    // MARK: money

    /// nil = the event has no fee.
    static var fee: EventFee?
    static var payments: [PlayerPayment] = []
    /// The viewer runs the event (organizer rows) or plays in it as Ann Ito (`me`).
    static var organizer = true
    static var finished = false
    static var custom: [String: Int] = [:]
    static var prizePaid: [String: String] = [:]
    static var account = PaymentsAccount(connected: true, ready: true, payouts: true, detailsSubmitted: true, disabledReason: nil)

    /// A $25 entry, in the app or at the door, top 4 paid, $7 an entry to the league, the host keeps 10%.
    static func startFee(mine: String = "unpaid") {
        fee = EventFee(amountCents: 2500, currency: "usd", payMode: "either", refundHours: 24, hostKeep: HostKeep(kind: "percent", value: 10),
                       addedCents: 5000, payout: Money.payoutPresets[2].payout, leagueCutCents: 700)
        let states: [(String, String?)] = [(mine, mine == "unpaid" ? nil : "app"), ("paid", "app"), ("paid", "door"), ("paid", "app"),
                                           ("unpaid", nil), ("paid", "comp"), ("pending", "app"), ("unpaid", nil)]
        payments = states.enumerated().map { i, s in
            PlayerPayment(participantId: "p\(i + 1)", userId: i == 0 ? "demo-me" : "u\(i + 1)", name: names[i], status: s.0, method: s.1,
                          amountCents: s.0 == "paid" && s.1 != "comp" ? 2500 : 0)
        }
    }

    static func money(_ eventId: String) -> EventMoney {
        guard let fee else { return EventMoney() }
        let paid = payments.filter { $0.status == "paid" && $0.method != "comp" }.count
        let pool = Money.pool(entries: paid, amountCents: fee.amountCents, cutCents: fee.leagueCutCents ?? 0, keepKind: fee.hostKeep?.kind ?? "none",
                              keepValue: fee.hostKeep?.value ?? 0, addedCents: fee.addedCents ?? 0)
        var m = EventMoney(fee: fee, appReady: fee.takesApp && account.ready, pool: pool)
        if let mine = payments.first {
            m.me = MyPayment(participantId: mine.participantId, status: mine.status, method: mine.method, amountCents: mine.amountCents,
                             canPay: fee.takesApp && mine.status != "paid" && !finished, canRefund: mine.status == "paid" && mine.method == "app" && !finished)
        }
        if finished {
            // The sample draft's final order.
            let order = [1, 7, 2, 6, 4, 3, 5, 8]
            m.prizes = order.enumerated().compactMap { i, p in
                let id = "p\(p)"
                let amount = custom[id] ?? Money.prizeAt(fee.payout ?? [], poolCents: pool.poolCents, place: i + 1)
                guard amount > 0 || custom[id] != nil else { return nil }
                return Prize(participantId: id, userId: "u\(p)", name: names[p - 1], place: i + 1, amountCents: amount, custom: custom[id] != nil,
                             paid: prizePaid[id] != nil, paidHow: prizePaid[id])
            }
        } else {
            m.prizes = []
        }
        if organizer {
            m.organizer = MoneyOrganizer(stripe: .init(connected: account.connected, ready: account.ready), players: payments,
                                         unpaid: payments.filter { $0.status != "paid" }.count)
        }
        return m
    }

    static func setFee(_ patch: [String: AnyJSON]?) -> EventFee? {
        guard let patch else { fee = nil; return nil }
        var f = fee ?? EventFee(amountCents: 0, currency: "usd", payMode: "door", refundHours: nil, hostKeep: HostKeep(), addedCents: 0, payout: [], leagueCutCents: 700)
        if case .integer(let n)? = patch["amount_cents"] { f.amountCents = n }
        if case .string(let s)? = patch["pay_mode"] { f.payMode = s }
        if let r = patch["refund_hours"] { if case .integer(let n) = r { f.refundHours = n } else { f.refundHours = nil } }
        if case .integer(let n)? = patch["added_cents"] { f.addedCents = n }
        if case .object(let k)? = patch["host_keep"], case .string(let kind)? = k["kind"] {
            var v = 0.0
            if case .integer(let n)? = k["value"] { v = Double(n) }
            f.hostKeep = HostKeep(kind: kind, value: v)
        }
        if case .array(let rows)? = patch["payout"] {
            f.payout = rows.compactMap { row in
                guard case .object(let o) = row, case .integer(let t)? = o["through"] else { return nil }
                var pct = 0.0
                if case .double(let d)? = o["percent"] { pct = d } else if case .integer(let n)? = o["percent"] { pct = Double(n) }
                return PayoutBracket(through: t, percent: pct)
            }
        }
        fee = f
        return f
    }

    static func mark(_ participantId: String, status: String, method: String?) {
        guard let i = payments.firstIndex(where: { $0.participantId == participantId }) else { return }
        payments[i].status = status
        payments[i].method = method
        payments[i].amountCents = status == "paid" && method != "comp" ? fee?.amountCents : 0
    }

    static func split(_ rows: [(participantId: String, cents: Int)]?) {
        custom = Dictionary(uniqueKeysWithValues: (rows ?? []).map { ($0.participantId, $0.cents) })
    }

    static func markPrize(_ participantId: String, paid: Bool, how: String?) { prizePaid[participantId] = paid ? (how ?? "") : nil }

    static var leagueMoney = LeagueMoney(entryCutCents: 700, poolCents: 140_000, receivedCents: 61_600, events: [
        .init(eventId: "p3", name: "Pauper Open", entries: 22, owedCents: 15_400, receivedCents: 15_400),
        .init(eventId: "p2", name: "Modern Open", entries: 41, owedCents: 28_700, receivedCents: 28_700),
        .init(eventId: "p1", name: "Legacy Open", entries: 34, owedCents: 23_800, receivedCents: 17_500),
        .init(eventId: "f1", name: "Modern Open", entries: 12, owedCents: 8_400, receivedCents: 0),
    ])

    static func markDue(_ eventId: String, _ cents: Int) {
        guard let i = leagueMoney.events?.firstIndex(where: { $0.eventId == eventId }) else { return }
        leagueMoney.events?[i].receivedCents = cents
        leagueMoney.receivedCents = leagueMoney.events?.reduce(0) { $0 + $1.receivedCents }
    }

    // MARK: teams

    static var teamSignup = false
    /// You're on a team (its captain, seat A).
    static var onTeam = false
    static var teamName = "Ravens"
    static var myMembers: [(id: String, user: String, name: String)] = [("p1", "demo-me", "Ann Ito"), ("p2", "u2", "Bo Lindqvist")]
    static var seats: [String]? = ["modern", "standard", "pioneer"]
    static var captain = "demo-me"

    static func teams(_ eventId: String) -> TeamMine {
        func members(_ list: [(id: String, user: String, name: String)]) -> String {
            "[" + list.enumerated().map { i, m in
                #"{"participant_id": "\#(m.id)", "user_id": "\#(m.user)", "name": "\#(m.name)", "slot": \#(i + 1)}"#
            }.joined(separator: ",") + "]"
        }
        let seatsJSON = seats.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        let mine = #"{"id": "t1", "name": "\#(teamName)", "captain_id": "\#(captain)", "join_code": "K7Q2M9XD", "members": \#(members(myMembers)), "complete": \#(myMembers.count == 3)}"#
        let owls = [("p4", "u4", "Dee Okafor"), ("p5", "u5", "Eli Moreau"), ("p6", "u6", "Fen Zhou")].map { (id: $0.0, user: $0.1, name: $0.2) }
        let crows = [(id: "p7", user: "u7", name: "Gus Varga")]
        let others: String
        if organizer {
            others = #"{"id": "t2", "name": "Owls", "captain_id": "u4", "join_code": "H4T8WQ2B", "members": \#(members(owls)), "complete": true},"#
                + #"{"id": "t3", "name": "Crows", "captain_id": "u7", "join_code": "Z6N3PLR5", "members": \#(members(crows)), "complete": false}"#
        } else {
            others = #"{"id": "t2", "name": "Owls", "members": 3, "complete": true}, {"id": "t3", "name": "Crows", "members": 1, "complete": false}"#
        }
        let first = organizer || onTeam ? (organizer ? mine : #"{"id": "t1", "name": "\#(teamName)", "members": \#(myMembers.count), "complete": \#(myMembers.count == 3)}"#) + "," : ""
        return decode(TeamMine.self, """
        {"team_signup": \(teamSignup), "team_size": 3, "seat_formats": \(seatsJSON), "team": \(onTeam ? mine : "null"),
         "captain": \(onTeam && captain == "demo-me"), "can_create": \(teamSignup && !onTeam && !organizer), "teams": [\(first)\(others)]}
        """)
    }

    static func createTeam(_ name: String) -> TeamMine {
        onTeam = true
        teamName = name
        myMembers = [("p1", "demo-me", "Ann Ito")]
        captain = "demo-me"
        return teams(eventId)
    }

    static func updateTeam(_ teamId: String, _ patch: [String: AnyJSON], _ eventId: String) -> TeamMine {
        guard teamId == "t1" else { return teams(eventId) }
        if case .string(let n)? = patch["name"] { teamName = n }
        if case .string(let c)? = patch["captain"] { captain = c }
        if case .string(let r)? = patch["remove"] { myMembers.removeAll { $0.id == r } }
        if case .array(let order)? = patch["order"] {
            let ids: [String] = order.compactMap { if case .string(let s) = $0 { s } else { nil } }
            myMembers = ids.compactMap { id in myMembers.first { $0.id == id } }
        }
        return teams(eventId)
    }

    // MARK: a season's final

    static var isFinal = false
    static var invited: Set<String> = ["u:demo-3", "u:demo-4"]

    static func finalStatus(_ eventId: String) throws -> FinalStatus {
        guard isFinal else { throw NSError(domain: "Table1", code: 42501, userInfo: [NSLocalizedDescriptionKey: "Only the organizers of a season's final can see this"]) }
        func row(_ r: LeagueRow, _ i: Int) -> String {
            let state = i < 3 ? "in" : invited.contains(r.key) ? "invited" : i == 5 ? "declined" : i == 8 ? "guest" : "none"
            return #"{"key": "\#(r.key)", "user_id": \#(state == "guest" ? "null" : "\"\(r.userId ?? "")\""), "name": "\#(r.name)", "rank": \#(r.rank), "points": \#(r.points), "how": \#(r.qualified.map { "\"\($0)\"" } ?? "null"), "state": "\#(state)"}"#
        }
        let table = LeaguesDemo.table
        let qualified = table.enumerated().filter { $0.element.qualified != nil }.map { row($0.element, $0.offset) }
        let next = table.enumerated().filter { $0.element.qualified == nil }.prefix(8).map { row($0.element, $0.offset) }
        return decode(FinalStatus.self, #"{"season_id": "\#(LeaguesDemo.seasonId)", "qualified": [\#(qualified.joined(separator: ","))], "next": [\#(next.joined(separator: ","))]}"#)
    }

    static func invite(_ keys: [String]?) -> Int {
        let fresh = keys ?? ((try? finalStatus(eventId))?.qualified.filter { $0.state == "none" }.map(\.key) ?? [])
        invited.formUnion(fresh)
        return fresh.count
    }

    // MARK: alerts

    static var alerts = EventAlerts(on: true, formats: ["modern", "limited"], km: 50, lat: 39.7, lng: -105.0)

    static func setAlerts(_ patch: [String: AnyJSON]) -> EventAlerts {
        if case .bool(let on)? = patch["on"] { alerts.on = on }
        if case .array(let f)? = patch["formats"] { alerts.formats = f.compactMap { if case .string(let s) = $0 { s } else { nil } } }
        if let km = patch["km"] { if case .integer(let n) = km { alerts.km = n } else { alerts.km = nil } }
        if case .double(let lat)? = patch["lat"], case .double(let lng)? = patch["lng"] { alerts.lat = lat; alerts.lng = lng }
        if patch["place"] != nil { alerts.lat = nil; alerts.lng = nil; alerts.km = nil }
        return alerts
    }

    // MARK: the room

    static var display = EventRoom.Display(show: "auto", message: nil)
    static var extras: [String: Int] = [:]
    /// Open judge calls: the match, its table, who called and how many minutes ago.
    static var calls: [(id: String, match: String, table: Int, by: String, minutes: Int)] = []
    /// The viewer's own match in the newest round (players).
    static var myMatch: String?

    /// Round 2 of the sample draft: table 3 has five more minutes and called a judge two minutes ago; table 4 just did.
    static func startRoom() {
        extras = ["m2-3": 300]
        calls = [("c1", "m2-3", 3, "Eli Moreau", 2), ("c2", "m2-4", 4, "Fen Zhou", 0)]
        display = EventRoom.Display(show: "pairings", message: "Lunch after round 2. Decklists to the desk.")
    }

    static func room(_ eventId: String) -> EventRoom {
        let ext = extras.sorted { $0.key < $1.key }.map { #"{"match_id": "\#($0.key)", "table_number": \#(Int($0.key.split(separator: "-").last ?? "") ?? 0), "extra_seconds": \#($0.value)}"# }
        let open = calls.map { c in
            #"{"call_id": "\#(c.id)", "match_id": "\#(c.match)", "table_number": \#(c.table), "called_at": "\#(Leagues.iso(Date().addingTimeInterval(Double(-c.minutes * 60) - 5)))", "by": "\#(c.by)"}"#
        }
        let mine = myMatch.map { m in
            #"{"match_id": "\#(m)", "table_number": 1, "extra_seconds": \#(extras[m] ?? 0), "call_open": \#(calls.contains { $0.match == m })}"#
        } ?? "null"
        let message = display.message.map { "\"\($0)\"" } ?? "null"
        return decode(EventRoom.self, """
        {"display": {"show": "\(display.show)", "message": \(message)}, "extensions": [\(ext.joined(separator: ","))],
         "calls": \(organizer ? "[" + open.joined(separator: ",") + "]" : "null"), "my_match": \(mine)}
        """)
    }

    static func setDisplay(_ patch: [String: AnyJSON]) -> EventRoom.Display {
        if case .string(let s)? = patch["show"] { display.show = s }
        if let m = patch["message"] { if case .string(let s) = m, !s.isEmpty { display.message = s } else { display.message = nil } }
        return display
    }

    static func extend(_ matchId: String, _ seconds: Int) {
        let total = max(0, min(3600, (extras[matchId] ?? 0) + seconds))
        extras[matchId] = total > 0 ? total : nil
    }

    static func judge(_ matchId: String, open: Bool) {
        calls.removeAll { $0.match == matchId }
        if open { calls.append(("c\(calls.count + 9)", matchId, 1, "Ann Ito", 0)) }
    }

    static func resolve(_ callId: String) { calls.removeAll { $0.id == callId } }
}
#endif
