import SwiftUI

struct CreateEventView: View {
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Thursday Draft"
    @State private var format = "draft"
    @State private var rounds = "3"
    @State private var minutes = "50"
    @State private var venue = ""
    @State private var nearby = true
    @State private var busy = false
    @State private var error: String?

    private let formats = ["draft", "sealed", "cube", "constructed"]

    var body: some View {
        T1Screen {
            Bar(title: "New event") { BarButton("Cancel") { dismiss() } }
            ScrollView {
                VStack(spacing: 1) {
                    Field(label: "Event name", text: $name)
                    Section1("Format")
                    HStack(spacing: 1) {
                        ForEach(formats, id: \.self) { f in Ghost(text: f, accent: f == format) { format = f } }
                    }
                    Field(label: "Rounds", text: $rounds, number: true)
                    Field(label: "Round length (minutes)", text: $minutes, number: true)
                    Field(label: "Venue (optional)", text: $venue)
                    Section1("Who can find it")
                    HStack(spacing: 1) {
                        Ghost(text: "Nearby + QR", accent: nearby) { nearby = true }
                        Ghost(text: "QR only", accent: !nearby) { nearby = false }
                    }
                    Notice(nearby
                        ? "Players within 150 m can find and join it, and players nearby who turned on alerts get a Join / Decline notification."
                        : "Only people who scan your QR code can join.")
                    if let error { Notice(error, error: true) }
                }
            }
            BigAction(text: "Create event", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, busy: busy, accent: true) {
                create()
            }
        }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let created = try await Repo.createEvent(
                    name: name.trimmingCharacters(in: .whitespaces),
                    format: format,
                    rounds: min(max(Int(rounds) ?? 3, 1), 20),
                    roundMinutes: min(max(Int(minutes) ?? 50, 1), 240)
                )
                // Pin it where the organizer stands; for nearby events this also alerts opted-in players around.
                if let fix = await LocationFix.shared.current() {
                    try? await Repo.setEventLocation(
                        eventId: created.eventId, lat: fix.lat, lng: fix.lng,
                        venue: venue.isEmpty ? nil : venue, nearby: nearby
                    )
                }
                path = [.event(created.eventId)]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
