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
    /// Quarter turns clockwise to draw it upright (set after upload; missing from servers before 2026-10-30).
    let turns: Int?
    /// Only in `my_deck_photos` (Account → Deck photos): the photo's event.
    var eventId: String? = nil
    var eventName: String? = nil
    var eventStatus: String? = nil
    var formatLabel: String? = nil
    var eventAt: String? = nil
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

    /// Turns an uploaded photo upright: the row keeps the quarter turns, the file never changes.
    static func turnDeckPhoto(_ id: String, turns: Int) async throws -> DeckPhotos {
        let data = try await supabase.rpc("deck_photo_turn", params: [
            "p_id": AnyJSON.string(id), "p_turns": .integer(turns),
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
            ListRow(title: "Deck photos", detail: "Add yours · see everyone's") { LabelText("Add", color: T1.accent) }
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
    /// Turns tapped but not yet saved, so Rotate answers at once.
    @State private var turning: [String: Int] = [:]

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
                    DeckPhotoCard(photo: photo, url: urls[photo.path], turns: turning[photo.id] ?? photo.turns ?? 0) { edit(photo) }
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
                    DeckNotePanel(title: player.displayName, image: image, note: "", saveLabel: "Save photo") { note, turns in
                        T1Overlays.shared.dismissPanel()
                        upload(image, for: player, note: note, turns: turns, camera: camera)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    @MainActor
    private func upload(_ image: UIImage, for player: ParticipantRow, note: String, turns: Int, camera: Bool) {
        guard let jpeg = image.deckJPEG(turns: turns) else { error = "Couldn't read that photo."; return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                await show(try await Repo.addDeckPhoto(eventId: eventId, participantId: player.id, jpeg: jpeg, note: note))
                error = nil
                Telemetry.capture("deck_photo_added", ["source": camera ? "camera" : "library",
                                                       "own": player.id == me?.id, "has_note": !note.isEmpty, "turns": turns,
                                                       "event_over": bundle?.event.isFinished ?? false])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Rotate after upload: shown at once, saved as the photo's quarter turns.
    @MainActor
    private func turn(_ photo: DeckPhoto, by: Int) {
        let next = DeckPhotoTurns.turn(turning[photo.id] ?? photo.turns ?? 0, by: by)
        turning[photo.id] = next
        Task { @MainActor in
            do {
                let saved = try await Repo.turnDeckPhoto(photo.id, turns: next)
                await show(saved)
                if turning[photo.id] == next { turning[photo.id] = nil }
                error = nil
                Telemetry.capture("deck_photo_turned", ["turns": next, "from": "event"])
            } catch {
                turning[photo.id] = nil
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func edit(_ photo: DeckPhoto) {
        guard photo.editable else { return }
        DeckPhotoMenu.show(photo, title: photo.player, from: "event", turn: { turn(photo, by: $0) }) { call in
            Task { @MainActor in
                do { await show(try await call()) } catch { self.error = error.localizedDescription }
            }
        }
    }
}

/// A photo's own actions (the player or whoever took it): Rotate, note, Remove. `extra` goes first (Account → Deck
/// photos adds Open event). `run` performs a call that answers with the event's photos.
@MainActor
enum DeckPhotoMenu {
    static func show(_ photo: DeckPhoto, title: String, from: String, extra: [T1MenuItem] = [],
                     turn: @escaping (Int) -> Void,
                     run: @escaping (@escaping () async throws -> DeckPhotos) -> Void) {
        T1Overlays.shared.showMenu(title, extra + [
            T1MenuItem(title: "Rotate right ↻") { turn(1) },
            T1MenuItem(title: "Rotate left ↺") { turn(-1) },
            T1MenuItem(title: photo.note.isEmpty ? "Add a note" : "Edit note") {
                T1Overlays.shared.present {
                    DeckNotePanel(title: title, image: nil, note: photo.note, saveLabel: "Save note") { note, _ in
                        T1Overlays.shared.dismissPanel()
                        run {
                            let out = try await Repo.setDeckPhotoNote(photo.id, note: note)
                            Telemetry.capture("deck_photo_note_saved", ["has_note": !note.isEmpty, "from": from])
                            return out
                        }
                    }
                }
            },
            T1MenuItem(title: "Remove photo", destructive: true) {
                run {
                    let out = try await Repo.deleteDeckPhoto(photo)
                    Telemetry.capture("deck_photo_removed", ["from": from])
                    return out
                }
            },
        ])
    }
}

struct DeckPhotoCard: View {
    let photo: DeckPhoto
    let url: URL?
    let turns: Int
    let onTap: () -> Void
    @State private var loaded: UIImage?
    /// The photo upright as its player turned it: what Copy, Save to Photos and Share hand over.
    @State private var turned: UIImage?
    @State private var share: ShareFile?
    @State private var said: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(T1.bg)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    GeometryReader { g in
                        if let loaded {
                            // Whole photo, never cropped, turned as its player set it: fitted into the box's
                            // swapped sides for a quarter turn, then rotated into place.
                            let odd = turns % 2 == 1
                            Image(uiImage: loaded).resizable().scaledToFit()
                                .frame(width: odd ? g.size.height : g.size.width, height: odd ? g.size.width : g.size.height)
                                .rotationEffect(.degrees(Double(turns) * 90))
                                .frame(width: g.size.width, height: g.size.height)
                        } else if url != nil {
                            LabelText("Loading…").frame(width: g.size.width, height: g.size.height)
                        }
                    }
                }
                .clipped()
                .modifier(PhotoMenu(image: turned, actions: actions))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    LabelText(photo.mine ? "\(photo.player) · you" : photo.player, color: T1.text)
                    Spacer()
                    if let said { LabelText(said, color: T1.accent) } else if photo.editable { LabelText("Edit") }
                }
                if !photo.note.isEmpty { Text(photo.note).font(T1.mono(13)).foregroundStyle(T1.text) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(T1.surface)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityActions {
            if turned != nil {
                Button("Copy") { said = actions.copy() }
                Button("Save to Photos") { Task { said = await actions.save() } }
                Button("Share") { actions.share() }
            }
        }
        .sheet(item: $share) { ShareSheet(share: $0).ignoresSafeArea() }
        .task(id: url) { await load() }
        .task(id: turns) { turn() }
        .task(id: said) {
            guard said != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            said = nil
        }
    }

    /// Long press: Copy, Save to Photos, Share (contract/event-night-2026-10-16.md § 7 "Long press").
    private var actions: MadeImageActions {
        MadeImageActions(
            copy: { turned.map(MadeImageActions.copy) ?? "" },
            save: {
                guard let turned else { return "" }
                return await MadeImageActions.save(turned)
            },
            share: {
                guard let data = turned?.jpegData(compressionQuality: 0.9) else { return }
                let url = FileManager.default.temporaryDirectory.appending(path: "deck-photo")
                    .appending(path: DeckPhotoTurns.fileName(photo.player))
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    share = ShareFile(url: url)
                } catch {
                    said = "Couldn't share the photo."
                }
            })
    }

    private func load() async {
        guard let url else { loaded = nil; turned = nil; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
        loaded = image
        turn()
    }

    private func turn() {
        turned = loaded?.deckRendered(turns: turns, longest: 2048)
    }
}

/// The system context menu on a deck photo once it has loaded; nothing before.
private struct PhotoMenu: ViewModifier {
    let image: UIImage?
    let actions: MadeImageActions

    func body(content: Content) -> some View {
        if let image {
            content.madeImageMenu(image, actions, screen: "deck_photo")
        } else {
            content
        }
    }
}

/// A note for a deck photo. When adding one, the photo shows whole with Rotate left / right to set it upright
/// (the turns go to `deckJPEG`).
private struct DeckNotePanel: View {
    let title: String
    let image: UIImage?
    @State var note: String
    let saveLabel: String
    let onSave: (String, Int) -> Void
    @State private var turns = 0
    @State private var preview: UIImage?

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: title, subtitle: "Deck photo") {
                BarButton("Cancel") { T1Overlays.shared.dismissPanel() }
            }
            if let image {
                Image(uiImage: preview ?? image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 260).background(T1.bg)
                HStack(spacing: 1) {
                    Ghost(text: "↺ Rotate left") { turn(-1, image) }
                    Ghost(text: "Rotate right ↻") { turn(1, image) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                LabelText("Note")
                TextField("Archetype, key cards, how it played…", text: $note, axis: .vertical)
                    .font(T1.mono(15)).tint(T1.accent).lineLimit(3...6)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
            .focusArea()
            BigAction(text: saveLabel, accent: true) {
                onSave(note.trimmingCharacters(in: .whitespacesAndNewlines), turns)
            }
        }
        .foregroundStyle(T1.text)
    }

    /// The preview is drawn small (the full photo is only turned once, on save).
    private func turn(_ by: Int, _ image: UIImage) {
        turns = DeckPhotoTurns.turn(turns, by: by)
        preview = image.deckRendered(turns: turns, longest: 900)
    }
}

/// Quarter turns clockwise for a deck photo, 0–3 (same rule as web `turnDeckPhoto` and Android `deckPhotoTurn`).
enum DeckPhotoTurns {
    static func turn(_ turns: Int, by: Int) -> Int { ((turns + by) % 4 + 4) % 4 }

    /// The shared file's name: "Deck photo - Ann Ito.jpg" (letters, digits, spaces and dashes kept).
    static func fileName(_ player: String) -> String {
        let kept = String(player.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" })
            .trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? "Deck photo.jpg" : "Deck photo - \(kept).jpg"
    }

    /// Longest side at most `longest`, never upscaled, then the sides swapped for an odd number of turns.
    static func size(width: Double, height: Double, turns: Int, longest: Double = 2048) -> (width: Double, height: Double) {
        let scale = min(1, longest / max(width, height, 1))
        let w = (width * scale).rounded(), h = (height * scale).rounded()
        return turns % 2 == 0 ? (w, h) : (h, w)
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
    func deckJPEG(turns: Int = 0) -> Data? {
        deckRendered(turns: turns, longest: 2048).jpegData(compressionQuality: 0.8)
    }

    /// Upright (UIKit applies the camera's orientation when drawing), turned `turns` quarter turns clockwise.
    func deckRendered(turns: Int, longest: Double) -> UIImage {
        let scale = min(1, longest / max(size.width, size.height, 1))
        let drawn = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let out = DeckPhotoTurns.size(width: size.width, height: size.height, turns: turns, longest: longest)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: out.width, height: out.height), format: format).image { ctx in
            // Positive angles turn clockwise in UIKit's flipped space.
            ctx.cgContext.translateBy(x: out.width / 2, y: out.height / 2)
            ctx.cgContext.rotate(by: CGFloat(turns) * .pi / 2)
            draw(in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
        }
    }
}

#if DEBUG
/// `-T1EventsDemo photo`: the add panel on a sample landscape picture marked TOP, to check Rotate left / right, then
/// the same picture as uploaded photos drawn with 0 and 1 saved turns.
struct DeckPhotoDemo: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                DeckNotePanel(title: "Ann Ito", image: Self.sample, note: "", saveLabel: "Save photo") { _, _ in }
                ForEach(0..<2) { turns in
                    DeckPhotoCard(photo: DeckPhoto(id: "demo\(turns)", participantId: "p1", player: "Ann Ito", path: "",
                                                   note: "Saved with \(turns) turn\(turns == 1 ? "" : "s")", createdAt: "",
                                                   mine: true, editable: true, turns: turns),
                                  url: Self.sampleFile, turns: turns) {}
                }
            }
        }
        .background(T1.bg)
    }

    static let sampleFile: URL? = {
        let url = FileManager.default.temporaryDirectory.appending(path: "deck-photo-demo.jpg")
        guard let data = sample.jpegData(compressionQuality: 0.8), (try? data.write(to: url)) != nil else { return nil }
        return url
    }()

    static let sample: UIImage = {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(T1.surface).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(T1.accent).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 120))
            let text = NSAttributedString(string: "TOP", attributes: [.font: UIFont.monospacedSystemFont(ofSize: 220, weight: .bold),
                                                                     .foregroundColor: UIColor.white])
            text.draw(at: CGPoint(x: 560, y: 400))
        }
    }()
}
#endif
