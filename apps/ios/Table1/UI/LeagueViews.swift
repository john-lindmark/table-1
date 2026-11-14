import SwiftUI

/* Leagues (contract/public-events-leagues-2026-11-13.md § 3 Clients): the league page (standings first, then its
   events), a player's season, the whole table, details, Follow. The organizer's tools are in LeagueTools.swift. */

/// League pages already read this launch, by id and slug, so a pushed screen opens on what the page showed.
@MainActor
enum LeagueCache {
    static var pages: [String: LeaguePage] = [:]
    static func keep(_ p: LeaguePage) {
        pages[p.league.id] = p
        pages[p.league.slug] = p
    }
}

/// One standings row: rank · name · points, `Q` in accent for the qualified.
struct LeagueStandingRow: View {
    let row: LeagueRow
    /// Your own row: outlined in accent.
    var mine = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(row.rank)").font(T1.mono(13)).monospacedDigit().foregroundStyle(T1.muted).frame(width: 30, alignment: .leading)
            Text(row.name).font(T1.mono(14)).lineLimit(1)
            Spacer(minLength: 0)
            if row.qualified != nil { LabelText("Q", color: T1.accent).accessibilityLabel("Qualified") }
            Text(verbatim: "\(row.points)").font(T1.mono(15)).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(T1.surface)
        .overlay { if mine { Rectangle().strokeBorder(T1.accent, lineWidth: 1) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct LeagueView: View {
    /// The league's id or slug.
    let league: String
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session
    @State private var page: LeaguePage?
    @State private var seasonId: String?
    @State private var error: String?
    @State private var missing = false

    /// `season`: the season it opens on (a profile's achievement); nil for the league's current one.
    init(league: String, path: Binding<[Route]>, season: String? = nil) {
        self.league = league
        _path = path
        _seasonId = State(initialValue: season)
    }

    var body: some View {
        T1Screen {
            Bar(title: page?.league.name ?? "League", back: { dismiss() }) {
                if let page {
                    if page.me.runs {
                        Button { path.append(.leagueTools(page.league.id)) } label: {
                            TuneIcon().fill(T1.text).frame(width: 18, height: 18).frame(width: 50, height: 50).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.vertical, -16)
                        .accessibilityLabel("Organizer tools")
                    } else {
                        LabelText(page.me.following ? "Following" : "Follow", color: page.me.following ? T1.accent : T1.text)
                            .padding(.vertical, 12).contentShape(Rectangle()).padding(.vertical, -12)
                            .onTapGesture { setFollow(!page.me.following, nil) }
                            .onLongPressGesture { followMenu(page) }
                            .accessibilityAddTraits(.isButton)
                    }
                    Button { path.append(.leagueDetails(page.league.id)) } label: {
                        ListIcon().fill(T1.text).frame(width: 18, height: 18).frame(width: 50, height: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.vertical, -16).padding(.trailing, -16).padding(.leading, -8)
                    .accessibilityLabel("Details")
                }
            }
            if missing {
                Notice("Leagues aren't available yet.")
            } else if let error {
                ListRow(title: error) { BarButton("Try again") { Task { await load() } } }
            }
            HairlineList {
                if let page {
                    seasonCell(page)
                    if let season = page.season {
                        // The season's prize pool from its cut of each entry (contract/entry-fees-2026-11-13.md § 5).
                        LeaguePoolRow(seasonId: season.id)
                        if let mine = page.myRow {
                            LeagueStandingRow(row: mine, mine: true).onTapGesture { open(mine, season) }
                        }
                        if page.standings.isEmpty {
                            ListRow(title: "No results yet")
                        }
                        ForEach(page.standings.prefix(10)) { r in
                            LeagueStandingRow(row: r).onTapGesture { open(r, season) }
                        }
                        if page.standingsCount > 10 {
                            Button { path.append(.leagueStandings(season.id, "\(page.league.name) · \(season.name)")) } label: {
                                ListRow(title: "All \(page.standingsCount)") { T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18) }
                            }
                            .buttonStyle(.plain)
                        }
                        if !page.events.isEmpty {
                            Section1("Events")
                            ForEach(Self.ordered(page.events)) { e in
                                Button { path.append(.eventPage(e.eventId, signUp: false)) } label: {
                                    ListRow(title: e.name, detail: Self.eventLine(e)) {
                                        if e.final == true { LabelText("Final", color: T1.text) }
                                        else if let m = e.multiplier, m != 1 { LabelText(Leagues.multiplierText(m), color: T1.text) }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ListRow(title: "No season yet")
                    }
                } else if error == nil, !missing {
                    Notice("Loading…")
                }
            }
            .refreshable { await load() }
        }
        .task(id: seasonId) { await load() }
        .onChange(of: session.foregrounds) { Task { await load() } }
    }

    /// The season: a dropdown when the league has several, and how far along it is.
    @ViewBuilder
    private func seasonCell(_ page: LeaguePage) -> some View {
        if let season = page.season {
            let state = season.state == "active" ? "Running" : season.state == "upcoming" ? "Upcoming" : "Over"
            if page.seasons.count > 1 {
                HStack(spacing: 1) {
                    FilterRow(cells: [
                        FilterCell(name: "Season", value: season.name,
                                   options: page.seasons.map { SelectorOption(value: $0.id, label: $0.name) }, current: season.id) { seasonId = $0 },
                    ], event: nil, screen: "league_season_picker")
                    cell(state)
                }
            } else {
                HStack(spacing: 1) {
                    cell(season.name)
                    cell(state)
                }
            }
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text.uppercased()).font(T1.mono(11)).tracking(1.5).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 50).background(T1.surface)
    }

    /// Upcoming soonest first, then finished newest first.
    static func ordered(_ events: [LeagueEvent]) -> [LeagueEvent] {
        let far = Date.distantFuture
        let upcoming = events.filter { !$0.isOver }.sorted { ($0.startDate ?? far) < ($1.startDate ?? far) }
        let over = events.filter(\.isOver).sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        return upcoming + over
    }

    /// `SUN 29 MAR · 10:00 · MODERN · MEH GAMES`, or once finished `29 MAR 2026 · MODERN · WON BY BEA`.
    static func eventLine(_ e: LeagueEvent) -> String {
        let format = e.formatLabel ?? Leagues.label(e.formatKey ?? "other")
        if e.isOver {
            return [e.startDate.map { Leagues.dateText($0) }, format, e.winner.map { "Won by \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        return Leagues.eventLine(status: e.status, currentRound: 0, formatLabel: format, venueName: e.venueName, capacity: nil,
                                 players: e.players ?? 0, km: nil, when: e.startDate.map { Leagues.whenText($0) })
    }

    private func open(_ row: LeagueRow, _ season: LeagueSeason) {
        Telemetry.capture("league_player_opened")
        path.append(.leaguePlayer(season.id, row.key, row.name))
    }

    private func followMenu(_ page: LeaguePage) {
        guard page.me.following else { setFollow(true, nil); return }
        T1Overlays.shared.showMenu(page.league.name, [
            T1MenuItem(title: page.me.notify ? "Turn notifications off" : "Turn notifications on") { setFollow(true, !page.me.notify) },
            T1MenuItem(title: "Unfollow") { setFollow(false, nil) },
        ])
    }

    private func setFollow(_ on: Bool, _ notify: Bool?) {
        guard let id = page?.league.id else { return }
        Task { @MainActor in
            do {
                let me = try await Repo.setLeagueFollow(id, follow: on, notify: notify)
                page?.me.following = me.following
                page?.me.notify = me.notify
                if let page { LeagueCache.keep(page) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func load() async {
        if page == nil, let kept = LeagueCache.pages[league] { page = kept }
        do {
            let p = try await Repo.leagueView(league, seasonId: seasonId)
            page = p
            error = nil
            LeagueCache.keep(p)
        } catch where error.isCancellation {
            return
        } catch {
            if Leagues.isMissing(error) { missing = true } else { self.error = error.localizedDescription }
        }
    }
}

/// The whole table, a hundred rows at a time.
struct LeagueStandingsView: View {
    let seasonId: String
    let title: String
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [LeagueRow] = []
    @State private var done = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: title, back: { dismiss() })
            if let error { ListRow(title: error) { BarButton("Try again") { Task { await more() } } } }
            HairlineList {
                ForEach(rows) { r in
                    LeagueStandingRow(row: r, mine: r.userId != nil && r.userId == Repo.userId)
                        .onTapGesture {
                            Telemetry.capture("league_player_opened")
                            path.append(.leaguePlayer(seasonId, r.key, r.name))
                        }
                        .onAppear { if r.id == rows.last?.id { Task { await more() } } }
                }
                if rows.isEmpty, error == nil { Notice(done ? "No results yet" : "Loading…") }
            }
        }
        .task { await more() }
    }

    @MainActor
    private func more() async {
        guard !done, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await Repo.leagueStandings(seasonId, after: rows.count)
            rows += next
            done = next.count < 100
            error = nil
        } catch where error.isCancellation {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One player's season: the points large, then each event with the place and what it earned (`·` marks a result
/// outside the best N).
struct LeaguePlayerView: View {
    let seasonId: String
    let key: String
    let name: String
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var player: LeaguePlayer?
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: player?.player.name ?? name, back: { dismiss() })
            if let error { ListRow(title: error) { BarButton("Try again") { Task { await load() } } } }
            HairlineList {
                if let p = player {
                    VStack(spacing: 8) {
                        AvatarView(name: p.player.name, userId: p.player.userId, size: 60, opensFrom: "league_player")
                        Text(verbatim: "\(p.player.points)").font(T1.mono(48)).monospacedDigit().foregroundStyle(T1.accent)
                        LabelText(Self.summary(p.player))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24).background(T1.bg)
                    ForEach(p.events) { e in
                        Button { path.append(.eventPage(e.eventId, signUp: false)) } label: {
                            ListRow(title: e.name, detail: Leagues.finishLine(place: e.place, players: e.players, formatLabel: e.formatLabel,
                                                                              when: e.startsAt.flatMap(Leagues.parseDate).map { Leagues.dateText($0) })) {
                                Text(verbatim: e.counted ? "\(e.points)" : "· \(e.points)").font(T1.mono(15)).monospacedDigit()
                                    .foregroundStyle(e.counted ? T1.text : T1.muted)
                                    .accessibilityLabel(e.counted ? "\(e.points) points" : "\(e.points) points, not counted")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else if error == nil {
                    Notice("Loading…")
                }
            }
        }
        .task { await load() }
    }

    /// `#3 · 6 EVENTS · 2 WINS · QUALIFIED`.
    static func summary(_ r: LeagueRow) -> String {
        var parts = ["#\(r.rank)", "\(r.events) event\(r.events == 1 ? "" : "s")"]
        if r.wins > 0 { parts.append("\(r.wins) win\(r.wins == 1 ? "" : "s")") }
        if r.qualified != nil { parts.append("Qualified") }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func load() async {
        do {
            player = try await Repo.leaguePlayer(seasonId, key: key)
            error = nil
        } catch where error.isCancellation {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The league's details: its description, where, the link, who runs it, and the season's rules in words.
struct LeagueDetailsView: View {
    let league: String
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session
    @State private var page: LeaguePage?
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: page?.league.name ?? "League", back: { dismiss() })
            if let error { Notice(error, error: true) }
            HairlineList {
                if let page {
                    let l = page.league
                    if let d = l.description, !d.isEmpty { LinkedText(text: d) }
                    if let r = l.region, !r.isEmpty { InfoRow(label: "Region", value: r) }
                    if let link = l.link, let url = URL(string: link) {
                        Button { session.webPage = WebPage(url: url) } label: {
                            InfoRow(label: "Link", value: link.replacingOccurrences(of: "https://", with: ""))
                        }
                        .buttonStyle(.plain)
                    }
                    if let o = l.organizers, !o.isEmpty { InfoRow(label: o.count == 1 ? "Organizer" : "Organizers", value: o.joined(separator: "\n")) }
                    if let s = page.season {
                        Section1(s.name)
                        if let a = Leagues.parseDay(s.startsOn), let b = Leagues.parseDay(s.endsOn) {
                            InfoRow(label: "Dates", value: "\(Leagues.dateText(a)) – \(Leagues.dateText(b))")
                        }
                        InfoRow(label: "Points", value: Leagues.pointsWords(s.points).replacingOccurrences(of: " · ", with: "\n"))
                        if let n = s.bestN { InfoRow(label: "Counts", value: "Best \(n) results") }
                        let q = Leagues.qualifyWords(s.qualify)
                        if !q.isEmpty { InfoRow(label: "Qualify", value: q) }
                    }
                    if page.me.following {
                        T1Switch(title: "Notifications", isOn: Binding(get: { page.me.notify }, set: { setNotify($0) }))
                    }
                } else if error == nil {
                    Notice("Loading…")
                }
            }
        }
        .task {
            page = LeagueCache.pages[league]
            if let p = try? await Repo.leagueView(league) { page = p; LeagueCache.keep(p) }
        }
    }

    private func setNotify(_ on: Bool) {
        guard let id = page?.league.id else { return }
        page?.me.notify = on
        Task { @MainActor in
            do {
                let me = try await Repo.setLeagueFollow(id, follow: true, notify: on)
                page?.me.notify = me.notify
                if let page { LeagueCache.keep(page) }
            } catch {
                page?.me.notify = !on
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: boards

/// A format board: your rating large with rank and record when you have one, then the listed players.
struct BoardView: View {
    let board: String
    @Environment(\.dismiss) private var dismiss
    @State private var data: Leaderboard?
    @State private var done = false
    @State private var loading = false
    @State private var error: String?
    @State private var missing = false

    var body: some View {
        T1Screen {
            Bar(title: data?.label ?? Leagues.label(board), back: { dismiss() })
            if missing {
                Notice("Boards aren't available yet.")
            } else if let error {
                ListRow(title: error) { BarButton("Try again") { Task { await more() } } }
            }
            HairlineList {
                if let data {
                    if let me = data.me {
                        VStack(spacing: 6) {
                            LabelText("Your rating")
                            Text(verbatim: "\(me.rating)").font(T1.mono(48)).monospacedDigit().foregroundStyle(T1.accent)
                            LabelText(Self.mine(me))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24).background(T1.bg)
                    }
                    if data.rows.isEmpty { ListRow(title: "Nobody listed yet") }
                    ForEach(Array(data.rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 12) {
                            Text(verbatim: "\(r.rank)").font(T1.mono(13)).monospacedDigit().foregroundStyle(T1.muted).frame(width: 30, alignment: .leading)
                            AvatarView(name: r.name, userId: r.userId)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(T1.mono(14)).lineLimit(1)
                                LabelText(r.record)
                            }
                            Spacer(minLength: 0)
                            Text(verbatim: "\(r.rating)").font(T1.mono(15)).monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(T1.surface)
                        .overlay { if r.userId != nil, r.userId == Repo.userId { Rectangle().strokeBorder(T1.accent, lineWidth: 1) } }
                        .opensProfile(r.userId, from: "board")
                        .onAppear { if i == data.rows.count - 1 { Task { await more() } } }
                    }
                } else if error == nil, !missing {
                    Notice("Loading…")
                }
            }
        }
        .task {
            Telemetry.capture("board_opened", ["board": board])
            await more()
        }
    }

    /// `#14 · 8-4-0 · 12 MATCHES`, or `4 TO GO · 3-3-0` before you're listed.
    static func mine(_ me: BoardMe) -> String {
        let place = me.rank.map { "#\($0)" } ?? (me.toGo > 0 ? "\(me.toGo) to go" : "Not listed")
        return [place, me.record, "\(me.matches) match\(me.matches == 1 ? "" : "es")"].joined(separator: " · ")
    }

    @MainActor
    private func more() async {
        guard !done, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await Repo.formatLeaderboard(board, after: data?.rows.count ?? 0)
            if var d = data { d.rows += next.rows; d.me = next.me; d.count = next.count; data = d } else { data = next }
            done = next.rows.count < 100
            error = nil
        } catch where error.isCancellation {
            return
        } catch {
            if Leagues.isMissing(error) { missing = true } else { self.error = error.localizedDescription }
        }
    }
}

// MARK: achievements on profiles (contract § 7)

/// A profile's achievements: small tiles in a row that scrolls sideways, a code over its label. The accent outline
/// marks a champion and a first place. A league tile opens the league on that season, a board tile the board.
struct AchievementsRow: View {
    let items: [Achievement]
    @Environment(SessionModel.self) private var session

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(items) { item in
                    let t = Leagues.achievementText(item)
                    Button { open(item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: t.code).font(T1.mono(15, .semibold)).tracking(2).lineLimit(1)
                                .foregroundStyle(t.accent ? T1.accent : T1.text)
                            // The label's two halves each on a line, so a long league name never hides its season.
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(t.label.components(separatedBy: " · ").enumerated()), id: \.offset) { _, part in
                                    Text(verbatim: part.uppercased()).font(T1.mono(9)).tracking(1.5).foregroundStyle(T1.muted)
                                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(12)
                        .frame(width: 168, height: 88, alignment: .topLeading)
                        .background(T1.surface)
                        .overlay { if t.accent { Rectangle().strokeBorder(T1.accent, lineWidth: 1) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(t.code), \(t.label)")
                }
            }
        }
        .background(T1.bg)
    }

    private func open(_ item: Achievement) {
        Telemetry.capture("achievement_opened", ["kind": item.kind])
        if item.isBoard {
            if let board = item.board { session.pendingEventsRoute = .board(board) }
        } else if let league = item.leagueSlug ?? item.leagueId {
            Telemetry.capture("league_opened", ["from": "achievement"])
            session.pendingEventsRoute = item.seasonId.map { .leagueOn(league, $0) } ?? .league(league)
        }
    }

    /// What a profile draws: everything on your own; in View as only what would reach that viewer (level 1 a friend,
    /// 0 anyone): the part's own setting under the profile's cap, never an unlisted board, no boards when hidden.
    static func shown(_ a: ProfileAchievements?, viewAs level: Int?, profile: Visibility?) -> [Achievement] {
        guard let a else { return [] }
        guard let level, level < 3 else { return a.items }
        let part = Visibility(rawValue: a.visibility ?? "public") ?? .public
        guard SharingRules.sees(level: level, profile: profile ?? .private, part: part) else { return [] }
        return a.items.filter { !$0.isBoard || (a.listed != false && $0.rank != nil) }
    }
}

/// Account → Sharing → Achievements: Private | Friends | Anyone, from your own profile_achievements. Nothing on a
/// server without it.
struct AchievementsSharing: View {
    let settings: SharingSettings
    @State private var visibility: Visibility?
    @State private var error: String?

    var body: some View {
        Group {
            LoadOnce {
                #if DEBUG
                // The friends design demo has no server: Anyone, the default.
                if FriendsStore.shared.demo != nil { visibility = .public; return }
                #endif
                guard let me = Repo.userId, let a = try? await Repo.profileAchievements(me) else { return }
                visibility = Visibility(rawValue: a.visibility ?? "public") ?? .public
            }
            if let visibility {
                SharingControl(title: "Achievements", detail: "League finishes and board ranks", own: visibility, inherits: false,
                               parent: nil, settings: settings, effect: "your league finishes and board ranks") { v in
                    if let v { change(to: v) }
                }
                if let error { Notice(error, error: true) }
            }
        }
    }

    /// Widening asks first, like every other part.
    private func change(to next: Visibility) {
        guard let before = visibility, next != before else { return }
        let was = SharingRules.reach(settings, before), will = SharingRules.reach(settings, next)
        guard will.asks < was.asks else { save(next, before); return }
        var w = SharingRules.Widening()
        if will == .public { w.anyone = ["your league finishes and board ranks"] } else { w.friends = ["your league finishes and board ranks"] }
        T1Overlays.shared.ask(w.title, message: w.message, action: "Show") { save(next, before) }
    }

    private func save(_ next: Visibility, _ before: Visibility) {
        visibility = next
        #if DEBUG
        if FriendsStore.shared.demo != nil { return }
        #endif
        Task { @MainActor in
            do {
                visibility = Visibility(rawValue: try await Repo.setAchievementsVisibility(next.rawValue)) ?? next
                error = nil
            } catch {
                visibility = before
                self.error = error.localizedDescription
            }
        }
    }
}

/// Account → Sharing → Leaderboards: Listed | Hidden. Nothing on a server without boards.
struct LeaderboardsSharing: View {
    @State private var listed: Bool?
    @State private var error: String?

    var body: some View {
        Group {
            LoadOnce {
                #if DEBUG
                // The friends design demo (`-T1LibraryDemo sharing`) has no server: listed, as a new account is.
                if FriendsStore.shared.demo != nil { listed = true; return }
                #endif
                listed = (try? await Repo.formatBoards())?.listed
            }
            if let listed {
                Section1("Leaderboards")
                T1Segmented(options: [(value: true, label: "Listed"), (value: false, label: "Hidden")],
                            selection: Binding(get: { listed }, set: { set($0) }))
                Notice("Your results in public events count either way.")
                if let error { Notice(error, error: true) }
            }
        }
    }

    private func set(_ on: Bool) {
        let before = listed
        listed = on
        #if DEBUG
        if FriendsStore.shared.demo != nil { return }
        #endif
        Task { @MainActor in
            do { listed = try await Repo.setLeaderboardsListed(on); error = nil } catch {
                listed = before
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: routes

/// The screens behind the Find, league and board routes (the Events tab and the Debug demos both push them).
struct LeaguesDestination: View {
    let route: Route
    @Binding var path: [Route]

    var body: some View {
        switch route {
        case .find(let tab): FindView(path: $path, tab: tab).screen("find")
        case .league(let league): LeagueView(league: league, path: $path).screen("league")
        case .leagueOn(let league, let season): LeagueView(league: league, path: $path, season: season).screen("league")
        case .leagueStandings(let season, let title): LeagueStandingsView(seasonId: season, title: title, path: $path).screen("league_standings")
        case .leaguePlayer(let season, let key, let name): LeaguePlayerView(seasonId: season, key: key, name: name, path: $path).screen("league_player")
        case .leagueDetails(let league): LeagueDetailsView(league: league).screen("league_details")
        case .leagueTools(let league): LeagueToolsView(league: league, path: $path).screen("league_tools")
        case .leagueSeason(let league, let season): LeagueSeasonView(leagueId: league, seasonId: season).screen("league_season")
        case .board(let key): BoardView(board: key).screen("board")
        default: EmptyView()
        }
    }
}
