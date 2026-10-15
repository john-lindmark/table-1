import SwiftUI

/// One event: the organizer's control room, or a player's match card — chosen by role.
struct EventView: View {
    let eventId: String
    @Binding var path: [Route]
    @State private var bundle: EventBundle?
    @State private var engine = StandingsResponse()
    @State private var error: String?

    var body: some View {
        Group {
            if let bundle {
                if bundle.isOrganizer {
                    OrganizerView(b: bundle, engine: engine, refresh: refresh,
                                  showSeating: { engine.seating = $0 }) { path.append(.addPlayers(eventId)) }
                } else {
                    PlayerView(b: bundle, engine: engine, refresh: refresh)
                }
            } else {
                T1Screen {
                    Bar(title: "Event")
                    Notice(error ?? "Loading…", error: error != nil)
                }
            }
        }
        .task(id: eventId) {
            await refresh()
            // Realtime: any change in this event refetches, coalesced so a burst of reports is one reload.
            for await _ in Repo.eventChanges(eventId) {
                try? await Task.sleep(for: .milliseconds(250))
                await refresh()
            }
        }
    }

    private func refresh() async {
        // The bundle and the engine's standings don't depend on each other: fetch both at once.
        async let latestStandings = try? Repo.standings(eventId)
        do {
            bundle = try await Repo.loadEvent(eventId)
            error = nil
        } catch {
            if bundle == nil { self.error = error.localizedDescription }
        }
        if let latest = await latestStandings { engine = latest }
        if bundle?.isOrganizer == false { await LiveActivityController.shared.refresh() }
    }
}

// MARK: organizer (the three phases live in OrganizerPhases.swift)

/// The organizer's result editor ("set result" panel), with Watch life tracker while the match is live.
struct EditResultSheet: View {
    let m: MatchRow
    let b: EventBundle
    let onSave: (Int, Int, Int) -> Void
    var onWatch: (() -> Void)?
    @State private var s0 = 0
    @State private var s1 = 0
    @State private var draws = 0

    var body: some View {
        let valid = s0 + s1 + draws <= 3
        VStack(spacing: 1) {
            Bar(title: "Table \(m.tableNumber.map(String.init) ?? "")", subtitle: "Set the result") {
                BarButton("Cancel") { T1Overlays.shared.dismissPanel() }
            }
            T1Stepper(label: b.name(m.side(0)?.participantId), value: $s0, range: 0...2)
            T1Stepper(label: b.name(m.side(1)?.participantId), value: $s1, range: 0...2)
            T1Stepper(label: "Drawn games", value: $draws, range: 0...3)
            if !valid { Notice("At most 3 games in a match.", error: true) }
            if let onWatch, !m.isBye { Ghost(text: "Watch life tracker") { onWatch() } }
            BigAction(text: "Save result", enabled: valid, accent: true) { onSave(s0, s1, draws) }
        }
        .foregroundStyle(T1.text)
        .onAppear {
            s0 = m.side(0)?.gameWins ?? 0
            s1 = m.side(1)?.gameWins ?? 0
            draws = m.gameDraws
        }
    }
}

/// The event's join QR and short code; shown in a panel from the organizer's Setup.
struct ShareQR: View {
    let eventId: String
    @State private var qr: JoinQr?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 1) {
            VStack(spacing: 12) {
                if let qr {
                    Image(uiImage: qrImage(qr.url)).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 240, height: 240).padding(8).background(Color.white)
                    Text(qr.shortCode).font(T1.mono(36)).tracking(10)
                    LabelText("Scan with the phone camera or the Table 1 app")
                }
                if let error { Notice(error, error: true) }
            }
            .frame(maxWidth: .infinity).padding(24).background(T1.surface)
            Ghost(text: "New code") { Task { qr = try? await Repo.joinQr(eventId, rotate: true) } }
        }
        .task {
            do { qr = try await Repo.joinQr(eventId) } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: player

private struct Outcome: Identifiable { let id: String; let my: Int; let their: Int }
private let outcomes = [
    Outcome(id: "Won 2–0", my: 2, their: 0), Outcome(id: "Won 2–1", my: 2, their: 1), Outcome(id: "Draw 1–1", my: 1, their: 1),
    Outcome(id: "Lost 1–2", my: 1, their: 2), Outcome(id: "Lost 0–2", my: 0, their: 2),
]

private struct PlayerView: View {
    let b: EventBundle
    let engine: StandingsResponse
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session
    /// Optimistic: the tapped result shows instantly; the server confirms or the error reverts it.
    @State private var optimistic: (Int, Int)?
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        let me = b.participants.first { $0.userId != nil && $0.userId == Repo.userId }
        let active = b.activeRound
        let match = active?.matches.first { m in m.matchSides.contains { $0.participantId == me?.id } }
        let mine = match?.matchSides.first { $0.participantId == me?.id }
        let theirs = match?.matchSides.first { $0.participantId != me?.id }
        let seating = engine.seating ?? []

        T1Screen {
            Bar(title: b.event.name, subtitle: subtitle(me: me, active: active)) {
                BarButton("Back") { dismiss() }
            }
            if b.event.isCancelled { CancelledBanner(reason: b.event.cancelReason) }
            HairlineList {
                if let active { RoundClock(endsAt: active.timerEndsAt) }
                if me == nil {
                    Notice("You're viewing this event. Scan the organizer's QR to take a seat.")
                } else if let match {
                    if match.isBye {
                        LabelText("You have the bye this round", color: T1.ink)
                            .frame(maxWidth: .infinity).padding(24).background(T1.accent)
                    } else {
                        VStack(spacing: 4) {
                            LabelText("Table \(match.tableNumber.map(String.init) ?? "–") · playing")
                            Text(b.name(theirs?.participantId)).font(T1.mono(22))
                        }
                        .frame(maxWidth: .infinity).padding(20).background(T1.surface)

                        if session.trackerMode == .tracker {
                            // Tracking here: the life tracker leads; results are secondary.
                            Button { session.openTracker(matchId: match.id) } label: {
                                LabelText("Open life tracker", color: T1.ink)
                                    .frame(maxWidth: .infinity).padding(.vertical, 18).background(T1.accent)
                            }
                            .buttonStyle(.plain)
                            results(match, mine: mine, theirs: theirs)
                        } else {
                            results(match, mine: mine, theirs: theirs)
                            Ghost(text: "Open life tracker") { session.openTracker(matchId: match.id) }
                        }
                    }
                } else if !b.event.isFinished {
                    Notice(active == nil ? "Waiting for the next round to be paired." : "You're not paired this round.")
                }
                if me != nil && !b.event.isFinished { trackerToggle }
                if let notice { Notice(notice) }
                if let error { Notice(error, error: true) }
                if b.event.isDraft && b.rounds.isEmpty && !seating.isEmpty {
                    SeatingList(pods: seating, highlight: me?.id, teamDraft: b.event.formatName == "team_draft")
                }
                Section1("Standings")
                StandingsRows(engine: engine, highlight: me?.id)
            }
        }
        .onChange(of: match?.version) { optimistic = nil }
    }

    /// "Team Lotus · seat B · Round 2 of 3" for team events; otherwise name · format · round.
    private func subtitle(me: ParticipantRow?, active: RoundRow?) -> String {
        let round = "Round \(active?.number ?? b.event.currentRound) of \(b.event.numberOfRounds)"
        guard let me else { return "Spectating · \(b.event.label) · \(round)" }
        if b.event.isTeamEvent, let team = engine.teamOf(me.id) {
            let slot: Int? = me.teamSlot ?? team.members.first(where: { $0.participantId == me.id })?.slot
            let teamName = team.name.lowercased().hasPrefix("team") ? team.name : "Team \(team.name)"
            return "\(teamName) · seat \(slotLetter(slot)) · \(round)"
        }
        return "\(me.displayName) · \(b.event.label) · \(round)"
    }

    private var trackerToggle: some View {
        T1Switch(title: "Use life tracker", detail: "Open the life tracker first for your matches", isOn: Binding(
            get: { session.trackerMode == .tracker },
            set: { on in setTrackerMode(on ? .tracker : .elsewhere) }
        ))
    }

    /// The Binding setter isn't main-actor isolated, so hop to the main actor explicitly here.
    private func setTrackerMode(_ mode: TrackerMode) {
        Task { @MainActor in
            do {
                try await session.setTrackerMode(mode)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func results(_ match: MatchRow, mine: SideRow?, theirs: SideRow?) -> some View {
        let opponentReported = match.status == "reported" && match.reportedByUser != nil && match.reportedByUser != Repo.userId
        if opponentReported {
            Notice("\(b.name(theirs?.participantId)) reported \(mine?.gameWins ?? 0)–\(theirs?.gameWins ?? 0) for you.\(match.disputed ? " Disputed — waiting on the organizer." : "")")
            if !match.disputed {
                HStack(spacing: 1) {
                    Ghost(text: "Dispute") { respond(match, accept: false) }
                    Ghost(text: "Confirm", accent: true) { respond(match, accept: true) }
                }
            }
        } else if match.status == "confirmed" {
            Notice("Result confirmed: \(mine?.gameWins ?? 0)–\(theirs?.gameWins ?? 0). The organizer can still correct it.")
        } else if b.event.allowPlayerReporting {
            ForEach(outcomes) { o in
                let selected = optimistic.map { $0.0 == o.my && $0.1 == o.their }
                    ?? (match.status == "reported" && mine?.gameWins == o.my && theirs?.gameWins == o.their)
                Button { report(match, mine: mine, my: o.my, their: o.their) } label: {
                    LabelText(o.id, color: selected ? T1.ink : T1.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(selected ? T1.accent : T1.surface)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: selected)
            }
            if match.status == "reported" { Notice("Reported. Tap a different result to correct it before the round ends.") }
        } else {
            Notice("The organizer is recording results for this event.")
        }
    }

    private func report(_ match: MatchRow, mine: SideRow?, my: Int, their: Int) {
        guard let side = mine?.side else { return }
        optimistic = (my, their)
        error = nil
        Task {
            do {
                let (s0, s1) = side == 0 ? (my, their) : (their, my)
                let outcome = try await Repo.reportMatch(match, side0: s0, side1: s1)
                if outcome.conflict == true {
                    notice = "Your opponent reported a different score. The first result stands until the organizer decides."
                }
                await LiveActivityController.shared.refresh(force: true)
                await refresh()
            } catch {
                optimistic = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func respond(_ match: MatchRow, accept: Bool) {
        Task {
            do {
                try await Repo.respondToResult(match.id, accept: accept)
                if !accept { notice = "Disputed. The organizer has been notified." }
                await LiveActivityController.shared.refresh(force: true)
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: shared

struct CancelledBanner: View {
    let reason: String?
    var body: some View {
        Notice("Cancelled by the organizer\(reason.map { ": \($0)" } ?? ""). Confirmed results still count.", error: true)
    }
}

struct StandingsList: View {
    let engine: StandingsResponse
    let highlight: String?
    var body: some View {
        HairlineList { StandingsRows(engine: engine, highlight: highlight) }
    }
}

/// Team events: the team table first, then individuals tagged with their team.
struct StandingsRows: View {
    let engine: StandingsResponse
    let highlight: String?

    var body: some View {
        let teams = engine.teams ?? []
        if engine.standings.isEmpty && teams.isEmpty { Notice("Standings appear after the first results.") }
        if !teams.isEmpty {
            Section1("Teams")
            ForEach(teams) { TeamStandingLine(t: $0, highlight: highlight) }
            Section1("Players")
        }
        ForEach(engine.standings) { s in
            StandingLine(s: s, highlight: s.participantId == highlight, tag: engine.teamOf(s.participantId)?.name)
        }
    }
}

/// rank · name · W-L-D · points, "N match wins", then members by seat letter with their match wins.
struct TeamStandingLine: View {
    let t: TeamStanding
    let highlight: String?
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 12) {
                LabelText("\(t.rank)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(T1.mono(15)).lineLimit(1)
                    LabelText("\(t.matchWins) match win\(t.matchWins == 1 ? "" : "s")")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(recordText(t.wins, t.losses, t.draws)).font(T1.mono(14))
                LabelText("\(t.points) pts", color: T1.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(T1.surface)
            ForEach(t.members.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }) { m in
                HStack(spacing: 12) {
                    LabelText(slotLetter(m.slot))
                    Text(m.displayName).font(T1.mono(13)).lineLimit(1)
                        .foregroundStyle(m.status == "dropped" ? T1.muted : T1.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LabelText("\(m.matchWins ?? 0) won")
                }
                .padding(.leading, 40).padding(.trailing, 16).padding(.vertical, 8)
                .background(m.participantId == highlight ? T1.surfaceHover : T1.bg)
            }
        }
    }
}

struct StandingLine: View {
    let s: Standing
    let highlight: Bool
    var tag: String?
    var body: some View {
        HStack(spacing: 12) {
            LabelText("\(s.rank)")
            Text(s.displayName).font(T1.mono(14)).lineLimit(1)
                .foregroundStyle(s.status == "dropped" ? T1.muted : T1.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tag { LabelText(tag) }
            Text(recordText(s.matchWins, s.matchLosses, s.matchDraws)).font(T1.mono(14))
            LabelText("\(s.matchPoints) pts")
            LabelText("\(Int((s.omw * 100).rounded()))%")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(highlight ? T1.surfaceHover : T1.surface)
    }
}

/// Counts down to the server's timer_ends_at, so every phone shows the same clock.
private struct RoundClock: View {
    let endsAt: String?
    var body: some View {
        if let end = endsAt.flatMap(Self.parse) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(end.timeIntervalSince(context.date)))
                Text(left == 0 ? "TIME" : String(format: "%02d:%02d", left / 60, left % 60))
                    .font(T1.mono(56)).tracking(4)
                    .foregroundStyle(left == 0 ? T1.danger : T1.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 16).background(T1.bg)
            }
        }
    }

    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
