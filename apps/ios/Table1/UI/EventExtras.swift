import PhotosUI
import Supabase
import SwiftUI
import UIKit

// After the matches (2026-10-16): the redraft pile and deck photos. Server: redraft_* and deck_photo* RPCs,
// private `deck-photos` bucket (supabase/migrations/20261016260000_redraft_deck_photos.sql).

// MARK: data

struct RedraftCard: Decodable, Identifiable, Hashable {
    let id: String
    let cardId: String
    let finish: String
    let name: String
    let set: String
    let cn: String
    let usd: Double?
    let addedBy: String
    let mine: Bool
}

struct RedraftPile: Decodable {
    var count = 0
    var totalUsd: Double = 0
    var cards: [RedraftCard] = []
}

struct DeckPhoto: Decodable, Identifiable, Hashable {
    let id: String
    let participantId: String
    let player: String
    let path: String
    let note: String
    let createdAt: String
    let mine: Bool
    let editable: Bool
}

struct DeckPhotos: Decodable {
    var shared = false
    var photos: [DeckPhoto] = []
}

extension Repo {
    static func redraftList(_ eventId: String) async throws -> RedraftPile {
        let data = try await supabase.rpc("redraft_list", params: ["p_event_id": AnyJSON.string(eventId)]).execute().data
        return try wireDecoder.decode(RedraftPile.self, from: data)
    }

    static func redraftAdd(_ eventId: String, cards: [ScannedCard]) async throws -> RedraftPile {
        let rows: [AnyJSON] = cards.map { .object(["card_id": .string($0.printing.cardId), "finish": .string($0.finish)]) }
        let data = try await supabase.rpc("redraft_add", params: [
            "p_event_id": AnyJSON.string(eventId), "p_cards": .array(rows),
        ]).execute().data
        return try wireDecoder.decode(RedraftPile.self, from: data)
    }

    static func redraftRemove(_ id: String) async throws -> RedraftPile {
        let data = try await supabase.rpc("redraft_remove", params: ["p_id": AnyJSON.string(id)]).execute().data
        return try wireDecoder.decode(RedraftPile.self, from: data)
    }

    static func deckPhotos(_ eventId: String) async throws -> DeckPhotos {
        let data = try await supabase.rpc("deck_photos", params: ["p_event_id": AnyJSON.string(eventId)]).execute().data
        return try wireDecoder.decode(DeckPhotos.self, from: data)
    }

    /// Uploads the JPEG to <event_id>/<photo_id>.jpg, then records it for the player.
    static func addDeckPhoto(eventId: String, participantId: String, jpeg: Data, note: String) async throws -> DeckPhotos {
        let id = UUID().uuidString.lowercased()
        let path = "\(eventId)/\(id).jpg"
        try await supabase.storage.from("deck-photos")
            .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
        let data = try await supabase.rpc("deck_photo_add", params: [
            "p_id": AnyJSON.string(id), "p_event_id": .string(eventId),
            "p_participant_id": .string(participantId), "p_note": .string(note),
        ]).execute().data
        return try wireDecoder.decode(DeckPhotos.self, from: data)
    }

    static func setDeckPhotoNote(_ id: String, note: String) async throws -> DeckPhotos {
        let data = try await supabase.rpc("deck_photo_note", params: [
            "p_id": AnyJSON.string(id), "p_note": .string(note),
        ]).execute().data
        return try wireDecoder.decode(DeckPhotos.self, from: data)
    }

    static func deleteDeckPhoto(_ photo: DeckPhoto) async throws -> DeckPhotos {
        let data = try await supabase.rpc("deck_photo_delete", params: ["p_id": AnyJSON.string(photo.id)]).execute().data
        // The file: only its uploader may remove it (storage policy); otherwise it stays, unreadable without its row.
        _ = try? await supabase.storage.from("deck-photos").remove(paths: [photo.path])
        return try wireDecoder.decode(DeckPhotos.self, from: data)
    }

    /// Signed links for photos (private bucket), valid an hour.
    static func deckPhotoURLs(_ paths: [String]) async -> [String: URL] {
        guard !paths.isEmpty,
              let results = try? await supabase.storage.from("deck-photos").createSignedURLs(paths: paths, expiresIn: 3600)
        else { return [:] }
        var out: [String: URL] = [:]
        for r in results { if case .success(let path, let url) = r { out[path] = url } }
        return out
    }
}

extension EventRow {
    /// Set drafts (not cubes) get a redraft once the event is over.
    var canRedraft: Bool {
        ["draft", "team_draft"].contains(formatName ?? format)
            && (cubeName ?? "").isEmpty && (cubeUrl ?? "").isEmpty
            && ["completed", "archived"].contains(status)
    }
}

/// "After the event" rows on the event screen (player and organizer Results): redraft and deck photos.
struct AfterEventLinks: View {
    let event: EventRow
    let open: (Route) -> Void

    var body: some View {
        Section1("After the event")
        if event.canRedraft {
            Button { open(.redraft(event.id)) } label: {
                ListRow(title: "Redraft", detail: "Scan the pile · most valuable first") { LabelText("Open", color: T1.text) }
            }
            .buttonStyle(.plain)
        }
        Button { open(.deckPhotos(event.id)) } label: {
            ListRow(title: "Deck photos", detail: "Everyone's decks and notes") { LabelText("Open", color: T1.text) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: redraft

/// The redraft pile for a finished set draft: anyone in the event scans cards in; the list runs most valuable
/// first (TCGplayer market for the finish scanned) and stays with the event.
struct RedraftView: View {
    let eventId: String
    @Environment(\.dismiss) private var dismiss
    @State private var pile: RedraftPile?
    @State private var busy = false
    @State private var error: String?
    private var catalog: CatalogStore { CatalogStore.shared }

    var body: some View {
        let printings = printingsById
        T1Screen {
            Bar(title: "Redraft", subtitle: subtitle, back: { dismiss() })
            HairlineList {
                Ghost(text: busy ? "Adding…" : "Scan cards", accent: true) { scan() }
                if let error { Notice(error, error: true) }
                if let pile {
                    if pile.cards.isEmpty {
                        Notice("Scan the cards going into the redraft. They line up most valuable first so the table can see what's in the pile.")
                    } else {
                        ForEach(Array(pile.cards.enumerated()), id: \.element.id) { i, card in
                            Button { menu(card) } label: {
                                CardRow(printing: printings[card.cardId], title: "\(i + 1). \(card.name)",
                                        detail: detail(card)) {
                                    Text(PriceBook.text(card.usd) ?? "–").font(T1.mono(14)).monospacedDigit()
                                        .foregroundStyle(i == 0 && card.usd != nil ? T1.accent : T1.text)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task {
            catalog.load(userInitiated: true)
            await load()
        }
    }

    private var subtitle: String? {
        guard let pile, pile.count > 0 else { return nil }
        let total = PriceBook.text(pile.totalUsd) ?? ""
        return "\(pile.count) \(pile.count == 1 ? "card" : "cards") · \(total)"
    }

    private var printingsById: [String: CatalogPrinting] {
        _ = catalog.generation
        guard let db = catalog.db, let pile else { return [:] }
        return db.printings(ids: pile.cards.map(\.cardId))
    }

    private func detail(_ card: RedraftCard) -> String {
        var parts = ["\(card.set.uppercased()) \(card.cn)"]
        if card.finish != "nonfoil" { parts.append(card.finish == "foil" ? "Foil" : "Etched") }
        parts.append(card.mine ? "You" : card.addedBy)
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            pile = try await Repo.redraftList(eventId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func scan() {
        guard !busy else { return }
        let id = eventId
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: "Scan the redraft", doneLabel: "Add", onDone: { cards in
                T1Overlays.shared.dismissPanel()
                guard !cards.isEmpty else { return }
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do {
                        pile = try await Repo.redraftAdd(id, cards: cards)
                        error = nil
                        Telemetry.capture("redraft_cards_added", ["cards": cards.count, "exact": cards.filter(\.exact).count])
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }, onCancel: { T1Overlays.shared.dismissPanel() })
        }
    }

    @MainActor
    private func menu(_ card: RedraftCard) {
        T1Overlays.shared.showMenu(card.name, [
            T1MenuItem(title: "Remove from the pile", destructive: true) {
                Task { @MainActor in
                    do {
                        pile = try await Repo.redraftRemove(card.id)
                        Telemetry.capture("redraft_card_removed")
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            },
        ])
    }
}

// MARK: deck photos

/// Deck photos for one event, with notes. Players add their own; the organizer can add for anyone (guests
/// too). Before the event ends each player sees only their own (the organizer sees all); after, everyone does.
struct DeckPhotosView: View {
    let eventId: String
    @Environment(\.dismiss) private var dismiss
    @State private var bundle: EventBundle?
    @State private var photos = DeckPhotos()
    @State private var urls: [String: URL] = [:]
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    private var me: ParticipantRow? { bundle?.participants.first { $0.userId != nil && $0.userId == Repo.userId } }

    var body: some View {
        T1Screen {
            Bar(title: "Deck photos", subtitle: bundle?.event.name, back: { dismiss() })
            HairlineList {
                if bundle?.event.isCancelled == false, me != nil || bundle?.isOrganizer == true {
                    Ghost(text: busy ? "Uploading…" : "Add a deck photo", accent: true) { add() }
                }
                if let error { Notice(error, error: true) }
                if loaded && !photos.shared {
                    Notice(bundle?.isOrganizer == true
                           ? "Players see only their own photos until the event is over. Then everyone in it sees all of them."
                           : "Only you and the organizer see your photos until the event is over. Then everyone in it sees all of them.")
                }
                if !loaded {
                    Notice("Loading…")
                } else if photos.photos.isEmpty {
                    Notice("No deck photos yet.")
                }
                ForEach(photos.photos) { photo in
                    DeckPhotoCard(photo: photo, url: urls[photo.path]) { edit(photo) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            async let b = Repo.loadEvent(eventId)
            async let p = Repo.deckPhotos(eventId)
            bundle = try await b
            await show(try await p)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func show(_ next: DeckPhotos) async {
        photos = next
        let missing = next.photos.map(\.path).filter { urls[$0] == nil }
        urls.merge(await Repo.deckPhotoURLs(missing)) { _, new in new }
    }

    /// Whose deck: yourself, or (organizer) any player. Then camera or library, then a note.
    @MainActor
    private func add() {
        guard !busy, let b = bundle else { return }
        if b.isOrganizer {
            let players = b.participants.sorted { ($0.id == me?.id ? 0 : 1, $0.displayName) < ($1.id == me?.id ? 0 : 1, $1.displayName) }
            T1Overlays.shared.showMenu("Whose deck?", players.map { p in
                T1MenuItem(title: p.id == me?.id ? "\(p.displayName) (you)" : p.displayName) { pickSource(for: p) }
            })
        } else if let me {
            pickSource(for: me)
        }
    }

    @MainActor
    private func pickSource(for player: ParticipantRow) {
        var items: [T1MenuItem] = []
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            items.append(T1MenuItem(title: "Take a photo") { capture(for: player, camera: true) })
        }
        items.append(T1MenuItem(title: "Choose from photos") { capture(for: player, camera: false) })
        T1Overlays.shared.showMenu(player.displayName, items)
    }

    @MainActor
    private func capture(for player: ParticipantRow, camera: Bool) {
        T1Overlays.shared.present(full: true, swipeBack: false) {
            ImagePicker(camera: camera) { image in
                T1Overlays.shared.dismissPanel()
                guard let image else { return }
                T1Overlays.shared.present {
                    DeckNotePanel(title: player.displayName, image: image, note: "", saveLabel: "Save photo") { note in
                        T1Overlays.shared.dismissPanel()
                        upload(image, for: player, note: note, camera: camera)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    @MainActor
    private func upload(_ image: UIImage, for player: ParticipantRow, note: String, camera: Bool) {
        guard let jpeg = image.deckJPEG() else { error = "Couldn't read that photo."; return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                await show(try await Repo.addDeckPhoto(eventId: eventId, participantId: player.id, jpeg: jpeg, note: note))
                error = nil
                Telemetry.capture("deck_photo_added", ["source": camera ? "camera" : "library",
                                                       "own": player.id == me?.id, "has_note": !note.isEmpty,
                                                       "event_over": bundle?.event.isFinished ?? false])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func edit(_ photo: DeckPhoto) {
        guard photo.editable else { return }
        T1Overlays.shared.showMenu(photo.player, [
            T1MenuItem(title: photo.note.isEmpty ? "Add a note" : "Edit note") {
                T1Overlays.shared.present {
                    DeckNotePanel(title: photo.player, image: nil, note: photo.note, saveLabel: "Save note") { note in
                        T1Overlays.shared.dismissPanel()
                        Task { @MainActor in
                            do {
                                await show(try await Repo.setDeckPhotoNote(photo.id, note: note))
                                Telemetry.capture("deck_photo_note_saved", ["has_note": !note.isEmpty])
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
            },
            T1MenuItem(title: "Remove photo", destructive: true) {
                Task { @MainActor in
                    do {
                        await show(try await Repo.deleteDeckPhoto(photo))
                        Telemetry.capture("deck_photo_removed")
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            },
        ])
    }
}

private struct DeckPhotoCard: View {
    let photo: DeckPhoto
    let url: URL?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(T1.bg)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if let url {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { LabelText("Loading…") }
                        }
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    LabelText(photo.mine ? "\(photo.player) · you" : photo.player, color: T1.text)
                    Spacer()
                    if photo.editable { LabelText("Edit") }
                }
                if !photo.note.isEmpty { Text(photo.note).font(T1.mono(13)).foregroundStyle(T1.text) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(T1.surface)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// A note for a deck photo (shown with the photo when adding one).
private struct DeckNotePanel: View {
    let title: String
    let image: UIImage?
    @State var note: String
    let saveLabel: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: title, subtitle: "Deck photo") {
                BarButton("Cancel") { T1Overlays.shared.dismissPanel() }
            }
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 180).clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                LabelText("Note")
                TextField("Archetype, key cards, how it played…", text: $note, axis: .vertical)
                    .font(T1.mono(15)).tint(T1.accent).lineLimit(3...6)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
            BigAction(text: saveLabel, accent: true) {
                onSave(note.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .foregroundStyle(T1.text)
    }
}

/// Camera or photo library, full screen. Returns nil when cancelled.
struct ImagePicker: UIViewControllerRepresentable {
    let camera: Bool
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if camera {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPick(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onPick(nil) }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                onPick(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                Task { @MainActor in self.onPick(image) }
            }
        }
    }
}

private extension UIImage {
    /// Longest side 2048 px, JPEG 0.8: a deck spread stays legible at a few hundred KB.
    func deckJPEG() -> Data? {
        let longest = max(size.width, size.height)
        let scale = min(1, 2048 / max(longest, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
