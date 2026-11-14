import SwiftUI
import Supabase

// Team Trios and teams that sign themselves up (contract/teams-finals-alerts-2026-11-13.md §§ 1–2): the Seats row of
// Create and Setup → Details, the event page's Sign up a team / Join a team, Your team with the captain's menu, the
// Teams list, the organizer's Teams sign up switch, and the top 4's team bracket.

// MARK: Team Trios seats

/// `A · MODERN` `B · STANDARD` `C · PIONEER`: three cells, each a format dropdown.
struct TriosSeatsRow: View {
    @Binding var seats: [String]

    var body: some View {
        Section1("Seats")
        FilterRow(cells: (0..<3).map { i in
            let key = seats.indices.contains(i) ? seats[i] : TeamRules.defaultSeats[i]
            return FilterCell(name: "Seat \(Array("ABC")[i])", value: TeamRules.seatLabel(slot: i + 1, seatFormats: seats),
                              options: TeamRules.seatFormats.map { SelectorOption(value: $0.key, label: $0.label) }, current: key) { v in
                var next = seats.count == 3 ? seats : TeamRules.defaultSeats
                next[i] = v
                seats = next
            }
        }, event: nil, screen: "trios_seat_picker", compact: true)
    }
}

// MARK: a team link's code

/// The code a tapped `…/s/<event>?team=<CODE>` link carried, waiting for that event's page to fill it in.
@MainActor
enum TeamLinkCode {
    static var pending: (eventId: String, code: String)?

    static func note(_ url: URL) {
        let p = url.pathComponents.filter { $0 != "/" }
        guard p.count == 2, p[0] == "s", let code = TeamRules.code(in: url) else { return }
        pending = (p[1].lowercased(), code)
    }

    static func take(_ eventId: String) -> String? {
        guard let p = pending, p.eventId == eventId.lowercased() else { return nil }
        pending = nil
        return p.code
    }
}

// MARK: the event page and the player's screen

/// For a team event whose teams sign themselves up: Sign up a team and Join a team when you're on none, Your team when
/// you are, and everyone's Teams. Nothing for other events, or on a server without it.
struct TeamSignUpRows: View {
    let eventId: String
    /// Sign-ups are open and you could take a seat (signed in, before round 1).
    var open = true
    /// After you joined, made or left a team (the page reloads its state).
    var changed: () -> Void = {}
    @State private var code = ""
    @State private var fromLink = false
    @State private var naming = false
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var canPaste = UIPasteboard.general.hasStrings

    var body: some View {
        let side = EventSide.of(eventId)
        Group {
            LoadOnce {
                if let c = TeamLinkCode.take(eventId) { code = c; fromLink = true }
                await side.refreshTeams()
            }
            if let t = side.teams, t.teamSignup {
                let size = t.teamSize ?? 3
                if let error { Notice(error, error: true) }
                if let mine = t.team {
                    Section1("Your team")
                    TeamBlock(eventId: eventId, team: mine, teamSize: size, seatFormats: t.seatFormats, edits: t.captain == true, mine: true,
                              failed: { error = $0 }, left: changed)
                } else if open {
                    if t.canCreate == true {
                        Ghost(text: busy ? "Working…" : "Sign up a team", accent: true) { name = ""; naming = true }
                    } else {
                        ListRow(title: "The event is full")
                    }
                    joinRow
                }
                Section1("Teams · \(t.teams.count)")
                if t.teams.isEmpty { ListRow(title: "No teams yet") }
                ForEach(t.teams) { team in
                    ListRow(title: team.name) {
                        LabelText(TeamRules.teamLine(members: team.count, complete: team.complete, teamSize: size),
                                  color: team.complete ? T1.text : T1.muted)
                    }
                }
            }
        }
        .alert("Team name", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Sign up") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're its captain, in seat A. Teammates join with the team's code.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in canPaste = UIPasteboard.general.hasStrings }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in canPaste = UIPasteboard.general.hasStrings }
    }

    /// Join a team: its code, typed or pasted (a pasted link gives its code).
    private var joinRow: some View {
        HStack(spacing: 1) {
            TextField("", text: $code, prompt: Text("TEAM CODE").foregroundStyle(T1.muted))
                .font(T1.mono(16)).tracking(4).tint(T1.accent)
                .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                .submitLabel(.join).onSubmit(join)
                .onChange(of: code) { _, v in
                    let c = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(12))
                    if c != v { code = c }
                }
                .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 50).background(T1.surface)
                .focusArea()
            if code.isEmpty, canPaste {
                cell("Paste", fill: T1.surface, ink: T1.text) {
                    guard let c = UIPasteboard.general.string.flatMap(TeamRules.clean) else { error = "What you copied has no team code in it."; return }
                    code = c
                    error = nil
                }
                .keepsKeyboard()
            }
            cell(busy ? "…" : "Join a team", fill: code.isEmpty ? T1.disabled : T1.accent, ink: T1.ink) { join() }
                .disabled(code.isEmpty || busy)
        }
    }

    private func cell(_ text: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabelText(text, color: ink).padding(.horizontal, 18).frame(height: 50).background(fill).contentShape(Rectangle())
        }
        .buttonStyle(FlatPress())
    }

    private func create() {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !n.isEmpty else { return }
        run { try await Repo.teamCreate(eventId, name: n) }
    }

    private func join() {
        guard let c = TeamRules.clean(code) else { return }
        let how = fromLink ? "link" : "code"
        run { try await Repo.teamJoin(eventId, code: c, how: how) }
    }

    private func run(_ work: @escaping () async throws -> TeamMine) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                EventSide.of(eventId).teams = try await work()
                code = ""
                Keyboard.dismiss()
                changed()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One team in full: members by seat with their seat labels, `2/3`, the code with Copy and Share. Whoever may change
/// it (its captain, or an organizer) gets a member's menu (Move up, Move down, Make captain, Remove) and Rename team;
/// on your own team, Leave team.
struct TeamBlock: View {
    let eventId: String
    let team: TeamInfo
    let teamSize: Int
    var seatFormats: [String]?
    /// The captain or an organizer, before round 1.
    var edits = false
    /// Your own team (Leave team).
    var mine = false
    var failed: (String) -> Void = { _ in }
    var left: () -> Void = {}
    @State private var renaming = false
    @State private var name = ""
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(team.name).font(T1.mono(17)).lineLimit(1)
            Spacer(minLength: 0)
            LabelText(TeamRules.teamLine(members: team.count, complete: team.complete, teamSize: teamSize), color: team.complete ? T1.accent : T1.text)
            if edits { BarButton("Rename") { name = team.name; renaming = true } }
        }
        .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
        .alert("Team name", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") {
                let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                if !n.isEmpty, n != team.name { update(["name": .string(n)], "name") }
            }
            Button("Cancel", role: .cancel) {}
        }
        ForEach(Array(team.members.enumerated()), id: \.element.id) { i, m in
            let captain = m.userId != nil && m.userId == team.captainId
            ListRow(title: m.name, detail: TeamRules.seatLabel(slot: m.slot ?? i + 1, seatFormats: seatFormats) + (captain ? " · CAPTAIN" : ""),
                    avatar: AvatarView(name: m.name, userId: m.userId)) {
                if edits { T1Icon.arrowDropDown.fill(T1.text).frame(width: 18, height: 18) }
            }
            .onTapGesture { if edits { menu(m, at: i) } }
            .accessibilityAddTraits(edits ? .isButton : [])
        }
        if let code = team.joinCode {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(code).font(T1.mono(18)).tracking(4).textSelection(.enabled)
                    LabelText("Team code")
                }
                Spacer(minLength: 0)
                BarButton(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = code
                    copied = true
                }
                ShareLink(item: TeamRules.link(eventId: eventId, code: code), message: Text("Join \(team.name) on Table 1")) {
                    LabelText("Share", color: T1.text)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
        }
        if mine { Ghost(text: "Leave team") { askLeave() } }
    }

    private func menu(_ m: TeamInfo.Member, at i: Int) {
        let ids = team.members.map(\.participantId)
        func moved(_ to: Int) -> [String: AnyJSON] {
            var order = ids
            order.swapAt(i, to)
            return ["order": .array(order.map { .string($0) })]
        }
        var items: [T1MenuItem] = []
        if i > 0 { items.append(T1MenuItem(title: "Move up") { update(moved(i - 1), "order") }) }
        if i < ids.count - 1 { items.append(T1MenuItem(title: "Move down") { update(moved(i + 1), "order") }) }
        if let user = m.userId, user != team.captainId {
            items.append(T1MenuItem(title: "Make captain") { update(["captain": .string(user)], "captain") })
        }
        if m.userId == nil || m.userId != team.captainId {
            items.append(T1MenuItem(title: "Remove", detail: "They leave the event", destructive: true) {
                T1Overlays.shared.ask("Remove \(m.name)?", message: "They leave \(team.name) and the event.", action: "Remove", destructive: true) {
                    update(["remove": .string(m.participantId)], "remove")
                }
            })
        }
        guard !items.isEmpty else { return }
        T1Overlays.shared.showMenu(m.name, message: TeamRules.seatLabel(slot: m.slot ?? i + 1, seatFormats: seatFormats), items)
    }

    private func update(_ patch: [String: AnyJSON], _ what: String) {
        Task { @MainActor in
            do {
                EventSide.of(eventId).teams = try await Repo.teamUpdate(team.id, patch: patch, what: what, eventId: eventId)
            } catch {
                failed(error.localizedDescription)
            }
        }
    }

    /// Leaving is leaving the event; the captain's confirm says who takes over.
    private func askLeave() {
        let me = Repo.userId
        let next = team.members.first { $0.userId != me }
        let message = team.captainId == me
            ? (next.map { "\($0.name) becomes captain. You leave the event." } ?? "The team closes. You leave the event.")
            : "You leave \(team.name) and the event."
        T1Overlays.shared.ask("Leave \(team.name)?", message: message, action: "Leave team", destructive: true) {
            Task { @MainActor in
                do {
                    try await Repo.leaveEvent(eventId, waitlist: false)
                    await EventSide.of(eventId).refreshTeams()
                    left()
                } catch {
                    failed(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: the organizer's Teams tab

/// Setup → Teams with Teams sign up on: every team in full with its code and `2/3`; the organizer has the captain's
/// menu on each.
struct SignUpTeamsList: View {
    let eventId: String
    @State private var error: String?

    var body: some View {
        let side = EventSide.of(eventId)
        Group {
            LoadOnce { await side.refreshTeams() }
            if let error { Notice(error, error: true) }
            if let t = side.teams {
                if t.teams.isEmpty { ListRow(title: "No teams yet") }
                ForEach(t.teams) { team in
                    Color.clear.frame(height: 15)
                    TeamBlock(eventId: eventId, team: team, teamSize: t.teamSize ?? 3, seatFormats: t.seatFormats, edits: true, failed: { error = $0 })
                }
            }
        }
    }
}

// MARK: the top 4 between teams

/// Standings → Top 4 of a team event: each team match "(1) Ravens 2–1 (4) Owls" with its seats' matches under it.
struct TeamBracketRows: View {
    let bracket: [TeamBracketStage]
    var seatFormats: [String]?

    var body: some View {
        if !bracket.isEmpty {
            Section1("Top 4")
            // One block a stage (not lazy rows of their own: a stage's matches share their indexes with the next's).
            ForEach(bracket, id: \.stage) { stage in
                VStack(spacing: 1) {
                    LabelText(EventRules.roundName(stage: stage.stage, number: 0, of: 0)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8).background(T1.bg)
                    ForEach(stage.matches.indices, id: \.self) { i in match(stage.matches[i]) }
                }
                .id("team-bracket-\(stage.stage)")
            }
            Section1("Standings")
        }
    }

    /// A team match with its seats' matches under it.
    private func match(_ m: TeamBracketStage.Match) -> some View {
        let a = m.sides.first?.matchWins ?? 0, b = m.sides.dropFirst().first?.matchWins ?? 0
        return VStack(spacing: 1) {
            HStack(spacing: 8) {
                team(m, 0)
                Text(m.status == "pending" && a + b == 0 ? "v" : "\(a)–\(b)").font(T1.mono(14)).foregroundStyle(T1.muted)
                team(m, 1)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
            ForEach(m.matches ?? []) { seat in
                HStack(spacing: 8) {
                    LabelText(TeamRules.seatLabel(slot: seat.sides.first?.slot, seatFormats: seatFormats)).frame(width: 110, alignment: .leading)
                    player(seat, 0)
                    Text(seat.isBye == true ? "bye" : seat.status == "pending" ? "v" : "\(seat.sides.first?.gameWins ?? 0)–\(seat.sides.dropFirst().first?.gameWins ?? 0)")
                        .font(T1.mono(12)).foregroundStyle(T1.muted)
                    player(seat, 1)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(T1.bg)
            }
        }
    }

    private func team(_ m: TeamBracketStage.Match, _ n: Int) -> some View {
        let s = m.sides.indices.contains(n) ? m.sides[n] : nil
        let won = s?.teamId != nil && s?.teamId == m.winner
        return Text("(\(s?.seed.map(String.init) ?? "–")) \(s?.name ?? "—")")
            .font(T1.mono(14, won ? .bold : .regular)).lineLimit(1)
            .foregroundStyle(won ? T1.accent : T1.text)
            .frame(maxWidth: .infinity, alignment: n == 0 ? .leading : .trailing)
    }

    private func player(_ seat: TeamBracketStage.Seat, _ n: Int) -> some View {
        let s = seat.sides.indices.contains(n) ? seat.sides[n] : nil
        let won = s?.participantId != nil && s?.participantId == seat.winner
        return Text(s?.displayName ?? "—").font(T1.mono(12)).lineLimit(1)
            .foregroundStyle(won ? T1.text : T1.muted)
            .frame(maxWidth: .infinity, alignment: n == 0 ? .leading : .trailing)
    }
}
