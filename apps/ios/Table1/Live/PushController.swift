import Supabase
import UIKit
import UserNotifications

/// Alert pushes (invitations, new events from organizers you play with, pairings, results). Asks for
/// permission on the permissions step after sign-in (PermissionsView), registers this phone's APNs token with `register_device`, and hands a tapped
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

    /// Signed in: register when allowed. Never prompts; skipping the permissions step means no prompt later either.
    func didSignIn() async {
        registeredFor = nil
        if await PermissionsStep.notifications() == .on { UIApplication.shared.registerForRemoteNotifications() }
        await register()
    }

    /// The system prompt (permissions step; iOS shows it only the first time), then register.
    func ask() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        Telemetry.capture("push_permission", ["granted": granted])
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        await register()
        return granted
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

    /// A tapped push with no event (friends, moderation, bugs): opens Account → Friends, From Table 1, Review or Bugs.
    private var pendingSocial: SocialRoute?
    var openSocial: ((SocialRoute) -> Void)? {
        didSet { if let r = pendingSocial, let openSocial { pendingSocial = nil; openSocial(r) } }
    }

    /// A tapped Collection push (a ranking of your cube): opens that stack on the Collection tab.
    private var pendingLibrary: [LibraryRoute]?
    var openLibrary: (([LibraryRoute]) -> Void)? {
        didSet { if let p = pendingLibrary, let openLibrary { pendingLibrary = nil; openLibrary(p) } }
    }

    /// A tapped "New in Insights" push: the Insights tab on that format or set (or the set's Rankings).
    private var pendingInsights: InsightsPush?
    var openInsights: ((InsightsPush) -> Void)? {
        didSet { if let p = pendingInsights, let openInsights { pendingInsights = nil; openInsights(p) } }
    }

    /// The deck finder job the Find a deck screen is showing: its own `deck.found` push needs no banner.
    var watchingDeckJob: String?

    /// Whether a push arriving in the foreground is already on screen, so no banner is shown.
    func quiet(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["kind"] as? String == "deck.found", let job = userInfo["job_id"] as? String else { return false }
        return job == watchingDeckJob
    }

    func didTap(_ userInfo: [AnyHashable: Any]) {
        if let p = PushRoutes.insights(userInfo) {
            Telemetry.capture("push_opened", ["kind": "insights.new", "what": p.what])
            if let openInsights { openInsights(p) } else { pendingInsights = p }
            return
        }
        if let path = PushRoutes.library(userInfo) {
            Telemetry.capture("push_opened", ["kind": userInfo["kind"] as? String ?? "unknown"])
            if let openLibrary { openLibrary(path) } else { pendingLibrary = path }
            return
        }
        if let route = PushRoutes.route(userInfo) {
            Telemetry.capture("push_opened", ["kind": userInfo["kind"] as? String ?? "unknown"])
            if let openSocial { openSocial(route) } else { pendingSocial = route }
            return
        }
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
