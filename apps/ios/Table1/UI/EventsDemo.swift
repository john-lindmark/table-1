#if DEBUG
import SwiftUI

/// Design QA without signing in (Debug only): `-T1EventsDemo <mode>` draws an event screen on sample data.
///
/// With the Create · Setup · Seating · Results · Photo switcher along the top:
/// - `create`: the create form (`-T1Kind constructed|limited`, `-T1Format <FormatOption raw value>` and
///   `-T1Product set|cube` pick its starting choices, e.g. `-T1Kind limited -T1Format roto`).
/// - `setup`: the organizer's Setup on a sample draft of 8, seated.
/// - `seating`: the seating table for 8, 7, 10 with the ends seated, and a 3 v 3 team draft.
/// - `results`: the organizer's Results of the same draft, finished after 3 rounds.
/// - `photo`: the deck photo panel (note + Rotate) on a sample picture.
///
/// Full screen, as the signed-in app draws them (no switcher):
/// - `home`: the Events home while you play round 2 (your match, an invitation, upcoming, waitlist, past), tab bar.
/// - `homeorg`: the Events home while you run round 2 (results in, a dispute), tab bar.
/// - `account`: the Account tab with a lifetime record and head-to-head, tab bar.
/// - `live`: the organizer's Live round 2 of the draft, playing table 1 yourself.
/// - `results`, as above.
/// - `player`: a player's screen in round 2 (table, opponent, report buttons, standings).
/// - `playerdone`: a player's screen once the draft is finished.
///
/// `-T1Tab <tab>` opens the organizer screen on that tab (Setup: players | seating | teams | details;
/// Live: round | standings | players; Results: standings | rounds | players).
/// "You" are Ann Ito (`Repo.demoUserId`). Server calls made from here fail (no session); everything on screen is
/// sample data, and nothing here asks for location or notifications.
struct EventsDemoRoot: View {
    static let switcherModes = ["create", "setup", "seating", "results", "photo"]
    static let fullModes = ["pods", "podslive", "home", "homeorg", "account", "live", "player", "playerdone"] + leagueModes + toolModes
    /// Entry fees, teams, a season's final, alerts and the room tools on stand-in data (EventToolsDemo.swift):
    /// - `payments` (`-T1Stripe none|setup|ready`): Account → Payments. `fee`: the fee editor. `pool`: the Prize pool.
    /// - `pay` (`-T1Pay unpaid|pending|paid|refunded`): a player's screen before round 1 with their entry.
    /// - `paysetup`: the organizer's Setup with payment tags. `prizes`: Results → Prizes. `dues`: a league's Dues.
    /// - `triosteams`: Setup → Teams of a Team Trios event whose teams sign themselves up. `teampage`: the event page's
    ///   Sign up a team / Join a team. `myteam`: Your team as its captain.
    /// - `teamcut`: a Team Trios event after Swiss (Cut to top 4). `teambracket`: its semifinals and final.
    /// - `display` (`-T1Screen <name>` pretends a second screen is connected): the Display panel. `room`: Live with judge
    ///   calls and a table with extra time. `judge`: a player's match with Call a judge and `+5:00`.
    /// - `final`: a season's final's Qualified list. `alerts`: Alerts for new public events.
    /// Create with Team Trios: `-T1EventsDemo create -T1Format team_trios`.
    static let toolModes = ["payments", "fee", "pool", "pay", "paysetup", "prizes", "dues", "triosteams", "teampage", "myteam",
                            "teamcut", "teambracket", "display", "room", "judge", "final", "alerts"]
    /// Finding events, leagues and boards on stand-in data (LeaguesDemo.swift): each opens over the demo home.
    /// - `find` | `findleagues` | `boards`: Find on its Events, Leagues or Boards tab.
    /// - `board`: the Modern board. `league`: a league's page (you follow it); `leaguedetails`, `leaguestandings`,
    ///   `leagueplayer`: its details, whole table and your season.
    /// - `leagueorg`: the same league as its owner, on the organizer's tools; `leagueseason`: a season being edited.
    /// - `about`: an event's About and league rows.
    /// `home` shows Find events under your own events.
    static let leagueModes = ["find", "findleagues", "boards", "board", "league", "leaguedetails", "leaguestandings", "leagueplayer",
                              "leagueorg", "leagueseason", "about"]

    @State private var screen: String
    @State private var path: [Route]
    @State private var accountPath: [LibraryRoute] = []
    private let full: Bool
    private let startTab: String?

    init() {
        let pick = Self.arg("-T1EventsDemo") ?? "create"
        let mode = (Self.switcherModes + Self.fullModes).contains(pick) ? pick : "create"
        _screen = State(initialValue: mode)
        full = Self.fullModes.contains(mode)
        startTab = Self.arg("-T1Tab")
        Repo.demoUserId = DemoData.me
        let leagues = Self.leagueModes.contains(mode)
        DemoScreens.home = mode == "home" || leagues ? DemoData.playerHome : mode == "homeorg" ? DemoData.organizerHome : nil
        DemoScreens.snapshots = mode == "home" || leagues ? [DemoData.playSnapshot] : []
        LeaguesDemo.on = true
        LeaguesDemo.role = ["leagueorg", "leagueseason", "setup"].contains(mode) ? "owner" : nil
        let league = Route.league(LeaguesDemo.slug)
        let start: [Route] = switch mode {
        case "find": [.find("events")]
        case "findleagues": [.find("leagues")]
        case "boards": [.find("boards")]
        case "board": [.find("boards"), .board("modern")]
        case "league": [league]
        case "leaguedetails": [league, .leagueDetails(LeaguesDemo.leagueId)]
        case "leaguestandings": [league, .leagueStandings(LeaguesDemo.seasonId, "\(LeaguesDemo.league) · 2026")]
        case "leagueplayer": [league, .leaguePlayer(LeaguesDemo.seasonId, "u:\(LeaguesDemo.me)", "Ann Ito")]
        case "leagueorg": [league, .leagueTools(LeaguesDemo.leagueId)]
        case "leagueseason": [league, .leagueTools(LeaguesDemo.leagueId), .leagueSeason(LeaguesDemo.leagueId, LeaguesDemo.seasonId)]
        case "about": [.eventPage("about", signUp: false)]
        default: []
        }
        _path = State(initialValue: start)
        ToolsDemo.on = true
        switch mode {
        case "payments":
            let s = Self.arg("-T1Stripe") ?? "setup"
            ToolsDemo.account = PaymentsAccount(connected: s != "none", ready: s == "ready", payouts: s == "ready", detailsSubmitted: s == "ready", disabledReason: nil)
        case "fee", "pool", "paysetup": ToolsDemo.startFee()
        case "pay":
            ToolsDemo.organizer = false
            ToolsDemo.startFee(mine: Self.arg("-T1Pay") ?? "unpaid")
        case "prizes":
            ToolsDemo.startFee(mine: "paid")
            ToolsDemo.finished = true
            ToolsDemo.prizePaid = ["p1": "cash"]
        case "room": ToolsDemo.startRoom()
        case "display":
            ToolsDemo.startRoom()
            SecondScreen.shared.demoName = Self.arg("-T1Screen")
        case "judge":
            ToolsDemo.organizer = false
            ToolsDemo.myMatch = "m2-1"
            ToolsDemo.extras = ["m2-1": 300]
            // `-T1Judge open`: the call already made (JUDGE CALLED with Cancel).
            if Self.arg("-T1Judge") == "open" { ToolsDemo.judge("m2-1", open: true) }
        case "triosteams": ToolsDemo.teamSignup = true
        case "teampage", "myteam":
            ToolsDemo.organizer = false
            ToolsDemo.teamSignup = true
            ToolsDemo.onTeam = mode == "myteam"
        case "final": ToolsDemo.isFinal = true
        default: break
        }
        if Self.toolModes.contains(mode) || mode == "setup" {
            Task { @MainActor in await EventSide.of(DemoData.eventId).refresh(teams: true) }
        }
        DemoScreens.account = mode == "account" ? DemoData.account : nil
        DemoScreens.deckPhotos = mode == "account" ? DemoData.myDeckPhotos : nil
    }

    static func arg(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            if !full {
                T1Segmented(options: [(value: "create", label: "Create"), (value: "setup", label: "Setup"),
                                      (value: "seating", label: "Seating"), (value: "results", label: "Results"),
                                      (value: "photo", label: "Photo")], selection: $screen)
            }
            switch screen {
            case "setup":
                organizer(DemoData.bundle, DemoData.engine)
            case "pods":
                // A seated draft of 15 in two pods, paired inside pods (contract/draft-pods-2026-11-09.md).
                organizer(DemoData.podsBundle, DemoData.podsEngine)
            case "podslive":
                // The same two pods running round 2 inside pods: Live round, Earlier and Players by pod.
                organizer(DemoData.podsLive, DemoData.podsLiveEngine)
            case "results":
                organizer(DemoData.finished, DemoData.finalStandings)
            case "live":
                organizer(DemoData.live, DemoData.liveStandings)
            case "paysetup":
                organizer(DemoData.bundle, DemoData.engine)
            case "pay":
                PlayerView(b: DemoData.bundle.asPlayer, engine: DemoData.engine, refresh: {}, open: { _ in })
            case "prizes":
                organizer(DemoData.finished, DemoData.finalStandings, tab: "prizes")
            case "room":
                organizer(DemoData.live, DemoData.liveStandings)
            case "judge":
                PlayerView(b: DemoData.live.asPlayer, engine: DemoData.liveStandings, refresh: {}, open: { _ in })
            case "triosteams":
                organizer(DemoData.trios(rounds: 0), DemoData.triosEngine(rounds: 0), tab: "teams")
            case "teamcut":
                organizer(DemoData.trios(rounds: 3), DemoData.triosEngine(rounds: 3))
            case "teambracket":
                organizer(DemoData.trios(rounds: 5), DemoData.triosEngine(rounds: 5), tab: "standings")
            case "teampage", "myteam":
                T1Screen {
                    Bar(title: "Team Trios Open", back: {})
                    HairlineList { TeamSignUpRows(eventId: DemoData.eventId) }
                }
            case "payments":
                PaymentsPanel(account: ToolsDemo.account)
            case "fee":
                FeeEditor(eventId: DemoData.eventId, money: ToolsDemo.money(DemoData.eventId))
            case "pool":
                let money = ToolsDemo.money(DemoData.eventId)
                if let fee = money.fee, let pool = money.pool { PrizePoolPanel(fee: fee, pool: pool) }
            case "dues":
                LeagueDuesPanel(seasonId: LeaguesDemo.seasonId, money: ToolsDemo.leagueMoney)
            case "display":
                DisplayPanel(eventId: DemoData.eventId, name: DemoData.draftName)
            case "final":
                if let status = try? ToolsDemo.finalStatus(DemoData.eventId) { QualifiedPanel(eventId: DemoData.eventId, status: status) }
            case "alerts":
                AlertsPanel(alerts: ToolsDemo.alerts)
            case "player":
                PlayerView(b: DemoData.live.asPlayer, engine: DemoData.liveStandings, refresh: {}, open: { _ in })
            case "playerdone":
                PlayerView(b: DemoData.finished.asPlayer, engine: DemoData.finalStandings, refresh: {}, open: { _ in })
            case let mode where mode == "home" || mode == "homeorg" || Self.leagueModes.contains(mode):
                NavigationStack(path: $path) {
                    EventsHomeView(path: $path, isFront: true)
                        .navigationDestination(for: Route.self) { destination($0) }
                }
                .environment(\.openProfile) { path.append(.library(.social(.profile($0)))) }
                // As in the app: only a tab's root draws the tab bar.
                if path.isEmpty { T1TabBar(items: SignedInView.tabs, selection: .events) { _ in } }
            case "account":
                NavigationStack(path: $accountPath) {
                    AccountView(path: $accountPath)
                        .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0, path: $accountPath) }
                        // `-T1Open deckphotos`: Account → Deck photos opened once the stack is up.
                        // `-T1Open support[:<section>[:<entry>]]`: Account → Support, or a guide section scrolled to an entry.
                        .task {
                            guard accountPath.isEmpty, let open = Self.arg("-T1Open") else { return }
                            if open == "deckphotos" { accountPath = [.myDeckPhotos] }
                            let parts = open.split(separator: ":").map(String.init)
                            if parts.first == "support" {
                                accountPath = [.support] + (parts.count > 1 ? [.supportGuide(parts[1], parts.count > 2 ? parts[2] : nil, "demo")] : [])
                            }
                        }
                }
                .environment(\.openProfile) { accountPath.append(.social(.profile($0))) }
                T1TabBar(items: SignedInView.tabs, selection: .account) { _ in }
            case "photo":
                DeckPhotoDemo()
            case "seating":
                T1Screen {
                    Bar(title: "Seating", subtitle: "Sample pods")
                    HairlineList {
                        SeatingTable(pods: [DemoData.pod(8)], highlight: "p3")
                        SeatingTable(pods: [DemoData.pod(7)])
                        SeatingTable(pods: [DemoData.pod(10)], highlight: "p3", seatEnds: true)
                        SeatingTable(pods: [DemoData.teamPod], teamDraft: true)
                    }
                }
            default:
                NavigationStack(path: $path) { CreateEventView(path: $path) }
            }
        }
        .background(T1.bg.ignoresSafeArea())
        .environment(SessionModel())
        // The Library demo's cubes, so the cube fields show "Your cubes".
        .task { if ListsStore.shared.lists.isEmpty { LibraryDemo.start() } }
    }

    private func organizer(_ b: EventBundle, _ engine: StandingsResponse, tab: String? = nil) -> some View {
        OrganizerView(b: b, engine: engine, refresh: {}, showSeating: { _ in }, open: { _ in }, startTab: startTab ?? tab) {}
    }

    /// Taps on the demo home: its sample events open their demo screens; anything else says so.
    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .event(DemoData.liveId) where screen == "homeorg":
            organizer(DemoData.live, DemoData.liveStandings)
        case .event(DemoData.liveId):
            PlayerView(b: DemoData.live.asPlayer, engine: DemoData.liveStandings, refresh: {}, open: { _ in })
        case .create:
            CreateEventView(path: $path)
        case .library(let r):
            LibraryDestination(route: r, path: Route.library($path))
        case .find, .league, .leagueOn, .leagueStandings, .leaguePlayer, .leagueDetails, .leagueTools, .leagueSeason, .board:
            LeaguesDestination(route: route, path: $path)
        case .eventPage("about", _):
            // An event's About and league rows, as its page and the player screen draw them.
            T1Screen {
                Bar(title: "Modern Open", back: { path.removeLast() })
                HairlineList { EventAboutRows(eventId: "about", open: { path.append($0) }) }
            }
        default:
            T1Screen {
                Bar(title: "Demo", back: { path.removeLast() })
                Notice("Not part of the demo.")
            }
        }
    }
}

/// What the signed-in screens show instead of the server's answer while a full-screen demo is up
/// (`EventsHomeView` and `AccountView` read these in Debug builds only).
enum DemoScreens {
    static var home: HomeData?
    static var snapshots: [LiveSnapshot] = []
    static var account: AccountOverview?
    /// Account → Deck photos (MyDeckPhotos.swift), drawn with DeckPhotoDemo's sample picture.
    static var deckPhotos: MyDeckPhotos?
}

private extension EventBundle {
    /// The same event seen by a player (Ann Ito, seat 1).
    var asPlayer: EventBundle {
        EventBundle(event: event, participants: participants, rounds: rounds, isOrganizer: false)
    }
}

private enum DemoData {
    static let me = "demo-me"
    static let eventId = "demo-event"
    static let liveId = eventId
    static let names = ["Ann Ito", "Bo Lindqvist", "Cy Park", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Hal Brandt", "Ivy Novak", "Jo Reyes"]

    /// Names carry their day like the server's automatic names, relative to today so they match the times shown.
    static func named(_ label: String, days: Double = 0) -> String {
        "\(label) · \(EventNaming.day(Date().addingTimeInterval(days * 24 * 3600)))"
    }
    static let draftName = named("Draft · Duskmourn: House of Horror")

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func pod(_ n: Int) -> SeatingPod {
        decode(SeatingPod.self, """
        {"pod_id": "pod\(n)", "name": "Pod 1", "seats": [\((1...n).map { """
        {"seat": \($0), "participant_id": "p\($0)", "display_name": "\(names[$0 - 1])", "team": null}
        """ }.joined(separator: ","))]}
        """)
    }

    static let teamPod: SeatingPod = decode(SeatingPod.self, """
    {"pod_id": "team", "name": "Pod 1", "seats": [\((1...6).map { """
    {"seat": \($0), "participant_id": "t\($0)", "display_name": "\(names[$0 - 1])", "team": "\($0 % 2 == 1 ? "Ravens" : "Owls")"}
    """ }.joined(separator: ","))]}
    """)

    static func event(status: String, round: Int) -> EventRow {
        decode(EventRow.self, """
        {"id": "\(eventId)", "short_code": "K7Q2", "name": "\(draftName)",
         "format": "draft", "status": "\(status)", "number_of_rounds": 3, "current_round": \(round),
         "round_length_seconds": 3000, "format_name": "draft", "format_label": "Draft · Duskmourn: House of Horror",
         "set_code": "dsk", "set_name": "Duskmourn: House of Horror", "show_clock": true, "auto_name": true,
         "created_at": "\(iso(Date().addingTimeInterval(-2 * 3600)))", "venue_name": "Dragon's Lair"}
        """)
    }

    /// Eight players; seat 1 is you (Ann Ito), seats 3 and 6 are guests.
    static let participants: [ParticipantRow] = (1...8).map { i in
        decode(ParticipantRow.self, """
        {"id": "p\(i)", "event_id": "\(eventId)", "display_name": "\(names[i - 1])", "seat": \(i), "status": "active",
         "user_id": \(i == 1 ? "\"\(me)\"" : i % 3 == 0 ? "null" : "\"u\(i)\""), "pod_id": "pod8"}
        """)
    }

    static let bundle = EventBundle(event: event(status: "seated", round: 0), participants: participants, rounds: [], isOrganizer: true)

    /// `-T1EventsDemo pods`: 15 seated in Pod 1 (8) and Pod 2 (7), the organizer picked 2 pods inside pods; a 16th
    /// joined after the draw and waits unseated.
    static let podNames = names + ["Kai Sato", "Lu Bianchi", "Max Weber", "Nia Adeyemi", "Oli Kerr", "Pia Holm"]
    static let podsParticipants: [ParticipantRow] = (1...16).map { i in
        let pod = i <= 8 ? "podA" : "podB"
        let seat = i == 16 ? "null" : "\(i <= 8 ? i : i - 8)"
        return decode(ParticipantRow.self, """
        {"id": "p\(i)", "event_id": "\(eventId)", "display_name": "\(podNames[i - 1])", "seat": \(seat), "status": "active",
         "user_id": \(i == 1 ? "\"\(me)\"" : "\"u\(i)\""), "pod_id": "\(pod)"}
        """)
    }
    static let podsBundle: EventBundle = {
        var e = event(status: "seated", round: 0)
        e.pods = 2
        e.podPairing = DraftPods.inside
        e.autoRounds = true
        return EventBundle(event: e, participants: podsParticipants, rounds: [], isOrganizer: true)
    }()
    static let podsEngine: StandingsResponse = {
        func seats(_ range: ClosedRange<Int>, offset: Int) -> String {
            range.map { #"{"seat": \#($0 - offset), "participant_id": "p\#($0)", "display_name": "\#(podNames[$0 - 1])", "team": null}"# }
                .joined(separator: ",")
        }
        var r = StandingsResponse()
        r.seating = [decode(SeatingPod.self, #"{"pod_id": "podA", "name": "Pod 1", "seats": [\#(seats(1...8, offset: 0))]}"#),
                     decode(SeatingPod.self, #"{"pod_id": "podB", "name": "Pod 2", "seats": [\#(seats(9...15, offset: 8))]}"#)]
        return r
    }()

    /// `-T1EventsDemo podslive`: 15 players in Pod 1 (8) and Pod 2 (7) on round 2 of 3, paired inside pods; Pod 2's
    /// odd player out has the bye each round.
    static func bye(_ round: Int, _ a: Int) -> String {
        """
        {"id": "m\(round)-bye", "event_id": "\(eventId)", "round_id": "r\(round)", "table_number": null, "is_bye": true,
         "game_draws": 0, "status": "confirmed", "version": 1, "disputed": false, "reported_by_user": null,
         "match_sides": [{"id": "m\(round)-bye-0", "match_id": "m\(round)-bye", "participant_id": "p\(a)", "side": 0, "game_wins": 2}]}
        """
    }
    static let podsLive: EventBundle = {
        var e = event(status: "in_progress", round: 2)
        e.pods = 2
        e.podPairing = DraftPods.inside
        let r1 = round(1, active: false, [match(1, 1, 1, 5, 2, 0), match(1, 2, 2, 6, 2, 1), match(1, 3, 3, 7, 0, 2),
                                          match(1, 4, 4, 8, 2, 1), match(1, 5, 9, 12, 2, 0), match(1, 6, 10, 13, 1, 2),
                                          match(1, 7, 11, 14, 2, 1), bye(1, 15)])
        let r2 = round(2, active: true, [
            match(2, 1, 1, 2, 0, 0, status: "pending"), match(2, 2, 7, 4, 2, 1),
            match(2, 3, 5, 3, 2, 1, status: "reported", disputed: true, reportedBy: "u5"),
            match(2, 4, 6, 8, 2, 0, status: "reported", reportedBy: "u8"), match(2, 5, 9, 15, 2, 1),
            match(2, 6, 13, 11, 0, 0, status: "pending"), match(2, 7, 12, 14, 0, 0, status: "pending"), bye(2, 10),
        ])
        return EventBundle(event: e, participants: Array(podsParticipants.prefix(15)), rounds: [r1, r2], isOrganizer: true)
    }()
    static let podsLiveEngine: StandingsResponse = {
        var r = standings([(1, 1, 0, 0.33, 1.0, 0.33), (9, 1, 0, 0.33, 1.0, 0.33), (15, 1, 0, 0.33, 1.0, 0.33),
                           (7, 1, 0, 0.33, 1.0, 0.33), (13, 1, 0, 0.33, 0.67, 0.4), (2, 1, 0, 0.33, 0.67, 0.4),
                           (4, 1, 0, 0.33, 0.67, 0.4), (11, 1, 0, 0.33, 0.67, 0.4), (6, 0, 1, 1.0, 0.33, 0.67),
                           (8, 0, 1, 1.0, 0.33, 0.67), (10, 0, 1, 1.0, 0.33, 0.67), (14, 0, 1, 1.0, 0.33, 0.67),
                           (3, 0, 1, 1.0, 0.33, 0.67), (5, 0, 1, 1.0, 0.0, 0.67), (12, 0, 1, 1.0, 0.0, 0.67)])
        for i in r.standings.indices {
            r.standings[i].podId = (Int(r.standings[i].participantId.dropFirst()) ?? 0) <= 8 ? "podA" : "podB"
        }
        r.seating = podsEngine.seating
        return r
    }()

    // MARK: Team Trios (contract/teams-finals-alerts-2026-11-13.md)

    static let trioNames = podNames + ["Quin Abara", "Rae Lindgren"]
    static let teamNames = ["Ravens", "Owls", "Crows", "Hawks", "Larks", "Wrens"]
    /// Team match wins after Swiss, best first: the top four go on.
    static let teamRecords: [(w: Int, l: Int)] = [(3, 0), (2, 1), (2, 1), (1, 2), (1, 2), (0, 3)]

    /// Six teams of three, Modern / Standard / Pioneer, top 4. `rounds`: 0 = Setup with sign-up on; 3 = Swiss done (Cut
    /// to top 4); 5 = semifinals played and the final running.
    static func trios(rounds n: Int) -> EventBundle {
        var e = decode(EventRow.self, """
        {"id": "\(eventId)", "short_code": "T3R1", "name": "Team Trios Open", "format": "constructed",
         "status": "\(n == 0 ? "setup" : "in_progress")", "number_of_rounds": 3, "current_round": \(n),
         "round_length_seconds": 3000, "format_name": "team_trios", "format_label": "Team Trios", "team_size": 3,
         "seat_formats": ["modern", "standard", "pioneer"], "team_signup": \(n == 0), "top_cut": 4, "show_clock": true,
         "auto_name": false, "venue_name": "Dragon's Lair"}
        """)
        e.capacity = 24
        let players: [ParticipantRow] = (1...18).map { i in
            decode(ParticipantRow.self, """
            {"id": "p\(i)", "event_id": "\(eventId)", "display_name": "\(trioNames[i - 1])", "seat": null, "status": "active",
             "user_id": \(i == 1 ? "\"\(me)\"" : "\"u\(i)\""), "team_id": "t\((i - 1) / 3 + 1)", "team_slot": \((i - 1) % 3 + 1)}
            """)
        }
        // Team a plays team b seat against seat: three tables a pairing.
        func teamMatches(_ round: Int, _ pairs: [(Int, Int)], status: String = "confirmed") -> [String] {
            pairs.enumerated().flatMap { k, pair in
                (0..<3).map { s in
                    match(round, k * 3 + s + 1, pair.0 * 3 + s + 1, pair.1 * 3 + s + 1, status == "pending" ? 0 : (s == 2 ? 1 : 2), status == "pending" ? 0 : (s == 2 ? 2 : s), status: status)
                }
            }
        }
        var rows: [RoundRow] = []
        let swiss: [[(Int, Int)]] = [[(0, 5), (1, 4), (2, 3)], [(0, 2), (1, 3), (4, 5)], [(0, 1), (2, 4), (3, 5)]]
        for r in 0..<min(n, 3) { rows.append(round(r + 1, active: false, teamMatches(r + 1, swiss[r]))) }
        if n >= 4 {
            var semi = round(4, active: false, teamMatches(4, [(0, 3), (1, 2)]))
            semi.stage = "semifinal"
            rows.append(semi)
        }
        if n >= 5 {
            var final = round(5, active: true, [match(5, 1, 1, 4, 2, 1), match(5, 2, 2, 5, 0, 0, status: "pending"), match(5, 3, 3, 6, 0, 0, status: "pending")])
            final.stage = "final"
            rows.append(final)
        }
        return EventBundle(event: e, participants: players, rounds: rows, isOrganizer: true)
    }

    static func triosEngine(rounds n: Int) -> StandingsResponse {
        guard n > 0 else { return StandingsResponse() }
        let playoff: [String?] = n >= 5 ? ["final", "final", "semifinal", "semifinal", nil, nil] : Array(repeating: nil, count: 6)
        let teams = (0..<6).map { t -> String in
            let rec = teamRecords[t]
            let members = (0..<3).map { s in
                #"{"participant_id": "p\#(t * 3 + s + 1)", "display_name": "\#(trioNames[t * 3 + s])", "slot": \#(s + 1), "match_wins": \#(max(0, rec.w - (s == 2 ? 1 : 0))), "match_losses": \#(rec.l + (s == 2 && rec.w > 0 ? 1 : 0)), "match_draws": 0, "status": "active"}"#
            }.joined(separator: ",")
            return #"{"rank": \#(t + 1), "team_id": "t\#(t + 1)", "name": "\#(teamNames[t])", "points": \#(rec.w * 3), "wins": \#(rec.w), "losses": \#(rec.l), "draws": 0, "byes": 0, "match_wins": \#(rec.w * 2 + rec.l), "gw": 0.6, "members": [\#(members)], "swiss_rank": \#(t + 1), "playoff": \#(playoff[t].map { "\"\($0)\"" } ?? "null")}"#
        }.joined(separator: ",")
        let rows = (1...18).map { i in
            let rec = teamRecords[(i - 1) / 3]
            return #"{"rank": \#(i), "participant_id": "p\#(i)", "display_name": "\#(trioNames[i - 1])", "status": "active", "match_points": \#(rec.w * 3), "match_wins": \#(rec.w), "match_losses": \#(rec.l), "match_draws": 0, "byes": 0, "omw": 0.5, "gw": 0.6, "ogw": 0.5}"#
        }.joined(separator: ",")
        func seats(_ a: Int, _ b: Int, _ round: Int, _ k: Int, done: Int) -> String {
            (0..<3).map { s in
                let played = s < done
                let aw = played ? (s == 2 ? 1 : 2) : 0, bw = played ? (s == 2 ? 2 : s) : 0
                return #"{"match_id": "m\#(round)-\#(k * 3 + s + 1)", "table_number": \#(k * 3 + s + 1), "is_bye": false, "status": "\#(played ? "confirmed" : "pending")", "winner": \#(played ? "\"p\((aw > bw ? a : b) * 3 + s + 1)\"" : "null"), "sides": [{"participant_id": "p\#(a * 3 + s + 1)", "display_name": "\#(trioNames[a * 3 + s])", "slot": \#(s + 1), "game_wins": \#(aw)}, {"participant_id": "p\#(b * 3 + s + 1)", "display_name": "\#(trioNames[b * 3 + s])", "slot": \#(s + 1), "game_wins": \#(bw)}]}"#
            }.joined(separator: ",")
        }
        func teamMatch(_ a: Int, _ b: Int, _ round: Int, _ k: Int, done: Int) -> String {
            let wins = done == 3 ? (2, 1) : done == 1 ? (1, 0) : (0, 0)
            return #"{"table_number": \#(k * 3 + 1), "status": "\#(done == 3 ? "confirmed" : "pending")", "winner": \#(done == 3 ? "\"t\(a + 1)\"" : "null"), "sides": [{"seed": \#(a + 1), "team_id": "t\#(a + 1)", "name": "\#(teamNames[a])", "match_wins": \#(wins.0)}, {"seed": \#(b + 1), "team_id": "t\#(b + 1)", "name": "\#(teamNames[b])", "match_wins": \#(wins.1)}], "matches": [\#(seats(a, b, round, k, done: done))]}"#
        }
        let bracket = n >= 5
            ? #"[{"stage": "semifinal", "matches": [\#(teamMatch(0, 3, 4, 0, done: 3)), \#(teamMatch(1, 2, 4, 1, done: 3))]}, {"stage": "final", "matches": [\#(teamMatch(0, 1, 5, 0, done: 1))]}]"#
            : "null"
        return decode(StandingsResponse.self, #"{"standings": [\#(rows)], "teams": [\#(teams)], "top_cut": 4, "team_bracket": \#(bracket)}"#)
    }

    /// One match. Sides are numbered 0 and 1, as the server sends them (`MatchRow.side(_:)`).
    static func match(_ round: Int, _ table: Int, _ a: Int, _ b: Int, _ aw: Int, _ bw: Int,
                      status: String = "confirmed", disputed: Bool = false, reportedBy: String? = nil) -> String {
        let id = "m\(round)-\(table)"
        return """
        {"id": "\(id)", "event_id": "\(eventId)", "round_id": "r\(round)", "table_number": \(table), "is_bye": false,
         "game_draws": 0, "status": "\(status)", "version": 1, "disputed": \(disputed),
         "reported_by_user": \(reportedBy.map { "\"\($0)\"" } ?? "null"),
         "result_source": \(status == "pending" ? "null" : "\"player\""),
         "match_sides": [
           {"id": "\(id)-0", "match_id": "\(id)", "participant_id": "p\(a)", "side": 0, "game_wins": \(aw)},
           {"id": "\(id)-1", "match_id": "\(id)", "participant_id": "p\(b)", "side": 1, "game_wins": \(bw)}]}
        """
    }

    static func round(_ n: Int, active: Bool, _ matches: [String]) -> RoundRow {
        let ends = active ? "\"\(iso(Date().addingTimeInterval(31 * 60 + 17)))\"" : "null"
        return decode(RoundRow.self, """
        {"id": "r\(n)", "event_id": "\(eventId)", "number": \(n), "status": "\(active ? "active" : "completed")",
         "timer_ends_at": \(ends), "timer_status": \(active ? "\"running\"" : "null"), "timer_duration_seconds": 3000,
         "stage": "swiss", "matches": [\(matches.joined(separator: ","))]}
        """)
    }

    static let round1 = round(1, active: false, [match(1, 1, 1, 5, 2, 0), match(1, 2, 2, 6, 2, 1),
                                                 match(1, 3, 3, 7, 0, 2), match(1, 4, 4, 8, 2, 1)])
    static let round2Done = round(2, active: false, [match(2, 1, 1, 2, 2, 1), match(2, 2, 7, 4, 2, 1),
                                                     match(2, 3, 5, 3, 0, 2), match(2, 4, 6, 8, 2, 0)])
    static let round3 = round(3, active: false, [match(3, 1, 1, 7, 2, 0), match(3, 2, 2, 4, 2, 1),
                                                 match(3, 3, 3, 6, 1, 2), match(3, 4, 5, 8, 2, 0)])

    /// `-T1Repair`: round 1's table 3 corrected by the organizer after round 2 went out (the re-pair notice).
    static var liveRound1: RoundRow {
        guard ProcessInfo.processInfo.arguments.contains("-T1Repair") else { return round1 }
        var r = round1
        r.matches[2].resultSource = "organizer"
        r.matches[2].updatedAt = iso(Date().addingTimeInterval(-60))
        return r
    }
    static var liveRound2: RoundRow {
        var r = round(2, active: true, [
            match(2, 1, 1, 2, 0, 0, status: "pending"),
            match(2, 2, 7, 4, 2, 1),
            match(2, 3, 5, 3, 2, 1, status: "reported", disputed: true, reportedBy: "u5"),
            match(2, 4, 6, 8, 2, 0, status: "reported", reportedBy: "u8"),
        ])
        r.pairingsPublishedAt = iso(Date().addingTimeInterval(-19 * 60))
        return r
    }

    /// Round 2 running: your match at table 1 open, one confirmed, one disputed, one reported.
    static let live = EventBundle(
        event: event(status: "in_progress", round: 2), participants: participants,
        rounds: [liveRound1, liveRound2],
        isOrganizer: true)

    /// The sample draft, finished.
    static let finished = EventBundle(event: event(status: "completed", round: 3), participants: participants,
                                      rounds: [round1, round2Done, round3], isOrganizer: true)

    static let engine: StandingsResponse = {
        var r = StandingsResponse()
        r.seating = [pod(8)]
        return r
    }()

    /// (participant, wins, losses, omw, gw, ogw) in rank order.
    static func standings(_ rows: [(Int, Int, Int, Double, Double, Double)]) -> StandingsResponse {
        decode(StandingsResponse.self, """
        {"standings": [\(rows.enumerated().map { i, r in """
        {"rank": \(i + 1), "participant_id": "p\(r.0)", "display_name": "\(podNames[r.0 - 1])", "status": "active",
         "match_points": \(r.1 * 3), "match_wins": \(r.1), "match_losses": \(r.2), "match_draws": 0, "byes": 0,
         "omw": \(r.3), "gw": \(r.4), "ogw": \(r.5)}
        """ }.joined(separator: ","))]}
        """)
    }

    static let liveStandings = standings([(1, 1, 0, 0.33, 1.0, 0.33), (7, 1, 0, 0.33, 1.0, 0.33), (2, 1, 0, 0.33, 0.67, 0.4),
                                          (4, 1, 0, 0.33, 0.67, 0.4), (6, 0, 1, 1.0, 0.33, 0.67), (8, 0, 1, 1.0, 0.33, 0.67),
                                          (3, 0, 1, 1.0, 0.33, 0.67), (5, 0, 1, 1.0, 0.33, 0.67)])
    static let finalStandings = standings([(1, 3, 0, 0.56, 0.86, 0.5), (7, 2, 1, 0.56, 0.67, 0.52), (2, 2, 1, 0.44, 0.63, 0.51),
                                           (6, 2, 1, 0.33, 0.57, 0.49), (4, 1, 2, 0.67, 0.43, 0.55), (3, 1, 2, 0.56, 0.43, 0.53),
                                           (5, 1, 2, 0.44, 0.33, 0.5), (8, 0, 3, 0.56, 0.14, 0.53)])

    // MARK: Events home

    static func homeEvent(id: String, name: String, format: String, label: String, bucket: String, status: String,
                          organizing: Bool, playing: Bool, round: Int = 0, rounds: Int = 3, players: Int,
                          startsAt: Date? = nil, venue: String? = nil, live: String? = nil, capacity: Int? = nil) -> String {
        """
        {"id": "\(id)", "name": "\(name)", "short_code": "K7Q2", "format": "\(format)", "status": "\(status)",
         "bucket": "\(bucket)", "organizing": \(organizing), "playing": \(playing), "number_of_rounds": \(rounds),
         "current_round": \(round), "is_demo": false, "players": \(players), "my_status": "active",
         "format_label": "\(label)", "format_name": "\(format)", "show_clock": true,
         "starts_at": \(startsAt.map { "\"\(iso($0))\"" } ?? "null"), "venue_name": \(venue.map { "\"\($0)\"" } ?? "null"),
         "capacity": \(capacity.map(String.init) ?? "null"), "round": \(live ?? "null")}
        """
    }

    static func homeRound(resultsIn: Int, disputed: Int) -> String {
        """
        {"number": 2, "timer_status": "running", "duration_seconds": 3000,
         "ends_at": "\(iso(Date().addingTimeInterval(31 * 60 + 17)))", "remaining_seconds": null,
         "results_in": \(resultsIn), "matches": 4, "disputed": \(disputed), "stage": "swiss"}
        """
    }

    static func home(live: String, upcoming: [String]) -> HomeData {
        let day: TimeInterval = 24 * 3600
        let past = [
            homeEvent(id: "past-1", name: named("Modern", days: -5), format: "modern", label: "Modern", bucket: "past",
                      status: "completed", organizing: false, playing: true, round: 4, rounds: 4, players: 16),
            homeEvent(id: "past-2", name: named("Draft · Duskmourn: House of Horror", days: -7), format: "draft",
                      label: "Draft · Duskmourn: House of Horror", bucket: "past", status: "completed",
                      organizing: true, playing: true, round: 3, players: 8),
        ]
        return decode(HomeData.self, """
        {"events": [\(([live] + upcoming + past).joined(separator: ","))],
         "invites": [{"event_id": "inv-1", "name": "\(named("Vintage Cube", days: 4))", "format": "draft", "source": "invite",
                      "venue_name": "Bo's place", "starts_at": "\(iso(Date().addingTimeInterval(4 * day)))",
                      "invited_by": "Bo Lindqvist", "players": 5, "format_label": "Draft · Vintage Cube"}],
         "waitlist": [{"event_id": "wait-1", "name": "\(named("Pioneer", days: 5))", "format_label": "Pioneer",
                       "starts_at": "\(iso(Date().addingTimeInterval(5 * day)))", "venue_name": "Dragon's Lair",
                       "position": 2, "players": 24, "capacity": 24}]}
        """)
    }

    static let playerHome = home(
        live: homeEvent(id: liveId, name: draftName, format: "draft",
                        label: "Draft · Duskmourn: House of Horror", bucket: "live", status: "in_progress",
                        organizing: false, playing: true, round: 2, players: 8,
                        live: homeRound(resultsIn: 2, disputed: 1)),
        upcoming: [homeEvent(id: "up-1", name: named("Modern", days: 2), format: "modern", label: "Modern",
                             bucket: "upcoming", status: "setup", organizing: false, playing: true, rounds: 4,
                             players: 11, startsAt: Date().addingTimeInterval(2 * 24 * 3600), venue: "Dragon's Lair",
                             capacity: 16)])

    static let organizerHome = home(
        live: homeEvent(id: liveId, name: draftName, format: "draft",
                        label: "Draft · Duskmourn: House of Horror", bucket: "live", status: "in_progress",
                        organizing: true, playing: true, round: 2, players: 8,
                        live: homeRound(resultsIn: 2, disputed: 1)),
        upcoming: [homeEvent(id: "up-2", name: named("Sealed · Duskmourn: House of Horror", days: 4), format: "sealed",
                             label: "Sealed · Duskmourn: House of Horror", bucket: "upcoming", status: "setup",
                             organizing: true, playing: false, rounds: 4, players: 9,
                             startsAt: Date().addingTimeInterval(4 * 24 * 3600), venue: "Dragon's Lair", capacity: 24)])

    /// Your seat in round 2, as the Live Activity keeps it: table 1 against Bo Lindqvist.
    static let playSnapshot = LiveSnapshot(
        eventId: liveId, eventName: draftName, participantId: "p1",
        state: LiveState(phase: "playing", round: 2, rounds: 3, roundSeconds: 3000,
                         endsAt: Date().addingTimeInterval(31 * 60 + 17).timeIntervalSince1970, pausedRemaining: nil,
                         table: 1, myName: names[0], myRank: 1, myRecord: "1-0", players: 8,
                         oppName: names[1], oppRank: 3, oppRecord: "1-0", matchId: "m2-1", matchVersion: 1, mySide: 0,
                         status: "pending", myWins: 0, theirWins: 0, draws: 0, canReport: true,
                         updatedAt: Date().timeIntervalSince1970))

    // MARK: Account

    static let account: AccountOverview = decode(AccountOverview.self, """
    {"profile": {"id": "\(me)", "display_name": "\(names[0])", "handle": null},
     "record": {"match_wins": 23, "match_losses": 11, "match_draws": 2, "byes": 1,
                "game_wins": 51, "game_losses": 29, "game_draws": 3, "events_played": 12},
     "head_to_head": [\([(2, 4, 2, 0, 9, 5), (4, 3, 1, 0, 6, 3), (5, 2, 2, 0, 4, 4), (7, 1, 2, 1, 3, 5),
                        (6, 2, 0, 0, 4, 1), (8, 1, 1, 0, 3, 2)].map { r in """
        {"opponent_id": "u\(r.0)", "name": "\(names[r.0 - 1])", "match_wins": \(r.1), "match_losses": \(r.2),
         "match_draws": \(r.3), "game_wins": \(r.4), "game_losses": \(r.5), "played": \(r.1 + r.2 + r.3)}
        """ }.joined(separator: ","))]}
    """)

    static let myDeckPhotos: MyDeckPhotos = decode(MyDeckPhotos.self, """
    {"total": 3, "events": 2, "photos": [
      {"id": "dp1", "participant_id": "p1", "player": "\(names[0])", "path": "demo/1.jpg", "note": "Pool before building",
       "created_at": "2026-11-05T19:10:00Z", "turns": 0, "mine": true, "editable": true, "event_id": "ev-sealed",
       "event_name": "Thursday Sealed", "event_status": "in_progress", "format_label": "Sealed", "event_at": "2026-11-05T18:30:00Z"},
      {"id": "dp2", "participant_id": "p2", "player": "\(names[0])", "path": "demo/2.jpg", "note": "Mono red, 17 lands",
       "created_at": "2026-10-29T19:40:00Z", "turns": 1, "mine": true, "editable": true, "event_id": "ev-draft",
       "event_name": "Team Draft", "event_status": "completed", "format_label": "Team draft", "event_at": "2026-10-29T18:00:00Z"},
      {"id": "dp3", "participant_id": "p2", "player": "\(names[0])", "path": "demo/3.jpg", "note": "",
       "created_at": "2026-10-29T22:10:00Z", "turns": 0, "mine": true, "editable": true, "event_id": "ev-draft",
       "event_name": "Team Draft", "event_status": "completed", "format_label": "Team draft", "event_at": "2026-10-29T18:00:00Z"}]}
    """)

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        do { return try wireDecoder.decode(T.self, from: Data(json.utf8)) } catch { fatalError("Events demo \(T.self): \(error)") }
    }
}
#endif
