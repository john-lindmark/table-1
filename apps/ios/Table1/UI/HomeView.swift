import SwiftUI

struct HomeView: View {
    @Binding var path: [Route]
    @State private var events: [Repo.MyEvent]?
    @State private var invites: [InviteRow] = []
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Table 1", subtitle: "Events") {
                BarButton("My record") { path.append(.profile) }
                BarButton("Sign out") { Task { await SignIn.signOut() } }
            }
            HStack(spacing: 1) {
                Ghost(text: "Scan QR", accent: true) { path.append(.scan) }
                Ghost(text: "Nearby") { path.append(.nearby) }
            }
            if let error { Notice(error, error: true) }
            HairlineList {
                if !invites.isEmpty {
                    Section1("Invitations")
                    ForEach(invites) { invite in
                        ListRow(
                            title: invite.events?.name ?? "Event",
                            detail: (invite.source == "nearby_alert" ? "Starting near you" : "You're invited")
                                + (invite.events?.venueName.map { " · \($0)" } ?? "")
                        ) {
                            BarButton("Decline") { answer(invite, accept: false) }
                            BarButton("Join") { answer(invite, accept: true) }
                        }
                    }
                }
                Section1("Your events")
                if let events {
                    if events.isEmpty {
                        Notice("No events yet. Create one, scan an organizer's QR, or look nearby.")
                    }
                    ForEach(events) { e in
                        Button { path.append(.event(e.event.id)) } label: {
                            ListRow(
                                title: e.event.name,
                                detail: "\(e.organizing ? "Organizing" : "Playing") · \(e.event.shortCode) · \(e.event.format) · \(e.event.status.replacingOccurrences(of: "_", with: " "))"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Notice("Loading…")
                }
            }
            BigAction(text: "Create event", accent: true) { path.append(.create) }
        }
        .task { await load() }
        .refreshable { await load() }
        .task {
            // Keep this account's area cell fresh for nearby alerts (opt-in on the Nearby screen).
            if let fix = await LocationFix.shared.current() { try? await Repo.updatePresence(lat: fix.lat, lng: fix.lng) }
        }
    }

    private func load() async {
        do { events = try await Repo.myEvents() } catch { self.error = error.localizedDescription }
        invites = (try? await Repo.invites()) ?? []
    }

    private func answer(_ invite: InviteRow, accept: Bool) {
        Task {
            do {
                _ = try await Repo.respondToInvite(invite.eventId, accept: accept)
                invites.removeAll { $0.eventId == invite.eventId }
                if accept { path.append(.event(invite.eventId)) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    let onLink: (JoinLink) -> Void
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Scan to join", subtitle: "Point at the organizer's QR") { BarButton("Close") { dismiss() } }
            if QRScanner.isAvailable {
                QRScanner { raw in
                    if let link = JoinLink(raw) {
                        dismiss()
                        onLink(link)
                    } else {
                        error = "That QR code isn't a Table 1 event."
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                Notice("This device can't scan here. Use the Camera app instead — the link opens Table 1.")
            }
            if let error { Notice(error, error: true) }
        }
    }
}
