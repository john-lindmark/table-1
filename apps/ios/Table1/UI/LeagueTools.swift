import SwiftUI

/* A league's organizer tools (contract/public-events-leagues-2026-11-13.md § 3 Clients "Organizers"): make or edit a
   league, its seasons (the two presets and custom brackets, best N, qualification, Close season), who runs it, and
   an event's League row in Setup → Details. */

/// Make a league (`league` nil) or edit one: name, region, description, link.
struct LeagueEditPanel: View {
    let league: LeagueInfo?
    let done: (LeagueInfo) -> Void
    @State private var name = ""
    @State private var region = ""
    @State private var description = ""
    @State private var link = ""
    @State private var busy = false
    @State private var error: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var linkOK: Bool {
        let l = link.trimmingCharacters(in: .whitespaces)
        return l.isEmpty || (l.hasPrefix("https://") && l.count <= 300)
    }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: league == nil ? "New league" : "Edit league", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    Field(label: "Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > 60 { name = String(v.prefix(60)) } }
                    Field(label: "Region", text: $region)
                        .onChange(of: region) { _, v in if v.count > 80 { region = String(v.prefix(80)) } }
                    Button {
                        T1Overlays.shared.present(full: true) {
                            TextPanel(title: "Description", text: description) { description = $0 }.screen("league_description")
                        }
                    } label: {
                        ListRow(title: "Description", detail: description.isEmpty ? nil : "\(description.count) characters") {
                            LabelText(description.isEmpty ? "Add" : "Change", color: T1.text)
                        }
                    }
                    .buttonStyle(.plain)
                    Field(label: "Link", text: $link, url: true)
                    if !linkOK { Notice("Links start with https://", error: true) }
                    if let error { Notice(error, error: true) }
                }
            }
            BigAction(text: league == nil ? "Make league" : "Save", enabled: trimmed.count >= 2 && linkOK, busy: busy, accent: true) { save() }
        }
        .foregroundStyle(T1.text)
        .onAppear {
            guard let league, name.isEmpty else { return }
            name = league.name; region = league.region ?? ""; description = league.description ?? ""; link = league.link ?? ""
        }
    }

    private func save() {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let saved: LeagueInfo
                if let league {
                    saved = try await Repo.updateLeague(league.id, patch: ["name": trimmed, "description": description, "region": region,
                                                                           "link": link.trimmingCharacters(in: .whitespaces)])
                } else {
                    saved = try await Repo.createLeague(name: trimmed, description: description, region: region, link: link)
                }
                T1Overlays.shared.dismissPanel()
                done(saved)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The organizer's tools: Edit league, the seasons, and who runs it.
struct LeagueToolsView: View {
    let league: String
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var page: LeaguePage?
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: page?.league.name ?? "League", back: { dismiss() })
            if let error { Notice(error, error: true) }
            HairlineList {
                if let page {
                    Button {
                        T1Overlays.shared.present(full: true) {
                            LeagueEditPanel(league: page.league) { _ in Task { await load() } }.screen("league_edit")
                        }
                    } label: {
                        ListRow(title: "Edit league", detail: page.league.region) { T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18) }
                    }
                    .buttonStyle(.plain)

                    Section1("Seasons")
                    ForEach(page.seasons) { s in
                        Button { path.append(.leagueSeason(page.league.id, s.id)) } label: {
                            ListRow(title: s.name, detail: Self.seasonLine(s)) { T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18) }
                        }
                        .buttonStyle(.plain)
                    }
                    Ghost(text: "Add a season") { path.append(.leagueSeason(page.league.id, nil)) }

                    Section1("Organizers")
                    let owner = page.me.role == "owner"
                    if let members = page.members {
                        // With their accounts: the owner changes a role or removes from a row's menu; organizers read.
                        ForEach(members) { m in
                            ListRow(title: m.name, detail: m.roleLabel, avatar: AvatarView(name: m.name, userId: m.userId))
                                .onTapGesture { if owner { memberMenu(m, page) } }
                                .accessibilityAddTraits(owner ? .isButton : [])
                        }
                    } else {
                        ForEach(page.league.organizers ?? [], id: \.self) { name in
                            ListRow(title: name, avatar: AvatarView(name: name))
                        }
                    }
                    if owner {
                        Ghost(text: "Add an organizer") {
                            T1Overlays.shared.present(full: true) {
                                LeagueOrganizerPanel(leagueId: page.league.id, have: page.league.organizers ?? [],
                                                     haveIds: (page.members ?? []).map(\.userId)) { Task { await load() } }
                                    .screen("league_organizer_add")
                            }
                        }
                        Color.clear.frame(height: 15)
                        Button { askArchive(page) } label: {
                            LabelText("Archive league", color: T1.danger).frame(maxWidth: .infinity).padding(.vertical, 14).background(T1.surface)
                        }
                        .buttonStyle(.plain)
                    }
                } else if error == nil {
                    Notice("Loading…")
                }
            }
        }
        .task { await load() }
        .onAppear { if page != nil { Task { await load() } } }
    }

    /// The owner's menu for one organizer: the other role, and Remove. A refusal (a league keeps an owner) shows as
    /// the screen's error.
    private func memberMenu(_ m: LeagueMember, _ page: LeaguePage) {
        T1Overlays.shared.showMenu(m.name, [
            T1MenuItem(title: m.isOwner ? "Make organizer" : "Make owner") { setRole(m, m.isOwner ? "organizer" : "owner", page) },
            T1MenuItem(title: "Remove", destructive: true) { setRole(m, nil, page) },
        ])
    }

    private func setRole(_ m: LeagueMember, _ role: String?, _ page: LeaguePage) {
        Task { @MainActor in
            do {
                try await Repo.setLeagueMember(page.league.id, userId: m.userId, role: role)
                Telemetry.capture("league_member_set", ["role": role ?? "removed"])
                error = nil
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func askArchive(_ page: LeaguePage) {
        T1Overlays.shared.ask("Archive \(page.league.name)?",
                              message: "Its page and standings close for everyone, and it leaves Find. Its events stay as they are.",
                              action: "Archive", destructive: true) {
            Task { @MainActor in
                do {
                    _ = try await Repo.updateLeague(page.league.id, patch: ["archived": true])
                    Telemetry.capture("league_archived")
                    LeagueCache.pages[page.league.id] = nil
                    LeagueCache.pages[page.league.slug] = nil
                    path = Self.afterArchive(path)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    /// Where an archived league's screens leave you: Find → Leagues. Everything from the league's page up comes off
    /// the stack; Find is put there when the league wasn't opened from it.
    static func afterArchive(_ path: [Route]) -> [Route] {
        let base = Array(path.prefix { route in
            switch route {
            case .league, .leagueOn, .leagueTools, .leagueDetails, .leagueSeason, .leagueStandings, .leaguePlayer: false
            default: true
            }
        })
        if case .find? = base.last { return Array(base.dropLast()) + [.find("leagues")] }
        return base + [.find("leagues")]
    }

    /// `1 JAN 2026 – 31 DEC 2026 · RUNNING`.
    static func seasonLine(_ s: LeagueSeasonHead) -> String {
        let state = s.state == "active" ? "Running" : s.state == "upcoming" ? "Upcoming" : "Over"
        guard let a = Leagues.parseDay(s.startsOn), let b = Leagues.parseDay(s.endsOn) else { return state }
        return "\(Leagues.dateText(a)) – \(Leagues.dateText(b)) · \(state)"
    }

    @MainActor
    private func load() async {
        if page == nil { page = LeagueCache.pages[league] }
        do {
            let p = try await Repo.leagueView(league)
            page = p
            error = nil
            LeagueCache.keep(p)
        } catch where error.isCancellation {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Add an organizer from your friends and the people you've played.
private struct LeagueOrganizerPanel: View {
    let leagueId: String
    let have: [String]
    /// The accounts already running it, when the server sends them (else `have`, their names).
    var haveIds: [String] = []
    let done: () -> Void
    @State private var people: [Person] = []
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Add an organizer", back: { T1Overlays.shared.dismissPanel() })
            if let error { Notice(error, error: true) }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(people) { p in
                        Button { add(p) } label: {
                            ListRow(title: p.displayName, avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                                LabelText(busy == p.userId ? "…" : "Add", color: T1.text)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(busy != nil)
                    }
                    if people.isEmpty { ListRow(title: "No friends or opponents to add yet") }
                }
            }
        }
        .foregroundStyle(T1.text)
        .task {
            let friends = FriendsStore.shared.list?.friends ?? []
            let played = (try? await FriendsStore.shared.search("")) ?? []
            var seen = Set<String>()
            people = (friends + played).filter { p in
                seen.insert(p.userId).inserted && (haveIds.isEmpty ? !have.contains(p.displayName) : !haveIds.contains(p.userId))
            }
        }
    }

    private func add(_ p: Person) {
        busy = p.userId
        Task { @MainActor in
            defer { busy = nil }
            do {
                try await Repo.setLeagueMember(leagueId, userId: p.userId, role: "organizer")
                T1Overlays.shared.dismissPanel()
                done()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A season, new (`seasonId` nil) or being changed: name, dates, the points rule (Places | Match wins | Custom
/// brackets), best N, who qualifies, and Close season.
struct LeagueSeasonView: View {
    let leagueId: String
    let seasonId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var starts = Date()
    @State private var ends = Date()
    @State private var preset = "places"
    @State private var custom = Leagues.places
    @State private var bestN: Int?
    @State private var qualify = Leagues.Qualify(winners: true, passDown: true, top: 0)
    @State private var closed = false
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    private var rule: Leagues.Rule { preset == "places" ? Leagues.places : preset == "match_wins" ? Leagues.matchWins : custom }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && ends >= starts && rule.valid }

    var body: some View {
        T1Screen {
            Bar(title: seasonId == nil ? "New season" : (name.isEmpty ? "Season" : name), back: { dismiss() })
            ScrollView {
                VStack(spacing: 1) {
                    Field(label: "Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > 40 { name = String(v.prefix(40)) } }
                    day("Starts", $starts)
                    day("Ends", $ends)
                    if ends < starts { Notice("The season ends before it starts.", error: true) }

                    Section1("Points")
                    T1Segmented(options: [(value: "places", label: "Places"), (value: "match_wins", label: "Match wins"), (value: "custom", label: "Custom")],
                                selection: $preset)
                    if preset == "custom" { brackets }
                    InfoRow(label: "Earns", value: Leagues.pointsWords(rule).replacingOccurrences(of: " · ", with: "\n"))
                    if !rule.valid { Notice("Brackets go up, and the rule has to give points.", error: true) }

                    Section1("Counts")
                    T1Switch(title: "Best results only", detail: bestN.map { "Best \($0)" } ?? "Every result",
                             isOn: Binding(get: { bestN != nil }, set: { bestN = $0 ? (bestN ?? 6) : nil }))
                    if bestN != nil {
                        T1Stepper(label: "Best", value: Binding(get: { bestN ?? 6 }, set: { bestN = $0 }), range: 1...50)
                    }

                    Section1("Qualify")
                    T1Switch(title: "Event winners", isOn: $qualify.winners)
                    if qualify.winners { T1Switch(title: "Pass down to 8th", isOn: $qualify.passDown) }
                    T1Stepper(label: "Top on points", value: $qualify.top, range: 0...64)

                    if let error { Notice(error, error: true) }
                    if seasonId != nil, loaded {
                        if closed {
                            ListRow(title: "Closed") { BarButton("Reopen") { close(false) } }
                        } else {
                            Ghost(text: "Close season") {
                                T1Overlays.shared.ask("Close \(name)?", message: "The standings become final, players who qualify on points are told, and no more events can join it.",
                                                      action: "Close season", destructive: true) { close(true) }
                            }
                        }
                    }
                }
            }
            BigAction(text: seasonId == nil ? "Add season" : "Save", enabled: valid && (loaded || seasonId == nil), busy: busy, accent: true) { save() }
        }
        .task { await load() }
    }

    private func day(_ label: String, _ date: Binding<Date>) -> some View {
        ListRow(title: label, detail: Leagues.dateText(date.wrappedValue)) {
            DatePicker(label, selection: date, displayedComponents: [.date]).labelsHidden().tint(T1.accent).colorScheme(.dark)
        }
    }

    /// Custom brackets: each a place it reaches through and its points, then To play and a Match win.
    @ViewBuilder private var brackets: some View {
        ForEach(custom.places.indices, id: \.self) { i in
            HStack(spacing: 1) {
                T1Stepper(label: "Through", value: $custom.places[i].through, range: 1...512)
                Button { custom.places.remove(at: i) } label: {
                    LabelText("Remove", color: T1.danger).padding(.horizontal, 12).frame(maxHeight: .infinity).background(T1.surface)
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: false, vertical: true)
            T1Stepper(label: "Points", value: $custom.places[i].points, range: 0...1000)
        }
        if custom.places.count < 16 {
            Ghost(text: "Add a bracket") {
                let last = custom.places.last
                custom.places.append(.init(through: min(512, max(1, (last?.through ?? 0) * 2)), points: max(0, (last?.points ?? 2) / 2)))
            }
        }
        T1Stepper(label: "To play", value: $custom.participation, range: 0...100)
        T1Stepper(label: "Match win", value: $custom.matchWin, range: 0...20)
    }

    @MainActor
    private func load() async {
        guard !loaded else { return }
        guard let seasonId else {
            // A new season: this calendar year, the Places table, winners qualify.
            let cal = Calendar.current
            let year = cal.component(.year, from: Date())
            name = "\(year)"
            starts = cal.date(from: DateComponents(year: year, month: 1, day: 1, hour: 12)) ?? Date()
            ends = cal.date(from: DateComponents(year: year, month: 12, day: 31, hour: 12)) ?? Date()
            loaded = true
            return
        }
        do {
            let p = try await Repo.leagueView(leagueId, seasonId: seasonId)
            guard let s = p.season else { return }
            name = s.name
            starts = Leagues.parseDay(s.startsOn) ?? Date()
            ends = Leagues.parseDay(s.endsOn) ?? Date()
            preset = Leagues.preset(s.points)
            custom = s.points
            bestN = s.bestN
            qualify = s.qualify
            closed = s.closed
            loaded = true
        } catch where error.isCancellation {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await Repo.setLeagueSeason(leagueId, seasonId: seasonId, name: name.trimmingCharacters(in: .whitespaces),
                                                   startsOn: Leagues.dayString(starts), endsOn: Leagues.dayString(ends),
                                                   points: rule, bestN: .some(bestN), qualify: qualify)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func close(_ on: Bool) {
        guard let seasonId else { return }
        Task { @MainActor in
            do {
                let s = try await Repo.setLeagueSeason(leagueId, seasonId: seasonId, closed: on)
                closed = s.closed
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: an event's League row (Setup → Details)

/// For organizers who run a league: the league and season this event counts for. Hidden for everyone else, and on a
/// server without leagues.
struct EventLeagueRow: View {
    let eventId: String
    @State private var mine: [LeagueCard] = []
    @State private var current: EventLeague?
    @State private var loaded = false

    var body: some View {
        Group {
            LoadOnce {
                async let home = try? await Repo.leaguesHome()
                async let about = try? await Repo.eventAbout(eventId)
                mine = (await home)?.mine ?? []
                current = (await about)?.league
                loaded = true
            }
            if loaded, !mine.isEmpty || current != nil {
                Section1("League")
                Button {
                    T1Overlays.shared.present(full: true) {
                        EventLeaguePanel(eventId: eventId, mine: mine, current: current) { current = $0 }.screen("event_league")
                    }
                } label: {
                    ListRow(title: current.map { [$0.name, $0.season].compactMap { $0 }.joined(separator: " · ") } ?? "Not in a league",
                            detail: current.flatMap(Self.detail)) {
                        LabelText(current == nil ? "Add" : "Change", color: T1.text)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `2× POINTS`, `THE FINAL`, or nothing at 1×.
    static func detail(_ l: EventLeague) -> String? {
        if l.final == true { return "The final" }
        if let m = l.multiplier, m != 1 { return "\(Leagues.multiplierText(m)) points" }
        return nil
    }
}

private struct EventLeaguePanel: View {
    let eventId: String
    let mine: [LeagueCard]
    let current: EventLeague?
    let done: (EventLeague?) -> Void
    @State private var leagueId: String?
    @State private var seasons: [LeagueSeasonHead] = []
    @State private var seasonId: String?
    @State private var multiplier = 1.0
    @State private var isFinal = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "League", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(mine) { l in
                        Button { leagueId = l.id } label: {
                            ListRow(title: l.name, detail: l.region) { if leagueId == l.id { LabelText("Picked", color: T1.accent) } }
                        }
                        .buttonStyle(.plain)
                    }
                    if leagueId != nil {
                        Section1("Season")
                        if seasons.isEmpty { ListRow(title: "No open season") }
                        ForEach(seasons) { s in
                            Button { seasonId = s.id } label: {
                                ListRow(title: s.name, detail: LeagueToolsView.seasonLine(s)) { if seasonId == s.id { LabelText("Picked", color: T1.accent) } }
                            }
                            .buttonStyle(.plain)
                        }
                        Section1("Points")
                        T1Segmented(options: Leagues.multipliers.map { (value: $0, label: Leagues.multiplierText($0)) }, selection: $multiplier)
                        T1Switch(title: "This is the final", isOn: $isFinal)
                    }
                    if let error { Notice(error, error: true) }
                    if current != nil {
                        Button { save(remove: true) } label: {
                            LabelText("Remove from league", color: T1.danger).frame(maxWidth: .infinity).padding(.vertical, 14).background(T1.surface)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            BigAction(text: "Save", enabled: seasonId != nil, busy: busy, accent: true) { save(remove: false) }
        }
        .foregroundStyle(T1.text)
        .onAppear {
            leagueId = current?.id ?? (mine.count == 1 ? mine.first?.id : nil)
            seasonId = current?.seasonId
            multiplier = current?.multiplier ?? 1
            isFinal = current?.final ?? false
        }
        .task(id: leagueId) {
            guard let leagueId else { return }
            // Seasons still running or to come (a closed season takes no events).
            let page = try? await Repo.leagueView(leagueId)
            seasons = (page?.seasons ?? []).filter { $0.state != "over" || $0.id == current?.seasonId }
            if !seasons.contains(where: { $0.id == seasonId }) { seasonId = seasons.count == 1 ? seasons.first?.id : nil }
        }
    }

    private func save(remove: Bool) {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let league = try await Repo.setLeagueEvent(eventId, seasonId: remove ? nil : seasonId, multiplier: multiplier, final: isFinal)
                T1Overlays.shared.dismissPanel()
                done(league)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
