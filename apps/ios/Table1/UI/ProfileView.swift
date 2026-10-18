import AuthenticationServices
import SwiftUI
import UIKit

/// The Account tab: lifetime record, friends and sharing, head-to-head, settings, and the account itself.
struct AccountView: View {
    @Binding var path: [LibraryRoute]
    @Environment(SessionModel.self) private var session
    @State private var overview: AccountOverview?
    @State private var alertsOn = false
    /// Send scan corrections as matcher test cases (ScanReports). On by default.
    @AppStorage(ScanReports.key) private var scanReports = true
    @State private var sharing = Telemetry.sharing
    @State private var showAllRivals = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var demoBusy = false
    @State private var isDemoTester = false
    @State private var error: String?
    @State private var notice: String?
    @State private var avatarBusy = false

    var body: some View {
        let r = overview?.record ?? AccountOverview.Record()
        let rivals = overview?.headToHead ?? []
        T1Screen {
            Bar(title: overview?.label ?? "Account", subtitle: "Account")
            HairlineList {
                if let error { Notice(error, error: true) }
                if let notice { Notice(notice) }

                VStack(spacing: 6) {
                    avatarButton.padding(.bottom, 18)
                    LabelText("Lifetime record")
                    Text(recordText(r.matchWins, r.matchLosses, r.matchDraws))
                        .font(T1.mono(48)).tracking(4).foregroundStyle(T1.accent)
                    LabelText("\(r.matches) matches · \(r.eventsPlayed) events · games \(recordText(r.gameWins, r.gameLosses, r.gameDraws))\(r.byes > 0 ? " · \(r.byes) byes" : "")")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24).background(T1.surface)

                AccountSocialRows(path: $path)

                Section1("Head-to-head")
                if overview == nil {
                    Notice("Loading…")
                } else if rivals.isEmpty {
                    Notice("Play a match to start your head-to-head.")
                }
                ForEach(showAllRivals ? rivals : Array(rivals.prefix(8))) { rival in
                    ListRow(title: rival.name, detail: "\(rival.played) match\(rival.played == 1 ? "" : "es") · games \(rival.gameWins)-\(rival.gameLosses)",
                            avatar: AvatarView(name: rival.name, userId: rival.opponentId)) {
                        Text(recordText(rival.matchWins, rival.matchLosses, rival.matchDraws)).font(T1.mono(16))
                    }
                }
                if rivals.count > 8 {
                    Ghost(text: showAllRivals ? "Show fewer" : "Show all \(rivals.count)") { showAllRivals.toggle() }
                }

                Section1("Settings")
                Button { nameDraft = overview?.profile?.displayName ?? ""; editingName = true } label: {
                    ListRow(title: "Display name", detail: overview?.profile?.displayName ?? "–") { LabelText("Edit", color: T1.text) }
                }
                .buttonStyle(.plain)
                trackGames
                Button { toggleAlerts() } label: {
                    ListRow(title: "Nearby alerts", detail: "Get a Join / Decline alert when an event opens near you") {
                        LabelText(alertsOn ? "On" : "Off", color: alertsOn ? T1.accent : T1.muted)
                    }
                }
                .buttonStyle(.plain)
                T1Switch(title: "Improve scanning",
                         detail: "When you fix a scanned card, send the text the camera read (no photos) so we can test the scanner",
                         isOn: $scanReports)
                T1Switch(title: "Share usage and crash data",
                         detail: "Which features you use and crash reports, tied to your account id only: never names, cards or events",
                         isOn: Binding(get: { sharing }, set: { sharing = $0; Telemetry.setSharing($0) }))
                Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                    ListRow(title: "Location, notifications, Live Activities", detail: "Managed in iOS Settings") { LabelText("Open", color: T1.text) }
                }
                .buttonStyle(.plain)

                if isDemoTester {
                    Section1("Developer · testers only")
                    Notice("Sample events, opponents and results on your account. Only accounts on the tester list see them; your real record never includes them.")
                    HStack(spacing: 1) {
                        Ghost(text: demoBusy ? "Working…" : "Load / reset demo", accent: true) { demo(seed: true) }
                        Ghost(text: "Remove demo") { demo(seed: false) }
                    }
                }

                Section1("Account")
                Ghost(text: "Sign out") { Task { await SignIn.signOut() } }
                Ghost(text: deleting ? "Deleting…" : "Delete account") { if !deleting { confirmDelete = true } }
            }
        }
        .refreshable { await load() }
        .task(id: session.foregrounds) { await load() }
        .alert("Display name", isPresented: $editingName) {
            TextField("Name", text: $nameDraft)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Shown to organizers and opponents.") }
        .alert("Delete your Table 1 account?", isPresented: $confirmDelete) {
            Button("Delete account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your sign-in, name and devices are removed. Results you played stay in their events as \"Deleted player\". This can't be undone."
                 + (SignIn.isAppleUser ? " You'll confirm with Apple once more." : ""))
        }
    }

    /// Your tile; tap to take or pick a photo, or go back to initials.
    private var avatarButton: some View {
        let uid = Repo.userId
        return Button { avatarMenu() } label: {
            VStack(spacing: 8) {
                AvatarView(name: overview?.profile?.displayName ?? "", userId: uid, size: 64)
                if avatarBusy { LabelText("Saving…") }
            }
        }
        .buttonStyle(.plain)
        .disabled(avatarBusy || overview?.profile == nil)
        .accessibilityLabel("Profile photo")
    }

    @MainActor
    private func avatarMenu() {
        var items: [T1MenuItem] = []
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            items.append(T1MenuItem(title: "Take a photo") { pickAvatar(camera: true) })
        }
        items.append(T1MenuItem(title: "Choose from photos") { pickAvatar(camera: false) })
        if let uid = Repo.userId, AvatarStore.shared.path(uid) != nil {
            items.append(T1MenuItem(title: "Remove photo") { removeAvatar() })
        }
        T1Overlays.shared.showMenu("Profile photo", items)
    }

    @MainActor
    private func pickAvatar(camera: Bool) {
        T1Overlays.shared.present(full: true) {
            ImagePicker(camera: camera) { image in
                T1Overlays.shared.dismissPanel()
                guard let image else { return }
                guard let jpeg = image.avatarJPEG() else { error = "Couldn't read that photo."; return }
                avatarBusy = true
                Task { @MainActor in
                    defer { avatarBusy = false }
                    do {
                        try await Repo.setAvatar(jpeg)
                        error = nil
                        Telemetry.capture("avatar_photo_set", ["source": camera ? "camera" : "library"])
                    } catch {
                        self.error = "Couldn't save the photo: \(error.localizedDescription)"
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func removeAvatar() {
        avatarBusy = true
        Task { @MainActor in
            defer { avatarBusy = false }
            do {
                try await Repo.clearAvatar()
                error = nil
                Telemetry.capture("avatar_photo_removed")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Where this player keeps score: the life tracker opens first, or results lead (default).
    private var trackGames: some View {
        VStack(spacing: 1) {
            ListRow(title: "Track games",
                    detail: session.trackerMode == .tracker ? "Here in the app · life tracker opens first" : "Elsewhere · report results when you're done")
            T1Segmented(options: TrackerMode.allCases.map { (value: $0, label: $0.label) }, selection: Binding(
                get: { session.trackerMode },
                set: { mode in setTrackerMode(mode) }
            ))
        }
    }

    /// The Binding setter isn't main-actor isolated, so hop to the main actor explicitly here.
    private func setTrackerMode(_ mode: TrackerMode) {
        Task { @MainActor in
            do {
                try await session.setTrackerMode(mode)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        isDemoTester = await Repo.isDemoTester()
        await session.loadSettings()
        do {
            overview = try await Repo.accountOverview()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        alertsOn = await Repo.nearbyAlertsOn()
        await FriendsStore.shared.load()
        await FriendsStore.shared.loadSharing()
    }

    private func toggleAlerts() {
        let next = !alertsOn
        alertsOn = next
        Task {
            do { try await Repo.setNearbyAlerts(next) } catch { alertsOn = !next; self.error = error.localizedDescription }
        }
    }

    private func saveName() {
        Task {
            do { try await Repo.setDisplayName(nameDraft); await load() } catch { self.error = error.localizedDescription }
        }
    }

    private func demo(seed: Bool) {
        guard !demoBusy else { return }
        demoBusy = true
        Task {
            defer { demoBusy = false }
            do {
                if seed { try await Repo.seedDemo() } else { try await Repo.removeDemo() }
                notice = seed ? "Demo data loaded. The live round's clock restarts each time you reset."
                              : "Demo data removed."
                session.foregrounds += 1   // Events tab reloads too
                await LiveActivityController.shared.refresh(force: true)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func deleteAccount() {
        deleting = true
        Task {
            do {
                try await SignIn.deleteAccount()   // session ends; RootView switches to sign-in
            } catch {
                self.error = (error as? ASAuthorizationError)?.code == .canceled
                    ? nil : "Couldn't delete the account: \(error.localizedDescription)"
                deleting = false
            }
        }
    }
}
