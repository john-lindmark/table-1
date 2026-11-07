import Supabase
import SwiftUI

// Your deck photos on your account (contract/event-night-2026-10-16.md § 7 "On your account", 2026-11-06): every
// photo of a deck you played, across events, newest event first (`my_deck_photos`). Account → Deck photos.

struct MyDeckPhotos: Decodable {
    var total = 0
    var events = 0
    var photos: [DeckPhoto] = []
}

extension Repo {
    static func myDeckPhotos(limit: Int = 200) async throws -> MyDeckPhotos {
        #if DEBUG
        if let demo = DemoScreens.deckPhotos { return demo }
        #endif
        let data = try await supabase.rpc("my_deck_photos", params: ["p_limit": AnyJSON.integer(limit)]).execute().data
        return try wireDecoder.decode(MyDeckPhotos.self, from: data)
    }
}

/// The Account row's summary and the screen's headings, shared with web `deckPhotos.ts` and Android `DeckPhotos.kt`
/// (testdata/deck-photos/cases.json `summary`, `groups`).
enum MyDeckPhotoRules {
    struct Group: Identifiable {
        let eventId: String
        let title: String
        var photos: [DeckPhoto]
        var id: String { eventId }
    }

    static func summary(total: Int, events: Int) -> String {
        total == 0 ? "None yet"
            : "\(total) photo\(total == 1 ? "" : "s") · \(events) event\(events == 1 ? "" : "s")"
    }

    /// The server's order kept; consecutive photos of one event under one heading.
    static func groups(_ photos: [DeckPhoto]) -> [Group] {
        var out: [Group] = []
        for photo in photos {
            let id = photo.eventId ?? ""
            if let last = out.last, last.eventId == id {
                out[out.count - 1].photos.append(photo)
            } else {
                let name = (photo.eventName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(Group(eventId: id, title: name.isEmpty ? "Event" : name, photos: [photo]))
            }
        }
        return out
    }

    /// "29 OCT 2026 · Draft": the event's date (local) and format, the heading's second half.
    static func detail(_ photo: DeckPhoto) -> String {
        var parts: [String] = []
        if let at = photo.eventAt, let date = parse(at) {
            let f = DateFormatter()
            f.dateFormat = "d MMM yyyy"
            parts.append(f.string(from: date))
        }
        // The format only when the event's name doesn't already say it ("Team Draft · 29 OCT 2026", not "… · Team draft").
        if let format = photo.formatLabel, !format.isEmpty,
           !(photo.eventName ?? "").localizedCaseInsensitiveContains(format) { parts.append(format) }
        return parts.joined(separator: " · ")
    }

    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Account → Deck photos: "12 photos · 5 events".
struct DeckPhotosAccountRow: View {
    @Binding var path: [LibraryRoute]
    @Environment(SessionModel.self) private var session
    @State private var mine: MyDeckPhotos?

    var body: some View {
        Button { path.append(.myDeckPhotos) } label: {
            ListRow(title: "Deck photos", detail: mine.map { MyDeckPhotoRules.summary(total: $0.total, events: $0.events) })
        }
        .buttonStyle(.plain)
        .task(id: session.foregrounds) { mine = try? await Repo.myDeckPhotos(limit: 1) }
    }
}

/// Every photo of your decks, headed by event (newest first). Tap a photo for Open event, the event's photos, and
/// the photo's own actions (Rotate, note, Remove) as on the event's Deck photos screen.
struct MyDeckPhotosView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session
    @State private var mine = MyDeckPhotos()
    @State private var urls: [String: URL] = [:]
    @State private var loaded = false
    @State private var error: String?
    /// Turns tapped but not yet saved, so Rotate answers at once.
    @State private var turning: [String: Int] = [:]

    var body: some View {
        T1Screen {
            Bar(title: "Deck photos", subtitle: loaded ? MyDeckPhotoRules.summary(total: mine.total, events: mine.events) : nil,
                back: { dismiss() })
            HairlineList {
                if let error { Notice(error, error: true) }
                if !loaded {
                    Notice("Loading…")
                } else if mine.photos.isEmpty {
                    Notice("No deck photos yet.")
                }
                ForEach(MyDeckPhotoRules.groups(mine.photos)) { group in
                    let detail = group.photos.first.map(MyDeckPhotoRules.detail) ?? ""
                    Section1(detail.isEmpty ? group.title : "\(group.title) · \(detail)")
                    ForEach(group.photos) { photo in
                        DeckPhotoCard(photo: photo, url: urls[photo.path], turns: turning[photo.id] ?? photo.turns ?? 0) { edit(photo) }
                    }
                }
                if mine.total > mine.photos.count {
                    Notice("Showing the newest \(mine.photos.count) of \(mine.total).")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let next = try await Repo.myDeckPhotos()
            mine = next
            let missing = next.photos.map(\.path).filter { urls[$0] == nil }
            #if DEBUG
            if DemoScreens.deckPhotos != nil {
                for p in missing { urls[p] = DeckPhotoDemo.sampleFile }
            }
            #endif
            urls.merge(await Repo.deckPhotoURLs(missing)) { _, new in new }
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
        loaded = true
    }

    @MainActor
    private func turn(_ photo: DeckPhoto, by: Int) {
        let next = DeckPhotoTurns.turn(turning[photo.id] ?? photo.turns ?? 0, by: by)
        turning[photo.id] = next
        Task { @MainActor in
            do {
                _ = try await Repo.turnDeckPhoto(photo.id, turns: next)
                await load()
                if turning[photo.id] == next { turning[photo.id] = nil }
                Telemetry.capture("deck_photo_turned", ["turns": next, "from": "account"])
            } catch {
                turning[photo.id] = nil
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func edit(_ photo: DeckPhoto) {
        var extra: [T1MenuItem] = []
        if let eventId = photo.eventId {
            extra.append(T1MenuItem(title: "Open event") {
                Telemetry.capture("my_deck_photo_opened", ["to": "event"])
                session.pendingEvent = eventId
            })
            // Everyone in an event sees all its photos once it's over; before that, only your own.
            if ["completed", "archived"].contains(photo.eventStatus ?? "") {
                extra.append(T1MenuItem(title: "Everyone's photos from this event") {
                    Telemetry.capture("my_deck_photo_opened", ["to": "event_photos"])
                    path.append(.eventDeckPhotos(eventId))
                })
            }
        }
        DeckPhotoMenu.show(photo, title: photo.eventName ?? photo.player, from: "account", extra: extra,
                           turn: { turn(photo, by: $0) }) { call in
            Task { @MainActor in
                do { _ = try await call(); await load() } catch { self.error = error.localizedDescription }
            }
        }
    }
}
