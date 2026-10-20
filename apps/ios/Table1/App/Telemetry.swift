import ActivityKit
import Foundation
import PostHog
import Sentry
import SwiftUI
import WidgetKit

/// Product analytics (PostHog) and crash reporting (Sentry), per contract/telemetry-2026-10-15.md.
/// Properties are counts, enums and booleans only: never names, free text, join codes or row ids.
/// Off when the keys in Info.plist are empty, in Debug unless launched with `-T1Telemetry`, and when
/// the person turns off "Share usage and crash data" in Account.
enum Telemetry {
    private static let optOutKey = "telemetry.optedOut"
    private static var postHogKey: String { Bundle.main.object(forInfoDictionaryKey: "T1PostHogKey") as? String ?? "" }
    private static var postHogHost: String { Bundle.main.object(forInfoDictionaryKey: "T1PostHogHost") as? String ?? "" }
    private static var sentryDSN: String { Bundle.main.object(forInfoDictionaryKey: "T1SentryDSN") as? String ?? "" }
    private static var postHogOn = false
    private static var sentryOn = false

    static var sharing: Bool { !UserDefaults.standard.bool(forKey: optOutKey) }

    private static var allowedInBuild: Bool {
        allowed(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
    }

    /// Never while XCTest hosts the app: a unit-test run on a phone sent a slow test to Sentry as a fatal
    /// app hang (TABLE-1-IOS-1, 2026-10-16).
    static func allowed(arguments: [String], environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil { return false }
        #if DEBUG
        return arguments.contains("-T1Telemetry")
        #else
        return true
        #endif
    }

    private static var environment: String {
        #if DEBUG
        return "debug"
        #else
        return BuildFlavor.isTest ? "testflight" : "production"
        #endif
    }

    private static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// Called once at launch, before anything else can crash.
    static func start() {
        guard allowedInBuild, sharing else { return }
        startSentry()
        startPostHog()
        // TestFlight vs App Store is only known after StoreKit answers; re-tag once it does.
        Task {
            await BuildFlavor.resolve()
            if postHogOn { PostHogSDK.shared.register(["environment": environment]) }
            if sentryOn { SentrySDK.configureScope { $0.setEnvironment(environment) } }
        }
    }

    private static func startSentry() {
        guard !sentryDSN.isEmpty else { return }
        let env = environment
        SentrySDK.start { o in
            o.dsn = sentryDSN
            o.environment = env
            o.releaseName = "site.table1.events@\(version)+\(build)"
            o.sendDefaultPii = false
            #if DEBUG
            o.debug = true
            #endif
            o.tracesSampleRate = env == "production" ? 0.1 : 1.0
            o.appHangTimeoutInterval = 2
            // 4xx is how RLS and validation answer; only server failures are bugs.
            o.failedRequestStatusCodes = [HttpStatusCodeRange(min: 500, max: 599)]
            // PostgREST filters put row ids in query strings.
            o.beforeBreadcrumb = { crumb in
                if let url = crumb.data?["url"] as? String { crumb.data?["url"] = stripQuery(url) }
                return crumb
            }
            o.beforeSend = { event in
                if let url = event.request?.url { event.request?.url = stripQuery(url) }
                event.request?.queryString = nil
                return event
            }
        }
        sentryOn = true
    }

    private static func startPostHog() {
        guard !postHogKey.isEmpty else { return }
        let config = PostHogConfig(apiKey: postHogKey, host: postHogHost.isEmpty ? "https://us.i.posthog.com" : postHogHost)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false      // named by hand with .screen(_:)
        config.captureElementInteractions = false
        config.sessionReplay = false
        // Rage-click capture records the tapped element's text, which can be a player's name.
        config.rageClickConfig.enabled = false
        config.captureAutocaptureElementText = false
        config.surveys = false
        // Push stays on: `$push_notification_opened` (needs the delegate in AppDelegate) and push
        // subscriptions. For pushes we send, PostHog records the open without the title or body.
        config.personProfiles = .identifiedOnly
        #if DEBUG
        config.debug = true   // logs each capture and flush to the console
        #endif
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.optIn()   // clears an earlier opt-out; start() only runs while sharing is on
        PostHogSDK.shared.register(["platform": "ios", "app_version": version, "build": build, "environment": environment])
        postHogOn = true
        Task { @MainActor in syncSurfaces() }
    }

    // MARK: identity

    /// The Supabase user id only: no email or name, in either tool.
    static func identify(_ userId: String) {
        if postHogOn {
            PostHogSDK.shared.identify(userId, userProperties: ["platform": "ios"], userPropertiesSetOnce: ["first_seen_app_version": version])
        }
        if sentryOn { SentrySDK.setUser(User(userId: userId)) }
    }

    static func reset() {
        if postHogOn { PostHogSDK.shared.reset() }
        if sentryOn { SentrySDK.setUser(nil) }
    }

    // MARK: events

    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        guard postHogOn else { return }
        PostHogSDK.shared.capture(event, properties: properties.isEmpty ? nil : properties)
    }

    /// Runs a server call and records `event` only once the server has accepted it.
    @discardableResult
    static func after<T>(_ event: String, _ properties: [String: Any] = [:], _ work: () async throws -> T) async rethrows -> T {
        let value = try await work()
        capture(event, properties)
        return value
    }

    static func screen(_ name: String) {
        guard postHogOn else { return }
        PostHogSDK.shared.screen(name)
    }

    /// A failure the app recovered from but that shouldn't happen.
    static func error(_ error: Error, _ area: String) {
        guard sentryOn else { return }
        SentrySDK.capture(error: error) { $0.setTag(value: area, key: "area") }
    }

    // MARK: Live Activities and widgets

    private static let widgetsKey = "telemetry.widgets"

    /// Super properties for the system surfaces (Live Activities allowed, widgets on the Home/Lock
    /// Screen), plus `widgets_changed` when the set of widgets differs from last time. Run at launch
    /// and on each return to the foreground.
    @MainActor
    static func syncSurfaces() {
        guard postHogOn else { return }
        PostHogSDK.shared.register(["live_activities_enabled": ActivityAuthorizationInfo().areActivitiesEnabled])
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success(let widgets) = result else { return }
            let families = widgets.map { "\($0.family)" }.sorted()
            PostHogSDK.shared.register(["widgets": widgets.count])
            let key = families.joined(separator: ",")
            guard key != UserDefaults.standard.string(forKey: widgetsKey) else { return }
            let first = UserDefaults.standard.string(forKey: widgetsKey) == nil
            UserDefaults.standard.set(key, forKey: widgetsKey)
            if !(first && widgets.isEmpty) { capture("widgets_changed", ["count": widgets.count, "families": families]) }
        }
    }

    /// A tap on a widget or the Live Activity: the extension tags its link with `src`.
    static func surfaceOpened(_ url: URL) {
        guard let src = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "src" })?.value
        else { return }
        capture("surface_opened", ["source": src, "target": url.host() ?? ""])
    }

    // MARK: opt-out

    static func setSharing(_ on: Bool) {
        guard on != sharing else { return }
        if on {
            UserDefaults.standard.set(false, forKey: optOutKey)
            start()
            if let id = Repo.userId { identify(id) }
        } else {
            capture("analytics_opted_out")
            if postHogOn { PostHogSDK.shared.flush(); PostHogSDK.shared.optOut() }
            if sentryOn { SentrySDK.close() }
            postHogOn = false
            sentryOn = false
            UserDefaults.standard.set(true, forKey: optOutKey)
        }
    }

    private static func stripQuery(_ url: String) -> String {
        url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
    }
}

extension View {
    /// Records a `$screen` view (names in contract/telemetry-2026-10-15.md).
    func screen(_ name: String) -> some View { onAppear { Telemetry.screen(name) } }

    /// For views that stay alive while hidden (tab roots): counts only while `active`.
    func screen(_ name: String, when active: Bool) -> some View { onAppear { if active { Telemetry.screen(name) } } }
}
