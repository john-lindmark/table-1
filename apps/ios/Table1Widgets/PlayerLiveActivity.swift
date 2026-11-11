import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen, StandBy, Dynamic Island and (watchOS 11) Smart Stack presentation of a player's match: the round
/// clock, the table and the opponent, nothing to tap but the event (contract/widgets-2026-10-22.md § Player Live
/// Activity). Results are reported in the app, never from the activity.
struct PlayerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivityAttributes.self) { context in
            PlayerLockScreenView(snap: LiveSnapshot(eventId: context.attributes.eventId, eventName: context.attributes.eventName,
                                                    participantId: context.attributes.participantId, state: context.state),
                                 stale: context.isStale)
                .activityBackgroundTint(W1.bg)
                .activitySystemActionForegroundColor(W1.accent)
                .widgetURL(URL(string: "table1://event/\(context.attributes.eventId)?src=live_activity"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(s.isPlaying ? s.tableText : "T1").font(W1.mono(20, .bold)).foregroundStyle(W1.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        RoundTimer(state: s, size: 20).frame(width: 76, alignment: .trailing)
                        WLabel(s.roundText)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.isPlaying ? "vs \(s.oppName ?? "—")" : s.statusLine).font(W1.mono(14)).lineLimit(1)
                }
            } compactLeading: {
                Text(s.isPlaying ? s.tableText : "T1").font(W1.mono(13, .bold)).foregroundStyle(W1.accent)
            } compactTrailing: {
                RoundTimer(state: s, size: 13).frame(maxWidth: 48)
            } minimal: {
                RoundTimer(state: s, size: 11).frame(maxWidth: 40)
            }
            .keylineTint(W1.accent)
            .widgetURL(URL(string: "table1://event/\(context.attributes.eventId)?src=dynamic_island"))
        }
    }
}
