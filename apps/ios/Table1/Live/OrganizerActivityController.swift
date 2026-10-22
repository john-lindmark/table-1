import ActivityKit
import Supabase
import UIKit

/// Owns the organizer's Live Activity on this device (contract/widgets-2026-10-22.md). Same battery rules as the
/// player's (LiveActivityController): the server starts and updates it by push; the app reconciles only when it is
/// already awake, using the same `state` request. Tokens are their own kinds: org_start and org_update.
@MainActor
final class OrganizerActivityController {
    static let shared = OrganizerActivityController()

    private var started = false
    private var observed = Set<String>()
    private var registered = Set<String>()
    private var startToken: String?
    private var requestedHere = Set<String>()

    private let env: String = {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }()
    private var deviceId: String { UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device" }
    private func isSignedIn() async -> Bool { (try? await supabase.auth.session) != nil }

    func start() {
        guard !started else { return }
        started = true
        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<OrganizerActivityAttributes>.pushToStartTokenUpdates {
                    startToken = data.map { String(format: "%02x", $0) }.joined()
                    await registerStartToken()
                }
            }
        }
        Task {
            for await activity in Activity<OrganizerActivityAttributes>.activityUpdates {
                if !observed.contains(activity.id), !requestedHere.contains(activity.id) {
                    Telemetry.capture("live_activity_started", ["via": "push", "type": "organizer"])
                }
                observe(activity)
            }
        }
        Activity<OrganizerActivityAttributes>.activities.forEach(observe)
    }

    func didSignIn() async {
        registered.removeAll()
        await registerStartToken()
        for activity in Activity<OrganizerActivityAttributes>.activities {
            if let token = activity.pushToken?.hexString { await registerUpdate(token, activity) }
        }
    }

    func didSignOut() async {
        for activity in Activity<OrganizerActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        registered.removeAll()
    }

    /// Brings this device's organizer activities in line with the server's answer.
    func reconcile(_ snaps: [OrganizerSnapshot]) async {
        let activities = Activity<OrganizerActivityAttributes>.activities
        for snap in snaps {
            let keep = snap.state.isLive || snap.state.phase == "between"
            let existing = activities.filter { $0.attributes.eventId == snap.eventId }
            if let first = existing.first {
                for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
                if !keep {
                    await first.end(ActivityContent(state: snap.state, staleDate: nil), dismissalPolicy: .after(.now + 30 * 60))
                } else if first.content.state != snap.state {
                    await first.update(ActivityContent(state: snap.state, staleDate: snap.state.staleDate))
                }
            } else if snap.state.isLive, ActivityAuthorizationInfo().areActivitiesEnabled {
                // Fallback when push-to-start didn't run (older iOS, or the round was paired from another device).
                if let started = try? Activity.request(
                    attributes: snap.attributes,
                    content: ActivityContent(state: snap.state, staleDate: snap.state.staleDate),
                    pushType: .token
                ) {
                    requestedHere.insert(started.id)
                    Telemetry.capture("live_activity_started", ["via": "app", "type": "organizer"])
                }
            }
        }
        let running = Set(snaps.map(\.eventId))
        for activity in activities where !running.contains(activity.attributes.eventId) {
            await activity.end(nil, dismissalPolicy: .after(.now + 15 * 60))
        }
    }

    private func observe(_ activity: Activity<OrganizerActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates { await registerUpdate(data.hexString, activity) }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                Telemetry.capture("live_activity_ended", ["reason": state == .dismissed ? "dismissed" : "ended", "type": "organizer"])
                if let token = activity.pushToken?.hexString {
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
                "p_kind": AnyJSON.string("org_start"), "p_token": .string(token), "p_env": .string(env),
                "p_device_id": .string(deviceId),
            ]).execute()
            registered.insert(token)
        } catch {}
    }

    private func registerUpdate(_ token: String, _ activity: Activity<OrganizerActivityAttributes>) async {
        guard !registered.contains(token), await isSignedIn() else { return }
        do {
            try await supabase.rpc("register_live_activity_token", params: [
                "p_kind": AnyJSON.string("org_update"), "p_token": .string(token), "p_env": .string(env),
                "p_device_id": .string(deviceId), "p_event_id": .string(activity.attributes.eventId),
                "p_activity_id": .string(activity.id),
            ]).execute()
            registered.insert(token)
        } catch {}
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
