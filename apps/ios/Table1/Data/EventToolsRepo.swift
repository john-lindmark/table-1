import Foundation
import Supabase

/* Server calls for teams, a season's final, alerts, entry fees and the room tools (contract/teams-finals-alerts,
   entry-fees and room-tools, all 2026-11-13). None of it may be live where a build runs: a function the server
   doesn't have is remembered in `ToolsServer.missing` and refused at once from then on, so its part of a screen stays
   hidden (every read here is called with `try?`), nothing is polled, and nothing is reported. In Debug the signed-out
   design demos answer from ToolsDemo. */

enum ToolsServer {
    /// Functions the server answered "no such function" for.
    static var missing: Set<String> = []
    /// The payments function said Table 1's own Stripe keys aren't in place (503), or isn't deployed: its line.
    static var paymentsOff: String?

    struct Missing: LocalizedError {
        var errorDescription: String? { "That isn't available yet." }
    }

    /// The payments function's 503: show the line, offer nothing.
    struct PaymentsOff: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

extension Repo {
    private struct FnError: Decodable { let error: String? }

    /// One RPC, decoded. A function the server doesn't have is noted and never asked for again this launch.
    static func tools<T: Decodable>(_ fn: String, _ params: [String: AnyJSON] = [:]) async throws -> T {
        if ToolsServer.missing.contains(fn) { throw ToolsServer.Missing() }
        do {
            let data = try await supabase.rpc(fn, params: params).execute().data
            return try wireDecoder.decode(T.self, from: data)
        } catch {
            if Leagues.isMissing(error) { ToolsServer.missing.insert(fn); throw ToolsServer.Missing() }
            throw error
        }
    }

    /// The payments edge function with the user's token. A refusal surfaces the function's own message; 503 (no
    /// Stripe keys yet) and 404 (not deployed) become `PaymentsOff`.
    private static func payments<T: Decodable>(_ body: [String: AnyJSON]) async throws -> T {
        do {
            let out: T = try await supabase.functions.invoke("payments", options: FunctionInvokeOptions(body: body)) { data, _ in
                try wireDecoder.decode(T.self, from: data)
            }
            ToolsServer.paymentsOff = nil
            return out
        } catch FunctionsError.httpError(let code, let data) {
            let message = (try? wireDecoder.decode(FnError.self, from: data))?.error
            if code == 503 || code == 404 {
                let off = ToolsServer.PaymentsOff(message: message ?? "Payments aren't set up yet")
                ToolsServer.paymentsOff = off.message
                throw off
            }
            throw NSError(domain: "Table1", code: code, userInfo: [NSLocalizedDescriptionKey: message ?? "Something went wrong. Try again."])
        }
    }

    private struct Link: Decodable { let url: String }

    private static func link(_ body: [String: AnyJSON]) async throws -> URL {
        let l: Link = try await payments(body)
        guard let url = URL(string: l.url), url.scheme == "https" else {
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something went wrong. Try again."])
        }
        return url
    }

    // MARK: a host's Stripe account (entry-fees § 1)

    /// The last known state, without asking Stripe.
    static func paymentsAccount() async throws -> PaymentsAccount {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.account }
        #endif
        return try await tools("payments_account")
    }

    /// Stripe's own onboarding page for you (the account is made on the first call).
    static func connectStart() async throws -> URL {
        Telemetry.capture("stripe_connect_started")
        return try await link(["action": .string("connect_start")])
    }

    /// Asks Stripe now.
    static func connectStatus() async throws -> PaymentsAccount {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.account }
        #endif
        let a: PaymentsAccount = try await payments(["action": .string("connect_status")])
        Telemetry.capture("stripe_connect_status", ["ready": a.ready])
        return a
    }

    static func connectDashboard() async throws -> URL { try await link(["action": .string("connect_dashboard")]) }

    // MARK: an event's fee and paying (§§ 2–4)

    static func eventMoney(_ eventId: String) async throws -> EventMoney {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.money(eventId) }
        #endif
        return try await tools("event_money", ["p_event_id": .string(eventId)])
    }

    /// Sets or changes the fee (only the keys given), or removes it (`fee` nil).
    @discardableResult
    static func setEventFee(_ eventId: String, fee: [String: AnyJSON]?) async throws -> EventFee? {
        struct Answer: Decodable { let fee: EventFee? }
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.setFee(fee) }
        #endif
        let a: Answer = try await tools("event_fee_set", ["p_event_id": .string(eventId), "p_fee": fee.map { .object($0) } ?? .null])
        if let f = a.fee { Telemetry.capture("fee_saved", ["pay_mode": f.payMode, "amount": f.amountCents]) }
        return a.fee
    }

    /// Stripe's hosted checkout for your entry (an open one is handed back, not doubled).
    static func checkout(_ eventId: String) async throws -> URL {
        Telemetry.capture("pay_started", ["origin": "ios"])
        return try await link(["action": .string("checkout"), "event_id": .string(eventId), "origin": .string("ios")])
    }

    /// Your own app payment (`participantId` nil), or any app payment when you run the event.
    static func refund(_ eventId: String, participantId: String? = nil) async throws {
        struct Answer: Decodable { let refunded: Bool? }
        Telemetry.capture("refund_asked", ["by": participantId == nil ? "player" : "organizer"])
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.mark(participantId ?? "p1", status: "refunded", method: "app"); return }
        #endif
        var body: [String: AnyJSON] = ["action": .string("refund"), "event_id": .string(eventId)]
        if let participantId { body["participant_id"] = .string(participantId) }
        let _: Answer = try await payments(body)
    }

    /// `state`: door | comp | unpaid.
    static func markPayment(_ eventId: String, participantId: String, state: String) async throws {
        Telemetry.capture("payment_marked", ["state": state])
        #if DEBUG
        if ToolsDemo.on {
            ToolsDemo.mark(participantId, status: state == "unpaid" ? "unpaid" : "paid", method: state == "unpaid" ? nil : state)
            return
        }
        #endif
        let _: AnyJSON = try await tools("event_payment_mark", [
            "p_event_id": .string(eventId), "p_participant_id": .string(participantId), "p_state": .string(state),
        ])
    }

    /// An agreed split (`rows`: participant and cents), or back to the table (nil).
    static func setPrizes(_ eventId: String, rows: [(participantId: String, cents: Int)]?) async throws {
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.split(rows); return }
        #endif
        let json: AnyJSON = rows.map { .array($0.map { .object(["participant_id": .string($0.participantId), "amount_cents": .integer($0.cents)]) }) } ?? .null
        let _: AnyJSON = try await tools("event_prizes_set", ["p_event_id": .string(eventId), "p_rows": json])
        if rows != nil { Telemetry.capture("prizes_split") }
    }

    static func markPrize(_ eventId: String, participantId: String, paid: Bool, how: String?) async throws {
        Telemetry.capture("prize_marked", ["how": paid ? (how ?? "paid") : "unpaid"])
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.markPrize(participantId, paid: paid, how: how); return }
        #endif
        let _: AnyJSON = try await tools("event_prize_mark", [
            "p_event_id": .string(eventId), "p_participant_id": .string(participantId), "p_paid": .bool(paid),
            "p_how": how.map { .string($0) } ?? .null,
        ])
    }

    // MARK: a league's cut (§ 5)

    static func leagueMoney(_ seasonId: String) async throws -> LeagueMoney {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.leagueMoney }
        #endif
        return try await tools("league_money", ["p_season_id": .string(seasonId)])
    }

    static func markDue(_ eventId: String, receivedCents: Int) async throws {
        Telemetry.capture("dues_marked")
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.markDue(eventId, receivedCents); return }
        #endif
        let _: AnyJSON = try await tools("league_due_mark", ["p_event_id": .string(eventId), "p_received_cents": .integer(receivedCents)])
    }

    /// A season's cut of each paid entry (league_season_set key `entry_cut_cents`).
    static func setSeasonCut(_ leagueId: String, seasonId: String, cents: Int) async throws {
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.leagueMoney.entryCutCents = cents; return }
        #endif
        let _: AnyJSON = try await tools("league_season_set", [
            "p_league_id": .string(leagueId), "p_season_id": .string(seasonId), "p_patch": .object(["entry_cut_cents": .integer(cents)]),
        ])
    }

    // MARK: Team Trios and teams that sign themselves up (teams-finals-alerts §§ 1–2)

    /// The three seats' formats, before round 1.
    static func setEventTrios(_ eventId: String, seats: [String]) async throws {
        let _: AnyJSON = try await tools("set_event_trios", ["p_event_id": .string(eventId), "p_seat_formats": .array(seats.map { .string($0) })])
    }

    static func setTeamSignup(_ eventId: String, on: Bool) async throws {
        Telemetry.capture("team_signup_set", ["on": on])
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.teamSignup = on; return }
        #endif
        let _: AnyJSON = try await tools("team_signup_set", ["p_event_id": .string(eventId), "p_on": .bool(on)])
    }

    static func teamMine(_ eventId: String) async throws -> TeamMine {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.teams(eventId) }
        #endif
        return try await tools("team_mine", ["p_event_id": .string(eventId)])
    }

    /// Signs you up and makes the team: you are its captain in seat A.
    static func teamCreate(_ eventId: String, name: String) async throws -> TeamMine {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.createTeam(name) }
        #endif
        let t: TeamMine = try await tools("team_create", ["p_event_id": .string(eventId), "p_name": .string(name)])
        Telemetry.capture("team_created")
        return t
    }

    /// `how`: code | link.
    static func teamJoin(_ eventId: String, code: String, how: String) async throws -> TeamMine {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.createTeam("Ravens") }
        #endif
        let t: TeamMine = try await tools("team_join", ["p_event_id": .string(eventId), "p_code": .string(code)])
        Telemetry.capture("team_joined", ["how": how])
        return t
    }

    /// The captain or an organizer, before round 1. `patch`: name | order | captain | remove.
    static func teamUpdate(_ teamId: String, patch: [String: AnyJSON], what: String, eventId: String) async throws -> TeamMine {
        Telemetry.capture("team_updated", ["what": what])
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.updateTeam(teamId, patch, eventId) }
        #endif
        return try await tools("team_update", ["p_team_id": .string(teamId), "p_patch": .object(patch)])
    }

    // MARK: a season's final (§ 3)

    /// 42501 unless you run both the event and its league and the event is the season's final.
    static func finalStatus(_ eventId: String) async throws -> FinalStatus {
        #if DEBUG
        if ToolsDemo.on { return try ToolsDemo.finalStatus(eventId) }
        #endif
        return try await tools("league_final_status", ["p_event_id": .string(eventId)])
    }

    /// Everyone qualified who isn't in or invited (`keys` nil), or those players (passing an invitation down).
    @discardableResult
    static func finalInvite(_ eventId: String, keys: [String]?) async throws -> Int {
        struct Answer: Decodable { let invited: Int? }
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.invite(keys) }
        #endif
        let a: Answer = try await tools("league_final_invite", [
            "p_event_id": .string(eventId), "p_keys": keys.map { .array($0.map { .string($0) }) } ?? .null,
        ])
        Telemetry.capture("final_invited", ["count": a.invited ?? 0, "passed_down": keys != nil])
        return a.invited ?? 0
    }

    // MARK: alerts for new public events (§ 4)

    static func eventAlerts() async throws -> EventAlerts {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.alerts }
        #endif
        return try await tools("event_alerts_get")
    }

    /// `patch`: on | formats | km | lat + lng | place: null.
    static func setEventAlerts(_ patch: [String: AnyJSON]) async throws -> EventAlerts {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.setAlerts(patch) }
        #endif
        let a: EventAlerts = try await tools("event_alerts_set", ["p_patch": .object(patch)])
        Telemetry.capture("event_alerts_saved", ["on": a.on, "formats": a.formats.count, "km": a.km ?? 0])
        return a
    }

    // MARK: the room (room-tools)

    static func eventRoom(_ eventId: String) async throws -> EventRoom {
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.room(eventId) }
        #endif
        return try await tools("event_room", ["p_event_id": .string(eventId)])
    }

    /// `patch`: show (auto | clock | pairings | standings), message (null or blank clears it).
    static func setDisplay(_ eventId: String, patch: [String: AnyJSON]) async throws -> EventRoom.Display {
        if case .string(let show)? = patch["show"] { Telemetry.capture("display_set", ["show": show, "message": false]) }
        if let m = patch["message"] { Telemetry.capture("display_set", ["show": "kept", "message": m != .null]) }
        #if DEBUG
        if ToolsDemo.on { return ToolsDemo.setDisplay(patch) }
        #endif
        return try await tools("event_display_set", ["p_event_id": .string(eventId), "p_patch": .object(patch)])
    }

    /// Adds to (or, with a negative number, takes from) a table's extra time; its total stays 0 to 60 minutes.
    static func extendMatch(_ matchId: String, seconds: Int) async throws {
        Telemetry.capture("time_extended", ["seconds": seconds])
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.extend(matchId, seconds); return }
        #endif
        let _: AnyJSON = try await tools("match_time_extend", ["p_match_id": .string(matchId), "p_seconds": .integer(seconds)])
    }

    static func judgeCall(_ matchId: String) async throws {
        Telemetry.capture("judge_called")
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.judge(matchId, open: true); return }
        #endif
        let _: AnyJSON = try await tools("judge_call", ["p_match_id": .string(matchId)])
    }

    static func judgeCancel(_ matchId: String) async throws {
        Telemetry.capture("judge_cancelled")
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.judge(matchId, open: false); return }
        #endif
        let _: AnyJSON = try await tools("judge_call_cancel", ["p_match_id": .string(matchId)])
    }

    static func judgeResolve(_ callId: String) async throws {
        Telemetry.capture("judge_resolved")
        #if DEBUG
        if ToolsDemo.on { ToolsDemo.resolve(callId); return }
        #endif
        let _: AnyJSON = try await tools("judge_call_resolve", ["p_call_id": .string(callId)])
    }

    /// Rules level and the decklist deadline (event_listing_set keys `rel`, `decklist_due_at`); a key left out stays.
    static func setEventRules(_ eventId: String, rel: String?? = nil, due: Date?? = nil) async throws {
        var patch: [String: AnyJSON] = [:]
        if let rel { patch["rel"] = rel.map { .string($0) } ?? .null }
        if let due { patch["decklist_due_at"] = due.map { .string(Leagues.iso($0)) } ?? .null }
        guard !patch.isEmpty else { return }
        #if DEBUG
        if ToolsDemo.on { return }
        #endif
        let _: AnyJSON = try await tools("event_listing_set", ["p_event_id": .string(eventId), "p_patch": .object(patch)])
    }
}

// MARK: payments, hidden until opened (entry-fees § 1 "Hidden for now")

/// `payments_account`, read once per signed-in account and again whenever the Account tab opens. Everything an
/// organizer could act on about payments draws only while `enabled`; a failed call hides it.
@MainActor
@Observable
final class PaymentsGate {
    static let shared = PaymentsGate()

    private(set) var account: PaymentsAccount?
    private var owner: String?
    private var loading = false

    var enabled: Bool { PaymentsAccount.shows(account) && owner == Repo.userId }

    /// Asks only when this account hasn't been answered for yet.
    func load() async {
        if account != nil, owner == Repo.userId { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let user = Repo.userId
        let answer = user == nil ? nil : try? await Repo.paymentsAccount()
        guard user == Repo.userId else { return }
        owner = user
        account = answer
    }

    /// connect_status answers without `enabled`: keep what payments_account said.
    func connected(_ a: PaymentsAccount) {
        guard account != nil else { return }
        var a = a
        a.enabled = account?.enabled
        account = a
    }
}

// MARK: what an event's screens read beside the event

/// The money, the room and the teams of one event, read wherever the event is re-read (on its ping, on foreground,
/// with the page's refresh) and shared by its screens. Each part is nil until the server answers and stays nil on a
/// server without it, so its rows never draw.
@MainActor
@Observable
final class EventSide {
    private static var all: [String: EventSide] = [:]
    static func of(_ eventId: String) -> EventSide {
        if let s = all[eventId] { return s }
        let s = EventSide(eventId: eventId)
        all[eventId] = s
        return s
    }

    let eventId: String
    var money: EventMoney?
    var room: EventRoom?
    var teams: TeamMine?
    private var loading = false

    init(eventId: String) { self.eventId = eventId }

    /// `teams`: only team events ask for them.
    func refresh(teams wantTeams: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        async let m = try? Repo.eventMoney(eventId)
        async let r = try? Repo.eventRoom(eventId)
        if let money = await m { self.money = money }
        if let room = await r { self.room = room }
        if wantTeams, let t = try? await Repo.teamMine(eventId) { teams = t }
    }

    func refreshMoney() async { if let m = try? await Repo.eventMoney(eventId) { money = m } }
    func refreshRoom() async { if let r = try? await Repo.eventRoom(eventId) { room = r } }
    func refreshTeams() async { if let t = try? await Repo.teamMine(eventId) { teams = t } }

    /// After a return from checkout: every 2 s for up to 20 s while your payment is pending (the webhook settles it).
    func settle() async {
        for _ in 0..<10 {
            await refreshMoney()
            guard money?.me?.status == "pending" else { return }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
        }
    }
}
