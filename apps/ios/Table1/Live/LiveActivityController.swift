import ActivityKit
import Supabase
import UIKit
import WidgetKit

/// Owns the player's Live Activity on this device.
///
/// Battery and performance:
/// - The server starts and updates the activity by push (push-to-start on pairing, updates only when
///   the match, clock or round changes). The countdown is drawn by the system from `endsAt`, so the
///   app does no work while the activity is on screen.
/// - The app only talks to the server when it is already running for another reason (foreground,
///   an event screen refresh, a result button) and at most once every 20 s.
/// - Push tokens are registered once per token, not per launch.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var started = false
    private var observed = Set<String>()
    private var registered = Set<String>()
    private var startToken: String?
    private var lastRefresh = Date.distantPast
    private var inFlight: Task<Void, Never>?
    /// Activities this app started itself (telemetry tells them apart from push-to-start).
    private var requestedHere = Set<String>()

    private let env: String = {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }()
    private var deviceId: String { UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device" }
    /// Reads the stored session (also right after a background launch, before any UI exists).
    private func isSignedIn() async -> Bool { (try? await supabase.auth.session) != nil }

    /// Call once at launch. Also runs when iOS wakes the app in the background after a push-to-start.
    func start() {
        guard !started else { return }
        started = true
        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<PlayerActivityAttributes>.pushToStartTokenUpdates {
                    startToken = data.hex
                    await registerStartToken()
                }
            }
        }
        Task {
            for await activity in Activity<PlayerActivityAttributes>.activityUpdates {
                // New since launch; the app's own fallback start is counted where it requests one.
                if !observed.contains(activity.id), !requestedHere.contains(activity.id) {
                    Telemetry.capture("live_activity_started", ["via": "push"])
                }
                observe(activity)
            }
        }
        Activity<PlayerActivityAttributes>.activities.forEach(observe)
    }

    func didSignIn() async {
        registered.removeAll()
        await registerStartToken()
        for activity in Activity<PlayerActivityAttributes>.activities {
            if let token = activity.pushToken?.hex { await registerUpdate(token, activity) }
        }
        await refresh(force: true)
    }

    func didSignOut() async {
        for activity in Activity<PlayerActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        registered.removeAll()
        LiveStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Fetches the authoritative state and reconciles the activity and widgets with it.
    /// Coalesced: concurrent callers share one request; non-forced calls run at most every 20 s.
    func refresh(force: Bool = false) async {
        guard await isSignedIn() else { return }
        if let inFlight { return await inFlight.value }
        guard force || Date().timeIntervalSince(lastRefresh) > 20 else { return }
        lastRefresh = Date()
        let task = Task { await self.reconcile() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    // MARK: - private

    private func reconcile() async {
        guard let snaps = try? await LiveAPI.fetch() else { return }
        if LiveStore.save(snaps) { WidgetCenter.shared.reloadAllTimelines() }

        let activities = Activity<PlayerActivityAttributes>.activities
        for snap in snaps {
            let live = snap.state.phase == "playing" || snap.state.phase == "bye" || snap.state.phase == "waiting"
            let existing = activities.filter { $0.attributes.participantId == snap.participantId }
            if let first = existing.first {
                // Duplicates can only come from a race between push-to-start and a local start.
                for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
                if !live {
                    await first.end(ActivityContent(state: snap.state, staleDate: nil), dismissalPolicy: .after(.now + 30 * 60))
                } else if first.content.state != snap.state {
                    await first.update(ActivityContent(state: snap.state, staleDate: snap.state.staleDate))
                }
            } else if snap.state.isPlaying || snap.state.phase == "bye",
                      ActivityAuthorizationInfo().areActivitiesEnabled {
                // Fallback when push-to-start didn't run (older iOS, or the event was joined mid-round).
                if let started = try? Activity.request(
                    attributes: snap.attributes,
                    content: ActivityContent(state: snap.state, staleDate: snap.state.staleDate),
                    pushType: .token
                ) {
                    requestedHere.insert(started.id)
                    Telemetry.capture("live_activity_started", ["via": "app"])
                }
            }
        }
        // Seats that are no longer live on the server.
        let liveSeats = Set(snaps.map(\.participantId))
        for activity in activities where !liveSeats.contains(activity.attributes.participantId) {
            await activity.end(nil, dismissalPolicy: .after(.now + 15 * 60))
        }
    }

    private func observe(_ activity: Activity<PlayerActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates { await registerUpdate(data.hex, activity) }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                // "dismissed": the player swiped it away; "ended": the match or event finished.
                Telemetry.capture("live_activity_ended", ["reason": state == .dismissed ? "dismissed" : "ended"])
                if let token = activity.pushToken?.hex {
                    _ = try? await supabase.rpc("unregister_live_activity_token", params: ["p_token": AnyJSON.string(token)]).execute()
                    registered.remove(token)
                }
                observed.remove(activity.id)
                break
            }
        }
    }

    private func registerStartToken() async {
        guard let token = startToken, !registered.contains(token), await isSignedIn() else { return }
        do {
            try await supabase.rpc("register_live_activity_token", params: [
                "p_kind": AnyJSON.string("start"), "p_token": .string(token), "p_env": .string(env),
                "p_device_id": .string(deviceId),
            ]).execute()
            registered.insert(token)
        } catch {}
    }

    private func registerUpdate(_ token: String, _ activity: Activity<PlayerActivityAttributes>) async {
        guard !registered.contains(token), await isSignedIn() else { return }
        do {
            try await supabase.rpc("register_live_activity_token", params: [
                "p_kind": AnyJSON.string("update"), "p_token": .string(token), "p_env": .string(env),
                "p_device_id": .string(deviceId), "p_event_id": .string(activity.attributes.eventId),
                "p_activity_id": .string(activity.id),
            ]).execute()
            registered.insert(token)
        } catch {}
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
