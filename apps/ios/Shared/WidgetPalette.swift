import SwiftUI

/// Table 1 look for widgets and the Live Activity (mirrors T1 in the app's Kit.swift).
enum W1 {
    static let bg = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x25 / 255)
    static let surface = Color(red: 0x28 / 255, green: 0x28 / 255, blue: 0x39 / 255)
    static let text = Color.white
    static let muted = Color(red: 0xC4 / 255, green: 0xC4 / 255, blue: 0xCA / 255)
    static let ink = bg
    static let accent = Color(red: 0, green: 1, blue: 0xD9 / 255)
    static let danger = Color(red: 1, green: 0.42, blue: 0.42)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct WLabel: View {
    let text: String
    var color: Color = W1.muted
    init(_ text: String, color: Color = W1.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(W1.mono(10)).tracking(1.2).foregroundStyle(color).lineLimit(1)
    }
}

/// The round clock. Rendered by the system from the end time, so it ticks without any app or
/// network work; a paused clock shows its frozen remaining time.
struct RoundTimer: View {
    let state: LiveState
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
            Text("--:--").font(W1.mono(size, .medium)).foregroundStyle(W1.muted)
        }
    }
}

/// Result buttons (2-0 … 0-2) or Confirm / Dispute, depending on where the match stands.
struct MatchActions: View {
    let snap: LiveSnapshot
    var compact = false
    var columns = 5

    var body: some View {
        let s = snap.state
        if s.canReportNow {
            let outcomes = MatchOutcome.allCases
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(Array(stride(from: 0, to: outcomes.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(outcomes[start..<min(start + columns, outcomes.count)], id: \.self) { o in
                            Button(intent: ReportResultIntent(participantId: snap.participantId, state: s, outcome: o)) {
                                Text(o.label).font(W1.mono(compact ? 12 : 14, .semibold))
                                    .frame(maxWidth: .infinity, minHeight: compact ? 28 : 34)
                                    .background(o.wins.my > o.wins.their ? W1.accent : W1.surface)
                                    .foregroundStyle(o.wins.my > o.wins.their ? W1.ink : W1.text)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else if s.needsMyAnswer, let matchId = s.matchId {
            HStack(spacing: 4) {
                Button(intent: RespondResultIntent(participantId: snap.participantId, matchId: matchId, accept: false)) {
                    Text("DISPUTE").font(W1.mono(12, .semibold)).frame(maxWidth: .infinity, minHeight: 34)
                        .background(W1.surface).foregroundStyle(W1.text)
                }.buttonStyle(.plain)
                Button(intent: RespondResultIntent(participantId: snap.participantId, matchId: matchId, accept: true)) {
                    Text("CONFIRM \(s.scoreText)").font(W1.mono(12, .semibold)).frame(maxWidth: .infinity, minHeight: 34)
                        .background(W1.accent).foregroundStyle(W1.ink)
                }.buttonStyle(.plain)
            }
        } else {
            WLabel(s.statusLine, color: s.status == "disputed" ? W1.danger : W1.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension LiveSnapshot {
    /// `src` tells the app which surface was tapped (telemetry only).
    func deepLink(src: String) -> URL { URL(string: "table1://event/\(eventId)?src=\(src)")! }
}
