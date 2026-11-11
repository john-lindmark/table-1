import SwiftUI
import WidgetKit

// Views for the widgets batch (contract/widgets-2026-10-22.md). They live in Shared so the app's Debug gallery
// (`-T1WidgetsDemo`) can draw them too; the widget entry views pass the family in.

// MARK: - organizer

/// The round clock for the organizer: same rules as the player clock (system-drawn, frozen when paused).
struct OrgClock: View {
    let state: OrgState
    var size: CGFloat = 28
    var body: some View {
        if let end = state.endDate {
            Text(timerInterval: Date.now...max(Date.now, end), countsDown: true, showsHours: false)
                .font(W1.mono(size, .medium)).monospacedDigit()
                .foregroundStyle(end > .now ? W1.text : W1.danger)
                .multilineTextAlignment(.trailing)
        } else if let paused = state.pausedText {
            Text(paused).font(W1.mono(size, .medium)).monospacedDigit().foregroundStyle(W1.muted)
        } else {
            EmptyView()
        }
    }
}

/// One tick per match: accent = result in, red = disputed, surface = waiting.
struct ResultsBar: View {
    let state: OrgState
    var height: CGFloat = 6
    var body: some View {
        let total = max(state.matches, 1)
        HStack(spacing: total > 24 ? 1 : 2) {
            ForEach(0..<total, id: \.self) { i in
                Rectangle()
                    .fill(i < state.done ? W1.accent : i < state.done + state.disputes ? W1.danger : W1.surface)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(state.done) of \(state.matches) results in")
    }
}

/// The player Live Activity on the Lock Screen and in StandBy: where you sit, who you play and the round clock. No
/// result buttons: results go in from the app (contract/widgets-2026-10-22.md § Player Live Activity).
struct PlayerLockScreenView: View {
    let snap: LiveSnapshot
    var stale = false

    var body: some View {
        let s = snap.state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WLabel(snap.eventName)
                Spacer(minLength: 8)
                WLabel(s.roundText, color: W1.text)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if s.isPlaying {
                        Text(s.tableText).font(W1.mono(30, .bold)).foregroundStyle(W1.accent)
                        Text("vs \(s.oppName ?? "—")").font(W1.mono(16)).foregroundStyle(W1.text).lineLimit(1)
                    } else {
                        Text(s.statusLine).font(W1.mono(15)).foregroundStyle(W1.text).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if s.isPlaying { RoundTimer(state: s, size: 30).frame(width: 110, alignment: .trailing) }
            }
            if stale { WLabel("Updating…") }
        }
        .padding(14)
        .foregroundStyle(W1.text)
    }
}

struct OrganizerLockScreenView: View {
    let snap: OrganizerSnapshot
    var stale = false

    var body: some View {
        let s = snap.state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WLabel(snap.eventName)
                Spacer(minLength: 8)
                WLabel(s.isLive || s.phase == "between" ? "\(s.roundText) · Organizing" : "Organizing", color: W1.text)
            }
            HStack(alignment: .firstTextBaseline) {
                if s.isLive {
                    Text(s.resultsText.uppercased()).font(W1.mono(22, .semibold))
                        .foregroundStyle(s.isReady ? W1.accent : W1.text)
                } else {
                    Text(s.nextStep).font(W1.mono(15)).foregroundStyle(W1.text).lineLimit(2)
                }
                Spacer(minLength: 8)
                if s.isLive { OrgClock(state: s, size: 28).frame(width: 110, alignment: .trailing) }
            }
            if s.isLive { ResultsBar(state: s) }
            HStack(spacing: 8) {
                if s.isLive { WLabel(s.nextStep, color: s.isReady ? W1.accent : W1.text) }
                Spacer(minLength: 0)
                if stale { WLabel("Updating…") }
            }
            if !s.flags.isEmpty {
                HStack(spacing: 12) {
                    ForEach(s.flags, id: \.self) { f in WLabel(f, color: f.contains("dispute") ? W1.danger : W1.muted) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .foregroundStyle(W1.text)
    }
}

// MARK: - next event

struct NextEventView: View {
    let family: WidgetFamily
    let data: NextEventData?
    var now: Date = .now

    var body: some View {
        let shown = NextEvent.pick(data?.events ?? [])
        let invites = data?.invites ?? 0
        switch family {
        case .accessoryInline:
            if let e = shown.first { Text("\(e.name) · \(NextEvent.timeText(e, now: now))") } else { Text("Table 1 · no events") }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let e = shown.first {
                    Text(NextEvent.timeText(e, now: now)).font(W1.mono(12, .bold)).widgetAccentable()
                    Text(e.name).font(W1.mono(12)).lineLimit(1)
                    Text(detail(e)).font(W1.mono(11)).lineLimit(1)
                } else {
                    Text("Table 1").font(W1.mono(12, .bold)).widgetAccentable()
                    Text("No events coming up").font(W1.mono(12)).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(spacing: 12) {
                card(shown.first, invites: 0).frame(maxWidth: .infinity)
                Rectangle().fill(W1.surface).frame(width: 1)
                VStack(alignment: .leading, spacing: 4) {
                    if shown.count > 1 {
                        WLabel("Then")
                        Text(shown[1].name).font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(2)
                        WLabel(NextEvent.timeText(shown[1], now: now))
                    } else {
                        WLabel("Then")
                        Text("Nothing else").font(W1.mono(13)).foregroundStyle(W1.muted)
                    }
                    Spacer(minLength: 0)
                    if invites > 0 { WLabel("\(invites) invite\(invites == 1 ? "" : "s")", color: W1.accent) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        default:
            card(shown.first, invites: invites)
        }
    }

    private func detail(_ e: NextEventItem) -> String {
        [e.venueName, "\(e.players) player\(e.players == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func card(_ e: NextEventItem?, invites: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e {
                WLabel(e.label)
                Text(NextEvent.timeText(e, now: now)).font(W1.mono(15, .semibold))
                    .foregroundStyle(e.isLive ? W1.accent : W1.text).lineLimit(1).minimumScaleFactor(0.8)
                if e.organizing { WLabel("Organizing") }
                Spacer(minLength: 0)
                Text(e.name).font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(2)
                WLabel(detail(e))
                if invites > 0 { WLabel("\(invites) invite\(invites == 1 ? "" : "s")", color: W1.accent) }
            } else {
                WLabel("Table 1", color: W1.accent)
                Spacer(minLength: 0)
                Text("No events coming up").font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(2)
                WLabel(invites > 0 ? "\(invites) invite\(invites == 1 ? "" : "s")" : "Create or join one",
                       color: invites > 0 ? W1.accent : W1.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - collection value

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, max(hi * 0.002, 0.01))
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                         y: g.size.height * (1 - CGFloat((v - lo) / span)))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(W1.accent, lineWidth: 1.5)
            } else {
                Rectangle().fill(W1.surface).frame(height: 1).frame(maxHeight: .infinity)
            }
        }
    }
}

struct ValueView: View {
    let family: WidgetFamily
    let record: ValueRecord?
    var now: Date = .now

    var body: some View {
        if let r = record, let value = r.current {
            if family == .systemMedium {
                HStack(spacing: 14) {
                    summary(r, value).frame(width: 136)
                    VStack(alignment: .leading, spacing: 6) {
                        Sparkline(values: r.points.map(\.usd)).frame(maxHeight: .infinity)
                        HStack {
                            WLabel("\(r.cards.formatted()) cards")
                            Spacer(minLength: 4)
                            WLabel("\(r.copies.formatted()) copies")
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    summary(r, value)
                    Sparkline(values: r.points.map(\.usd)).frame(height: 30)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WLabel("Collection", color: W1.accent)
                Spacer(minLength: 0)
                Text("Open the Collection tab to start").font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func summary(_ r: ValueRecord, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WLabel("Collection")
            Spacer(minLength: 0)
            Text(Self.money(value)).font(W1.mono(22, .semibold)).foregroundStyle(W1.text)
                .lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
            if let c = r.change(now: now) {
                WLabel("\(c.usd >= 0 ? "+" : "−")\(Self.money(abs(c.usd))) · \(c.days) day\(c.days == 1 ? "" : "s")",
                       color: c.usd > 0 ? W1.accent : c.usd < 0 ? W1.danger : W1.muted)
                    .privacySensitive()
            } else {
                WLabel("From today")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func money(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd >= 1000 ? 0 : 2)))
    }
}
