import ActivityKit
import Foundation
import WidgetKit

/// Applies a state change everywhere the player can see it: cache, Live Activity, widgets.
/// Used by the result buttons for instant (optimistic) feedback and to settle on the server's answer.
enum LiveSync {
    /// Changes one seat locally and returns the previous state so a failed request can roll back.
    @discardableResult
    static func apply(participantId: String, _ change: (inout LiveState) -> Void) async -> LiveState? {
        var snaps = LiveStore.load()
        guard let i = snaps.firstIndex(where: { $0.participantId == participantId }) else { return nil }
        let before = snaps[i].state
        change(&snaps[i].state)
        LiveStore.save(snaps, fetched: false)
        await updateActivity(snaps[i])
        WidgetCenter.shared.reloadAllTimelines()
        return before
    }

    static func restore(participantId: String, to state: LiveState) async {
        await apply(participantId: participantId) { $0 = state }
    }

    /// Pulls the authoritative state once and pushes it to every surface.
    static func refreshFromServer() async {
        guard let snaps = try? await LiveAPI.fetch() else { return }
        let changed = LiveStore.save(snaps)
        for s in snaps { await updateActivity(s) }
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Updates the running Live Activity for this seat, if any. Only touches it when content changed.
    static func updateActivity(_ snap: LiveSnapshot) async {
        guard !T1Shared.isExtension else { return }
        for activity in Activity<PlayerActivityAttributes>.activities
        where activity.attributes.participantId == snap.participantId && activity.content.state != snap.state {
            await activity.update(ActivityContent(state: snap.state, staleDate: snap.state.staleDate))
        }
    }
}
