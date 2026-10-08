import SwiftUI

/// One event: the organizer's control room, or a player's match card — chosen by role.
struct EventView: View {
    let eventId: String
    @State private var bundle: EventBundle?
    @State private var standings: [Standing] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let bundle {
                if bundle.isOrganizer {
                    OrganizerView(b: bundle, standings: standings, refresh: refresh)
                } else {
                    PlayerView(b: bundle, standings: standings, refresh: refresh)
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
        do {
            bundle = try await Repo.loadEvent(eventId)
            error = nil
        } catch {
            if bundle == nil { self.error = error.localizedDescription }
        }
        let latest = try? await Repo.standings(eventId)
        if let latest { standings = latest }
        if bundle?.isOrganizer == false { await LiveActivityController.shared.refresh() }
    }
}

// MARK: organizer

private struct OrganizerView: View {
    static let tabs: [(id: String, label: String)] = [("round", "Round"), ("standings", "Standings"), ("players", "Players"), ("share", "Join QR")]
    let b: EventBundle
    let standings: [Standing]
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "round"
    @State private var busy = false
    @State private var error: String?
    @State private var editing: MatchRow?

    var body: some View {
        let event = b.event
        let active = b.activeRound
        let nextNumber = (b.rounds.map(\.number).max() ?? 0) + 1
        let outstanding = active?.matches.filter { !$0.isBye && $0.status == "pending" }.count ?? 0
        let disputes = active?.matches.filter { $0.disputed && $0.status != "confirmed" }.count ?? 0

        T1Screen {
            Bar(title: event.name, subtitle: "\(event.shortCode) · Round \(event.currentRound) of \(event.numberOfRounds) · \(b.participants.count) players") {
                BarButton("Back") { dismiss() }
            }
            HStack(spacing: 1) {
                ForEach(Self.tabs, id: \.id) { t in
                    Ghost(text: t.label, accent: tab == t.id) { tab = t.id }
                }
            }
            if let error { Notice(error, error: true) }

            switch tab {
            case "standings": StandingsList(standings: standings, highlight: nil)
            case "players":
                HairlineList {
                    ForEach(b.participants) { p in
                        ListRow(title: p.displayName, detail: "Seat \(p.seat.map(String.init) ?? "–") · \(p.status)\(p.userId == nil ? " · guest" : "")")
                    }
                }
            case "share": ShareQR(eventId: event.id)
            default:
                HairlineList {
                    if let active {
                        RoundClock(endsAt: active.timerEndsAt)
                        if disputes > 0 { Notice("\(disputes) disputed result\(disputes == 1 ? "" : "s") — tap to set the score.", error: true) }
                        ForEach(active.matches) { m in
                            Button { if !m.isBye { editing = m } } label: { MatchLine(m: m, b: b) }.buttonStyle(.plain)
                        }
                    } else {
                        Notice(event.status == "completed" ? "Event complete." : "No round running. Pair round \(nextNumber) when everyone is seated.")
                    }
                }
            }

            if event.status != "completed" {
                if active == nil && nextNumber <= event.numberOfRounds {
                    BigAction(text: "Pair round \(nextNumber)", enabled: b.participants.filter { $0.status == "active" }.count >= 2, busy: busy, accent: true) {
                        act { try await pair(event.id) }
                    }
                } else if active != nil && outstanding > 0 {
                    BigAction(text: "Waiting on \(outstanding) result\(outstanding == 1 ? "" : "s")", enabled: false) {}
                } else if let active, active.number < event.numberOfRounds {
                    BigAction(text: "Pair round \(active.number + 1)", busy: busy, accent: true) { act { try await pair(event.id) } }
                } else if let active {
                    BigAction(text: "Finish event", busy: busy, accent: true) {
                        act { try await Repo.recordRound(eventId: event.id, roundId: active.id, finalRound: true) }
                    }
                }
            }
        }
        .sheet(item: $editing) { m in
            EditResultSheet(m: m, b: b) { s0, s1, draws in
                editing = nil
                act { try await Repo.setMatchResult(m.id, side0: s0, side1: s1, draws: draws, reason: "Set by organizer") }
            }
            .presentationDetents([.medium])
        }
    }

    private func pair(_ eventId: String) async throws {
        let r = try await Repo.pairNextRound(eventId)
        if let message = r.error { throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func act(_ block: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
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

private struct MatchLine: View {
    let m: MatchRow
    let b: EventBundle
    var body: some View {
        let a = m.side(0)
        let c = m.side(1)
        let scored = m.status != "pending"
        HStack(spacing: 12) {
            LabelText("T\(m.tableNumber.map(String.init) ?? "–")")
            Text(b.name(a?.participantId)).font(T1.mono(14)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if m.isBye {
                LabelText("Bye", color: T1.accent)
            } else {
                Text(scored ? "\(a?.gameWins ?? 0)–\(c?.gameWins ?? 0)" : "·")
                    .font(T1.mono(18)).foregroundStyle(scored ? T1.accent : T1.muted)
                Text(b.name(c?.participantId)).font(T1.mono(14)).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(m.disputed && m.status != "confirmed" ? T1.danger.opacity(0.15) : T1.surface)
    }
}

private struct EditResultSheet: View {
    let m: MatchRow
    let b: EventBundle
    let onSave: (Int, Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var s0 = 0
    @State private var s1 = 0
    @State private var draws = 0

    var body: some View {
        let valid = s0 + s1 + draws <= 3
        T1Screen {
            Bar(title: "Table \(m.tableNumber.map(String.init) ?? "")", subtitle: "Set the result") { BarButton("Cancel") { dismiss() } }
            Stepper1(label: b.name(m.side(0)?.participantId), value: $s0, range: 0...2)
            Stepper1(label: b.name(m.side(1)?.participantId), value: $s1, range: 0...2)
            Stepper1(label: "Drawn games", value: $draws, range: 0...3)
            if !valid { Notice("At most 3 games in a match.", error: true) }
            Spacer()
            BigAction(text: "Save result", enabled: valid, accent: true) { onSave(s0, s1, draws) }
        }
        .onAppear {
            s0 = m.side(0)?.gameWins ?? 0
            s1 = m.side(1)?.gameWins ?? 0
            draws = m.gameDraws
        }
    }
}

private struct Stepper1: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack {
            Text(label).font(T1.mono(13)).lineLimit(1)
            Spacer()
            BarButton("−") { value = max(range.lowerBound, value - 1) }
            Text("\(value)").font(T1.mono(22)).foregroundStyle(T1.accent).frame(minWidth: 44)
            BarButton("+") { value = min(range.upperBound, value + 1) }
        }
        .padding(16).background(T1.surface)
        .sensoryFeedback(.selection, trigger: value)
    }
}

private struct ShareQR: View {
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
            Spacer()
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
    let standings: [Standing]
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
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
        let opponentReported = match.map { $0.status == "reported" && $0.reportedByUser != nil && $0.reportedByUser != Repo.userId } ?? false

        T1Screen {
            Bar(title: b.event.name, subtitle: "\(me?.displayName ?? "Spectating") · Round \(active?.number ?? b.event.currentRound) of \(b.event.numberOfRounds)") {
                BarButton("Back") { dismiss() }
            }
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
                } else {
                    Notice(active == nil ? "Waiting for the next round to be paired." : "You're not paired this round.")
                }
                if let notice { Notice(notice) }
                if let error { Notice(error, error: true) }
                Section1("Standings")
                ForEach(standings) { s in StandingLine(s: s, highlight: s.participantId == me?.id) }
            }
        }
        .onChange(of: match?.version) { optimistic = nil }
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

private struct StandingsList: View {
    let standings: [Standing]
    let highlight: String?
    var body: some View {
        HairlineList {
            if standings.isEmpty { Notice("Standings appear after the first results.") }
            ForEach(standings) { StandingLine(s: $0, highlight: $0.participantId == highlight) }
        }
    }
}

private struct StandingLine: View {
    let s: Standing
    let highlight: Bool
    var body: some View {
        HStack(spacing: 12) {
            LabelText("\(s.rank)")
            Text(s.displayName).font(T1.mono(14)).lineLimit(1)
                .foregroundStyle(s.status == "dropped" ? T1.muted : T1.text)
                .frame(maxWidth: .infinity, alignment: .leading)
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
