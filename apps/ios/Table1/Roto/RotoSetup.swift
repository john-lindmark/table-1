import SwiftUI

// Roto pieces that sit inside the existing event screens: Setup (cube, picks per player, order, pick clock, pick
// order, Start draft), Create (Pairing) and Live (the round-robin Schedule, the read-only Draft).

/// One store per roto event, shared by Setup, the Draft phase and Live, so the pool is fetched once.
@MainActor
enum RotoStores {
    private static var stores: [String: RotoStore] = [:]
    private static var order: [String] = []

    static func store(_ eventId: String) -> RotoStore {
        if let s = stores[eventId] { return s }
        let s = RotoStore(eventId: eventId)
        put(s)
        return s
    }

    /// The Debug demo puts in a store backed by a local draft.
    static func put(_ s: RotoStore) {
        stores[s.eventId] = s
        order.removeAll { $0 == s.eventId }
        order.append(s.eventId)
        while order.count > 4 { stores[order.removeFirst()] = nil }
    }
}

extension EventRow {
    var isRoto: Bool { formatName == "roto" }
}

/// The read-only Draft over Live / Results (players look at each other's picks during the matches).
@MainActor
func presentRotoDraft(eventId: String, title: String, isOrganizer: Bool, pairing: String?) {
    let store = RotoStores.store(eventId)
    T1Overlays.shared.present(full: true) {
        RotoDraftView(store: store, title: title, isOrganizer: isOrganizer, readOnly: true,
                      back: { T1Overlays.shared.dismissPanel() }, pairing: pairing)
            .task { await store.load() }
    }
}

// MARK: Create / Details: pairing

/// Roto only: Swiss · Round robin. Round robin hides the Rounds stepper ("7 rounds · everyone plays everyone").
struct RotoPairingFields: View {
    @Binding var pairing: String
    let players: Int

    var body: some View {
        Section1("Pairing")
        T1Segmented(options: [(value: "swiss", label: "Swiss"), (value: "round_robin", label: "Round robin")], selection: $pairing)
        if pairing == "round_robin" {
            let n = RotoMath.roundRobinRounds(players: max(2, players))
            Notice("\(n) round\(n == 1 ? "" : "s") · everyone plays everyone\(players % 2 == 1 && players > 1 ? ", one bye a round" : ""). Set from the players when round 1 is paired.")
        }
    }
}

// MARK: Setup → Seating (pick order)

/// Pick order 1…n. Seats are drawn at random when the draft starts unless the organizer seats them first.
struct RotoPickOrderTab: View {
    let b: EventBundle
    let busy: Bool
    let seat: () -> Void

    var body: some View {
        let seated = b.participants.filter { $0.status == "active" && $0.seat != nil }.sorted { ($0.seat ?? 0) < ($1.seat ?? 0) }
        HairlineList {
            Ghost(text: busy ? "Working…" : (seated.isEmpty ? "Draw pick order" : "Re-draw"), accent: seated.isEmpty) { seat() }
            if seated.isEmpty {
                Notice("Seat 1 picks first. Draw the order now, or Start draft draws it at random.")
            } else {
                Section1("Pick order · snake: 1 → \(seated.count), then back")
                ForEach(seated) { p in
                    ListRow(title: p.userId == Repo.userId && p.userId != nil ? "You · \(p.displayName)" : p.displayName,
                            detail: p.userId == nil ? "Guest · picks once they claim their seat" : nil,
                            avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                        Text("\(p.seat ?? 0)").font(T1.mono(17)).monospacedDigit()
                    }
                    .opensProfile(p.userId, from: "roto_seats")
                }
            }
        }
    }
}

// MARK: Setup → Details (roto)

/// The cube (one of your Library cubes, or a Cube Cobra link imported into your Library first), picks per player,
/// pick order and the pick clock. Picks per player and order are sent with Start draft.
struct RotoSetupFields: View {
    let event: EventRow
    let store: RotoStore
    let refresh: () async -> Void
    @State private var link = ""
    @State private var working: String?
    @State private var error: String?
    @State private var maxPicks: Int?

    private var lists: ListsStore { ListsStore.shared }

    var body: some View {
        let cubes = lists.lists(.cube)
        let chosen = store.draft.sourceListId
        Section1("Cube for the draft")
        if cubes.isEmpty { Notice("No cubes in your Library yet. Paste a Cube Cobra link below to import one.") }
        ForEach(cubes) { cube in
            Button { use(cube) } label: {
                ListRow(title: cube.name, detail: "\(cube.count("main")) cards · Library") {
                    if chosen == cube.id { LabelText("Selected", color: T1.accent) } else { LabelText("Use", color: T1.text) }
                }
            }
            .buttonStyle(.plain)
            .disabled(working != nil)
        }
        Field(label: "Or a Cube Cobra link", text: $link, url: true)
        if !link.trimmingCharacters(in: .whitespaces).isEmpty {
            Ghost(text: working == "import" ? "Importing…" : "Import into Library and use", accent: true) { importLink() }
                .disabled(working != nil)
        }
        if let working, working != "import" { Notice("Setting the cube…") }
        if let error { Notice(error, error: true) }
        if store.draft.poolCount > 0 {
            Notice("\(store.draft.poolCount) cards in the pool · up to \(maxPerPlayer) picks each for \(players) players.")
        }

        Section1("Picks")
        T1Stepper(label: "Picks per player", value: Binding(get: { min(store.planPicks, maxPerPlayer) }, set: { store.planPicks = $0 }),
                  range: 1...max(1, maxPerPlayer))
        T1Segmented(options: [(value: "snake", label: "Snake"), (value: "fixed", label: "Same order")],
                    selection: Binding(get: { store.planOrder }, set: { store.planOrder = $0 }))
        Notice(store.planOrder == "snake" ? "1 → \(players), then \(players) → 1, and so on." : "Seat 1 picks first every round.")

        RotoClockEditor(ranges: Binding(get: { store.draft.clock ?? [] }, set: { _ in }), rounds: min(store.planPicks, maxPerPlayer),
                        save: { ranges in await saveClock(ranges) })
    }

    private var players: Int { max(1, event.isRoto ? store.players : 1) }
    private var maxPerPlayer: Int {
        if let maxPicks { return min(100, maxPicks) }
        guard store.draft.poolCount > 0 else { return 100 }
        return min(100, store.draft.poolCount / max(1, players))
    }

    @MainActor
    private func use(_ cube: CardList) {
        guard working == nil else { return }
        working = cube.id
        error = nil
        let id = event.id
        Task { @MainActor in
            defer { working = nil }
            do {
                let r = try await Repo.rotoSetCube(id, listId: cube.id, from: "library")
                maxPicks = r.maxPicksPerPlayer
                if store.planPicks > r.maxPicksPerPlayer { store.planPicks = r.maxPicksPerPlayer }
                await store.refresh(full: true)
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func importLink() {
        let url = link.trimmingCharacters(in: .whitespaces)
        guard url.lowercased().hasPrefix("https://") else { error = "Paste a Cube Cobra link (https://cubecobra.com/…)"; return }
        working = "import"
        error = nil
        let id = event.id
        Task { @MainActor in
            defer { working = nil }
            do {
                let cube = try await Repo.importCubeToLibrary(url: url)
                let r = try await Repo.rotoSetCube(id, listId: cube.id, from: "cube_cobra")
                maxPicks = r.maxPicksPerPlayer
                if store.planPicks > r.maxPicksPerPlayer { store.planPicks = r.maxPicksPerPlayer }
                link = ""
                await store.refresh(full: true)
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func saveClock(_ ranges: [RotoClockRange]) async -> Bool {
        await store.setClock(ranges)
    }
}

/// Setup's big action for a roto: Start draft (roto_start) instead of Pair round 1.
struct RotoStartButton: View {
    let event: EventRow
    let store: RotoStore
    let activePlayers: Int
    let busy: Bool
    let act: (@escaping () async throws -> Void) -> Void
    @State private var confirm = false

    var body: some View {
        let blocker: String? = activePlayers < 2 ? "Add at least 2 players"
            : store.draft.sourceListId == nil ? "Choose a cube in Details" : nil
        BigAction(text: blocker ?? "Start draft", enabled: blocker == nil, busy: busy, accent: true) { confirm = true }
            .alert("Start the draft?", isPresented: $confirm) {
                Button("Not yet", role: .cancel) {}
                Button("Start") { start() }
            } message: {
                Text("\(activePlayers) players, \(store.planPicks) picks each, \(store.planOrder == "snake" ? "snake order" : "the same order every round"). Players and seats lock until the draft is done; everyone gets a deck in their Library that fills as they pick.")
            }
    }

    @MainActor
    private func start() {
        let id = event.id, picks = store.planPicks, order = store.planOrder, ranges = store.draft.clock?.count ?? 0
        let store = store
        act {
            _ = try await Repo.rotoStart(id, picksPerPlayer: picks, order: order, clockRanges: ranges)
            await store.refresh(full: true)
            await store.load()
        }
    }
}

// MARK: pick clock

/// Optional time per pick on a schedule that quickens: ranges of rounds, each with a time (30 s to 24 h).
/// `ROUNDS 1–10 · 4 H`; Add a range splits the last one. Saved ~600 ms after the last change.
struct RotoClockEditor: View {
    @Binding var ranges: [RotoClockRange]
    let rounds: Int
    let save: ([RotoClockRange]) async -> Bool
    @State private var local: [RotoClockRange]?
    @State private var task: Task<Void, Never>?

    static let durations = [30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400]

    var body: some View {
        let shown = local ?? ranges
        Section1("Pick clock")
        T1Switch(title: "Pick clock", detail: shown.isEmpty ? "Off: no time limit" : "Time per pick, by round",
                 isOn: Binding(get: { !shown.isEmpty }, set: { on in change(on ? [RotoClockRange(fromRound: 1, seconds: 14400)] : []) }))
        ForEach(Array(shown.enumerated()), id: \.offset) { i, r in
            let end = i + 1 < shown.count ? shown[i + 1].fromRound - 1 : max(rounds, r.fromRound)
            Button { chooseTime(i, shown) } label: {
                ListRow(title: end > r.fromRound ? "Rounds \(r.fromRound)–\(end)" : "Round \(r.fromRound)",
                        detail: i == 0 ? "From the first pick" : nil) {
                    LabelText("\(RotoMath.durationText(r.seconds)) ›", color: T1.accent)
                }
            }
            .buttonStyle(.plain)
            if i > 0 {
                let low = shown[i - 1].fromRound + 1
                let high = max(low, (i + 1 < shown.count ? shown[i + 1].fromRound : rounds + 1) - 1)
                HStack(spacing: 1) {
                    T1Stepper(label: "Starts at round", value: Binding(get: { r.fromRound }, set: { v in
                        var next = shown
                        next[i].fromRound = v
                        change(next)
                    }), range: low...high)
                    Button {
                        var next = shown
                        next.remove(at: i)
                        change(next)
                    } label: {
                        LabelText("Remove", color: T1.danger).frame(width: 84).frame(maxHeight: .infinity).background(T1.surface)
                    }
                    .buttonStyle(.plain)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let last = shown.last, shown.count < 10, rounds - last.fromRound >= 1 {
            Ghost(text: "Add a range") {
                var next = shown
                let from = last.fromRound + max(1, (rounds - last.fromRound + 1) / 2)
                let seconds = Self.durations.last { $0 <= max(30, last.seconds / 2) } ?? 30
                next.append(RotoClockRange(fromRound: min(rounds, from), seconds: seconds))
                change(next)
            }
        }
        if !shown.isEmpty {
            Notice("Your time starts when your turn does. When it runs out, the first card on your list is picked; with nothing listed the draft waits and the organizer can pick for you.")
        }
    }

    @MainActor
    private func chooseTime(_ i: Int, _ shown: [RotoClockRange]) {
        T1Overlays.shared.showMenu("Time per pick", Self.durations.map { s in
            T1MenuItem(title: RotoMath.durationText(s), checked: shown[i].seconds == s) {
                var next = shown
                next[i].seconds = s
                change(next)
            }
        })
    }

    @MainActor
    private func change(_ next: [RotoClockRange]) {
        local = next
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            if await save(next) { local = nil }
        }
    }
}

/// Organizer, during the draft: the schedule editor and Pause / Resume, as a panel.
struct RotoClockPanel: View {
    let store: RotoStore

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Pick clock", subtitle: store.draft.clockPaused ? "Paused" : nil) {
                BarButton("Done") { T1Overlays.shared.dismissPanel() }
            }
            ScrollView {
                VStack(spacing: 1) {
                    RotoClockEditor(ranges: .constant(store.draft.clock ?? []), rounds: store.draft.picksPerPlayer) { ranges in
                        await store.setClock(ranges)
                    }
                    if store.draft.clock?.isEmpty == false {
                        Ghost(text: store.draft.clockPaused ? "Resume clock" : "Pause clock") {
                            Task { _ = await store.setClock(nil, paused: !store.draft.clockPaused) }
                        }
                    }
                    Notice("Changes apply from the next turn; the current turn keeps its time.")
                    if let e = store.error { Notice(e, error: true) }
                }
            }
            .frame(maxHeight: 520)
        }
        .foregroundStyle(T1.text)
    }
}

// MARK: Live: round robin schedule

/// Each player's opponents by round (the engine's circle method over the pick order): played rounds with scores,
/// the current one marked, upcoming ones plain.
struct RotoScheduleView: View {
    let b: EventBundle
    @State private var player: String?

    var body: some View {
        let roster = Self.roster(b)
        let total = max(b.event.numberOfRounds, RotoMath.roundRobinRounds(players: roster.count))
        let me = b.participants.first { $0.userId != nil && $0.userId == Repo.userId }
        let chosen = player ?? (roster.contains { $0.id == me?.id } ? me?.id : nil) ?? roster.first?.id
        let current = b.activeRound?.number ?? b.rounds.map(\.number).max() ?? 0
        HairlineList {
            Section1("Round \(max(1, current)) of \(total) · everyone plays everyone")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(roster) { p in
                        let on = p.id == chosen
                        Button { player = p.id } label: {
                            LabelText(p.id == me?.id ? "You" : p.displayName, color: on ? T1.ink : T1.text)
                                .padding(.horizontal, 14).padding(.vertical, 14)
                                .background(on ? T1.text : T1.surface)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let chosen {
                ForEach(1...max(1, total), id: \.self) { r in
                    let opp = Self.opponent(of: chosen, round: r, roster: roster.map(\.id))
                    let played = matchFor(chosen, round: r)
                    ListRow(title: opp.map { b.name($0) } ?? "Bye",
                            detail: r == current ? "Round \(r) · playing now" : "Round \(r)") {
                        if let played, played.status != "pending" || played.isBye {
                            Text(score(played, for: chosen)).font(T1.mono(15)).foregroundStyle(T1.text)
                        } else if r < current {
                            LabelText("No result")
                        }
                    }
                }
            }
            if roster.count < 2 { Notice("The schedule appears once round 1 is paired.") }
        }
    }

    /// Seated players in pick order, as the engine's roster (active, or dropped after round 1).
    static func roster(_ b: EventBundle) -> [ParticipantRow] {
        b.participants.filter { $0.seat != nil && ($0.status == "active" || ($0.droppedInRound ?? 0) >= 1) }
            .sorted { ($0.seat ?? 0) < ($1.seat ?? 0) }
    }

    /// Mirrors roundRobinPairs in events-engine/roundrobin.ts; nil is the bye.
    static func opponent(of id: String, round: Int, roster ids: [String]) -> String? {
        var seats: [String?] = ids
        if seats.count % 2 == 1 { seats.append(nil) }
        let n = seats.count
        guard n >= 2 else { return nil }
        let rot = [seats[0]] + (0..<(n - 1)).map { g in seats[1 + ((g + round - 1) % (n - 1))] }
        for k in 0..<(n / 2) {
            if rot[k] == id { return rot[n - 1 - k] }
            if rot[n - 1 - k] == id { return rot[k] }
        }
        return nil
    }

    private func matchFor(_ id: String, round: Int) -> MatchRow? {
        b.rounds.first { $0.number == round }?.matches.first { m in m.matchSides.contains { $0.participantId == id } }
    }

    private func score(_ m: MatchRow, for id: String) -> String {
        if m.isBye { return "Bye" }
        let mine = m.matchSides.first { $0.participantId == id }?.gameWins ?? 0
        let theirs = m.matchSides.first { $0.participantId != id }?.gameWins ?? 0
        let word = mine > theirs ? "W" : mine < theirs ? "L" : "D"
        return "\(word) \(mine)–\(theirs)"
    }
}

enum RotoSetup {
    /// After Create: use the Library cube with the typed name, else import the Cube Cobra link into the Library and
    /// use that. Quietly leaves it for Setup → Details when neither works.
    @MainActor
    static func linkCube(eventId: String, name: String?, url: String?) {
        let wanted = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let link = url?.trimmingCharacters(in: .whitespaces) ?? ""
        let library = ListsStore.shared.lists(.cube).first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        Task { @MainActor in
            do {
                if let library {
                    _ = try await Repo.rotoSetCube(eventId, listId: library.id, from: "library")
                } else if !link.isEmpty {
                    let cube = try await Repo.importCubeToLibrary(url: link)
                    _ = try await Repo.rotoSetCube(eventId, listId: cube.id, from: "cube_cobra")
                } else {
                    return
                }
                await RotoStores.store(eventId).refresh(full: true)
            } catch {
                Telemetry.error(error, "roto")
            }
        }
    }
}
