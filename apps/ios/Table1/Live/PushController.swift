import Supabase
import UIKit
import UserNotifications

/// Alert pushes (invitations, new events from organizers you play with, pairings, results). Asks for
/// permission once signed in, registers this phone's APNs token with `register_device`, and hands a tapped
/// alert's event to the app. The server side is the notify-worker edge function.
@MainActor
final class PushController {
    static let shared = PushController()

    private var token: String?
    private var registeredFor: String?
    /// A tapped alert's event, held until the app is ready to open it (a cold launch from the alert).
    private var pendingEvent: String?
    var openEvent: ((String) -> Void)? {
        didSet { if let id = pendingEvent, let openEvent { pendingEvent = nil; openEvent(id) } }
    }

    private let env: String = {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }()

    /// Launch: re-registers when permission was already given (tokens can change between launches).
    func start() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Signed in: ask once (iOS shows the prompt only the first time), then register.
    func didSignIn() async {
        registeredFor = nil
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        Telemetry.capture("push_permission", ["granted": granted])
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        await register()
    }

    func didSignOut() async {
        guard let token else { return }
        _ = try? await supabase.rpc("unregister_device", params: ["p_push_token": AnyJSON.string(token)]).execute()
        registeredFor = nil
    }

    func didRegister(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await register() }
    }

    func didTap(_ userInfo: [AnyHashable: Any]) {
        guard let id = userInfo["event_id"] as? String else { return }
        Telemetry.capture("push_opened", ["kind": userInfo["kind"] as? String ?? "unknown"])
        if let openEvent { openEvent(id) } else { pendingEvent = id }
    }

    private func register() async {
        guard let token, registeredFor != token, (try? await supabase.auth.session) != nil else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        do {
            try await supabase.rpc("register_device", params: [
                "p_platform": AnyJSON.string("ios"), "p_push_token": .string(token),
                "p_app_version": version.map { AnyJSON.string($0) } ?? .null, "p_env": .string(env),
            ]).execute()
            registeredFor = token
        } catch {}
    }
}
