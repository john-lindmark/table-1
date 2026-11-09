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
    /// Pushes a screen over the event (redraft, deck photos).
    let open: (Route) -> Void
    /// Seats players (or re-seats) and shows the answer at once; the reload follows in the background.
    let seat: () -> Void
    /// Runs a seating change (move, swap) and shows its answer at once; the reload follows.
    let reseat: (@escaping () async throws -> [SeatingPod]) -> Void

    var event: EventRow { b.event }
}

/// The organizer's screen: picks Setup, Live or Results from the event's state.
struct OrganizerView: View {
    let b: EventBundle
    let engine: StandingsResponse
    let refresh: () async -> Void
    let showSeating: ([SeatingPod]) -> Void
    let open: (Route) -> Void
    let addPlayers: () -> Void
    @Environment(SessionModel.self) private var session
    @State private var tab: String
    @State private var busy = false
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var cancelReason = ""

    init(b: EventBundle, engine: StandingsResponse, refresh: @escaping () async -> Void,
         showSeating: @escaping ([SeatingPod]) -> Void, open: @escaping (Route) -> Void, startTab: String? = nil,
         addPlayers: @escaping () -> Void) {
        self.b = b
        self.engine = engine
        self.refresh = refresh
        self.showSeating = showSeating
        self.open = open
        self.addPlayers = addPlayers
        // `startTab`: the design demo's `-T1Tab`; the app always opens on the phase's first tab.
        _tab = State(initialValue: startTab ?? OrganizerPhase.of(b).firstTab)
    }

    var body: some View {
        let phase = OrganizerPhase.of(b)
        let ctx = OrganizerContext(
            b: b, engine: engine, busy: busy, error: error, refresh: refresh,
            act: { block in act(block) },
            edit: { m, watch in edit(m, watch: watch) },
            cancelEvent: { confirmCancel = true },
            addPlayers: addPlayers,
            open: open,
            seat: { seat() },
            reseat: { block in reseat(block) }
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
    private func reseat(_ block: @escaping () async throws -> [SeatingPod]) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                showSeating(try await block())
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
    @State private var removing: ParticipantRow?
    /// Players removed here, hidden at once while the server call and reload catch up.
    @State private var removed: Set<String> = []
    @State private var removeError: String?
    @State private var guestName = ""
    /// Seating: the player picked by "Swap with…", waiting for the other tap.
    @State private var swapFrom: SeatingPod.Seat?

    private var b: EventBundle { ctx.b }
    private var participants: [ParticipantRow] { b.participants.filter { !removed.contains($0.id) } }
    private var event: EventRow { ctx.b.event }
    private var active: [ParticipantRow] { participants.filter { $0.status == "active" } }
    private var seating: [SeatingPod] { ctx.engine.seating ?? [] }
    private var me: ParticipantRow? { participants.first { $0.userId != nil && $0.userId == Repo.userId } }
    private var guestTrimmed: String {
        guestName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    private var guestDuplicate: Bool {
        let t = guestTrimmed.lowercased()
        return participants.contains { $0.displayName.lowercased() == t }
    }

    private var tabs: [(id: String, label: String)] {
        var list: [(id: String, label: String)] = [(id: "players", label: "Players")]
        if event.isDraft || event.isRoto { list.append((id: "seating", label: event.isRoto ? "Pick order" : "Seating")) }
        if event.isTeamEvent { list.append((id: "teams", label: "Teams")) }
        list.append((id: "details", label: "Details"))
        return list
    }

    var body: some View {
        T1Screen {
            Bar(title: event.name, subtitle: "\(event.shortCode) · Setup · \(playersText(participants.count)) · \(event.label)", back: { dismiss() }) {
                BarButton("More") { showMore() }
            }
            PhaseTabs(tabs: tabs, selection: $tab)
            if let error = ctx.error { Notice(error, error: true) }

            switch tab {
            case "seating":
                if event.isRoto { RotoPickOrderTab(b: b, busy: ctx.busy) { seat() } } else { seatingTab }
            case "teams": TeamsEditor(b: b, refresh: ctx.refresh)
            case "details": EventDetailsEditor(b: b, refresh: ctx.refresh)
            default: playersTab
            }

            if event.isRoto {
                // Roto: Start draft (roto_start) replaces Pair round 1 until the draft is done.
                RotoStartButton(event: event, store: RotoStores.store(event.id), activePlayers: active.count, busy: ctx.busy, act: ctx.act)
            } else {
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
    }

    // MARK: tabs

    private var playersTab: some View {
        HairlineList {
            HStack(spacing: 1) {
                Ghost(text: "Add players", accent: true) { ctx.addPlayers() }
                Ghost(text: "Show join QR") { showJoinQR() }
                Ghost(text: "Share link") { shareEventLink(event) }
            }
            ListRow(title: "Join code", detail: EventRules.when(event.startsAt).map { [$0, event.venueName].compactMap { $0 }.joined(separator: " · ") }) {
                Text(event.shortCode).font(T1.mono(18)).tracking(4)
            }
            Section1(event.capacity.map { "Players · \(active.count)/\($0)" } ?? "Players · \(participants.count)")
            if event.takesDecklists {
                Notice(EventRules.decklistsLine(sent: active.count - b.decklistsMissing, players: active.count)
                       + (event.decklists == "required" ? " · required before round 1" : ""))
            }
            if let removeError { Notice(removeError, error: true) }
            if me == nil {
                Button { joinAsPlayer() } label: {
                    ListRow(title: "You're not playing", detail: "Organizing only") {
                        LabelText("Join as a player", color: T1.accent)
                    }
                }
                .buttonStyle(.plain)
            }
            if participants.isEmpty {
                Notice("No one yet. Add people you've played with, or show the join QR.")
            }
            ForEach(participants) { p in
                ListRow(title: p.id == me?.id ? "You · \(p.displayName)" : p.displayName, detail: playerDetail(p),
                        avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                    HStack(spacing: 16) {
                        if event.takesDecklists {
                            Button { openDecklist(p) } label: { LabelText(b.decklist(p.id) == nil ? "Enter list" : "List", color: T1.accent) }
                                .buttonStyle(.plain)
                        }
                        if event.isBeforeRound1 {
                            Button { removing = p } label: { LabelText("Remove", color: T1.danger) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(p.displayName)")
                        }
                    }
                }
                .opensProfile(p.userId, from: "event_players")
            }
            AddByNameRow(text: $guestName, enabled: !guestTrimmed.isEmpty && !guestDuplicate && !ctx.busy) { addGuest() }
            if guestDuplicate && !guestTrimmed.isEmpty { Notice("\(guestTrimmed) is already in this event.", error: true) }
            WaitlistRows(b: b, act: ctx.act)
        }
        .alert("Remove \(removing?.displayName ?? "player")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { p in
            Button("Keep", role: .cancel) {}
            Button("Remove", role: .destructive) { remove(p) }
        } message: { p in
            Text(p.seat != nil && event.status == "seated" ? "They'll leave the event. Seats after theirs move up one." : "They'll leave the event.")
        }
    }

    @MainActor
    private func addGuest() {
        let name = guestTrimmed
        guard !name.isEmpty, !guestDuplicate else { return }
        let id = event.id
        guestName = ""
        ctx.act { try await Repo.addGuest(id, name: name) }
    }

    @MainActor
    private func openDecklist(_ p: ParticipantRow) {
        presentDecklist(event: event, participantId: p.id, playerName: p.displayName, byOrganizer: true, refresh: ctx.refresh)
    }

    @MainActor
    private func joinAsPlayer() {
        let id = event.id
        ctx.act { try await Repo.addSelf(id) }
    }

    @MainActor
    private func remove(_ p: ParticipantRow) {
        // The row goes at once; the reload follows. If the server refuses, the player comes back.
        let pid = p.id
        removed.insert(pid)
        removeError = nil
        Task { @MainActor in
            do {
                try await Repo.removeParticipant(pid)
                await ctx.refresh()
            } catch {
                removed.remove(pid)
                removeError = error.localizedDescription
            }
        }
    }

    /// Draft (not team draft or roto): pods, how rounds 2+ pair, and seats moved by hand.
    private var hasPods: Bool { event.formatName == "draft" }
    private var unseated: [ParticipantRow] {
        guard event.status == "seated" else { return [] }
        let seatedIds = Set(seating.flatMap { $0.seats.map(\.participantId) })
        return active.filter { !seatedIds.contains($0.id) }
    }

    private var seatingTab: some View {
        HairlineList {
            if hasPods {
                DraftPodFields(pods: Binding(get: { event.pods }, set: { setPods($0, event.podPairing) }),
                               pairing: Binding(get: { event.podPairing }, set: { setPods(event.pods, $0) }),
                               players: active.count, seated: !seating.isEmpty)
            }
            Ghost(text: ctx.busy ? "Working…" : (seating.isEmpty ? "Seat players" : "Randomize"), accent: seating.isEmpty) { seat() }
            if let from = swapFrom {
                ListRow(title: "Swap \(from.displayName) with…", detail: "Tap the other player") {
                    Button { swapFrom = nil } label: { LabelText("Cancel", color: T1.accent) }.buttonStyle(.plain)
                }
            }
            if seating.isEmpty {
                Notice("Seat players for the draft, then start the event: round 1 pairs across the table.")
            } else {
                T1Switch(title: "Seat the ends", detail: "Players at both ends of the table, not just the sides",
                         isOn: Binding(get: { event.seatEnds }, set: { on in
                             let id = event.id
                             ctx.act {
                                 try await Repo.setSeatEnds(id, on: on)
                                 Telemetry.capture("seat_ends_changed", ["on": on, "players": seating.reduce(0) { $0 + $1.seats.count }])
                             }
                         }))
                SeatingTable(pods: seating, teamDraft: event.formatName == "team_draft", highlight: swapFrom?.participantId ?? me?.id,
                             seatEnds: event.seatEnds, onTap: hasPods && event.isBeforeRound1 ? { seat, pod in tapSeat(seat, pod) } : nil)
                if !unseated.isEmpty {
                    Section1("Not seated · \(unseated.count)")
                    ForEach(unseated) { p in
                        ListRow(title: p.displayName, detail: "Seated at round 1, in the smallest pod",
                                avatar: AvatarView(name: p.displayName, userId: p.userId)) { EmptyView() }
                    }
                }
            }
        }
    }

    @MainActor
    private func setPods(_ pods: Int?, _ pairing: String) {
        let id = event.id
        ctx.act { try await Repo.setEventPods(id, pods: pods, pairing: pairing) }
    }

    @MainActor
    private func tapSeat(_ seat: SeatingPod.Seat, _ pod: SeatingPod) {
        if let from = swapFrom {
            swapFrom = nil
            guard from.participantId != seat.participantId else { return }
            let a = from.participantId, b = seat.participantId
            ctx.reseat { try await Repo.seatSwap(a, b) }
            return
        }
        let pid = seat.participantId
        var items = seating.filter { $0.podId != pod.podId }.map { other in
            T1MenuItem(title: "Move to \(other.name ?? "pod")", detail: "\(other.seats.count) players") {
                let to = other.podId
                ctx.reseat { try await Repo.seatMove(pid, podId: to) }
            }
        }
        if pod.seats.count > 1 {
            items.append(T1MenuItem(title: "Move to a new pod") { ctx.reseat { try await Repo.seatMove(pid, podId: nil) } })
        }
        items.append(T1MenuItem(title: "Swap with…") { swapFrom = seat })
        T1Overlays.shared.showMenu("\(pod.name ?? "Pod") · seat \(seat.seat)", message: seat.displayName, items)
    }

    // MARK: start

    /// Why the event can't start yet, shown on the big action (nil = ready).
    private var startBlocker: String? {
        if active.count < 2 { return "Add at least 2 players" }
        if event.isTeamEvent { return teamProblem }
        if event.decklists == "required", b.decklistsMissing > 0 {
            return "Waiting on \(b.decklistsMissing) decklist\(b.decklistsMissing == 1 ? "" : "s")"
        }
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
        let pairs = event.isDraft ? "Pairs round 1 across the table" : "Pairs round 1"
        let clock = event.showClock ? "starts the \(event.roundLengthSeconds / 60)-minute clock" : "starts the round (clocks hidden)"
        let rounds = event.autoRounds ? " It's \(EventRules.swissRounds(active.count)) Swiss rounds for \(active.count) players." : ""
        return "\(pairs) and \(clock). Format, rounds and teams lock.\(rounds)"
    }

    @MainActor
    private func start() {
        let id = event.id
        let pairing = event.pairing
        ctx.act { try await pairNext(id, pairing: pairing) }
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
        let e = event
        T1Overlays.shared.showMenu(name, [
            T1MenuItem(title: "Add players") { add() },
            T1MenuItem(title: "Show join QR") { presentJoinQR(eventId: id, name: name) },
            T1MenuItem(title: "Share link") { shareEventLink(e) },
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
        if let d = b.decklistDetail(p) { parts.append(d) }
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
        var showClock: Bool
        /// Roto only: swiss | round_robin.
        var pairing: String
        /// Empty = named by the server from these choices.
        var autoName: Bool
        var topCut: Int
        var autoRounds: Bool
        var decklists: String

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
            showClock = e.showClock
            pairing = e.isRoto ? e.pairing : "round_robin"
            autoName = e.autoName
            name = e.autoName ? "" : e.name
            topCut = e.topCut
            autoRounds = e.autoRounds
            decklists = e.decklists
        }

        var swiss: Bool { !format.isTeam && !(format == .roto && pairing == "round_robin") }

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
                && rounds == o.rounds && showClock == o.showClock && pairing == o.pairing
                && topCut == o.topCut && autoRounds == o.autoRounds && decklists == o.decklists
        }

        /// The full state, as update_event_details takes it.
        var draft: NewEventDraft {
            let f = format
            let useSet = kind == .limited && product == .set && f != .roto
            let useCube = kind == .limited && (product == .cube || f == .roto)
            let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return NewEventDraft(
                name: typed.isEmpty ? nil : typed,
                formatName: f.rawValue,
                rounds: rounds,
                showClock: showClock,
                setCode: useSet ? chosenSet?.code : nil,
                setName: useSet ? (chosenSet?.name ?? typedSetName) : nil,
                cubeName: useCube ? cubeName : nil,
                cubeUrl: useCube ? cubeUrl.trimmingCharacters(in: .whitespaces) : nil,
                teamSize: f.isTeam ? teamSize : nil,
                formatOther: f == .otherConstructed ? formatOther : nil,
                pairing: f == .roto ? pairing : nil,
                topCut: swiss ? topCut : 0,
                autoRounds: swiss && autoRounds,
                decklists: kind == .limited ? "off" : decklists,
                autoName: typed.isEmpty
            )
        }
    }

    @State private var form: DetailsForm
    /// The last state the server accepted (or the state loaded from the event).
    @State private var lastSaved: NewEventDraft
    @State private var visibility: String
    @State private var schedule: EventSchedule
    @State private var savedSchedule: EventSchedule
    @State private var scheduleTask: Task<Void, Never>?
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
        let s = EventSchedule(startsAt: b.event.startsAt.flatMap(T1Date.parse), venue: b.event.venueName ?? "", capacity: b.event.capacity)
        _schedule = State(initialValue: s)
        _savedSchedule = State(initialValue: s)
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
                if form.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Notice("Left empty, it's named from the format and date: \(b.event.autoName ? b.event.name : "set when you save").")
                }

                FormatFields(kind: $form.kind, constructedFormat: $form.constructedFormat,
                             limitedFormat: $form.limitedFormat, formatOther: $form.formatOther)

                if form.kind == .limited && form.format == .roto && b.event.isRoto {
                    // The pool is one of your Library cubes (roto_set_cube), not a typed name.
                    RotoSetupFields(event: b.event, store: RotoStores.store(b.event.id), refresh: refresh)
                } else if form.kind == .limited {
                    ProductFields(product: $form.product, chosenSet: form.chosenSet, typedSetName: $form.typedSetName,
                                  cubeName: $form.cubeName, cubeUrl: $form.cubeUrl, setsUnavailable: setsUnavailable,
                                  cubeOnly: form.format == .roto) {
                        choosingSet = true
                    }
                }

                if form.format.isTeam {
                    TeamSizeFields(format: form.format, teamSize: $form.teamSize)
                }

                ScheduleFields(schedule: $schedule)

                Section1("Rounds")
                if !(form.format == .roto && form.pairing == "round_robin") {
                    CutAndRoundsFields(autoRounds: $form.autoRounds, rounds: $form.rounds, topCut: $form.topCut,
                                       players: b.participants.filter { $0.status == "active" }.count, swiss: form.swiss)
                }
                RoundTimerSwitch(isOn: $form.showClock)
                if form.format == .roto {
                    RotoPairingFields(pairing: $form.pairing, players: b.participants.filter { $0.status == "active" }.count)
                }

                if form.kind == .constructed { DecklistsFields(mode: $form.decklists) }

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
        .onChange(of: schedule) { old, new in scheduleChanged(from: old, to: new) }
        // roto_set_cube renames the event's cube; take it in without saving it back.
        .onChange(of: b.event.cubeName) { _, name in
            guard b.event.isRoto else { return }
            lastSaved.cubeName = name
            lastSaved.cubeUrl = b.event.cubeUrl
            form.cubeName = name ?? ""
            form.cubeUrl = b.event.cubeUrl ?? ""
        }
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

    /// When / where / cap save through set_event_schedule: the venue after a pause, the rest at once.
    @MainActor
    private func scheduleChanged(from old: EventSchedule, to new: EventSchedule) {
        guard new != savedSchedule else { scheduleTask?.cancel(); return }
        let typing = old.startsAt == new.startsAt && old.capacity == new.capacity
        scheduleTask?.cancel()
        let eventId = b.event.id
        scheduleTask = Task { @MainActor in
            try? await Task.sleep(for: typing ? .milliseconds(600) : .milliseconds(300))
            if Task.isCancelled { return }
            do {
                try await Repo.setEventSchedule(eventId: eventId, new)
                savedSchedule = new
                error = nil
                await refresh()
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func save(_ draft: NewEventDraft) async {
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
    @Environment(SessionModel.self) private var session
    @State private var confirmFinish = false
    @State private var confirmCut = false
    @State private var dropping: ParticipantRow?

    private var b: EventBundle { ctx.b }
    private var event: EventRow { ctx.b.event }
    private var round: RoundRow? { b.activeRound }

    private var tabs: [(id: String, label: String)] {
        var list: [(id: String, label: String)] = [
            (id: "round", label: "Round"), (id: "standings", label: "Standings"), (id: "players", label: "Players"),
        ]
        if event.isTeamEvent { list.append((id: "teams", label: "Teams")) }
        if event.pairing == "round_robin" { list.insert((id: "schedule", label: "Schedule"), at: 1) }
        return list
    }

    var body: some View {
        let groups = MatchGroups(round?.matches ?? [])
        T1Screen {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Bar(title: event.name, subtitle: subtitle(at: context.date), back: { dismiss() }) {
                    BarButton("More") { showMore() }
                }
            }
            PhaseTabs(tabs: tabs, selection: $tab)
            if let error = ctx.error { Notice(error, error: true) }

            switch tab {
            case "standings": standingsTab(groups)
            case "schedule": RotoScheduleView(b: b)
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
            let last = b.rounds.max(by: { $0.number < $1.number })
            return "\(last?.name(of: event.numberOfRounds) ?? "Round \(event.currentRound) of \(event.numberOfRounds)") · \(event.label)"
        }
        guard event.showClock else { return "\(round.name(of: event.numberOfRounds)) · \(event.label)" }
        let clock: String
        if round.clockPaused {
            clock = "paused"
        } else {
            let left = round.secondsLeft(at: date)
            clock = left == 0 ? "time" : "\(clockText(left)) left"
        }
        return "\(round.name(of: event.numberOfRounds)) · \(clock) · \(event.label)"
    }

    // MARK: round

    @ViewBuilder
    private func roundTab(_ g: MatchGroups) -> some View {
        HairlineList {
            if let clinch = ctx.engine.clinched { Notice("\(clinch.text) You can finish now; open matches won't count.") }
            if let round {
                if event.showClock {
                    RoundClockHero(round: round, caption: caption(round, g))
                    HStack(spacing: 1) {
                        Ghost(text: round.clockPaused ? "Resume clock" : "Pause clock") {
                            clock(round, round.clockPaused ? .resume : .pause)
                        }
                        Ghost(text: "+5 min") { clock(round, .add) }
                    }
                } else {
                    // Round timer off: no clock anywhere for this event (rounds still run 50 minutes).
                    Notice(caption(round, g))
                }
                if let mine = myMatch(round) { yourMatch(mine) }
                // Each section's rows get their own identity: in the lazy stack a match keyed only by its id kept its
                // "Set" row after moving to Results in (2026-10-23).
                if !g.disputed.isEmpty {
                    Section1("Disputed · \(g.disputed.count)")
                    ForEach(g.disputed) { m in
                        matchButton(m, detail: "Reported differently · tap to set", value: "Set", tone: T1.danger)
                            .id("disputed-\(m.id)-\(m.version)")
                    }
                }
                if !g.waiting.isEmpty {
                    Section1("Waiting · \(g.waiting.count)")
                    ForEach(g.waiting) { m in
                        matchButton(m, detail: "No result yet", value: "Set", tone: T1.text)
                            .id("waiting-\(m.id)-\(m.version)")
                    }
                }
                if !g.resultsIn.isEmpty || !g.byes.isEmpty {
                    Section1("Results in · \(g.resultsIn.count + g.byes.count)")
                    ForEach(g.resultsIn) { m in
                        matchButton(m, detail: resultDetail(m, b), value: scoreText(m), tone: T1.accent)
                            .id("in-\(m.id)-\(m.version)")
                    }
                    ForEach(g.byes) { m in
                        ListRow(title: "\(b.name(m.side(0)?.participantId)) · Bye")
                    }
                }
            } else {
                switch b.nextStep {
                case .pair: Notice("No round running. Pair round \((b.rounds.map(\.number).max() ?? 0) + 1) when everyone is ready.")
                case .cut: Notice("Swiss is done. Cut to the top 8 to pair the quarterfinals.")
                case .semifinals, .final: Notice("No round running. Pair the next playoff round when everyone is ready.")
                default: Notice("Every round is played. Finish the event to send final standings.")
                }
            }
        }
    }

    /// The organizer's own match when they're playing this round (organizers play by default).
    private func myMatch(_ r: RoundRow) -> MatchRow? {
        guard let me = b.participants.first(where: { $0.userId != nil && $0.userId == Repo.userId }) else { return nil }
        return r.matches.first { m in !m.isBye && m.matchSides.contains { $0.participantId == me.id } }
    }

    /// Running the event and playing in it: the life tracker for your match sits above everyone's results.
    @ViewBuilder
    private func yourMatch(_ m: MatchRow) -> some View {
        let me = b.participants.first { $0.userId != nil && $0.userId == Repo.userId }
        let theirs = m.matchSides.first { $0.participantId != me?.id }
        Section1("Your match · Table \(m.tableNumber.map(String.init) ?? "–")")
        ListRow(title: "vs \(b.name(theirs?.participantId))", detail: m.status == "confirmed" ? scoreText(m) : "Playing")
        HStack(spacing: 1) {
            Button { session.openTracker(matchId: m.id, source: "organizer_match") } label: {
                LabelText("Open life tracker", color: T1.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 18).background(T1.accent)
            }
            .buttonStyle(.plain)
            Ghost(text: "Set result") { ctx.edit(m, false) }
        }
    }

    /// "Round 2 of 3 · 5 of 8 results in · 1 disputed"; paused: "Paused · Round 2 of 3".
    private func caption(_ r: RoundRow, _ g: MatchGroups) -> String {
        let of = r.name(of: event.numberOfRounds)
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
            BracketRows(bracket: ctx.engine.bracket ?? [])
            StandingsRows(engine: ctx.engine, highlight: nil, players: b.participants)
        }
    }

    // MARK: players

    private var playersTab: some View {
        let playing = b.participants.filter { $0.status != "dropped" }
        let dropped = b.participants.filter { $0.status == "dropped" }
        return HairlineList {
            Section1("Playing · \(playing.count)")
            ForEach(playing) { p in
                ListRow(title: p.displayName, detail: [recordDetail(p), b.decklistDetail(p)].compactMap { $0 }.joined(separator: " · "),
                        avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                    HStack(spacing: 16) {
                        if event.takesDecklists {
                            Button {
                                presentDecklist(event: event, participantId: p.id, playerName: p.displayName, byOrganizer: true, refresh: ctx.refresh)
                            } label: { LabelText("List", color: T1.accent) }.buttonStyle(.plain)
                        }
                        BarButton("Drop") { dropping = p }
                    }
                }
                .opensProfile(p.userId, from: "event_players")
            }
            if !dropped.isEmpty {
                Section1("Dropped · \(dropped.count)")
                ForEach(dropped) { p in
                    ListRow(title: p.displayName,
                            detail: p.droppedInRound.map { "Dropped after round \($0) · still counts in tiebreakers" }
                                ?? "Dropped · still counts in tiebreakers",
                            avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                        BarButton("Reinstate") { setStatus(p, dropped: false) }
                    }
                    .opensProfile(p.userId, from: "event_players")
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
        let disputed = round?.matches.contains { $0.disputed && $0.status != "confirmed" } ?? false
        if let clinch = ctx.engine.clinched, !disputed {
            // A team can't be caught: finish now (open matches don't count), or play on when the round is in.
            if outstanding == 0 && nextNumber <= event.numberOfRounds {
                HStack(spacing: 1) { Ghost(text: "Play on · pair round \(nextNumber)") { pair() } }
            }
            finishButton(clinch)
        } else if event.isTeamEvent || event.pairing == "round_robin" {
            // Team events and round robin stop at their round count (no top cut).
            if round == nil && nextNumber <= event.numberOfRounds {
                BigAction(text: "Pair round \(nextNumber)", enabled: activePlayers >= 2, busy: ctx.busy, accent: true) { pair() }
            } else if round != nil && outstanding > 0 {
                BigAction(text: "Waiting on \(outstanding) result\(outstanding == 1 ? "" : "s")", enabled: false) {}
            } else if let round, round.number < event.numberOfRounds {
                BigAction(text: "Pair round \(round.number + 1)", busy: ctx.busy, accent: true) { pair() }
            } else if !b.rounds.isEmpty {
                finishButton(nil)
            }
        } else {
            // Swiss, then the top 8 when there is one (contract/scheduled-events-2026-10-27.md §6).
            switch b.nextStep {
            case .waiting: BigAction(text: "Waiting on \(outstanding) result\(outstanding == 1 ? "" : "s")", enabled: false) {}
            case .pair, .start: BigAction(text: "Pair round \(nextNumber)", enabled: activePlayers >= 2, busy: ctx.busy, accent: true) { pair() }
            case .cut:
                BigAction(text: "Cut to top 8", busy: ctx.busy, accent: true) { confirmCut = true }
                    .alert("Cut to top 8?", isPresented: $confirmCut) {
                        Button("Not yet", role: .cancel) {}
                        Button("Cut") { pair() }
                    } message: {
                        Text("Pairs the quarterfinals from the Swiss standings. Swiss is over: no more Swiss rounds.")
                    }
            case .semifinals: BigAction(text: "Pair semifinals", busy: ctx.busy, accent: true) { pair() }
            case .final: BigAction(text: "Pair the final", busy: ctx.busy, accent: true) { pair() }
            case .finish: finishButton(nil)
            }
        }
    }

    private func finishButton(_ clinch: TeamClinch?) -> some View {
        BigAction(text: "Finish event", busy: ctx.busy, accent: true) { confirmFinish = true }
            .alert("Finish \(event.name)?", isPresented: $confirmFinish) {
                Button("Not yet", role: .cancel) {}
                Button("Finish") { finish() }
            } message: {
                Text(clinch.map { "\($0.text) Open matches won't count. Final standings go to every player and the event moves to Past." }
                     ?? "Final standings go to every player and the event moves to Past. You can still correct a result afterwards.")
            }
    }

    @MainActor
    private func pair() {
        let id = event.id
        let pairing = event.pairing
        ctx.act { try await pairNext(id, pairing: pairing) }
    }

    /// Records the last round and completes the event.
    @MainActor
    private func finish() {
        guard let roundId = round?.id ?? b.rounds.max(by: { $0.number < $1.number })?.id else { return }
        let eventId = event.id
        let clinch = ctx.engine.clinched
        ctx.act {
            try await Repo.recordRound(eventId: eventId, roundId: roundId, finalRound: true)
            if let clinch { Telemetry.capture("event_finished_clinched", ["remaining": clinch.remaining]) }
        }
    }

    @MainActor
    private func showMore() {
        let cancel = ctx.cancelEvent
        let open = ctx.open
        let id = event.id
        let name = event.name
        let pairing = event.pairing
        T1Overlays.shared.showMenu(event.name, [
            T1MenuItem(title: "Deck photos") { open(.deckPhotos(id)) },
        ] + (event.isRoto ? [
            T1MenuItem(title: "Draft picks") { presentRotoDraft(eventId: id, title: name, isOrganizer: true, pairing: pairing) },
        ] : []) + [
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
            Bar(title: event.name, subtitle: subtitle, back: { dismiss() }) {
                // Live's More carried Deck photos; finishing the event mustn't take it away.
                if !event.isCancelled { BarButton("More") { showMore() } }
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
                StandingsRows(engine: ctx.engine, highlight: nil, players: b.participants)
                Notice("Confirmed results count toward records. Unplayed rounds never do.")
            } else {
                winnerCard
                AfterEventLinks(event: event, open: ctx.open)
                if event.isRoto {
                    Ghost(text: "Draft picks") {
                        presentRotoDraft(eventId: event.id, title: event.name, isOrganizer: true, pairing: event.pairing)
                    }
                }
                BracketRows(bracket: ctx.engine.bracket ?? [])
                if (ctx.engine.bracket ?? []).isEmpty { Section1("Final standings") }
                StandingsRows(engine: ctx.engine, highlight: nil, players: b.participants)
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
                Section1(r.isPlayoff ? r.name(of: event.numberOfRounds) : "Round \(r.number)")
                ForEach(r.matches.filter { !$0.isBye }) { m in
                    Button { ctx.edit(m, false) } label: {
                        ListRow(title: matchTitle(m, b), detail: m.resultSource == "organizer" ? "Set by organizer" : nil) {
                            Text(m.status == "pending" ? "Set" : scoreText(m))
                                .font(T1.mono(16))
                                .foregroundStyle(m.status == "pending" ? T1.muted : T1.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .id("\(m.id)-\(m.version)")
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
                ListRow(title: p.displayName, detail: finalDetail(p, s), avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                    Text(s.map { recordText($0.matchWins, $0.matchLosses, $0.matchDraws) } ?? "–").font(T1.mono(14))
                }
                .opensProfile(p.userId, from: "event_players")
            }
        }
    }

    @MainActor
    private func showMore() {
        let open = ctx.open
        let id = event.id
        let name = event.name
        let pairing = event.pairing
        let e = event
        T1Overlays.shared.showMenu(name, [
            T1MenuItem(title: "Add a deck photo") { open(.deckPhotos(id)) },
        ] + (event.canRedraft ? [
            T1MenuItem(title: "Redraft") { open(.redraft(id)) },
        ] : []) + (event.isRoto ? [
            T1MenuItem(title: "Draft picks") { presentRotoDraft(eventId: id, title: name, isOrganizer: true, pairing: pairing) },
        ] : []) + [
            T1MenuItem(title: "Share link") { shareEventLink(e) },
        ])
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
func pairNext(_ eventId: String, pairing: String = "swiss") async throws {
    let r = try await Repo.pairNextRound(eventId, pairing: pairing)
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
