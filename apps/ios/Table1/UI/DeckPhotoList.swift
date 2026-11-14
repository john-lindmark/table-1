import Supabase
import SwiftUI

// The decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md): the photo, the list beside it,
// corrections by whoever may edit the photo, and Add to my decks for everyone who sees it.

// MARK: data

/// One line of a photo's decklist. `cardId` nil = a title the reader couldn't match to a card.
struct DeckListEntry: Codable, Hashable {
    var cardId: String?
    var name: String
    var qty: Int
    var board: String // main | side | out
    var sure: Bool
    var read: String?

    init(cardId: String?, name: String, qty: Int, board: String, sure: Bool = true, read: String? = nil) {
        self.cardId = cardId; self.name = name; self.qty = qty; self.board = board; self.sure = sure; self.read = read
    }

    enum CodingKeys: String, CodingKey { case cardId, name, qty, board, sure, read }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cardId = try c.decodeIfPresent(String.self, forKey: .cardId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        qty = try c.decodeIfPresent(Int.self, forKey: .qty) ?? 1
        let b = try c.decodeIfPresent(String.self, forKey: .board) ?? "main"
        board = ["side", "out"].contains(b) ? b : "main"
        sure = try c.decodeIfPresent(Bool.self, forKey: .sure) ?? true
        read = try c.decodeIfPresent(String.self, forKey: .read)
    }

    /// As `deck_photo_list_save` takes it.
    var json: AnyJSON {
        var o: [String: AnyJSON] = ["name": .string(name), "qty": .integer(qty), "board": .string(board), "sure": .bool(sure)]
        if let cardId { o["card_id"] = .string(cardId) }
        if let read, !read.isEmpty { o["read"] = .string(read) }
        return .object(o)
    }
}

/// A photo row's `list`: where its decklist stands.
struct DeckListBrief: Decodable, Hashable {
    var status = "done"
    var cards = 0
    var check = 0
    var checked = false
}

struct DeckPhotoListData: Decodable {
    struct Pool: Decodable { var kind: String?; var label: String?; var size: Int? }
    struct Event: Decodable { var name: String?; var format: String?; var eventType: String?; var formatLabel: String? }
    let photoId: String
    var eventId: String?
    var player: String?
    var path: String?
    var turns: Int?
    var status = "none"
    var steps: [String] = []
    var entries: [DeckListEntry] = []
    var message: String?
    var notes: String?
    var pool: Pool?
    var checked: Bool?
    var editable: Bool?
    var mine: Bool?
    var readsLeft: Int?
    var event: Event?

    var reading: Bool { status == "queued" || status == "reading" }
}

extension Repo {
    static func deckPhotoList(_ photoId: String) async throws -> DeckPhotoListData {
        #if DEBUG
        if let demo = DemoScreens.deckList { return demo }
        #endif
        let data = try await supabase.rpc("deck_photo_list", params: ["p_photo_id": AnyJSON.string(photoId)]).execute().data
        return try wireDecoder.decode(DeckPhotoListData.self, from: data)
    }

    static func readDeckPhoto(_ photoId: String) async throws -> DeckPhotoListData {
        let data = try await supabase.rpc("deck_photo_read_start", params: ["p_photo_id": AnyJSON.string(photoId)]).execute().data
        return try wireDecoder.decode(DeckPhotoListData.self, from: data)
    }

    static func saveDeckPhotoList(_ photoId: String, entries: [DeckListEntry]) async throws -> DeckPhotoListData {
        let data = try await supabase.rpc("deck_photo_list_save", params: [
            "p_photo_id": AnyJSON.string(photoId), "p_entries": .array(entries.map(\.json)),
        ]).execute().data
        return try wireDecoder.decode(DeckPhotoListData.self, from: data)
    }
}

// MARK: rules (testdata/deck-photo-lists/cases.json; web deckPhotoList.ts, Android DeckPhotoList)

enum DeckPhotoList {
    struct Counts: Equatable { var main = 0, side = 0, out = 0, check = 0 }
    struct Card: Equatable { let cardId: String; let name: String }

    private static func cards(_ n: Int) -> String { "\(n) \(n == 1 ? "card" : "cards")" }

    /// The line under a photo.
    static func row(_ brief: DeckListBrief?) -> String {
        guard let b = brief else { return "Read decklist" }
        if b.status == "queued" || b.status == "reading" { return "Reading the decklist…" }
        if b.status == "failed" { return "Decklist · couldn't read · try again" }
        if b.cards <= 0 { return "Decklist · no cards read" }
        let text = "Decklist · \(cards(b.cards))"
        if b.checked { return text + " · checked" }
        return b.check > 0 ? text + " · \(b.check) to check" : text
    }

    /// Cards the main deck should hold, when the event says.
    static func target(eventType: String?, format: String?) -> Int? {
        let f = (format ?? "").lowercased(), t = (eventType ?? "").lowercased()
        if t == "limited" { return 40 }
        if ["commander", "canadian_highlander", "canlander"].contains(f) { return 100 }
        if t == "constructed" { return 60 }
        return nil
    }

    static func counts(_ entries: [DeckListEntry]) -> Counts {
        var c = Counts()
        for e in entries {
            switch e.board { case "side": c.side += e.qty; case "out": c.out += e.qty; default: c.main += e.qty }
            if e.board != "out" && (e.cardId == nil || !e.sure) { c.check += 1 }
        }
        return c
    }

    static func sizeLine(main: Int, target: Int?) -> String {
        let text = cards(main)
        if let target, main < target { return "\(text) · \(target - main) short of \(target)" }
        if target == 100, main > 100 { return "\(text) · \(main - 100) over 100" }
        return text
    }

    private static let order = ["main": 0, "side": 1, "out": 2]
    private static func key(_ e: DeckListEntry) -> String { "\(e.cardId ?? "?" + e.name.lowercased())|\(e.board)" }

    /// The same card on the same board is one line (first place kept); main, then side, then out.
    static func tidy(_ entries: [DeckListEntry]) -> [DeckListEntry] {
        var out: [DeckListEntry] = [], at: [String: Int] = [:]
        for e in entries {
            if let i = at[key(e)] {
                out[i].qty = min(99, out[i].qty + e.qty)
                if !e.sure {
                    out[i].sure = false
                    if let r = e.read, !r.isEmpty, (out[i].read ?? "").isEmpty { out[i].read = r }
                }
            } else {
                at[key(e)] = out.count
                out.append(e)
            }
        }
        return out.enumerated().sorted { (order[$0.element.board] ?? 0, $0.offset) < (order[$1.element.board] ?? 0, $1.offset) }.map(\.element)
    }

    static func setQty(_ entries: [DeckListEntry], _ i: Int, _ qty: Int) -> [DeckListEntry] {
        var es = entries
        guard es.indices.contains(i) else { return es }
        if qty <= 0 { es.remove(at: i) } else { es[i].qty = min(99, qty) }
        return es
    }

    static func move(_ entries: [DeckListEntry], _ i: Int, to board: String) -> [DeckListEntry] {
        var es = entries
        guard es.indices.contains(i) else { return es }
        es[i].board = board
        return tidy(es)
    }

    /// The player picked the card this line really is: sure, nothing left to check.
    static func replace(_ entries: [DeckListEntry], _ i: Int, with card: Card) -> [DeckListEntry] {
        var es = entries
        guard es.indices.contains(i) else { return es }
        es[i] = DeckListEntry(cardId: card.cardId, name: card.name, qty: es[i].qty, board: es[i].board)
        return tidy(es)
    }

    static func confirm(_ entries: [DeckListEntry], _ i: Int) -> [DeckListEntry] {
        var es = entries
        guard es.indices.contains(i), es[i].cardId != nil else { return es }
        es[i].sure = true
        es[i].read = nil
        return es
    }

    static func add(_ entries: [DeckListEntry], _ card: Card, to board: String) -> [DeckListEntry] {
        tidy(entries + [DeckListEntry(cardId: card.cardId, name: card.name, qty: 1, board: board)])
    }

    /// What a new deck takes: main and sideboard lines with a card; lines without one are left out and counted.
    static func deckEntries(_ entries: [DeckListEntry]) -> (entries: [CardList.Entry], skipped: Int) {
        var out: [CardList.Entry] = [], skipped = 0
        for e in entries where e.board != "out" {
            guard let id = e.cardId else { skipped += 1; continue }
            if let i = out.firstIndex(where: { $0.cardId == id && $0.board == e.board }) {
                out[i] = .init(cardId: id, board: e.board, qty: out[i].qty + e.qty)
            } else {
                out.append(.init(cardId: id, board: e.board, qty: e.qty))
            }
        }
        return (out, skipped)
    }

    static func deckName(event: String?, player: String?, mine: Bool) -> String {
        var name = (event ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Deck photo" }
        let p = (player ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine, !p.isEmpty { name = "\(p) · \(name)" }
        return String(name.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deckFormat(eventType: String?, format: String?) -> String {
        let f = (format ?? "").lowercased()
        if f == "canadian_highlander" { return "canlander" }
        return ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander"].contains(f) ? f : "other"
    }
}

extension EnvironmentValues {
    /// Pushes a Library screen on the tab's own stack (set beside `openProfile`), for screens that hold no path.
    @Entry var openLibrary: ((LibraryRoute) -> Void)? = nil
}

// MARK: the row under a photo

/// "Decklist · 40 cards · 2 to check" under a deck photo; a tap opens the decklist.
struct DeckListRow: View {
    let photo: DeckPhoto
    let from: String
    @Environment(\.openLibrary) private var openLibrary

    var body: some View {
        Button {
            Telemetry.capture("deck_list_opened", ["status": photo.list?.status ?? "none", "mine": photo.mine, "editable": photo.editable, "from": from])
            openLibrary?(.deckPhotoList(photo.id))
        } label: {
            HStack(spacing: 12) {
                LabelText(DeckPhotoList.row(photo.list), color: T1.text)
                Spacer(minLength: 0)
                T1Icon.arrowRight.fill(T1.muted).frame(width: 18, height: 18)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(T1.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: the screen

struct DeckPhotoListView: View {
    let photoId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var data: DeckPhotoListData?
    @State private var entries: [DeckListEntry] = []
    @State private var image: UIImage?
    @State private var error: String?
    /// Changes not yet sent (editors): saved 0.8 s after the last one.
    @State private var dirty = 0
    @State private var saved = false
    @State private var outOpen = false
    @State private var added: CardList?
    @State private var skipped = 0
    @State private var printings: [String: CatalogPrinting] = [:]

    private var editable: Bool { data?.editable == true }
    private var counts: DeckPhotoList.Counts { DeckPhotoList.counts(entries) }
    private var target: Int? { DeckPhotoList.target(eventType: data?.event?.eventType, format: data?.event?.format) }

    var body: some View {
        T1Screen {
            Bar(title: "Decklist", subtitle: subtitle, back: { dismiss() }) {
                if saved { LabelText("Saved", color: T1.accent) }
            }
            HairlineList {
                photo
                if let error { Notice(error, error: true) }
                if let data {
                    if data.reading && entries.isEmpty {
                        Section1("Reading the photo")
                        ForEach(Array((data.steps.isEmpty ? ["Waiting to start"] : data.steps).enumerated()), id: \.offset) { _, s in
                            ListRow(title: s)
                        }
                    } else if data.status == "none" || (data.status == "failed" && entries.isEmpty) {
                        if let m = data.message { Notice(m) }
                        Ghost(text: "Read decklist", accent: true) { read(again: false) }
                    } else {
                        summary(data)
                        if data.reading { Notice("Reading the photo again…") }
                        if let m = data.message { Notice(m) }
                        section("Main deck", "main")
                        if counts.side > 0 { section("Sideboard", "side") }
                        if editable || data.editable == false {
                            Ghost(text: "Add a card") { pick(title: "Add a card", query: "") { card in change("add") { DeckPhotoList.add($0, card, to: "main") } } }
                        }
                        if counts.out > 0 {
                            Button { outOpen.toggle() } label: {
                                PodHeader("Left out · \(counts.out)", detail: outOpen ? "Hide" : "Show")
                            }.buttonStyle(.plain)
                            if outOpen {
                                Notice("In the photo but not in the deck: lying sideways, off the mat or cut off.")
                                lines("out")
                            }
                        }
                        if editable, !data.reading, (data.readsLeft ?? 0) > 0 {
                            Color.clear.frame(height: 15)
                            Button { askAgain() } label: { ListRow(title: "Read the photo again") }.buttonStyle(.plain)
                        }
                    }
                } else if error == nil {
                    Notice("Loading…")
                }
            }
            if let added {
                if skipped > 0 { Notice("\(skipped) line\(skipped == 1 ? "" : "s") without a card \(skipped == 1 ? "was" : "were") left out.") }
                BigAction(text: "Open deck", accent: true) { path.append(.list(added.id)) }
            } else if data != nil, counts.main + counts.side > 0 {
                BigAction(text: "Add to my decks") { toDeck() }
            }
        }
        .task { await load() }
        .task(id: data?.reading) { await poll() }
        .task(id: dirty) { await save() }
        .task(id: entries.compactMap(\.cardId)) { await art() }
    }

    private var subtitle: String? {
        guard let d = data else { return nil }
        return [d.player, d.event?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var photo: some View {
        let turns = data?.turns ?? 0
        Rectangle().fill(T1.bg)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    if let image {
                        let odd = turns % 2 == 1
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: odd ? g.size.height : g.size.width, height: odd ? g.size.width : g.size.height)
                            .rotationEffect(.degrees(Double(turns) * 90))
                            .frame(width: g.size.width, height: g.size.height)
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                guard let image else { return }
                let upright = image.deckRendered(turns: turns, longest: 2048)
                T1Overlays.shared.present(full: true) {
                    ZoomImagePanel(title: "Deck photo", subtitle: data?.player, image: upright, actions: nil, screen: "deck_photo_list")
                }
            }
            .accessibilityLabel("Deck photo. Tap to zoom.")
    }

    private func summary(_ d: DeckPhotoListData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DeckPhotoList.sizeLine(main: counts.main, target: target).uppercased())
                .font(T1.mono(20, .bold)).tracking(2).foregroundStyle(T1.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            LabelText(detail(d))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(T1.surface)
    }

    private func detail(_ d: DeckPhotoListData) -> String {
        var parts: [String] = []
        if counts.side > 0 { parts.append("\(counts.side) sideboard") }
        if counts.check > 0 { parts.append("\(counts.check) to check") } else if d.checked == true { parts.append("Checked") }
        if let label = d.pool?.label, !label.isEmpty, (d.pool?.size ?? 0) > 0 { parts.append(label) }
        return parts.isEmpty ? (d.event?.formatLabel ?? "Read from the photo") : parts.joined(separator: " · ")
    }

    @ViewBuilder private func section(_ title: String, _ board: String) -> some View {
        let n = board == "main" ? counts.main : counts.side
        PodHeader(title, detail: "\(n)")
        lines(board)
    }

    @ViewBuilder private func lines(_ board: String) -> some View {
        ForEach(Array(entries.enumerated()).filter { $0.element.board == board }, id: \.offset) { i, e in
            line(i, e)
        }
    }

    private func line(_ i: Int, _ e: DeckListEntry) -> some View {
        let check = e.board != "out" && (e.cardId == nil || !e.sure)
        let note: String? = e.cardId == nil ? "No card by this name · tap to pick" : (check ? (e.read?.isEmpty == false ? e.read : "Not sure") : nil)
        return HStack(spacing: 1) {
            Button { menu(i, e) } label: {
                CardRow(printing: e.cardId.flatMap { printings[$0] }, title: e.name, detail: note) {
                    if check { LabelText("Check", color: T1.text) }
                }
            }
            .buttonStyle(.plain)
            step("−", enabled: true) { change("qty") { DeckPhotoList.setQty($0, i, e.qty - 1) } }
            Text("\(e.qty)").font(T1.mono(16)).monospacedDigit().foregroundStyle(T1.text)
                .frame(minWidth: 34, maxHeight: .infinity).background(T1.surface)
            step("+", enabled: e.qty < 99) { change("qty") { DeckPhotoList.setQty($0, i, e.qty + 1) } }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
    }

    private func step(_ glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(T1.mono(20)).foregroundStyle(enabled ? T1.text : T1.disabled)
                .frame(width: 44).frame(maxHeight: .infinity).background(T1.surfaceHover)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(glyph == "+" ? "One more" : "One fewer")
    }

    // MARK: actions

    private func load() async {
        do {
            let d = try await Repo.deckPhotoList(photoId)
            show(d)
            if let p = d.path, image == nil {
                #if DEBUG
                if DemoScreens.deckList != nil { image = DeckPhotoDemo.sample; return }
                #endif
                if let url = await Repo.deckPhotoURLs([p])[p], let (bytes, _) = try? await URLSession.shared.data(from: url) {
                    image = UIImage(data: bytes)
                }
            }
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    /// The server's list, unless changes of ours are still on their way.
    private func show(_ d: DeckPhotoListData) {
        data = d
        if dirty == 0 || !editable { entries = d.entries }
        error = nil
    }

    private func poll() async {
        while data?.reading == true, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            if let d = try? await Repo.deckPhotoList(photoId) {
                let was = data?.reading == true
                data = d
                if was && !d.reading { entries = d.entries; dirty = 0 }
            }
        }
    }

    private func read(again: Bool) {
        Telemetry.capture("deck_list_read_asked", ["again": again])
        Task {
            do {
                let d = try await Repo.readDeckPhoto(photoId)
                dirty = 0
                data = d
                if !again { entries = d.entries }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func askAgain() {
        T1Overlays.shared.ask("Read the photo again?", message: "Reading again replaces this list.", action: "Read again") { read(again: true) }
    }

    private func change(_ op: String, _ edit: ([DeckListEntry]) -> [DeckListEntry]) {
        entries = edit(entries)
        added = nil
        saved = false
        Telemetry.capture("deck_list_edited", ["op": op, "editable": editable])
        if editable { dirty += 1 }
    }

    private func save() async {
        guard dirty > 0, editable else { return }
        let mark = dirty
        try? await Task.sleep(for: .milliseconds(800))
        if Task.isCancelled { return }
        do {
            let d = try await Repo.saveDeckPhotoList(photoId, entries: entries)
            let c = DeckPhotoList.counts(entries)
            Telemetry.capture("deck_list_saved", ["lines": entries.count, "cards": c.main + c.side, "check": c.check])
            if dirty == mark {
                dirty = 0
                data = d
                saved = true
            }
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    private func menu(_ i: Int, _ e: DeckListEntry) {
        var items: [T1MenuItem] = [
            T1MenuItem(title: "Change card") { pick(title: e.name, query: e.cardId == nil ? e.name : "") { card in change("replace") { DeckPhotoList.replace($0, i, with: card) } } },
        ]
        if e.cardId != nil, !e.sure, e.board != "out" {
            items.append(T1MenuItem(title: "Looks right") { change("confirm") { DeckPhotoList.confirm($0, i) } })
        }
        for (board, title) in [("main", "Move to main deck"), ("side", "Move to sideboard"), ("out", "Leave out of the deck")] where board != e.board {
            items.append(T1MenuItem(title: title) { change("move") { DeckPhotoList.move($0, i, to: board) } })
        }
        items.append(T1MenuItem(title: "Remove", destructive: true) { change("remove") { DeckPhotoList.setQty($0, i, 0) } })
        T1Overlays.shared.showMenu(e.name, message: e.read, items)
    }

    private func pick(title: String, query: String, onPick: @escaping (DeckPhotoList.Card) -> Void) {
        T1Overlays.shared.present(full: true) {
            DeckListPickPanel(title: title, query: query) { card in
                T1Overlays.shared.dismissPanel()
                onPick(card)
            }
        }
    }

    private func toDeck() {
        guard let d = data else { return }
        let out = DeckPhotoList.deckEntries(entries)
        let mine = d.mine == true
        let c = counts
        let l = ListsStore.shared.create(
            kind: .deck, name: DeckPhotoList.deckName(event: d.event?.name, player: d.player, mine: mine),
            format: DeckPhotoList.deckFormat(eventType: d.event?.eventType, format: d.event?.format), entries: out.entries,
            note: mine ? "From your deck photo" : String("From \(d.player ?? "a player")'s deck photo".prefix(120)), from: "deck_photo")
        Telemetry.capture("deck_list_to_deck", ["cards": c.main + c.side, "skipped": out.skipped, "mine": mine, "checked": d.checked == true])
        skipped = out.skipped
        added = l
    }

    private func art() async {
        guard let db = CatalogStore.shared.db else { return }
        let ids = entries.compactMap(\.cardId).filter { printings[$0] == nil }
        guard !ids.isEmpty else { return }
        let found = await Task.detached(priority: .userInitiated) { db.printings(ids: ids) }.value
        if !Task.isCancelled { printings.merge(found) { _, new in new } }
    }
}

/// Pick the card a line really is, or a card to add: a search of every card.
private struct DeckListPickPanel: View {
    let title: String
    let onPick: (DeckPhotoList.Card) -> Void
    @State private var query: String
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @FocusState private var focused: Bool

    init(title: String, query: String, onPick: @escaping (DeckPhotoList.Card) -> Void) {
        self.title = title
        self.onPick = onPick
        _query = State(initialValue: query)
    }

    var body: some View {
        T1Screen {
            Bar(title: title, back: { T1Overlays.shared.dismissPanel() })
            T1SearchField(text: $query, prompt: "Card name").focused($focused)
            HairlineList {
                if CardName.norm(query).count >= 2 && hits.isEmpty { Notice("No card by that name") }
                ForEach(hits, id: \.idx) { o in
                    Button {
                        if let p = covers[o.idx] { onPick(.init(cardId: p.cardId, name: o.name)) }
                    } label: {
                        CardRow(printing: covers[o.idx], title: o.name, detail: o.typeLine) { LabelText("Pick", color: T1.text) }
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            guard let db = CatalogStore.shared.db else { return }
            let q = query
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { () -> ([CatalogOracle], [Int: CatalogPrinting]) in
                let hits = db.search(q)
                return (hits, db.covers(oracleIdxs: hits.map(\.idx)))
            }.value
            if !Task.isCancelled { hits = found.0; covers = found.1 }
        }
    }
}
