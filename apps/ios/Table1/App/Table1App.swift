import AuthenticationServices
import GoogleSignIn
import Supabase
import SwiftUI
import UserNotifications

@main
struct Table1App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionModel()
    @Environment(\.scenePhase) private var phase

    init() {
        Telemetry.start()
        // Also runs when iOS wakes the app in the background for a pushed Live Activity.
        LiveActivityController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG
                // Design QA: `-T1Tracker` opens the local life tracker without signing in.
                .overlay {
                    if ProcessInfo.processInfo.arguments.contains("-T1Tracker") { LifeTrackerView(matchId: nil) {} }
                }
                // `-T1LibraryDemo` opens the Library on 2,000 demo cards, five Modern decks and a Vintage cube.
                .overlay {
                    if ProcessInfo.processInfo.arguments.contains("-T1LibraryDemo") { LibraryDemoRoot() }
                }
                // `-T1EventsDemo [create|setup|seating]`: the create form, Setup and the seating table on sample data.
                .overlay {
                    if ProcessInfo.processInfo.arguments.contains("-T1EventsDemo") { EventsDemoRoot() }
                }
                // `-T1RotoDemo [grid|cube|picks|list|schedule]`: a roto draft (8 players, the demo Vintage cube).
                .overlay {
                    if ProcessInfo.processInfo.arguments.contains("-T1RotoDemo") { RotoDemoRoot() }
                }
                #endif
                // App-drawn menus and panels sit above everything (tabs, life tracker); only alerts are native.
                .overlay { T1OverlayHost() }
                .environment(session)
                .preferredColorScheme(.dark)
                // Owner's QR from the camera (universal link) or a shared link; Google's sign-in return.
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    // Widget / Live Activity taps: table1://event/<id>
                    if url.scheme == "table1" {
                        Telemetry.surfaceOpened(url)
                        if url.host == "event", let id = url.pathComponents.dropFirst().first { session.pendingEvent = id }
                        return
                    }
                    session.openWebLink(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { session.openWebLink(url) }
                }
                .task { await session.watchAuth() }
                .task {
                    PushController.shared.openEvent = { session.pendingEvent = $0 }
                    PushController.shared.openSocial = { session.pendingSocial = $0 }
                    PushController.shared.openLibrary = { session.pendingLibrary = $0 }
                }
                // Apple ID access can be withdrawn from Settings at any time.
                .onChange(of: phase) { before, now in
                    if now == .active {
                        // Coming back from the background re-arms "open my live match".
                        if before == .background { session.autoOpenArmed = true }
                        session.foregrounds += 1
                        Task { await session.loadSettings() }
                        Task { await SignIn.checkAppleCredential() }
                        Task { await LiveActivityController.shared.refresh() }
                        Telemetry.syncSurfaces()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                    Task { await SignIn.checkAppleCredential() }
                }
        }
    }
}

/// Notification delegate: without one iOS reports taps to nobody, so PostHog can't see push opens
/// (`$push_notification_opened`, captured by the SDK) and foreground pushes would be silent.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushController.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushController.shared.didRegister(deviceToken)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { PushController.shared.didTap(info) }
    }
}

/// Signed in or not, plus a QR join that arrived before sign-in finished.
@MainActor
@Observable
final class SessionModel {
    enum State { case loading, signedOut, signedIn }
    var state: State = .loading
    /// A new email account: the name step comes before the app (SignIn.needsName).
    var needsName = false
    var pendingJoin: JoinLink?
    /// An event opened from a widget or the Live Activity.
    var pendingEvent: String?
    /// A tapped friend push: Account → Friends.
    var pendingSocial: SocialRoute?
    /// A tapped Collection push (someone ranking your cube): the Collection tab's stack.
    var pendingLibrary: [LibraryRoute]?
    /// While a round you're playing is running, the app opens straight into it — once per launch or
    /// return from the background. Cleared as soon as it fires.
    var autoOpenArmed = true
    /// Bumped each time the app comes to the foreground; screens reload on it.
    var foregrounds = 0
    /// Where this player keeps score: "elsewhere" (default; results lead) or "tracker" (life tracker leads).
    /// Cached on the device so auto-open knows it before the first request returns.
    private(set) var trackerMode: TrackerMode = TrackerMode(rawValue: UserDefaults.standard.string(forKey: TrackerMode.cacheKey) ?? "") ?? .elsewhere
    /// The life tracker, shown full screen over the tabs. Nil match = local session.
    var tracker: TrackerLaunch?
    /// Why the sign-in email's link didn't sign in (used or expired); shown on the sign-in screen.
    var emailLinkError: String?

    /// https://table-1.site links: the sign-in email's button, or the owner's join QR.
    func openWebLink(_ url: URL) {
        if url.path.hasPrefix("/auth/confirm") {
            emailLinkError = nil
            Task {
                do { _ = try await SignIn.handleEmailLink(url) } catch {
                    Telemetry.capture("sign_in_failed", ["method": "email_link", "reason": "error"])
                    emailLinkError = "That sign-in link has expired or was already used. Send a new one."
                }
            }
            return
        }
        if let link = JoinLink(url.absoluteString) { pendingJoin = link }
    }

    func watchAuth() async {
        for await (event, session) in supabase.auth.authStateChanges {
            state = session == nil ? .signedOut : .signedIn
            needsName = SignIn.needsName(session?.user)
            if let id = session?.user.id.uuidString.lowercased() { Telemetry.identify(id) }
            if session != nil, event == .initialSession || event == .signedIn {
                Task { await LiveActivityController.shared.didSignIn() }
                Task { await PushController.shared.didSignIn() }
                Task { await loadSettings() }
            }
        }
    }

    /// `source`: where it was opened from (home_life, organizer_match, event, …), for telemetry.
    func openTracker(matchId: String?, source: String = "event") {
        T1Overlays.shared.dismissAll()
        tracker = TrackerLaunch(matchId: matchId)
        Telemetry.capture("life_tracker_opened", ["mode": matchId == nil ? "local" : "match", "source": source])
    }

    func loadSettings() async {
        guard let raw = await Repo.trackerMode(), let mode = TrackerMode(rawValue: raw) else { return }
        cache(mode)
    }

    /// Optimistic; reverts if the server refuses.
    func setTrackerMode(_ mode: TrackerMode) async throws {
        let before = trackerMode
        cache(mode)
        do {
            try await Repo.setTrackerMode(mode.rawValue)
        } catch {
            cache(before)
            throw error
        }
    }

    private func cache(_ mode: TrackerMode) {
        trackerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: TrackerMode.cacheKey)
    }
}

enum TrackerMode: String, CaseIterable {
    case tracker, elsewhere
    static let cacheKey = "settings.trackerMode"
    var label: String { self == .tracker ? "Life tracker" : "Elsewhere" }
}

struct TrackerLaunch: Identifiable, Hashable {
    let id = UUID()
    let matchId: String?
}

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        switch session.state {
        case .loading: T1Screen { Bar(title: "Table 1") }
        case .signedOut: SignInView().screen("sign_in")
        case .signedIn:
            if session.needsName { NameView().screen("sign_in_name") } else { SignedInView() }
        }
    }
}

enum Route: Hashable {
    case event(String)
    case create
    case nearby
    case scan
    case addPlayers(String)
    case redraft(String)
    case deckPhotos(String)
}

enum Tab: Hashable { case events, collection, account }

/// Three tabs in the app's own bar: Events (what's happening, and getting into it), Collection (the
/// Library) and Account. Each tab keeps its own NavigationStack alive (switched by opacity),
/// so going back to a tab finds it where it was.
struct SignedInView: View {
    @Environment(SessionModel.self) private var session
    @State private var tab: Tab = .events
    @State private var path: [Route] = []
    @State private var libraryPath: [LibraryRoute] = []
    /// Account → Friends, profiles, Sharing (the Library's routes, so a profile's cards and trades open in place).
    @State private var accountPath: [LibraryRoute] = []
    @State private var joinError: String?
    @State private var keyboardUp = false

    private let tabs: [T1TabItem<Tab>] = [
        T1TabItem(id: .events, label: "Events", tiles: T1TileGlyph.events),
        T1TabItem(id: .collection, label: "Collection", tiles: T1TileGlyph.collection),
        T1TabItem(id: .account, label: "Account", tiles: T1TileGlyph.account),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                NavigationStack(path: $path) {
                    EventsHomeView(path: $path, isFront: tab == .events)
                        .screen("events_home", when: tab == .events)
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .event(let id): EventView(eventId: id, path: $path).screen("event")
                            case .create: CreateEventView(path: $path).screen("create_event")
                            case .nearby: NearbyView(path: $path).screen("nearby")
                            case .scan: ScanView { link in join(link, via: "qr") }.screen("scan_qr")
                            case .addPlayers(let id): AddPlayersView(eventId: id).screen("add_players")
                            case .redraft(let id): RedraftView(eventId: id).screen("redraft")
                            case .deckPhotos(let id): DeckPhotosView(eventId: id).screen("deck_photos")
                            }
                        }
                }
                .opacity(tab == .events ? 1 : 0)
                .allowsHitTesting(tab == .events)
                .accessibilityHidden(tab != .events)

                NavigationStack(path: $libraryPath) {
                    LibraryHomeView(path: $libraryPath)
                        .screen("library_home", when: tab == .collection)
                        .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0, path: $libraryPath) }
                }
                .opacity(tab == .collection ? 1 : 0)
                .allowsHitTesting(tab == .collection)
                .accessibilityHidden(tab != .collection)

                NavigationStack(path: $accountPath) {
                    AccountView(path: $accountPath)
                        .screen("account", when: tab == .account)
                        .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0, path: $accountPath) }
                }
                    .opacity(tab == .account ? 1 : 0)
                    .allowsHitTesting(tab == .account)
                    .accessibilityHidden(tab != .account)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Only on a tab's main view (anything pushed above it hides the bar), and hidden while typing
            // so it doesn't ride up on the keyboard.
            if !keyboardUp && atTabRoot {
                T1TabBar(items: tabs, selection: tab) { select($0) }
            }
        }
        .background(T1.bg.ignoresSafeArea())
        // The collection mirror syncs on open and on each return; the catalog pack is checked once a day.
        .task {
            if let id = Repo.userId {
                await CollectionStore.shared.start(userId: id)
                await ListsStore.shared.start(userId: id)
                await BindersStore.shared.start(userId: id)
                await HeroesStore.shared.start(userId: id)
                await FriendsStore.shared.load()
            }
            CatalogStore.shared.load(userInitiated: false)
        }
        .onChange(of: session.foregrounds) {
            Task { await CollectionStore.shared.sync() }
            Task { await ListsStore.shared.sync() }
            Task { await HeroesStore.shared.refresh() }
            CatalogStore.shared.load(userInitiated: tab == .collection)
        }
        .onDisappear {
            CollectionStore.shared.stop()
            ListsStore.shared.stop()
            TradesStore.shared.stop()
            BindersStore.shared.stop()
            HeroesStore.shared.stop()
            FriendsStore.shared.stop()
            ModerationStore.shared.stop()
            BugsStore.shared.stop()
        }
        // The life tracker covers the tabs (no tab bar) until it's closed.
        .overlay {
            if let launch = session.tracker {
                LifeTrackerView(matchId: launch.matchId) {
                    T1Overlays.shared.dismissAll()
                    session.tracker = nil
                }
                    .screen("life_tracker")
                    .id(launch.id)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy(duration: 0.25), value: session.tracker?.id)
        // A field focused on a hidden tab mustn't keep the keyboard up over the next one (a tapped push switches tabs).
        .onChange(of: tab) { Keyboard.dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .task(id: session.pendingEvent) {
            if let id = session.pendingEvent {
                session.pendingEvent = nil
                session.autoOpenArmed = false
                session.tracker = nil
                tab = .events
                path = [.event(id)]
            }
        }
        .task(id: session.pendingLibrary) {
            if let p = session.pendingLibrary {
                session.pendingLibrary = nil
                tab = .collection
                libraryPath = p
            }
        }
        .task(id: session.pendingSocial) {
            if let route = session.pendingSocial {
                session.pendingSocial = nil
                tab = .account
                accountPath = PushRoutes.path(route)
            }
        }
        .task(id: session.pendingJoin) {
            if let link = session.pendingJoin {
                session.pendingJoin = nil
                join(link, via: "link")
            }
        }
        .alert("Couldn't join", isPresented: Binding(get: { joinError != nil }, set: { if !$0 { joinError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(joinError ?? "") }
    }

    private var atTabRoot: Bool {
        switch tab {
        case .events: path.isEmpty
        case .collection: libraryPath.isEmpty
        case .account: accountPath.isEmpty
        }
    }

    private func select(_ next: Tab) {
        if next == .collection {
            Task { await CollectionStore.shared.sync() }
            Task { await ListsStore.shared.sync() }
            CatalogStore.shared.load(userInitiated: true)
        }
        // Hidden tabs stay alive, so a tab root's onAppear doesn't fire on a switch.
        if next != tab {
            switch next {
            case .events: if path.isEmpty { Telemetry.screen("events_home") }
            case .collection: if libraryPath.isEmpty { Telemetry.screen("library_home") }
            case .account: if accountPath.isEmpty { Telemetry.screen("account") }
            }
        }
        tab = next
    }

    private func join(_ link: JoinLink, via: String) {
        Task {
            do {
                let seat = try await Repo.joinByQr(link, via: via)
                session.autoOpenArmed = false
                tab = .events
                path = [.event(seat.eventId)]
            } catch {
                joinError = error.localizedDescription
            }
        }
    }
}
