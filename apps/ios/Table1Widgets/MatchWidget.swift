import SwiftUI
import WidgetKit

struct MatchEntry: TimelineEntry {
    let date: Date
    let snap: LiveSnapshot?
}

/// Reads the shared cache first; refreshes from the server at most once a minute, with a hard timeout.
/// Reload cadence follows the event: every 15 min during a match, 10 min between rounds, rarely when idle.
/// The app also reloads widgets whenever it learns something new, which doesn't count against the budget.
struct MatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> MatchEntry { MatchEntry(date: .now, snap: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (MatchEntry) -> Void) {
        let cached = LiveStore.featured(LiveStore.load())
        completion(MatchEntry(date: .now, snap: context.isPreview ? (cached ?? .sample) : cached))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MatchEntry>) -> Void) {
        Task {
            var snaps = LiveStore.load()
            if LiveStore.isStale(maxAge: 60),
               let fresh = try? await LiveAPI.withTimeout(8, { try await LiveAPI.fetch() }) {
                LiveStore.save(fresh)
                snaps = fresh
            }
            let snap = LiveStore.featured(snaps)
            completion(Timeline(entries: [MatchEntry(date: .now, snap: snap)], policy: Self.policy(for: snap?.state)))
        }
    }

    static func policy(for s: LiveState?) -> TimelineReloadPolicy {
        let now = Date()
        guard let s else { return .after(now.addingTimeInterval(6 * 3600)) }
        switch s.phase {
        case "playing":
            let next = now.addingTimeInterval(15 * 60)
            if let end = s.endDate, end > now { return .after(min(next, end.addingTimeInterval(60))) }
            return .after(next)
        case "waiting", "bye": return .after(now.addingTimeInterval(10 * 60))
        default: return .after(now.addingTimeInterval(6 * 3600))
        }
    }
}

struct MatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "site.table1.match", provider: MatchProvider()) { entry in
            MatchWidgetView(entry: entry)
        }
        .configurationDisplayName("Current match")
        .description("Round clock, table, opponent and ranks. Report your result without opening the app.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct MatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MatchEntry

    var body: some View {
        Group {
            if let snap = entry.snap {
                switch family {
                case .systemSmall: SmallView(snap: snap)
                case .systemMedium: MediumView(snap: snap)
                case .accessoryCircular: CircularView(state: snap.state)
                case .accessoryRectangular: RectangularView(state: snap.state)
                case .accessoryInline: InlineView(state: snap.state)
                default: SmallView(snap: snap)
                }
            } else {
                NoMatchView(family: family)
            }
        }
        .widgetURL(entry.snap?.deepLink ?? URL(string: "table1://home"))
        .containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium { W1.bg } else { Color.clear }
        }
    }
}

private struct SmallView: View {
    let snap: LiveSnapshot
    var body: some View {
        let s = snap.state
        VStack(alignment: .leading, spacing: 4) {
            WLabel("\(s.roundText) · \(s.tableText)", color: W1.accent)
            if s.isPlaying {
                RoundTimer(state: s, size: 26)
                Spacer(minLength: 0)
                Text("vs \(s.oppName ?? "—")").font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(1)
                WLabel("\(s.oppRankText) · \(s.oppRecord ?? "0-0")")
                WLabel("You \(s.myRankText) · \(s.myRecord)", color: s.needsMyAnswer ? W1.accent : W1.muted)
            } else {
                Spacer(minLength: 0)
                Text(s.statusLine).font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(3)
                WLabel("You \(s.myRankText) · \(s.myRecord)", color: W1.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumView: View {
    let snap: LiveSnapshot
    var body: some View {
        HStack(spacing: 12) {
            SmallView(snap: snap).frame(width: 128)
            VStack(alignment: .leading, spacing: 6) {
                WLabel(snap.eventName)
                Spacer(minLength: 0)
                if snap.state.isPlaying {
                    MatchActions(snap: snap, compact: true, columns: 3)
                } else {
                    Text(snap.state.statusLine).font(W1.mono(12)).foregroundStyle(W1.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct CircularView: View {
    let state: LiveState
    var body: some View {
        if let window = state.roundWindow, state.isPlaying {
            ProgressView(timerInterval: window, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                Text(state.tableText).font(W1.mono(13, .bold))
            }
            .progressViewStyle(.circular)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Text(state.isPlaying ? state.tableText : "T1").font(W1.mono(13, .bold))
            }
        }
    }
}

private struct RectangularView: View {
    let state: LiveState
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(state.roundText) · \(state.tableText)").font(W1.mono(12, .bold)).widgetAccentable()
            if state.isPlaying {
                Text("vs \(state.oppName ?? "—") \(state.oppRankText)").font(W1.mono(12)).lineLimit(1)
                HStack(spacing: 4) {
                    RoundTimer(state: state, size: 13)
                    Text("· you \(state.myRankText)").font(W1.mono(12))
                }
            } else {
                Text(state.statusLine).font(W1.mono(12)).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineView: View {
    let state: LiveState
    var body: some View {
        if state.isPlaying, let end = state.endDate {
            Text("\(state.tableText) vs \(state.oppName ?? "—") · \(end, style: .timer)")
        } else {
            Text(state.statusLine)
        }
    }
}

private struct NoMatchView: View {
    let family: WidgetFamily
    var body: some View {
        switch family {
        case .accessoryInline: Text("Table 1 · no match")
        case .accessoryCircular: ZStack { AccessoryWidgetBackground(); Text("T1").font(W1.mono(13, .bold)) }
        case .accessoryRectangular:
            VStack(alignment: .leading) { Text("Table 1").font(W1.mono(12, .bold)); Text("No match right now").font(W1.mono(12)) }
        default:
            VStack(alignment: .leading, spacing: 6) {
                WLabel("Table 1", color: W1.accent)
                Spacer(minLength: 0)
                Text("No match right now").font(W1.mono(13)).foregroundStyle(W1.text)
                WLabel("Join an event to see it here")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
