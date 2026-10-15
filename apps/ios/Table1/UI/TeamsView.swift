import SwiftUI

// MARK: seating

/// Draft seating: each pod's seats in passing order, team per seat, and how round 1 pairs.
struct SeatingList: View {
    let pods: [SeatingPod]
    var highlight: String?
    /// Team draft: seats alternate A1, B1, A2, B2…, and round 1 pairs A slot i with B slot i+1 (wrapping).
    var teamDraft = false

    var body: some View {
        ForEach(pods) { pod in
            Section1("\(pods.count > 1 ? (pod.name ?? "Pod") : "Seating") · \(pod.seats.count) players")
            Notice("Pack 1 passes left · Pack 2 right · Pack 3 left")
            ForEach(pod.seats) { seat in
                HStack(spacing: 12) {
                    Text("\(seat.seat)").font(T1.mono(18)).foregroundStyle(T1.accent).frame(width: 32, alignment: .leading)
                    Text(seat.displayName).font(T1.mono(14)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let team = seat.team { LabelText(team) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(seat.participantId == highlight ? T1.surfaceHover : T1.surface)
            }
            Notice(teamDraft ? Self.teamDraftText(pod) : Self.acrossText(pod))
        }
    }

    /// Team draft round 1: team A slot i (seat 2i−1) plays team B slot (i mod n)+1 (seat 2·that),
    /// e.g. 3 v 3 → "1 v 4, 3 v 6, 5 v 2".
    static func teamDraftText(_ pod: SeatingPod) -> String {
        let seats = pod.seats.map(\.seat).sorted()
        let a = stride(from: 0, to: seats.count, by: 2).map { seats[$0] }
        let b = stride(from: 1, to: seats.count, by: 2).map { seats[$0] }
        guard !a.isEmpty, a.count == b.count else { return "Round 1 pairs each player with the other team." }
        let n = a.count
        let pairs = (0..<n).map { "\(a[$0]) v \(b[($0 + 1) % n])" }.joined(separator: ", ")
        return "Round 1 pairs: \(pairs)."
    }

    /// "Round 1 pairs across the table: 1 v 5, 2 v 6, 3 v 7, 4 v 8." An odd pod's last seat has the bye.
    static func acrossText(_ pod: SeatingPod) -> String {
        let seats = pod.seats.map(\.seat).sorted()
        let even = seats.count - seats.count % 2
        let half = even / 2
        guard half > 0 else { return "Round 1 pairs across the table." }
        let pairs = (0..<half).map { "\(seats[$0]) v \(seats[$0 + half])" }.joined(separator: ", ")
        let bye = seats.count % 2 == 1 ? " Seat \(seats[seats.count - 1]) has the bye." : ""
        return "Round 1 pairs across the table: \(pairs).\(bye)"
    }
}

// MARK: teams (organizer)

/// Organizer's Teams tab: randomize, move players between teams, rename, add teams, save with set_teams.
/// Read-only once round 1 is paired.
struct TeamsEditor: View {
    let b: EventBundle
    let refresh: () async -> Void

    struct DraftTeam: Identifiable, Hashable {
        let id: String
        var name: String
        var members: [String]
    }

    @State private var teams: [DraftTeam] = []
    @State private var loaded = false
    @State private var dirty = false
    @State private var busy = false
    @State private var error: String?
    @State private var renaming: String?
    @State private var nameDraft = ""

    private var event: EventRow { b.event }
    private var locked: Bool { !event.isBeforeRound1 || !b.rounds.isEmpty }
    private var size: Int { event.teamSize ?? 3 }
    private var maxTeams: Int? { event.formatName == "team_draft" ? 2 : nil }
    private var active: [ParticipantRow] { b.participants.filter { $0.status == "active" } }
    private var unassigned: [ParticipantRow] { active.filter { p in !teams.contains { $0.members.contains(p.id) } } }
    private var canAddTeam: Bool { maxTeams.map { teams.count < $0 } ?? true }

    var body: some View {
        HairlineList {
            if locked {
                Notice("Teams lock when round 1 is paired.")
            } else {
                HStack(spacing: 1) {
                    Ghost(text: "Randomize") { randomize() }
                    if canAddTeam { Ghost(text: "+ Team") { addTeam() } }
                    Ghost(text: busy ? "Saving…" : (dirty ? "Save" : "Saved"), accent: dirty) { if dirty && !busy { save() } }
                }
                Notice("\(size) players per team\(maxTeams == 2 ? ", two teams" : ""). Tap a player to move them. Pairing round 1 needs everyone on a team.")
            }
            if let error { Notice(error, error: true) }
            if !loaded { Notice("Loading…") }

            ForEach(teams) { team in
                teamHeader(team)
                if team.members.isEmpty { Notice("No players yet.") }
                ForEach(Array(team.members.enumerated()), id: \.element) { index, pid in
                    memberRow(pid, slot: index + 1)
                }
            }
            if loaded && (!unassigned.isEmpty || !locked) {
                Section1("Unassigned · \(unassigned.count)")
                ForEach(unassigned) { p in memberRow(p.id, slot: nil) }
            }
        }
        .task(id: b.participants.map(\.id)) {
            if !dirty { await load() }
        }
        .alert("Team name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Up to 40 characters.")
        }
    }

    private func teamHeader(_ team: DraftTeam) -> some View {
        HStack(spacing: 12) {
            LabelText("\(team.name) · \(team.members.count)/\(size)", color: T1.accent)
            Spacer(minLength: 0)
            if !locked {
                BarButton("Edit") {
                    T1Overlays.shared.showMenu(team.name, [
                        T1MenuItem(title: "Rename") {
                            nameDraft = team.name
                            renaming = team.id
                        },
                        T1MenuItem(title: "Remove team", detail: team.members.isEmpty ? nil : "Its players become unassigned",
                                   destructive: true) { removeTeam(team.id) },
                    ])
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(T1.surface)
    }

    private func memberRow(_ pid: String, slot: Int?) -> some View {
        let p = b.participants.first { $0.id == pid }
        let name = p?.displayName ?? "—"
        var detail = slot.map { "Seat \(slotLetter($0))" } ?? "Not on a team"
        if p?.status == "dropped" { detail += " · dropped" }
        return Button {
            if !locked { showMove(pid, name: name) }
        } label: {
            ListRow(title: name, detail: detail) {
                if !locked { LabelText("Move", color: T1.text) }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: changes

    /// "Move to…": every team with room, plus Unassigned.
    private func showMove(_ pid: String, name: String) {
        var items = teams.filter { !$0.members.contains(pid) }.map { team in
            T1MenuItem(title: team.name, detail: "\(team.members.count)/\(size)", enabled: team.members.count < size) {
                move(pid, to: team.id)
            }
        }
        if teams.contains(where: { $0.members.contains(pid) }) {
            items.append(T1MenuItem(title: "Unassigned") { move(pid, to: nil) })
        }
        T1Overlays.shared.showMenu("Move to…", message: name, items)
    }

    private func addTeam() {
        var n = teams.count + 1
        while teams.contains(where: { $0.name == "Team \(n)" }) { n += 1 }
        teams.append(DraftTeam(id: UUID().uuidString, name: "Team \(n)", members: []))
        dirty = true
    }

    private func removeTeam(_ id: String) {
        teams.removeAll { $0.id == id }
        dirty = true
    }

    private func move(_ pid: String, to teamId: String?) {
        for i in teams.indices { teams[i].members.removeAll { $0 == pid } }
        if let teamId, let i = teams.firstIndex(where: { $0.id == teamId }) {
            teams[i].members.append(pid)
        }
        dirty = true
    }

    private func rename() {
        let trimmed = String(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if let id = renaming, !trimmed.isEmpty, let i = teams.firstIndex(where: { $0.id == id }) {
            teams[i].name = trimmed
            dirty = true
        }
        renaming = nil
    }

    // MARK: server

    private func apply(_ rows: [EventTeam]) {
        teams = rows.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map { t in
            DraftTeam(id: t.id, name: t.name,
                      members: t.members.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }.map(\.participantId))
        }
        dirty = false
        loaded = true
    }

    private func load() async {
        do {
            apply(try await Repo.eventTeams(event.id))
            error = nil
        } catch {
            loaded = true
            self.error = error.localizedDescription
        }
    }

    private func randomize() {
        run { try await Repo.randomizeTeams(event.id) }
    }

    private func save() {
        let activeIds = Set(active.map(\.id))
        let payload = teams.map { (name: $0.name, members: $0.members.filter { activeIds.contains($0) }) }
        run { try await Repo.setTeams(event.id, teams: payload) }
    }

    private func run(_ work: @escaping () async throws -> [EventTeam]) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                apply(try await work())
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
