import SwiftUI

// The organizer's event screen in three phases (spec: contract/organizer-phases-2026-10-14.md).
// Setup (players, seating, teams, details) → Live (round clock, results, drops) → Results (winner, rounds,
// records). The phase is derived from the event, never stored; when it changes the tab resets.

// MARK: phase

enum OrganizerPhase: Equatable {
    case setup, live, results

    static func of(_ b: EventBundle) -> OrganizerPhase {
        let status = b.event.status
        if ["completed", "archived", "cancelled"].contains(status) { return .results }
        if status == "in_progress" || !b.rounds.isEmpty { return .live }
        return .setup
    }

    var firstTab: String {
        switch self {
        case .setup: "players"
        case .live: "round"
        case .results: "standings"
        }
    }
}

/// What every phase gets from the screen: the data, the shared busy / error state, and the actions.
struct OrganizerContext {
    let b: EventBundle
    let engine: StandingsResponse
    let busy: Bool
    let error: String?
    let refresh: () async -> Void
    /// Runs a server call with the busy state, shows its error inline, then reloads.
    let act: (@escaping () async throws -> Void) -> Void
    /// Opens the set-result panel for a match; `watch` offers the life tracker (live rounds only).
    let edit: (MatchRow, Bool) -> Void
    /// Shows the Cancel event alert.
    let cancelEvent: () -> Void
    let addPlayers: () -> Void
    /// Seats players (or re-seats) and shows the answer at once; the reload follows in the background.
    let seat: () -> Void

    var event: EventRow { b.event }
}

/// The organizer's screen: picks Setup, Live or Results from the event's state.
struct OrganizerView: View {
    let b: EventBundle
    let engine: StandingsResponse
    let refresh: () async -> Void
    let showSeating: ([SeatingPod]) -> Void
    let addPlayers: () -> Void
    @Environment(SessionModel.self) private var session
    @State private var tab: String
    @State private var busy = false
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var cancelReason = ""

    init(b: EventBundle, engine: StandingsResponse, refresh: @escaping () async -> Void,
         showSeating: @escaping ([SeatingPod]) -> Void, addPlayers: @escaping () -> Void) {
        self.b = b
        self.engine = engine
        self.refresh = refresh
        self.showSeating = showSeating
        self.addPlayers = addPlayers
        _tab = State(initialValue: OrganizerPhase.of(b).firstTab)
    }

    var body: some View {
        let phase = OrganizerPhase.of(b)
        let ctx = OrganizerContext(
            b: b, engine: engine, busy: busy, error: error, refresh: refresh,
            act: { block in act(block) },
            edit: { m, watch in edit(m, watch: watch) },
            cancelEvent: { confirmCancel = true },
            addPlayers: addPlayers,
            seat: { seat() }
        )
        Group {
            switch phase {
            case .setup: OrganizerSetupView(ctx: ctx, tab: $tab)
            case .live: OrganizerLiveView(ctx: ctx, tab: $tab)
            case .results: OrganizerResultsView(ctx: ctx, tab: $tab)
            }
        }
        .onChange(of: phase) { _, next in
            tab = next.firstTab
            error = nil
        }
        .alert("Cancel this event?", isPresented: $confirmCancel) {
            TextField("Reason (optional)", text: $cancelReason)
            Button("Cancel event", role: .destructive) { cancel() }
            Button("Keep event", role: .cancel) {}
        } message: {
            Text("Everyone in it is told it's off and their Live Activity ends. Results already confirmed stay on players' records; unreported matches don't count. This can't be undone.")
        }
    }

    @MainActor
    private func cancel() {
        let id = b.event.id
        let reason = cancelReason
        act { try await Repo.cancelEvent(id, reason: reason) }
    }

    /// The organizer's result editor, as a panel over the event.
    @MainActor
    private func edit(_ m: MatchRow, watch: Bool) {
        let b = b
        let session = session
        var onWatch: (() -> Void)?
        if watch && !m.isBye {
            onWatch = { session.openTracker(matchId: m.id) }   // closes the panel too
        }
        let watchAction = onWatch
        T1Overlays.shared.present {
            EditResultSheet(m: m, b: b, onSave: { s0, s1, draws in
                T1Overlays.shared.dismissPanel()
                act { try await Repo.setMatchResult(m.id, side0: s0, side1: s1, draws: draws, reason: "Set by organizer") }
            }, onWatch: watchAction)
        }
    }

    @MainActor
    private func seat() {
        guard !busy else { return }
        busy = true
        error = nil
        let id = b.event.id
        Task { @MainActor in
            do {
                showSeating(try await Repo.seatPlayers(id))
                busy = false
                await refresh()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    @MainActor
    private func act(_ block: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await block()
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: 1. Setup

private struct OrganizerSetupView: View {
    let ctx: OrganizerContext
    @Binding var tab: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStart = false

    private var b: EventBundle { ctx.b }
    private var event: EventRow { ctx.b.event }
    private var active: [ParticipantRow] { b.participants.filter { $0.status == "active" } }
    private var seating: [SeatingPod] { ctx.engine.seating ?? [] }

    private var tabs: [(id: String, label: String)] {
        var list: [(id: String, label: String)] = [(id: "players", label: "Players")]
        if event.isDraft { list.append((id: "seating", label: "Seating")) }
        if event.isTeamEvent { list.append((id: "teams", label: "Teams")) }
        list.append((id: "details", label: "Details"))
        return list
    }

    var body: some View {
        T1Screen {
            Bar(title: event.name, subtitle: "\(event.shortCode) · Setup · \(playersText(b.participants.count)) · \(event.label)") {
                BarButton("Back") { dismiss() }
                BarButton("More") { showMore() }
            }
            PhaseTabs(tabs: tabs, selection: $tab)
            if let error = ctx.error { Notice(error, error: true) }

            switch tab {
            case "seating": seatingTab
            case "teams": TeamsEditor(b: b, refresh: ctx.refresh)
            case "details": EventDetailsEditor(b: b, refresh: ctx.refresh)
            default: playersTab
            }

            BigAction(text: startBlocker ?? "Start event · pair round 1", enabled: startBlocker == nil, busy: ctx.busy, accent: true) {
                confirmStart = true
            }
            .alert("Start \(event.name)?", isPresented: $confirmStart) {
                Button("Not yet", role: .cancel) {}
                Button("Start") { start() }
            } message: {
                Text(startMessage)
            }
        }
    }

    // MARK: tabs

    private var playersTab: some View {
        HairlineList {
            HStack(spacing: 1) {
                Ghost(text: "Add players", accent: true) { ctx.addPlayers() }
                Ghost(text: "Show join QR") { showJoinQR() }
            }
            ListRow(title: "Join code") {
                Text(event.shortCode).font(T1.mono(18)).tracking(4)
            }
            Section1("Players · \(b.participants.count)")
            if b.participants.isEmpty {
                Notice("No one yet. Add people you've played with, or show the join QR.")
            }
            ForEach(b.participants) { p in
                ListRow(title: p.displayName, detail: playerDetail(p))
            }
        }
    }

    private var seatingTab: some View {
        HairlineList {
            Ghost(text: ctx.busy ? "Working…" : (seating.isEmpty ? "Seat players" : "Re-seat"), accent: seating.isEmpty) { seat() }
            if seating.isEmpty {
                Notice("Seat players for the draft, then start the event: round 1 pairs across the table.")
            } else {
                SeatingList(pods: seating, teamDraft: event.formatName == "team_draft")
            }
        }
    }

    // MARK: start

    /// Why the event can't start yet, shown on the big action (nil = ready).
    private var startBlocker: String? {
        if active.count < 2 { return "Add at least 2 players" }
        if event.isTeamEvent { return teamProblem }
        return nil
    }

    /// Every active player on a team; team draft needs exactly two teams; no team over size.
    private var teamProblem: String? {
        let loose = active.filter { $0.teamId == nil }.count
        if loose > 0 { return "\(loose) player\(loose == 1 ? " isn't" : "s aren't") on a team yet" }
        var sizes: [String: Int] = [:]
        for p in active { if let t = p.teamId { sizes[t, default: 0] += 1 } }
        if event.formatName == "team_draft" && sizes.count != 2 { return "A team draft needs exactly two teams" }
        if sizes.count < 2 { return "Add at least two teams" }
        let size = event.teamSize ?? 3
        if let over = sizes.first(where: { $0.value > size }) {
            let name = ctx.engine.teams?.first(where: { $0.teamId == over.key })?.name ?? "A team"
            return "\(name) has more than \(size) players"
        }
        return nil
    }

    private var startMessage: String {
        let minutes = event.roundLengthSeconds / 60
        let pairs = event.isDraft ? "Pairs round 1 across the table" : "Pairs round 1"
        return "\(pairs) and starts the \(minutes)-minute clock. Format, rounds and teams lock."
    }

    @MainActor
    private func start() {
        let id = event.id
        ctx.act { try await pairNext(id) }
    }

    @MainActor
    private func seat() {
        guard !ctx.busy else { return }
        ctx.seat()
    }

    // MARK: menus and panels

    @MainActor
    private func showMore() {
        let add = ctx.addPlayers
        let cancel = ctx.cancelEvent
        let id = event.id
        let name = event.name
        T1Overlays.shared.showMenu(name, [
            T1MenuItem(title: "Add players") { add() },
            T1MenuItem(title: "Show join QR") { presentJoinQR(eventId: id, name: name) },
            T1MenuItem(title: "Cancel event", destructive: true) { cancel() },
        ])
    }

    @MainActor
    private func showJoinQR() {
        presentJoinQR(eventId: event.id, name: event.name)
    }

    private func playerDetail(_ p: ParticipantRow) -> String {
        var parts = [p.userId == nil ? "Guest" : "Joined"]
        if event.isTeamEvent, let team = ctx.engine.teamOf(p.id) {
            let slot: Int? = p.teamSlot ?? team.members.first(where: { $0.participantId == p.id })?.slot
            parts.append("\(team.name) \(slotLetter(slot))")
        }
        if p.status == "dropped" { parts.append("Dropped") }
        return parts.joined(separator: " · ")
    }
}

/// The existing join QR, as a T1 panel.
@MainActor
private func presentJoinQR(eventId: String, name: String) {
    T1Overlays.shared.present {
        VStack(spacing: 1) {
            Bar(title: "Join QR", subtitle: name) {
                BarButton("Done") { T1Overlays.shared.dismissPanel() }
            }
            ShareQR(eventId: eventId)
        }
        .foregroundStyle(T1.text)
    }
}

/// Setup → Details: editable until round 1 is paired. Every change sends the full state to
/// update_event_details — text after a 600 ms pause, steppers and pickers at once.
private struct EventDetailsEditor: View {
    let b: EventBundle
    let refresh: () async -> Void

    struct DetailsForm: Equatable {
        var name: String
        var kind: EventKind
        var constructedFormat: FormatOption
        var limitedFormat: FormatOption
        var formatOther: String
        var product: EventProduct
        var chosenSet: DraftableSet?
        var typedSetName: String
        var cubeName: String
        var cubeUrl: String
        var teamSize: Int
        var rounds: Int
        var minutes: Int

        init(_ e: EventRow) {
            let f = FormatOption(rawValue: e.formatName ?? "") ?? Self.legacyFormat(e.format)
            let limited = FormatOption.limited.contains(f)
            name = e.name
            kind = limited ? .limited : .constructed
            constructedFormat = limited ? .modern : f
            limitedFormat = limited ? f : .draft
            formatOther = e.formatOther ?? ""
            product = e.cubeName == nil ? .set : .cube
            chosenSet = e.setCode.map { code in
                DraftableSet(code: code, name: e.setName ?? code.uppercased(), setType: nil, releasedAt: nil, iconSvgUri: nil)
            }
            typedSetName = e.setCode == nil ? (e.setName ?? "") : ""
            cubeName = e.cubeName ?? ""
            cubeUrl = e.cubeUrl ?? ""
            teamSize = e.teamSize ?? 3
            rounds = min(15, max(1, e.numberOfRounds))
            minutes = min(240, max(10, e.roundLengthSeconds / 60))
        }

        /// Events from before typed formats.
        static func legacyFormat(_ format: String) -> FormatOption {
            switch format {
            case "sealed": .sealed
            case "constructed": .otherConstructed
            default: .draft
            }
        }

        var format: FormatOption { kind == .constructed ? constructedFormat : limitedFormat }

        /// Same choices (pickers and steppers); only typed text may differ.
        func sameChoices(_ o: DetailsForm) -> Bool {
            kind == o.kind && constructedFormat == o.constructedFormat && limitedFormat == o.limitedFormat
                && product == o.product && chosenSet == o.chosenSet && teamSize == o.teamSize
                && rounds == o.rounds && minutes == o.minutes
        }

        /// The full state, as update_event_details takes it.
        var draft: NewEventDraft {
            let f = format
            let useSet = kind == .limited && product == .set
            let useCube = kind == .limited && product == .cube
            return NewEventDraft(
                name: name,
                formatName: f.rawValue,
                rounds: rounds,
                roundMinutes: minutes,
                setCode: useSet ? chosenSet?.code : nil,
                setName: useSet ? (chosenSet?.name ?? typedSetName) : nil,
                cubeName: useCube ? cubeName : nil,
                cubeUrl: useCube ? cubeUrl.trimmingCharacters(in: .whitespaces) : nil,
                teamSize: f.isTeam ? teamSize : nil,
                formatOther: f == .otherConstructed ? formatOther : nil
            )
        }
    }

    @State private var form: DetailsForm
    /// The last state the server accepted (or the state loaded from the event).
    @State private var lastSaved: NewEventDraft
    @State private var visibility: String
    @State private var saveTask: Task<Void, Never>?
    @State private var choosingSet = false
    @State private var setsUnavailable = false
    @State private var error: String?

    init(b: EventBundle, refresh: @escaping () async -> Void) {
        self.b = b
        self.refresh = refresh
        let form = DetailsForm(b.event)
        _form = State(initialValue: form)
        _lastSaved = State(initialValue: form.draft)
        _visibility = State(initialValue: b.event.visibility ?? "link_only")
    }

    private let visibilityOptions: [(value: String, label: String)] = [
        (value: "nearby", label: "Nearby"), (value: "link_only", label: "Link only"), (value: "private", label: "Private"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                Section1("Name")
                Field(label: "Event name", text: $form.name)
                    .onChange(of: form.name) { _, v in if v.count > 80 { form.name = String(v.prefix(80)) } }

                FormatFields(kind: $form.kind, constructedFormat: $form.constructedFormat,
                             limitedFormat: $form.limitedFormat, formatOther: $form.formatOther)

                if form.kind == .limited {
                    ProductFields(product: $form.product, chosenSet: form.chosenSet, typedSetName: $form.typedSetName,
                                  cubeName: $form.cubeName, cubeUrl: $form.cubeUrl, setsUnavailable: setsUnavailable) {
                        choosingSet = true
                    }
                }

                if form.format.isTeam {
                    TeamSizeFields(format: form.format, teamSize: $form.teamSize)
                }

                Section1("Rounds")
                T1Stepper(label: "Rounds", value: $form.rounds, range: 1...15)
                T1Stepper(label: "Round length", value: $form.minutes, range: 10...240, step: 5, unit: " min")

                Section1("Who can find it")
                T1Segmented(options: visibilityOptions, selection: Binding(
                    get: { visibility },
                    set: { next in setVisibility(next) }
                ))

                if let error { Notice(error, error: true) }
                Notice("Details lock when round 1 is paired. Changes save as you make them.")
            }
        }
        .frame(maxHeight: .infinity)
        .navigationDestination(isPresented: $choosingSet) { SetPickerScreen(selected: $form.chosenSet) }
        .onChange(of: form) { old, new in formChanged(from: old, to: new) }
        .task {
            // No sets synced on the server: type the set's name instead (as on Create).
            let sets = (try? await Repo.draftableSets(query: "")) ?? []
            if sets.isEmpty { setsUnavailable = true }
        }
    }

    // MARK: saving

    @MainActor
    private func formChanged(from old: DetailsForm, to new: DetailsForm) {
        let draft = new.draft
        guard draft != lastSaved else {
            saveTask?.cancel()   // typed and undone before the pause ended
            return
        }
        schedule(draft, delay: old.sameChoices(new) ? .milliseconds(600) : .zero)
    }

    @MainActor
    private func schedule(_ draft: NewEventDraft, delay: Duration) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await save(draft)
        }
    }

    @MainActor
    private func save(_ draft: NewEventDraft) async {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "Name the event (up to 80 characters)"
            return
        }
        // The product fields already say "Links start with https://".
        if let url = draft.cubeUrl, !EventProduct.cubeUrlValid(url) { return }
        let eventId = b.event.id
        do {
            _ = try await Repo.updateEventDetails(eventId: eventId, draft)
            lastSaved = draft
            error = nil
            await refresh()
        } catch {
            if Task.isCancelled { return }   // a newer change replaced this save
            self.error = error.localizedDescription
        }
    }

    /// set_event_location pins the event where the organizer stands, with the chosen visibility.
    @MainActor
    private func setVisibility(_ next: String) {
        guard next != visibility else { return }
        let previous = visibility
        visibility = next
        let event = b.event
        Task { @MainActor in
            guard let fix = await LocationFix.shared.current() else {
                visibility = previous
                error = "Turn on location to change who can find it."
                return
            }
            do {
                try await Repo.setEventLocation(eventId: event.id, lat: fix.lat, lng: fix.lng, venue: event.venueName, visibility: next)
                error = nil
                await refresh()
            } catch {
                visibility = previous
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: 2. Live

private struct OrganizerLiveView: View {
    let ctx: OrganizerContext
    @Binding var tab: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmFinish = false
    @State private var dropping: ParticipantRow?

    private var b: EventBundle { ctx.b }
    private var event: EventRow { ctx.b.event }
    private var round: RoundRow? { b.activeRound }

    private var tabs: [(id: String, label: String)] {
        var list: [(id: String, label: String)] = [
            (id: "round", label: "Round"), (id: "standings", label: "Standings"), (id: "players", label: "Players"),
        ]
        if event.isTeamEvent { list.append((id: "teams", label: "Teams")) }
        return list
    }

    var body: some View {
        let groups = MatchGroups(round?.matches ?? [])
        T1Screen {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Bar(title: event.name, subtitle: subtitle(at: context.date)) {
                    BarButton("Back") { dismiss() }
                    BarButton("More") { showMore() }
                }
            }
            PhaseTabs(tabs: tabs, selection: $tab)
            if let error = ctx.error { Notice(error, error: true) }

            switch tab {
            case "standings": standingsTab(groups)
            case "players": playersTab
            case "teams": TeamsEditor(b: b, refresh: ctx.refresh)
            default: roundTab(groups)
            }

            bigAction
        }
    }

    /// "Round 2 of 3 · 41:07 left · Modern" (or "paused", or "time").
    private func subtitle(at date: Date) -> String {
        guard let round else {
            let last = b.rounds.map(\.number).max() ?? event.currentRound
            return "Round \(last) of \(event.numberOfRounds) · \(event.label)"
        }
        let clock: String
        if round.clockPaused {
            clock = "paused"
        } else {
            let left = round.secondsLeft(at: date)
            clock = left == 0 ? "time" : "\(clockText(left)) left"
        }
        return "Round \(round.number) of \(event.numberOfRounds) · \(clock) · \(event.label)"
    }

    // MARK: round

    @ViewBuilder
    private func roundTab(_ g: MatchGroups) -> some View {
        HairlineList {
            if let round {
                RoundClockHero(round: round, caption: caption(round, g))
                HStack(spacing: 1) {
                    Ghost(text: round.clockPaused ? "Resume clock" : "Pause clock") {
                        clock(round, round.clockPaused ? .resume : .pause)
                    }
                    Ghost(text: "+5 min") { clock(round, .add) }
                }
                if !g.disputed.isEmpty {
                    Section1("Disputed · \(g.disputed.count)")
                    ForEach(g.disputed) { m in
                        matchButton(m, detail: "Reported differently · tap to set", value: "Set", tone: T1.danger)
                    }
                }
                if !g.waiting.isEmpty {
                    Section1("Waiting · \(g.waiting.count)")
                    ForEach(g.waiting) { m in
                        matchButton(m, detail: "No result yet", value: "Set", tone: T1.text)
                    }
                }
                if !g.resultsIn.isEmpty || !g.byes.isEmpty {
                    Section1("Results in · \(g.resultsIn.count + g.byes.count)")
                    ForEach(g.resultsIn) { m in
                        matchButton(m, detail: resultDetail(m, b), value: scoreText(m), tone: T1.accent)
                    }
                    ForEach(g.byes) { m in
                        ListRow(title: "\(b.name(m.side(0)?.participantId)) · Bye")
                    }
                }
            } else {
                let next = (b.rounds.map(\.number).max() ?? 0) + 1
                Notice(next <= event.numberOfRounds
                       ? "No round running. Pair round \(next) when everyone is ready."
                       : "Every round is played. Finish the event to send final standings.")
            }
        }
    }

    /// "Round 2 of 3 · 5 of 8 results in · 1 disputed"; paused: "Paused · Round 2 of 3".
    private func caption(_ r: RoundRow, _ g: MatchGroups) -> String {
        let of = "Round \(r.number) of \(event.numberOfRounds)"
        if r.clockPaused { return "Paused · \(of)" }
        var text = "\(of) · \(g.resultsIn.count) of \(g.played) results in"
        if !g.disputed.isEmpty { text += " · \(g.disputed.count) disputed" }
        return text
    }

    private func matchButton(_ m: MatchRow, detail: String, value: String, tone: Color) -> some View {
        Button { ctx.edit(m, true) } label: {
            ListRow(title: matchTitle(m, b), detail: detail) {
                Text(value).font(T1.mono(16)).foregroundStyle(tone)
            }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func clock(_ round: RoundRow, _ action: Repo.ClockAction) {
        let id = round.id
        ctx.act { _ = try await Repo.setRoundClock(roundId: id, action: action, seconds: 300) }
    }

    // MARK: standings

    private func standingsTab(_ g: MatchGroups) -> some View {
        HairlineList {
            if g.open > 0 {
                Notice("Live: updates as results come in. \(g.open) \(g.open == 1 ? "match" : "matches") still open.")
            }
            StandingsRows(engine: ctx.engine, highlight: nil)
        }
    }

    // MARK: players

    private var playersTab: some View {
        let playing = b.participants.filter { $0.status != "dropped" }
        let dropped = b.participants.filter { $0.status == "dropped" }
        return HairlineList {
            Section1("Playing · \(playing.count)")
            ForEach(playing) { p in
                ListRow(title: p.displayName, detail: recordDetail(p)) {
                    BarButton("Drop") { dropping = p }
                }
            }
            if !dropped.isEmpty {
                Section1("Dropped · \(dropped.count)")
                ForEach(dropped) { p in
                    ListRow(title: p.displayName,
                            detail: p.droppedInRound.map { "Dropped after round \($0) · still counts in tiebreakers" }
                                ?? "Dropped · still counts in tiebreakers") {
                        BarButton("Reinstate") { setStatus(p, dropped: false) }
                    }
                }
            }
        }
        .alert("Drop \(dropping?.displayName ?? "player")?",
               isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
               presenting: dropping) { p in
            Button("Keep", role: .cancel) {}
            Button("Drop", role: .destructive) { setStatus(p, dropped: true) }
        } message: { _ in
            Text("They won't be paired again. Their results so far still count.")
        }
    }

    private func recordDetail(_ p: ParticipantRow) -> String? {
        guard let s = ctx.engine.standings.first(where: { $0.participantId == p.id }) else { return nil }
        return "\(recordText(s.matchWins, s.matchLosses, s.matchDraws)) · \(s.matchPoints) points"
    }

    @MainActor
    private func setStatus(_ p: ParticipantRow, dropped: Bool) {
        let id = p.id
        let roundNumber = b.activeRound?.number ?? b.rounds.map(\.number).max() ?? event.currentRound
        ctx.act {
            try await Repo.setParticipantStatus(participantId: id, status: dropped ? "dropped" : "active",
                                                droppedInRound: dropped ? roundNumber : nil)
        }
    }

    // MARK: big action

    @ViewBuilder
    private var bigAction: some View {
        let nextNumber = (b.rounds.map(\.number).max() ?? 0) + 1
        let outstanding = round?.matches.filter { !$0.isBye && ($0.status == "pending" || ($0.disputed && $0.status != "confirmed")) }.count ?? 0   // disputes block pairing too
        let activePlayers = b.participants.filter { $0.status == "active" }.count
        if round == nil && nextNumber <= event.numberOfRounds {
            BigAction(text: "Pair round \(nextNumber)", enabled: activePlayers >= 2, busy: ctx.busy, accent: true) { pair() }
        } else if round != nil && outstanding > 0 {
            BigAction(text: "Waiting on \(outstanding) result\(outstanding == 1 ? "" : "s")", enabled: false) {}
        } else if let round, round.number < event.numberOfRounds {
            BigAction(text: "Pair round \(round.number + 1)", busy: ctx.busy, accent: true) { pair() }
        } else if !b.rounds.isEmpty {
            BigAction(text: "Finish event", busy: ctx.busy, accent: true) { confirmFinish = true }
                .alert("Finish \(event.name)?", isPresented: $confirmFinish) {
                    Button("Not yet", role: .cancel) {}
                    Button("Finish") { finish() }
                } message: {
                    Text("Final standings go to every player and the event moves to Past. You can still correct a result afterwards.")
                }
        }
    }

    @MainActor
    private func pair() {
        let id = event.id
        ctx.act { try await pairNext(id) }
    }

    /// Records the last round and completes the event.
    @MainActor
    private func finish() {
        guard let roundId = round?.id ?? b.rounds.max(by: { $0.number < $1.number })?.id else { return }
        let eventId = event.id
        ctx.act { try await Repo.recordRound(eventId: eventId, roundId: roundId, finalRound: true) }
    }

    @MainActor
    private func showMore() {
        let cancel = ctx.cancelEvent
        T1Overlays.shared.showMenu(event.name, [
            T1MenuItem(title: "Cancel event", destructive: true) { cancel() },
        ])
    }
}

/// The round's matches in the order the organizer acts on them.
private struct MatchGroups {
    var disputed: [MatchRow] = []
    /// No result yet.
    var waiting: [MatchRow] = []
    /// Reported or confirmed.
    var resultsIn: [MatchRow] = []
    var byes: [MatchRow] = []

    init(_ matches: [MatchRow]) {
        for m in matches {
            if m.isBye {
                byes.append(m)
            } else if m.disputed && m.status != "confirmed" {
                disputed.append(m)
            } else if m.status == "pending" {
                waiting.append(m)
            } else {
                resultsIn.append(m)
            }
        }
    }

    /// Matches that need a result (byes excluded).
    var played: Int { disputed.count + waiting.count + resultsIn.count }
    var open: Int { disputed.count + waiting.count }
}

/// Big clock: time left in the round, counting down live; paused shows what was left.
private struct RoundClockHero: View {
    let round: RoundRow
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            if round.clockEnd != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    clock(round.secondsLeft(at: context.date))
                }
            } else {
                clock(round.secondsLeft(at: Date()))
            }
            LabelText(caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20).padding(.horizontal, 16)
        .background(T1.surface)
    }

    private func clock(_ left: Int) -> some View {
        Text(clockText(left))
            .font(T1.mono(64)).tracking(4).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.5)
            .foregroundStyle(round.clockPaused ? T1.muted : left == 0 ? T1.danger : T1.text)
    }
}

// MARK: 3. Results

private struct OrganizerResultsView: View {
    let ctx: OrganizerContext
    @Binding var tab: String
    @Environment(\.dismiss) private var dismiss

    private var b: EventBundle { ctx.b }
    private var event: EventRow { ctx.b.event }
    private var tabs: [(id: String, label: String)] {
        [(id: "standings", label: "Standings"), (id: "rounds", label: "Rounds"), (id: "players", label: "Players")]
    }

    var body: some View {
        T1Screen {
            Bar(title: event.name, subtitle: subtitle) {
                BarButton("Back") { dismiss() }
            }
            PhaseTabs(tabs: tabs, selection: $tab)
            if let error = ctx.error { Notice(error, error: true) }

            switch tab {
            case "rounds": roundsTab
            case "players": playersTab
            default: standingsTab
            }
        }
    }

    private var lastRound: Int { b.rounds.map(\.number).max() ?? 0 }

    private var dateText: String {
        let raw = event.isCancelled ? (event.cancelledAt ?? event.startsAt ?? event.createdAt) : (event.startsAt ?? event.createdAt)
        guard let raw, let date = T1Date.parse(raw) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Final · Oct 12 · 8 players · Modern"; cancelled: "Cancelled · Oct 12 · after round 2 of 3".
    private var subtitle: String {
        let parts: [String]
        if event.isCancelled {
            parts = ["Cancelled", dateText, lastRound == 0 ? "before round 1" : "after round \(lastRound) of \(event.numberOfRounds)"]
        } else {
            parts = ["Final", dateText, playersText(b.participants.count), event.label]
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: standings

    private var standingsTab: some View {
        HairlineList {
            if event.isCancelled {
                let reason = event.cancelReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Notice(reason.isEmpty ? "Cancelled by the organizer." : "Cancelled: \(reason)", error: true)
                Section1("Standings after round \(lastRound)")
                StandingsRows(engine: ctx.engine, highlight: nil)
                Notice("Confirmed results count toward records. Unplayed rounds never do.")
            } else {
                winnerCard
                Section1("Final standings")
                StandingsRows(engine: ctx.engine, highlight: nil)
            }
        }
    }

    @ViewBuilder
    private var winnerCard: some View {
        let teams = (ctx.engine.teams ?? []).sorted { $0.rank < $1.rank }
        if event.isTeamEvent, let team = teams.first {
            WinnerCard(
                label: "WINNING TEAM",
                name: team.name,
                caption: "\(recordText(team.wins, team.losses, team.draws)) · \(team.points) points · \(team.matchWins) match win\(team.matchWins == 1 ? "" : "s")",
                members: team.members.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }.map(\.displayName).joined(separator: ", ")
            )
        } else if let s = ctx.engine.standings.min(by: { $0.rank < $1.rank }) {
            let games = b.gameRecord(s.participantId)
            WinnerCard(
                label: "WINNER",
                name: s.displayName,
                caption: "\(s.matchWins)-\(s.matchLosses)-\(s.matchDraws) · \(s.matchPoints) points · games \(games.won)-\(games.lost)"
            )
        }
    }

    // MARK: rounds

    private var roundsTab: some View {
        HairlineList {
            if b.rounds.isEmpty { Notice("No rounds were played.") }
            ForEach(b.rounds.sorted(by: { $0.number > $1.number })) { r in
                Section1("Round \(r.number)")
                ForEach(r.matches.filter { !$0.isBye }) { m in
                    Button { ctx.edit(m, false) } label: {
                        ListRow(title: matchTitle(m, b), detail: m.resultSource == "organizer" ? "Set by organizer" : nil) {
                            Text(m.status == "pending" ? "Set" : scoreText(m))
                                .font(T1.mono(16))
                                .foregroundStyle(m.status == "pending" ? T1.muted : T1.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(r.matches.filter { $0.isBye }) { m in
                    ListRow(title: "\(b.name(m.side(0)?.participantId)) · Bye")
                }
            }
            if !b.rounds.isEmpty {
                Notice("Tap a match to correct its result. Standings and records update.")
            }
        }
    }

    // MARK: players

    private var playersTab: some View {
        let rank: [String: Int] = Dictionary(ctx.engine.standings.map { ($0.participantId, $0.rank) },
                                             uniquingKeysWith: { first, _ in first })
        let ordered = b.participants.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
        return HairlineList {
            Section1("Players · \(ordered.count)")
            ForEach(ordered) { p in
                let s = ctx.engine.standings.first { $0.participantId == p.id }
                ListRow(title: p.displayName, detail: finalDetail(p, s)) {
                    Text(s.map { recordText($0.matchWins, $0.matchLosses, $0.matchDraws) } ?? "–").font(T1.mono(14))
                }
            }
        }
    }

    private func finalDetail(_ p: ParticipantRow, _ s: Standing?) -> String? {
        if p.status == "dropped" {
            return p.droppedInRound.map { "Dropped after round \($0)" } ?? "Dropped"
        }
        return s.map { "#\($0.rank) · \($0.matchPoints) points" }
    }
}

/// Results → Standings: the winner (or winning team) on a surface block.
struct WinnerCard: View {
    let label: String
    let name: String
    let caption: String
    var members: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabelText(label, color: T1.accent)
            Text(name).font(T1.mono(22)).lineLimit(2)
            LabelText(caption)
            if let members, !members.isEmpty {
                Text(members).font(T1.mono(12)).foregroundStyle(T1.muted).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(T1.surface)
    }
}

// MARK: shared

/// A phase's tabs in the T1 segmented style.
private struct PhaseTabs: View {
    let tabs: [(id: String, label: String)]
    @Binding var selection: String

    var body: some View {
        T1Segmented(options: tabs.map { (value: $0.id, label: $0.label) }, selection: $selection)
    }
}

/// Pairs the next round with the engine; a refusal surfaces the engine's own message.
private func pairNext(_ eventId: String) async throws {
    let r = try await Repo.pairNextRound(eventId)
    if let message = r.error { throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func playersText(_ n: Int) -> String { "\(n) player\(n == 1 ? "" : "s")" }

/// "0:00", "9:59", "50:00".
private func clockText(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

/// "T3 · Ana v Ben"
private func matchTitle(_ m: MatchRow, _ b: EventBundle) -> String {
    "T\(m.tableNumber.map(String.init) ?? "–") · \(b.name(m.side(0)?.participantId)) v \(b.name(m.side(1)?.participantId))"
}

/// "2–1", or "1–1–1" with a drawn game.
private func scoreText(_ m: MatchRow) -> String {
    let s0 = m.side(0)?.gameWins ?? 0
    let s1 = m.side(1)?.gameWins ?? 0
    return m.gameDraws > 0 ? "\(s0)–\(s1)–\(m.gameDraws)" : "\(s0)–\(s1)"
}

/// Results in: Set by organizer / Confirmed / Reported by <name>.
private func resultDetail(_ m: MatchRow, _ b: EventBundle) -> String {
    if m.resultSource == "organizer" { return "Set by organizer" }
    if m.status == "confirmed" { return "Confirmed" }
    if let pid = m.reportedByParticipant { return "Reported by \(b.name(pid))" }
    return "Reported"
}

private extension EventBundle {
    /// Games won and lost by one player across every result in (a bye counts 2–0).
    func gameRecord(_ participantId: String) -> (won: Int, lost: Int) {
        var won = 0, lost = 0
        for r in rounds {
            for m in r.matches where m.isBye || m.status != "pending" {
                guard let mine = m.matchSides.first(where: { $0.participantId == participantId }) else { continue }
                won += mine.gameWins
                lost += m.matchSides.first(where: { $0.side != mine.side })?.gameWins ?? 0
            }
        }
        return (won, lost)
    }
}
