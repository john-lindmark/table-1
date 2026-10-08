import AuthenticationServices
import GoogleSignIn
import Supabase
import SwiftUI

@main
struct Table1App: App {
    @State private var session = SessionModel()
    @Environment(\.scenePhase) private var phase

    init() {
        // Also runs when iOS wakes the app in the background for a pushed Live Activity.
        LiveActivityController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .preferredColorScheme(.dark)
                // Owner's QR from the camera (universal link) or a shared link; Google's sign-in return.
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    // Widget / Live Activity taps: table1://event/<id>
                    if url.scheme == "table1" {
                        if url.host == "event", let id = url.pathComponents.dropFirst().first { session.pendingEvent = id }
                        return
                    }
                    if let link = JoinLink(url.absoluteString) { session.pendingJoin = link }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let link = JoinLink(activity.webpageURL?.absoluteString) { session.pendingJoin = link }
                }
                .task { await session.watchAuth() }
                // Apple ID access can be withdrawn from Settings at any time.
                .onChange(of: phase) { _, now in
                    if now == .active {
                        Task { await SignIn.checkAppleCredential() }
                        Task { await LiveActivityController.shared.refresh() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                    Task { await SignIn.checkAppleCredential() }
                }
        }
    }
}

/// Signed in or not, plus a QR join that arrived before sign-in finished.
@MainActor
@Observable
final class SessionModel {
    enum State { case loading, signedOut, signedIn }
    var state: State = .loading
    var pendingJoin: JoinLink?
    /// An event opened from a widget or the Live Activity.
    var pendingEvent: String?

    func watchAuth() async {
        for await (event, session) in supabase.auth.authStateChanges {
            state = session == nil ? .signedOut : .signedIn
            if session != nil, event == .initialSession || event == .signedIn {
                Task { await LiveActivityController.shared.didSignIn() }
            }
        }
    }
}

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        switch session.state {
        case .loading: T1Screen { Bar(title: "Table 1") }
        case .signedOut: SignInView()
        case .signedIn: SignedInView()
        }
    }
}

enum Route: Hashable {
    case event(String)
    case create
    case nearby
    case profile
    case scan
}

struct SignedInView: View {
    @Environment(SessionModel.self) private var session
    @State private var path: [Route] = []
    @State private var joinError: String?

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .event(let id): EventView(eventId: id)
                    case .create: CreateEventView(path: $path)
                    case .nearby: NearbyView(path: $path)
                    case .profile: ProfileView()
                    case .scan: ScanView { link in join(link) }
                    }
                }
        }
        .tint(T1.accent)
        .task(id: session.pendingEvent) {
            if let id = session.pendingEvent {
                session.pendingEvent = nil
                path = [.event(id)]
            }
        }
        .task(id: session.pendingJoin) {
            if let link = session.pendingJoin {
                session.pendingJoin = nil
                join(link)
            }
        }
        .alert("Couldn't join", isPresented: Binding(get: { joinError != nil }, set: { if !$0 { joinError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(joinError ?? "") }
    }

    private func join(_ link: JoinLink) {
        Task {
            do {
                let seat = try await Repo.joinByQr(link)
                path = [.event(seat.eventId)]
            } catch {
                joinError = error.localizedDescription
            }
        }
    }
}
