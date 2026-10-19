import SwiftUI

/// Open events within 150 m, nearest first. Coordinates are sent once per lookup and never stored.
struct NearbyView: View {
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var fix: Fix?
    @State private var events: [NearbyEvent]?
    @State private var alertsOn: Bool?
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Nearby", subtitle: "Events within 150 m", back: { dismiss() }) {
                BarButton("Refresh") { Task { await search() } }
            }
            Ghost(text: alertsOn == true ? "Alerts on" : "Alert me when one starts", accent: alertsOn == true) {
                Task {
                    let next = alertsOn != true
                    do { try await Repo.setNearbyAlerts(next); alertsOn = next } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Notice(error, error: true) }
            HairlineList {
                if let events {
                    if events.isEmpty { Notice("Nothing open nearby right now.") } else { Notice(JoinNotice.text) }
                    ForEach(events) { e in
                        let detail = "\(e.distanceM) m · \(e.label) · \(e.players)\(e.capacity.map { "/\($0)" } ?? "") players\(e.venueName.map { " · \($0)" } ?? "")"
                        if e.joined == true {
                            Button { path.append(.event(e.eventId)) } label: {
                                ListRow(title: e.name, detail: detail) { LabelText("Joined") }
                            }.buttonStyle(.plain)
                        } else {
                            ListRow(title: e.name, detail: detail) { BarButton("Join") { join(e) } }
                        }
                    }
                } else {
                    Notice("Finding events near you…")
                }
            }
        }
        .task { await search() }
    }

    private func search() async {
        error = nil
        guard let f = await LocationFix.shared.current() else {
            error = "Location is off. Scan the organizer's QR code to join instead."
            events = []
            return
        }
        fix = f
        try? await Repo.updatePresence(lat: f.lat, lng: f.lng)
        do { events = try await Repo.nearbyEvents(lat: f.lat, lng: f.lng, accuracyM: f.accuracyM) } catch {
            self.error = error.localizedDescription
            events = []
        }
    }

    private func join(_ e: NearbyEvent) {
        guard let f = fix else { return }
        Task {
            do {
                let seat = try await Repo.joinNearby(eventId: e.eventId, lat: f.lat, lng: f.lng, accuracyM: f.accuracyM)
                path = [.event(seat.eventId)]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
