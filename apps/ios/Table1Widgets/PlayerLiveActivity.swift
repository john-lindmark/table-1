import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen, StandBy, Dynamic Island and (watchOS 11) Smart Stack presentation of a player's match.
struct PlayerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivityAttributes.self) { context in
            LockScreenView(snap: LiveSnapshot(eventId: context.attributes.eventId, eventName: context.attributes.eventName,
                                              participantId: context.attributes.participantId, state: context.state),
                           stale: context.isStale)
                .activityBackgroundTint(W1.bg)
                .activitySystemActionForegroundColor(W1.accent)
                .widgetURL(URL(string: "table1://event/\(context.attributes.eventId)?src=live_activity"))
        } dynamicIsland: { context in
            let s = context.state
            let snap = LiveSnapshot(eventId: context.attributes.eventId, eventName: context.attributes.eventName,
                                    participantId: context.attributes.participantId, state: s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.tableText).font(W1.mono(20, .bold)).foregroundStyle(W1.accent)
                        WLabel("You \(s.myRankText)")
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        RoundTimer(state: s, size: 20).frame(width: 76, alignment: .trailing)
                        WLabel(s.roundText)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if s.isPlaying {
                        Text("vs \(s.oppName ?? "—") \(s.oppRankText)").font(W1.mono(14)).lineLimit(1)
                    } else {
                        Text(s.statusLine).font(W1.mono(13)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.isPlaying { MatchActions(snap: snap, compact: true).padding(.top, 4) }
                }
            } compactLeading: {
                Text(s.isPlaying ? s.tableText : "T1").font(W1.mono(13, .bold)).foregroundStyle(W1.accent)
            } compactTrailing: {
                RoundTimer(state: s, size: 13).frame(maxWidth: 48)
            } minimal: {
                if s.needsMyAnswer {
                    Image(systemName: "exclamationmark").foregroundStyle(W1.accent)
                } else {
                    RoundTimer(state: s, size: 11).frame(maxWidth: 40)
                }
            }
            .keylineTint(W1.accent)
            .widgetURL(URL(string: "table1://event/\(context.attributes.eventId)?src=dynamic_island"))
        }
    }
}

struct LockScreenView: View {
    let snap: LiveSnapshot
    var stale = false

    var body: some View {
        let s = snap.state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WLabel(snap.eventName)
                Spacer(minLength: 8)
                WLabel("\(s.roundText) · \(s.tableText)", color: W1.text)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if s.isPlaying {
                        Text("vs \(s.oppName ?? "—")").font(W1.mono(16)).foregroundStyle(W1.text).lineLimit(1)
                        WLabel("\(s.oppRankText) · \(s.oppRecord ?? "0-0")")
                    } else {
                        Text(s.statusLine).font(W1.mono(15)).foregroundStyle(W1.text).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if s.isPlaying { RoundTimer(state: s, size: 30).frame(width: 110, alignment: .trailing) }
            }
            HStack {
                WLabel("You \(s.myRankText) · \(s.myRecord)", color: W1.accent)
                Spacer()
                if stale { WLabel("Updating…") }
            }
            if s.isPlaying { MatchActions(snap: snap) }
        }
        .padding(14)
        .foregroundStyle(W1.text)
    }
}
