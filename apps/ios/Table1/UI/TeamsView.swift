import SwiftUI

// MARK: seating

/// Draft seating: each pod's seats in passing order, team per seat, and how round 1 pairs.
struct SeatingTable: View {
    let pods: [SeatingPod]
    /// Team draft: seats alternate A1, B1, A2, B2…, and round 1 pairs A slot i with B slot i+1 (wrapping).
    var teamDraft = false
    var highlight: String?
    /// Seat the two ends of the table too (event setting; changes only the drawing).
    var seatEnds = false
    /// Organizer before round 1: a tapped seat (move or swap it).
    var onTap: ((SeatingPod.Seat, SeatingPod) -> Void)?

    private var seatNumbers: [[Int]] { pods.map { $0.seats.map(\.seat) } }

    var body: some View {
        ForEach(Array(pods.enumerated()), id: \.element.id) { i, pod in
            Section1("\(pods.count > 1 ? (pod.name ?? "Pod") : "Seating") · \(pod.seats.count) players")
            PodTable(pod: pod, pairs: Self.pairs(pod, teamDraft: teamDraft), highlight: highlight,
                     seatEnds: seatEnds, byeSeat: teamDraft ? nil : DraftPods.byeSeat(seatNumbers, pod: i),
                     onTap: onTap.map { tap in { seat in tap(seat, pod) } })
            Notice(teamDraft ? Self.teamDraftText(pod) : Self.acrossText(pods, pod: i))
        }
    }

    /// Round 1 pairs as seat numbers (the same rule as the notes below the table).
    static func pairs(_ pod: SeatingPod, teamDraft: Bool) -> [(Int, Int)] {
        let seats = pod.seats.map(\.seat).sorted()
        if teamDraft {
            let a = stride(from: 0, to: seats.count, by: 2).map { seats[$0] }
            let b = stride(from: 1, to: seats.count, by: 2).map { seats[$0] }
            guard !a.isEmpty, a.count == b.count else { return [] }
            return (0..<a.count).map { (a[$0], b[($0 + 1) % a.count]) }
        }
        let half = (seats.count - seats.count % 2) / 2
        return (0..<half).map { (seats[$0], seats[$0 + half]) }
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

    /// "Round 1 pairs across the table: 1 v 4, 2 v 5, 3 v 6. Seat 7 plays Pod 2's seat 7." An odd pod's last seat
    /// plays another odd pod's, or has the bye when the event is odd (DraftPods.note, testdata/draft-pods).
    static func acrossText(_ pods: [SeatingPod], pod index: Int) -> String {
        DraftPods.note(pods.map { $0.seats.map(\.seat) }, pod: index) { i in pods[i].name ?? "Pod \(i + 1)" }
    }
}

/// One pod drawn the way a draft table really seats people: one long table, players along both long sides,
/// and (when the organizer turns it on) one player at each end. Seats run clockwise: the top end, down the
/// right side, the bottom end, up the left side. Lines join round 1 opponents; the middle says which way each
/// pack passes (left = clockwise, to the next seat number: packs 1 and 3; pack 2 goes right). Only the drawing changes; seats and pairings don't.
private struct PodTable: View {
    let pod: SeatingPod
    let pairs: [(Int, Int)]
    let highlight: String?
    let seatEnds: Bool
    /// The seat with round 1's bye (an odd pod's last seat plays another odd pod's unless the event is odd).
    let byeSeat: Int?
    var onTap: ((SeatingPod.Seat) -> Void)?

    private var seats: [SeatingPod.Seat] { pod.seats.sorted { $0.seat < $1.seat } }
    private var mySeat: Int? { seats.first { $0.participantId == highlight }?.seat }
    private var layout: TableLayout { TableLayout(count: seats.count, ends: seatEnds) }

    var body: some View {
        let layout = layout
        GeometryReader { geo in
            let size = geo.size
            let chip = CGSize(width: min(140, (size.width - 24) * 0.36), height: TableLayout.chipHeight)
            let points = layout.positions(in: size, chip: chip)
            let table = layout.tableRect(in: size, chip: chip)
            let index = Dictionary(uniqueKeysWithValues: seats.enumerated().map { ($1.seat, $0) })
            ZStack {
                // The table.
                Rectangle()
                    .fill(T1.bg)
                    .overlay(Rectangle().stroke(T1.disabled, lineWidth: 1))
                    .frame(width: table.width, height: table.height)
                    .position(x: table.midX, y: table.midY)
                // Round 1 opponents.
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    if let i = index[pair.0], let j = index[pair.1] {
                        let mine = mySeat == pair.0 || mySeat == pair.1
                        Path { p in
                            p.move(to: points[i])
                            p.addLine(to: points[j])
                        }
                        .stroke(mine ? T1.accent : T1.disabled, lineWidth: mine ? 2 : 1)
                    }
                }
                VStack(spacing: 6) {
                    Text("↻ 1·3 left").font(T1.mono(12, .bold)).foregroundStyle(T1.text)
                    Text("↺ 2 right").font(T1.mono(12)).foregroundStyle(T1.muted)
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(T1.bg)
                .position(x: table.midX, y: table.midY)
                ForEach(Array(seats.enumerated()), id: \.element.id) { i, seat in
                    Group {
                        if let onTap {
                            Button { onTap(seat) } label: {
                                SeatChip(seat: seat, mine: seat.participantId == highlight, bye: seat.seat == byeSeat)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Move or swap")
                        } else {
                            SeatChip(seat: seat, mine: seat.participantId == highlight, bye: seat.seat == byeSeat)
                        }
                    }
                    .frame(width: chip.width, height: chip.height)
                    .position(points[i])
                }
            }
        }
        .frame(height: layout.height)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(T1.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table\(seatEnds ? " with players at the ends" : ""). Packs 1 and 3 pass left, pack 2 passes right")
    }
}

/// Where each seat goes around one long table drawn upright (portrait phones): `right` seats down the right
/// side, then `left` seats up the left side, with an end seat before each side when the ends are seated.
/// Ends need at least four players; an odd side count puts the extra player on the right.
struct TableLayout {
    static let chipHeight: CGFloat = 46
    static let gap: CGFloat = 10
    let count: Int
    let ends: Bool
    let right: Int
    let left: Int

    init(count: Int, ends: Bool) {
        self.count = count
        self.ends = ends && count >= 4
        let sides = count - (self.ends ? 2 : 0)
        right = (sides + 1) / 2
        left = sides - right
    }

    var rows: Int { max(right, left, 1) }
    private var step: CGFloat { Self.chipHeight + Self.gap }
    /// Height of the drawing: the side rows, plus a row above and below for the ends.
    var height: CGFloat { CGFloat(rows + (ends ? 2 : 0)) * step - Self.gap + 8 }
    private var firstRowY: CGFloat { 4 + Self.chipHeight / 2 + (ends ? step : 0) }

    /// The table between the two columns, reaching up to the end seats.
    func tableRect(in size: CGSize, chip: CGSize) -> CGRect {
        let x0 = chip.width + 12, x1 = size.width - chip.width - 12
        let y0 = firstRowY - Self.chipHeight / 2 - (ends ? Self.gap / 2 : 0)
        let y1 = firstRowY + CGFloat(rows - 1) * step + Self.chipHeight / 2 + (ends ? Self.gap / 2 : 0)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 40), height: y1 - y0)
    }

    /// Seat centres in seat order (clockwise from the top end, or from the right side's first seat).
    func positions(in size: CGSize, chip: CGSize) -> [CGPoint] {
        guard count > 0 else { return [] }
        let midX = size.width / 2
        let rightX = size.width - chip.width / 2 - 4
        let leftX = chip.width / 2 + 4
        func rowY(_ r: Int) -> CGFloat { firstRowY + CGFloat(r) * step }
        var points: [CGPoint] = []
        if ends { points.append(CGPoint(x: midX, y: 4 + Self.chipHeight / 2)) }
        for r in 0..<right { points.append(CGPoint(x: rightX, y: rowY(r))) }
        if ends { points.append(CGPoint(x: midX, y: rowY(rows - 1) + step)) }
        for r in (0..<left).reversed() { points.append(CGPoint(x: leftX, y: rowY(r + rows - left))) }
        return points
    }
}

private struct SeatChip: View {
    let seat: SeatingPod.Seat
    let mine: Bool
    let bye: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(seat.seat)").font(T1.mono(13, .bold)).foregroundStyle(T1.accent)
                if let team = seat.team { LabelText(team) .lineLimit(1) }
                if bye { LabelText("Bye", color: T1.warning) }
            }
            Text(seat.displayName).font(T1.mono(12)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(mine ? T1.surfaceHover : T1.bg)
        .overlay(Rectangle().stroke(mine ? T1.accent : T1.disabled, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Seat \(seat.seat), \(seat.displayName)\(seat.team.map { ", \($0)" } ?? "")\(bye ? ", bye" : "")")
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
