import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen, StandBy and Dynamic Island for the organizer running a round (contract/widgets-2026-10-22.md).
/// Read-only: a tap opens the event's organizer screen.
struct OrganizerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrganizerActivityAttributes.self) { context in
            let snap = OrganizerSnapshot(eventId: context.attributes.eventId, eventName: context.attributes.eventName,
                                         state: context.state)
            OrganizerLockScreenView(snap: snap, stale: context.isStale)
                .activityBackgroundTint(W1.bg)
                .activitySystemActionForegroundColor(W1.accent)
                .widgetURL(snap.deepLink(src: "organizer_activity"))
        } dynamicIsland: { context in
            let s = context.state
            let snap = OrganizerSnapshot(eventId: context.attributes.eventId, eventName: context.attributes.eventName, state: s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.isLive ? s.resultsText.uppercased() : s.roundText).font(W1.mono(18, .bold))
                            .foregroundStyle(s.isReady ? W1.accent : W1.text)
                        WLabel(s.roundText)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    OrgClock(state: s, size: 20).frame(width: 76, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.nextStep).font(W1.mono(13)).lineLimit(1)
                        .foregroundStyle(s.isReady ? W1.accent : W1.text)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if s.isLive { ResultsBar(state: s) }
                        HStack(spacing: 8) {
                            ForEach(s.flags, id: \.self) { f in WLabel(f, color: f.contains("dispute") ? W1.danger : W1.muted) }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Text(s.isLive ? "\(s.done)/\(s.matches)" : "R\(s.round)").font(W1.mono(13, .bold))
                    .foregroundStyle(s.isReady ? W1.accent : s.disputes > 0 ? W1.danger : W1.text)
            } compactTrailing: {
                if s.endDate != nil || s.pausedText != nil {
                    OrgClock(state: s, size: 13).frame(maxWidth: 48)
                } else {
                    Text(s.isReady ? "READY" : "\(s.waiting)").font(W1.mono(12, .bold)).foregroundStyle(W1.accent)
                }
            } minimal: {
                if s.disputes > 0 {
                    Image(systemName: "exclamationmark").foregroundStyle(W1.danger)
                } else if s.isReady {
                    Image(systemName: "checkmark").foregroundStyle(W1.accent)
                } else {
                    Text("\(s.waiting)").font(W1.mono(12, .bold))
                }
            }
            .keylineTint(W1.accent)
            .widgetURL(snap.deepLink(src: "organizer_island"))
        }
    }
}
