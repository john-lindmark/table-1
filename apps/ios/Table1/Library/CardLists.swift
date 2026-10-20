import Supabase
import SwiftUI

// Decks and cubes ("card lists", plan-collection-2026-10-14.md §6). The server tables come with L3; until then
// only the Debug demo fills this store.
//  - Sections: decks have Main deck, Sideboard and Considering; cubes have Main and Considering. Considering
//    is ideas, not commitments: it never counts as missing and never counts against the copies you own.
//  - Lists never reserve copies; what a list is missing is derived from the collection.
//  - Every list is a series of versions (oldest first); the current contents are the newest. Nothing is ever
//    edited in place: a change, or restoring an old version, appends a new version, so history is complete.

struct CardList: Identifiable, Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        let cardId: String
        let board: String // main | side | maybe | commander
        let qty: Int
        /// nonfoil | foil | etched. A line is printing × section × finish, so 2 foil and 2 non-foil copies of a
        /// card are two lines.
        var finish: String = "nonfoil"
    }
    struct Version: Identifiable, Hashable, Sendable {
        let number: Int
        let at: Date
        let note: String
        let entries: [Entry]
        var id: Int { number }
    }
    /// One line of a diff between two versions.
    struct Change: Hashable, Sendable {
        let cardId: String
        let board: String
        let delta: Int
        var finish: String = "nonfoil"
    }
    enum Kind: String, Sendable { case deck, cube }

    let id: String
    let kind: Kind
    let name: String
    let format: String
    /// Oldest first; never empty.
    let versions: [Version]
    /// A roto deck linked to its event: filled by the draft, the cards belong to the cube's owner, so it never
    /// counts Missing (contract/roto-2026-10-16.md).
    var eventId: String? = nil
    var eventName: String? = nil

    var entries: [Entry] { versions.last?.entries ?? [] }
    var current: Version? { versions.last }

    func count(_ board: String) -> Int { entries.filter { $0.board == board }.reduce(0) { $0 + $1.qty } }

    /// Sections in display order, only those with cards.
    var boards: [String] { Self.boardOrder.filter { b in entries.contains { $0.board == b } } }
    static let boardOrder = ["commander", "main", "side", "maybe"]

    func boardTitle(_ board: String) -> String {
        switch board {
        case "commander": "Commander"
        case "main": kind == .deck ? "Main deck" : "Main"
        case "side": "Sideboard"
        case "maybe": "Considering"
        default: board.capitalized
        }
    }

    func version(_ number: Int) -> Version? { versions.first { $0.number == number } }

    /// What changed from `older` (nil = nothing) to `newer`, per card and section; sorted by section, then
    /// removals before additions.
    static func diff(_ older: Version?, _ newer: Version) -> [Change] {
        var qty: [String: Int] = [:]
        for e in older?.entries ?? [] { qty["\(e.board)|\(e.cardId)|\(e.finish)", default: 0] -= e.qty }
        for e in newer.entries { qty["\(e.board)|\(e.cardId)|\(e.finish)", default: 0] += e.qty }
        return qty.compactMap { k, d -> Change? in
            guard d != 0 else { return nil }
            let parts = k.split(separator: "|", maxSplits: 2).map(String.init)
            return Change(cardId: parts[1], board: parts[0], delta: d, finish: parts[2])
        }
        .sorted { a, b in
            let ia = boardOrder.firstIndex(of: a.board) ?? 9, ib = boardOrder.firstIndex(of: b.board) ?? 9
            return ia != ib ? ia < ib : a.delta < b.delta
        }
    }
}

@MainActor
@Observable
final class ListsStore {
    static let shared = ListsStore()
    private(set) var lists: [CardList] = []
    private(set) var syncing = false
    var error: String?

    /// Signed in: lists live in the database (contract/lists-2026-10-15.md) and sync by seq; this device keeps a
    /// cached copy so they show instantly and offline. Demo (`replace`): local only.
    @ObservationIgnored private var userId: String?
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var demo = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false

    func replace(_ lists: [CardList]) {
        demo = true
        userId = nil
        self.lists = lists
    }

    func lists(_ kind: CardList.Kind) -> [CardList] { lists.filter { $0.kind == kind } }
    func list(id: String) -> CardList? { lists.first { $0.id == id } }

    // MARK: sync

    func start(userId: String) async {
        guard self.userId != userId else { return await sync() }
        demo = false
        self.userId = userId
        let cached = Self.loadCache(userId)
        lists = cached.lists
        cursor = cached.cursor
        await sync()
    }

    func stop() {
        userId = nil
        lists = []
        cursor = 0
    }

    /// Pulls every list changed after the local cursor. A call during a run schedules one more run after it.
    func sync() async {
        guard let user = userId, !demo else { return }
        if let running = syncTask {
            syncAgain = true
            await running.value
            return
        }
        let task = Task {
            syncing = true
            defer { syncing = false }
            do {
                for _ in 0..<50 {
                    let page: ListsPage = try await supabase.rpc("lists_changes", params: [
                        "p_after": AnyJSON.integer(cursor), "p_limit": .integer(100),
                    ]).execute().value
                    guard userId == user else { return }
                    for dto in page.lists { merge(dto) }
                    cursor = page.next
                    Self.saveCache(user, lists: lists, cursor: cursor)
                    if !page.more { break }
                }
                error = nil
            } catch {
                if userId == user { self.error = error.localizedDescription }
            }
        }
        syncTask = task
        await task.value
        syncTask = nil
        if syncAgain {
            syncAgain = false
            await sync()
        }
    }

    private func merge(_ dto: ListDTO) {
        lists.removeAll { $0.id == dto.id }
        if dto.deleted != true, let l = dto.list { lists.append(l) }
        lists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sends one change to the server and replaces the local list with the server's version (the source of
    /// truth: it groups edits into versions). On failure the local copy is re-synced.
    private func send(_ fn: String, _ params: [String: AnyJSON]) {
        guard userId != nil, !demo else { return }
        Task {
            do {
                let dto: ListDTO = try await supabase.rpc(fn, params: params).execute().value
                merge(dto)
                if let u = userId { Self.saveCache(u, lists: lists, cursor: cursor) }
                error = nil
            } catch {
                self.error = error.localizedDescription
                await sync()
            }
        }
    }

    // MARK: changes (shown at once, then confirmed by the server)

    /// Makes an old version current again by appending a copy of it as a new version (history is never
    /// rewritten).
    @discardableResult
    func restore(listId: String, version number: Int) -> CardList.Version? {
        guard let i = lists.firstIndex(where: { $0.id == listId }), let old = lists[i].version(number),
              number != lists[i].current?.number else { return nil }
        let l = lists[i]
        let next = CardList.Version(number: (l.versions.map(\.number).max() ?? 0) + 1, at: .now,
                                    note: "Restored v\(number)", entries: old.entries)
        lists[i] = CardList(id: l.id, kind: l.kind, name: l.name, format: l.format, versions: l.versions + [next])
        openEdit[listId] = nil
        send("list_restore", ["p_list_id": .string(listId), "p_version": .integer(number)])
        Telemetry.capture("list_version_restored", ["kind": l.kind.rawValue])
        return next
    }

    /// The version an editing session is filling: edits within 10 minutes of each other share one version.
    /// The server applies the same rule; this keeps the screen in step until its answer arrives.
    @ObservationIgnored private var openEdit: [String: (number: Int, at: Date)] = [:]

    /// A new list, optionally starting with cards (a duplicate, an import or a found decklist).
    @discardableResult
    /// `from` is for telemetry only: new / duplicate / import / finder.
    func create(kind: CardList.Kind, name: String, format: String, entries: [CardList.Entry] = [], note: String = "Created",
                from: String = "new") -> CardList {
        let l = CardList(id: UUID().uuidString.lowercased(), kind: kind, name: name, format: format,
                         versions: [CardList.Version(number: 1, at: .now, note: note, entries: entries)])
        lists.append(l)
        lists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let wire: [AnyJSON] = entries.map { e in
            .array([.string(e.cardId), .string(e.board), .integer(e.qty)] + (e.finish == "nonfoil" ? [] : [.string(e.finish)]))
        }
        send("list_create", ["p_id": .string(l.id), "p_kind": .string(kind.rawValue), "p_name": .string(name),
                             "p_format": .string(format), "p_entries": .array(wire), "p_note": .string(note)])
        Telemetry.capture("list_created", ["kind": kind.rawValue, "format": format, "from": from])
        FriendsStore.shared.noteCreated(kind: kind == .cube ? "cube" : "deck", id: l.id, name: name)
        return l
    }

    /// A new list with the current version's cards; its history starts fresh and names where it came from.
    @discardableResult
    func duplicate(listId: String) -> CardList? {
        guard let l = list(id: listId), let cur = l.current else { return nil }
        return create(kind: l.kind, name: "\(l.name) (copy)", format: l.format, entries: cur.entries,
                      note: "Duplicated from \(l.name) v\(cur.number)", from: "duplicate")
    }

    func delete(listId: String) {
        if let l = list(id: listId) { Telemetry.capture("list_deleted", ["kind": l.kind.rawValue]) }
        lists.removeAll { $0.id == listId }
        send("list_delete", ["p_list_id": .string(listId)])
    }

    func add(listId: String, cardId: String, board: String, finish: String = "nonfoil", delta: Int) {
        edit(listId, op: ["card_id": .string(cardId), "board": .string(board), "finish": .string(finish), "delta": .integer(delta)]) { entries in
            if let i = entries.firstIndex(where: { $0.cardId == cardId && $0.board == board && $0.finish == finish }) {
                let q = entries[i].qty + delta
                if q > 0 { entries[i] = .init(cardId: cardId, board: board, qty: q, finish: finish) } else { entries.remove(at: i) }
            } else if delta > 0 {
                entries.append(.init(cardId: cardId, board: board, qty: delta, finish: finish))
            }
        }
    }

    /// Moves every copy of a line to another section (merging with copies already there).
    func move(listId: String, cardId: String, finish: String = "nonfoil", from: String, to: String) {
        guard from != to else { return }
        edit(listId, op: ["card_id": .string(cardId), "finish": .string(finish), "from": .string(from), "to": .string(to)]) { entries in
            Self.shift(&entries, cardId: cardId, board: from, finish: finish, toCardId: cardId, toBoard: to, toFinish: finish, qty: nil)
        }
    }

    /// Moves `qty` copies (nil = all) of a line to another printing and/or finish in the same section: change a
    /// printing, or split 4 non-foil into 2 non-foil and 2 foil.
    func swap(listId: String, cardId: String, board: String, finish: String, toCardId: String, toFinish: String, qty: Int?) {
        guard cardId != toCardId || finish != toFinish else { return }
        var op: [String: AnyJSON] = ["card_id": .string(cardId), "board": .string(board), "finish": .string(finish),
                                     "to_card_id": .string(toCardId), "to_finish": .string(toFinish)]
        if let qty { op["qty"] = .integer(qty) }
        edit(listId, op: op) { entries in
            Self.shift(&entries, cardId: cardId, board: board, finish: finish, toCardId: toCardId, toBoard: board, toFinish: toFinish, qty: qty)
        }
    }

    nonisolated static func shift(_ entries: inout [CardList.Entry], cardId: String, board: String, finish: String,
                              toCardId: String, toBoard: String, toFinish: String, qty: Int?) {
        guard let i = entries.firstIndex(where: { $0.cardId == cardId && $0.board == board && $0.finish == finish }) else { return }
        let have = entries[i].qty
        let n = min(have, qty ?? have)
        guard n > 0 else { return }
        if have - n > 0 { entries[i] = .init(cardId: cardId, board: board, qty: have - n, finish: finish) } else { entries.remove(at: i) }
        if let j = entries.firstIndex(where: { $0.cardId == toCardId && $0.board == toBoard && $0.finish == toFinish }) {
            entries[j] = .init(cardId: toCardId, board: toBoard, qty: entries[j].qty + n, finish: toFinish)
        } else {
            entries.append(.init(cardId: toCardId, board: toBoard, qty: n, finish: toFinish))
        }
    }

    /// Replaces one copy of a line with another card (Cube Cobra's Remove/Replace), in the same section: one edit,
    /// so the version history shows the swap.
    func replaceCard(listId: String, cardId: String, board: String, finish: String, with toCardId: String, toFinish: String) {
        swap(listId: listId, cardId: cardId, board: board, finish: finish, toCardId: toCardId, toFinish: toFinish, qty: 1)
        Telemetry.capture("list_card_replaced", ["kind": list(id: listId)?.kind.rawValue ?? "cube"])
    }

    func remove(listId: String, cardId: String, board: String, finish: String = "nonfoil") {
        edit(listId, op: ["card_id": .string(cardId), "board": .string(board), "finish": .string(finish), "qty": .integer(0)]) {
            $0.removeAll { $0.cardId == cardId && $0.board == board && $0.finish == finish }
        }
    }

    /// Several cards into one section as one edit (a scan session): one request, one step in the history.
    func addMany(listId: String, board: String, cards: [(cardId: String, finish: String)]) {
        guard !cards.isEmpty else { return }
        let ops: [[String: AnyJSON]] = cards.map { ["card_id": .string($0.cardId), "board": .string(board), "finish": .string($0.finish), "delta": .integer(1)] }
        edit(listId, ops: ops) { entries in
            for c in cards {
                if let i = entries.firstIndex(where: { $0.cardId == c.cardId && $0.board == board && $0.finish == c.finish }) {
                    entries[i] = .init(cardId: c.cardId, board: board, qty: entries[i].qty + 1, finish: c.finish)
                } else {
                    entries.append(.init(cardId: c.cardId, board: board, qty: 1, finish: c.finish))
                }
            }
        }
    }

    private func edit(_ listId: String, op: [String: AnyJSON], _ change: (inout [CardList.Entry]) -> Void) {
        edit(listId, ops: [op], change)
    }

    private func edit(_ listId: String, ops: [[String: AnyJSON]], _ change: (inout [CardList.Entry]) -> Void) {
        guard let i = lists.firstIndex(where: { $0.id == listId }), let cur = lists[i].current else { return }
        var entries = cur.entries
        change(&entries)
        guard entries != cur.entries else { return }
        let l = lists[i]
        var versions = l.versions
        if let open = openEdit[listId], open.number == cur.number, Date.now.timeIntervalSince(open.at) < 600 {
            versions[versions.count - 1] = CardList.Version(number: cur.number, at: .now, note: cur.note, entries: entries)
        } else {
            let n = (versions.map(\.number).max() ?? 0) + 1
            versions.append(CardList.Version(number: n, at: .now, note: "Edited", entries: entries))
        }
        openEdit[listId] = (versions[versions.count - 1].number, .now)
        lists[i] = CardList(id: l.id, kind: l.kind, name: l.name, format: l.format, versions: versions)
        send("list_edit", ["p_list_id": .string(listId), "p_ops": .array(ops.map { .object($0) })])
    }

    /// Lists that use any of these printings: copies committed (main, side, commander) and copies considered.
    func uses(cardIds: Set<String>) -> [(list: CardList, qty: Int, considering: Int)] {
        lists.compactMap { l in
            let hits = l.entries.filter { cardIds.contains($0.cardId) }
            let q = hits.filter { $0.board != "maybe" }.reduce(0) { $0 + $1.qty }
            let c = hits.filter { $0.board == "maybe" }.reduce(0) { $0 + $1.qty }
            return q + c > 0 ? (l, q, c) : nil
        }
    }

    // MARK: device cache (one JSON file per account)

    private struct Cache: Codable {
        var cursor: Int
        var lists: [ListDTO]
    }

    nonisolated private static func cacheURL(_ userId: String) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "lists-\(userId).json")
    }

    private static func loadCache(_ userId: String) -> (lists: [CardList], cursor: Int) {
        guard let data = try? Data(contentsOf: cacheURL(userId)),
              let c = try? JSONDecoder().decode(Cache.self, from: data) else { return ([], 0) }
        return (c.lists.compactMap(\.list), c.cursor)
    }

    private static func saveCache(_ userId: String, lists: [CardList], cursor: Int) {
        let c = Cache(cursor: cursor, lists: lists.map(ListDTO.init))
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: cacheURL(userId), options: .atomic) }
    }
}

/// A list on the wire (lists_changes and the list_* RPCs): entries are [card_id, board, qty].
struct ListDTO: Codable {
    struct VersionDTO: Codable {
        let version: Int
        let note: String
        let at: Double
        let entries: [[Atom]]
    }
    enum Atom: Codable {
        case text(String), int(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .text(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            }
        }
        var text: String { if case .text(let s) = self { s } else { "" } }
        var int: Int { if case .int(let i) = self { i } else { 0 } }
    }
    let id: String
    var kind: String?
    var name: String?
    var format: String?
    var deleted: Bool?
    var versions: [VersionDTO]?
    var eventId: String?
    var eventName: String?

    var list: CardList? {
        guard let kind, let name, let format, let versions, !versions.isEmpty else { return nil }
        return CardList(id: id, kind: kind == "cube" ? .cube : .deck, name: name, format: format,
                        versions: versions.map { v in
                            CardList.Version(number: v.version, at: Date(timeIntervalSince1970: v.at), note: v.note,
                                             entries: v.entries.map { CardList.Entry(cardId: $0[0].text, board: $0[1].text, qty: $0[2].int,
                                                                                    finish: $0.count > 3 ? $0[3].text : "nonfoil") })
                        }, eventId: eventId, eventName: eventName)
    }

    init(_ l: CardList) {
        id = l.id
        kind = l.kind.rawValue
        name = l.name
        format = l.format
        deleted = false
        eventId = l.eventId
        eventName = l.eventName
        versions = l.versions.map { v in
            VersionDTO(version: v.number, note: v.note, at: v.at.timeIntervalSince1970,
                       entries: v.entries.map { [.text($0.cardId), .text($0.board), .int($0.qty)] + ($0.finish == "nonfoil" ? [] : [.text($0.finish)]) })
        }
    }
}

private struct ListsPage: Decodable {
    let lists: [ListDTO]
    let next: Int
    let more: Bool
}

/// Copies owned of each printing in each finish ("card_id|finish"), over every condition and language.
@MainActor
func ownedByPrinting() -> [String: Int] {
    var out: [String: Int] = [:]
    for it in CollectionStore.shared.items.values { out["\(it.cardId)|\(it.finish)", default: 0] += it.qty }
    return out
}

/// Copies a list still needs. A line counts as covered only by the printing and finish it names; Considering is
/// excluded.
@MainActor
func missing(in list: CardList, owned: [String: Int]) -> Int {
    guard list.eventId == nil else { return 0 }
    var need: [String: Int] = [:]
    for e in list.entries where e.board != "maybe" { need["\(e.cardId)|\(e.finish)", default: 0] += e.qty }
    return need.reduce(0) { $0 + max(0, $1.value - (owned[$1.key] ?? 0)) }
}

private let shortDate: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()

private func statCell(_ label: String, _ value: Int, warn: Bool = false) -> some View {
    VStack(spacing: 2) {
        LabelText(label)
        Text(value.formatted()).font(T1.mono(22)).monospacedDigit().foregroundStyle(warn ? T1.error : T1.text)
    }.frame(maxWidth: .infinity)
}

/// A deck format as players write it.
func formatName(_ format: String) -> String {
    switch format {
    case "canlander": "Canadian Highlander"
    case "premodern": "Premodern"
    default: format.capitalized
    }
}

// MARK: lists of one kind

struct ListsView: View {
    let kind: CardList.Kind
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: ListsStore { ListsStore.shared }
    /// Each list's hero cards, as the printings it holds.
    @State private var heroArt: [String: [CatalogPrinting]] = [:]

    var body: some View {
        let lists = store.lists(kind)
        let owned = ownedByPrinting()
        T1Screen {
            Bar(title: kind == .deck ? "Decks" : "Cubes", subtitle: "\(lists.count)", back: { dismiss() })
            HairlineList {
                Button {
                    T1Overlays.shared.present {
                        NewListPanel(kind: kind, created: { id in path.append(.list(id)) }, find: { path.append(.findDeck) },
                                     importList: { path.append(.importList(kind)) })
                    }
                } label: {
                    ListRow(title: kind == .deck ? "New deck" : "New cube", detail: "Name it, then add cards")
                }.buttonStyle(.plain)
                ForEach(lists) { l in
                    let miss = missing(in: l, owned: owned)
                    Button { path.append(.list(l.id)) } label: {
                        HeroListRow(heroes: heroArt[l.id] ?? [], title: l.name, detail: detail(l, missing: miss)) {
                            Text(l.count("main").formatted()).font(T1.mono(17)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .task(id: "\(HeroesStore.shared.heroes)-\(CatalogStore.shared.generation)-\(lists.map { "\($0.id)\($0.current?.number ?? 0)" })") {
            guard let db = CatalogStore.shared.db else { return }
            let wanted = lists.compactMap { l -> (String, [String], [String])? in
                let h = HeroesStore.shared.heroes(.list(l.id))
                return h.isEmpty ? nil : (l.id, h, l.entries.sorted { $0.qty > $1.qty }.map(\.cardId))
            }
            heroArt = await Task.detached(priority: .userInitiated) {
                Dictionary(wanted.map { ($0.0, HeroArt.printings($0.1, held: $0.2, db)) }, uniquingKeysWith: { a, _ in a })
            }.value
        }
    }

    private func detail(_ l: CardList, missing: Int) -> String {
        let side = l.count("side"), maybe = l.count("maybe")
        let have: String = l.eventName.map { "From \($0)" } ?? (missing == 0 ? "All owned" : "\(missing) missing")
        let parts: [String?] = [formatName(l.format), side > 0 ? "\(side) sideboard" : nil, maybe > 0 ? "\(maybe) considering" : nil,
                                have, "v\(l.current?.number ?? 1)"]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: resolving entries to cards

struct ListLine: Identifiable, Hashable {
    let id: String
    let cardId: String
    let printing: CatalogPrinting?
    let oracleId: String?
    let name: String
    /// The section heading it sits under (type for decks, color for cubes, or the Group by picked).
    var group: String
    let board: String
    let qty: Int
    /// Its group under each grouping (Group by in the View menu).
    var keys = GroupKeys()
    /// The card's legality code (`CatalogPack.legalityFormats`).
    var legal: String = ""
    var finish: String = "nonfoil"
    /// Canadian Highlander points for one copy (0 = none).
    var points: Int = 0
    /// Basic lands are exempt from singleton rules.
    var basic: Bool = false
    var type: String = ""
    /// Key into `ownedByPrinting()`.
    var ownKey: String { "\(cardId)|\(finish)" }
    /// "Foil" / "Etched" for those lines; nil for non-foil.
    var finishLabel: String? { finish == "nonfoil" ? nil : finish.capitalized }

    static let typeOrder = ["Creatures", "Planeswalkers", "Instants", "Sorceries", "Artifacts", "Enchantments", "Battles", "Lands", "Other"]
    static let colorOrder = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"]

    /// Decks group by card type; cubes by color (from mana cost; lands in their own group).
    nonisolated static func resolve(_ entries: [CardList.Entry], kind: CardList.Kind, _ db: CatalogDB) -> [ListLine] {
        let printings = db.printings(ids: entries.map(\.cardId))
        let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
        return entries.enumerated().map { i, e in
            let o = printings[e.cardId].flatMap { oracles[$0.oracleIdx] }
            let type = o?.typeLine.components(separatedBy: " // ").first ?? ""
            let keys = GroupKeys(o)
            return ListLine(id: "\(e.board)-\(i)", cardId: e.cardId, printing: printings[e.cardId], oracleId: o?.oracleId,
                            name: o?.name ?? "Unknown card", group: keys[kind == .deck ? .type : .color], board: e.board, qty: e.qty,
                            keys: keys, legal: o?.legal ?? "", finish: e.finish,
                            points: o?.points ?? 0, basic: type.contains("Basic"), type: o?.typeLine ?? "")
        }
        .sorted { $0.name < $1.name }
    }

    /// The list's own lines whose card matches a search (name or type), by name: what Remove or replace offers.
    static func matching(_ lines: [ListLine], _ query: String) -> [ListLine] {
        guard !CardName.norm(query).isEmpty else { return [] }
        return lines.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }
            .sorted { $0.name != $1.name ? $0.name < $1.name : (boardOrderIndex($0.board), $0.finish) < (boardOrderIndex($1.board), $1.finish) }
    }

    private static func boardOrderIndex(_ b: String) -> Int { CardList.boardOrder.firstIndex(of: b) ?? 9 }

    nonisolated static func typeGroup(_ t: String) -> String {
        if t.contains("Creature") { return "Creatures" }
        if t.contains("Planeswalker") { return "Planeswalkers" }
        if t.contains("Land") { return "Lands" }
        if t.contains("Instant") { return "Instants" }
        if t.contains("Sorcery") { return "Sorceries" }
        if t.contains("Artifact") { return "Artifacts" }
        if t.contains("Enchantment") { return "Enchantments" }
        if t.contains("Battle") { return "Battles" }
        return "Other"
    }

    nonisolated static func colorGroup(_ cost: String) -> String {
        let colors = ["W": "White", "U": "Blue", "B": "Black", "R": "Red", "G": "Green"].filter { cost.contains($0.key) }
        if colors.count > 1 { return "Multicolor" }
        return colors.first?.value ?? "Colorless"
    }

    /// Why each card can't be played in the deck's format, by oracle id: banned, not legal, a restricted card with
    /// more than one copy across the main deck and sideboard, or (Canadian Highlander) a second copy of a non-basic
    /// card. Cubes and unchecked formats have none.
    static func issues(_ lines: [ListLine], list: CardList) -> [String: String] {
        guard list.kind == .deck else { return [:] }
        let singleton = list.format == "canlander"
        var copies: [String: Int] = [:]
        for l in lines where l.board != "maybe" { copies[l.oracleId ?? l.cardId, default: 0] += l.qty }
        var out: [String: String] = [:]
        for l in lines {
            let key = l.oracleId ?? l.cardId
            switch CatalogPack.legality(l.legal, list.format) {
            case "banned": out[key] = "Banned"
            case "not_legal": out[key] = "Not legal"
            case "restricted" where (copies[key] ?? 0) > 1: out[key] = "Restricted to 1"
            default:
                if singleton && !l.basic && (copies[key] ?? 0) > 1 { out[key] = "Singleton" }
            }
        }
        return out
    }

    /// Canadian Highlander points in the main deck and sideboard (Considering doesn't count), with the cards that
    /// carry them, highest first.
    static func points(_ lines: [ListLine]) -> (total: Int, cards: [(name: String, points: Int)]) {
        var byName: [String: Int] = [:]
        for l in lines where l.board != "maybe" && l.points > 0 { byName[l.name, default: 0] += l.points * l.qty }
        let cards = byName.map { (name: $0.key, points: $0.value) }.sorted { $0.points != $1.points ? $0.points > $1.points : $0.name < $1.name }
        return (cards.reduce(0) { $0 + $1.points }, cards)
    }

    static func groups(_ lines: [ListLine], kind: CardList.Kind) -> [String] {
        groups(lines, by: kind == .deck ? .type : .color)
    }

    static func groups(_ lines: [ListLine], by: CardGrouping) -> [String] { by.sorted(lines.map(\.group)) }

    /// The lines under another grouping.
    static func regrouped(_ lines: [ListLine], by: CardGrouping) -> [ListLine] {
        lines.map { l in var l = l; l.group = l.keys[by]; return l }
    }
}

/// One card's lines in one section (its printings and finishes), shown as one row until opened. Name order is kept;
/// inside, the line with the most copies leads.
struct LineGroup: Identifiable {
    let id: String
    let lines: [ListLine]
    var lead: ListLine { lines[0] }
    var qty: Int { lines.reduce(0) { $0 + $1.qty } }
    var key: String { lead.oracleId ?? lead.cardId }

    static func of(_ lines: [ListLine]) -> [LineGroup] {
        var order: [String] = []
        var by: [String: [ListLine]] = [:]
        for l in lines {
            let k = "\(l.board)|\(l.oracleId ?? l.cardId)"
            if by[k] == nil { order.append(k) }
            by[k, default: []].append(l)
        }
        return order.map { k in
            LineGroup(id: k, lines: by[k]!.sorted { $0.qty != $1.qty ? $0.qty > $1.qty : $0.id < $1.id })
        }
    }
}

/// A section title that reads above the group headers: "MAIN DECK · 60".
struct BoardHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title.uppercased()).font(T1.mono(13)).tracking(2)
            Spacer(minLength: 0)
            Text(count.formatted()).font(T1.mono(15)).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(T1.surfaceHover)
    }
}

// MARK: one list

struct ListDetailView: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    /// Card names, art and groups, looked up once per card; quantities always come from the live list.
    @State private var meta: [String: ListLine] = [:]
    @State private var editing = false
    @State private var query = ""
    @AppStorage("library.list.layout") private var layout = CardLayout.list.rawValue
    @AppStorage("library.deck.grouping") private var deckGrouping = CardGrouping.type.rawValue
    @AppStorage("library.cube.grouping") private var cubeGrouping = CardGrouping.color.rawValue
    @State private var printings = PrintingsDisclosure()
    private var heroScope: HeroScope { .list(listId) }

    /// Group by, kept apart for decks (Type) and cubes (Color).
    private var grouping: CardGrouping {
        let kind = ListsStore.shared.list(id: listId)?.kind ?? .deck
        return CardGrouping(rawValue: kind == .deck ? deckGrouping : cubeGrouping) ?? (kind == .deck ? .type : .color)
    }

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        // A roto deck's cards come from the cube, never from your collection: treat every line as covered.
        let owned = list.flatMap { $0.eventId == nil ? nil : eventCover($0) } ?? ownedByPrinting()
        let rows = list.map { lines(for: $0) } ?? []
        let issues = list.map { ListLine.issues(rows, list: $0) } ?? [:]
        let shown = query.isEmpty ? rows : rows.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }
        T1Screen {
            Bar(title: list?.name ?? "List", subtitle: list.map(subtitle), back: { dismiss() }) {
                HStack(spacing: 20) {
                    BarButton(editing ? "Done" : "Edit") { editing.toggle() }
                    if !editing {
                        BarButton("View") {
                            CardLayout.menu($layout, screen: list?.kind == .cube ? "cube" : "deck", printings: $printings,
                                            grouping: list?.kind == .cube ? $cubeGrouping : $deckGrouping, list: true)
                        }
                    }
                }
            }
            CatalogStatusRow(catalog: catalog)
            if let error = ListsStore.shared.error { Notice(error, error: true) }
            if let list {
                if !list.entries.isEmpty { T1SearchField(text: $query, prompt: list.kind == .cube ? "Search this cube" : "Search this deck") }
                if layout == CardLayout.grid.rawValue && !editing {
                    gridBody(list, rows: rows, shown: shown, owned: owned, issues: issues)
                } else if layout == CardLayout.stacks.rawValue && !editing {
                    stacksBody(list, rows: rows, shown: shown, owned: owned, issues: issues)
                } else {
                    HairlineList {
                        // While searching, matches come first: the summary rows would push them under the keyboard.
                        if query.isEmpty { top(list, owned: owned, rows: rows, issues: issues) }
                        if shown.isEmpty && !query.isEmpty { ListRow(title: "No cards match") }
                        ForEach(list.boards.filter { b in query.isEmpty || shown.contains { $0.board == b } }, id: \.self) { board in
                            let lines = shown.filter { $0.board == board }
                            BoardHeader(title: list.boardTitle(board), count: lines.reduce(0) { $0 + $1.qty })
                            ForEach(ListLine.groups(lines, by: grouping), id: \.self) { g in
                                let inGroup = lines.filter { $0.group == g }
                                Section1("\(grouping.label(g)) · \(inGroup.reduce(0) { $0 + $1.qty })")
                                if editing {
                                    ForEach(inGroup) { line in editRow(line, list: list) }
                                } else {
                                    ForEach(LineGroup.of(inGroup)) { cg in groupRows(cg, owned: owned, issue: issues[cg.key]) }
                                }
                            }
                        }
                    }
                }
            } else {
                Notice("That list isn't here anymore.", error: true)
            }
        }
        // Re-resolve only when a card the view hasn't seen appears (not on every count change).
        .task(id: "\(catalog.generation)-\(listId)-\(Set(list?.entries.map(\.cardId) ?? []).subtracting(meta.keys).count)") {
            catalog.load(userInitiated: true)
            guard let db = catalog.db, let list = ListsStore.shared.list(id: listId) else { return }
            let entries = list.entries, kind = list.kind
            let resolved = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: kind, db) }.value
            for line in resolved { meta[line.cardId] = line }
        }
        .searchUsed(query, screen: ListsStore.shared.list(id: listId)?.kind == .deck ? "deck" : "cube")
        #if DEBUG
        // Design QA: `-T1LibraryDemo deck|cube -T1ListExport <format>` exports once the card data is in.
        .task(id: catalog.db == nil) {
            let args = ProcessInfo.processInfo.arguments
            guard catalog.db != nil, T1Overlays.shared.panels.isEmpty, let i = args.firstIndex(of: "-T1ListExport"), i + 1 < args.count,
                  let f = ListExport.Format(rawValue: args[i + 1]), let list = ListsStore.shared.list(id: listId) else { return }
            exportList(list, f)
        }
        // Design QA: `-T1LibraryDemo deck -T1DeckImage` opens Deck image once the card data is in.
        .task(id: catalog.db == nil) {
            guard catalog.db != nil, T1Overlays.shared.panels.isEmpty, ProcessInfo.processInfo.arguments.contains("-T1DeckImage"),
                  let list = ListsStore.shared.list(id: listId), list.kind == .deck else { return }
            deckImage(list)
        }
        #endif
    }

    private func deckImage(_ list: CardList) {
        let entries = list.entries
        T1Overlays.shared.present(full: true) {
            DeckImagePanel(name: list.name, format: list.format, entries: entries, from: "own").screen("deck_image")
        }
    }

    private func exportList(_ list: CardList, _ format: ListExport.Format = .text) {
        let entries = list.entries
        T1Overlays.shared.present(full: true) {
            ListExportPanel(name: list.name, kind: list.kind, entries: entries, from: "own", format: format).screen("list_export")
        }
    }

    /// The list's current lines: live quantities and sections, with card details from `meta`.
    private func lines(for list: CardList) -> [ListLine] {
        list.entries.compactMap { e in
            guard let m = meta[e.cardId] else { return nil }
            return ListLine(id: "\(e.board)|\(e.cardId)|\(e.finish)", cardId: e.cardId, printing: m.printing, oracleId: m.oracleId,
                            name: m.name, group: m.keys[grouping], board: e.board, qty: e.qty, keys: m.keys, legal: m.legal, finish: e.finish,
                            points: m.points, basic: m.basic, type: m.type)
        }
        .sorted { $0.name < $1.name }
    }

    /// Summary, Add cards and Version history: the same in every layout.
    @ViewBuilder private func top(_ list: CardList, owned: [String: Int], rows: [ListLine], issues: [String: String]) -> some View {
        WhoSeesRow(kind: list.kind == .cube ? "cube" : "deck", id: list.id, name: list.name)
        if !issues.isEmpty {
            // Considering cards are flagged on their rows but don't make the deck unplayable.
            let bad = Array(Set(rows.filter { $0.board != "maybe" && issues[$0.oracleId ?? $0.cardId] != nil }.map(\.name))).sorted()
            if !bad.isEmpty {
                let names = bad.prefix(3).joined(separator: ", ") + (bad.count > 3 ? " and \(bad.count - 3) more" : "")
                Notice("\(bad.count == 1 ? "1 card isn't" : "\(bad.count) cards aren't") legal in \(formatName(list.format)): \(names)", error: true)
            }
        }
        if list.kind == .deck && list.format == "canlander" {
            let pts = ListLine.points(rows)
            let limit = CatalogPack.canlanderPointLimit
            let detail = pts.cards.prefix(6).map { "\($0.name) \($0.points)" }.joined(separator: ", ") + (pts.cards.count > 6 ? ", …" : "")
            if pts.total > limit {
                Notice("Over the points limit: \(pts.total) of \(limit). \(detail)", error: true)
            } else if pts.total > 0 {
                Notice("Points: \(pts.total) of \(limit). \(detail)")
            }
            let main = list.count("main")
            if main < 100 { Notice("Canadian Highlander decks need at least 100 cards: \(main) so far.") }
        }
        if editing {
            Button {
                if let copy = ListsStore.shared.duplicate(listId: list.id) {
                    editing = false
                    path.append(.list(copy.id))
                }
            } label: {
                ListRow(title: list.kind == .deck ? "Duplicate deck" : "Duplicate cube", detail: "A new list with these cards")
            }.buttonStyle(.plain)
            Button {
                T1Overlays.shared.showMenu("Delete \(list.name)?", message: "It goes from every device. This can't be undone.", [
                    T1MenuItem(title: list.kind == .deck ? "Delete deck" : "Delete cube", destructive: true) {
                        ListsStore.shared.delete(listId: list.id)
                        dismiss()
                    },
                ])
            } label: {
                ListRow(title: list.kind == .deck ? "Delete deck" : "Delete cube", detail: "From every device")
            }.buttonStyle(.plain)
        }
        if !editing { ListStatsRow(listId: list.id, path: $path) }
        Button { path.append(.listAdd(list.id)) } label: {
            ListRow(title: "Add, remove or replace", detail: list.kind == .deck ? "Main deck, sideboard or considering" : "Search the catalog, or this cube's own cards")
        }.buttonStyle(.plain)
        historyRow(list)
        if !list.entries.isEmpty && !editing {
            Button { exportList(list) } label: {
                ListRow(title: "Export", detail: list.kind == .deck ? "Text, Arena, MTGO, download or copy" : "Text, Cube Cobra, download or copy")
            }.buttonStyle(.plain)
            if list.kind == .deck {
                Button { deckImage(list) } label: {
                    ListRow(title: "Deck image", detail: "The cards as a picture, to save or share")
                }.buttonStyle(.plain)
            }
        }
        if list.entries.isEmpty { ListRow(title: "No cards yet", detail: "Add cards to start this list") }
    }

    private func subtitle(_ l: CardList) -> String {
        if let event = l.eventName { return "From \(event) · v\(l.current?.number ?? 1)" }
        return "\(formatName(l.format)) \(l.kind == .deck ? "deck" : "cube") · v\(l.current?.number ?? 1)"
    }

    /// Every line's own count, so nothing reads as missing.
    private func eventCover(_ l: CardList) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in l.entries { out["\(e.cardId)|\(e.finish)", default: 0] += e.qty }
        return out
    }

    private func historyRow(_ list: CardList) -> some View {
        Button { path.append(.versions(list.id)) } label: {
            ListRow(title: "Version history", detail: list.current.map { "v\($0.number) · \($0.note) · \($0.at.formatted(shortDate))" }) {
                Text("\(list.versions.count)").font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }

    /// A card with one line is that line's row; with several, a summary row with a chevron that opens one row per
    /// printing and finish.
    @ViewBuilder private func groupRows(_ cg: LineGroup, owned: [String: Int], issue: String?) -> some View {
        if cg.lines.count == 1 {
            lineRow(cg.lead, owned: owned[cg.lead.ownKey] ?? 0, issue: issue)
        } else {
            let open = printings.open(cg.id)
            let hero = HeroesStore.shared.isHero(cg.lead.oracleId, heroScope)
            let considering = cg.lead.board == "maybe"
            let eventDeck = ListsStore.shared.list(id: listId)?.eventId != nil
            let short = cg.lines.reduce(0) { $0 + max(0, $1.qty - (owned[$1.ownKey] ?? 0)) }
            let have = cg.lines.reduce(0) { $0 + (owned[$1.ownKey] ?? 0) }
            let haveText: String? = eventDeck ? nil : considering ? (have > 0 ? "Owned \(have)" : "Not owned") : short > 0 ? "Missing \(short)" : "All owned"
            HStack(spacing: 1) {
                Button { if let o = cg.lead.oracleId { path.append(.cardIn(o, .list(listId))) } } label: {
                    CardRow(printing: cg.lead.printing, title: cg.lead.name,
                            detail: [issue, "\(cg.lines.count) printings", haveText].compactMap { $0 }.joined(separator: " · "),
                            finish: cg.lead.finish, hero: hero) {
                        Text("\(cg.qty)").font(T1.mono(17)).monospacedDigit()
                            .foregroundStyle((!considering && short > 0) || issue != nil ? T1.error : T1.text)
                    }
                }.buttonStyle(.plain)
                PrintingsChevron(open: open, hero: hero) {
                    printings.toggle(cg.id)
                    Telemetry.capture("printings_toggled", ["expanded": !open, "all": false, "screen": "list"])
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if open {
                ForEach(cg.lines) { line in
                    lineRow(line, owned: owned[line.ownKey] ?? 0, issue: issue, sub: true).padding(.leading, 24).background(T1.surface)
                }
            }
        }
    }

    private func lineRow(_ line: ListLine, owned: Int, issue: String?, sub: Bool = false) -> some View {
        let considering = line.board == "maybe"
        let short = !considering && owned < line.qty
        let eventDeck = ListsStore.shared.list(id: listId)?.eventId != nil
        let have: String? = eventDeck ? nil : considering ? (owned > 0 ? "Owned \(owned)" : "Not owned")
            : short ? "Owned \(owned) · missing \(line.qty - owned)" : "Owned \(owned)"
        let pts = line.points > 0 && ListsStore.shared.list(id: listId)?.format == "canlander" ? "\(line.points) pt\(line.points == 1 ? "" : "s")" : nil
        let detail = [sub ? nil : issue, pts, line.finishLabel, have].compactMap { $0 }.joined(separator: " · ")
        return Button {
            if let o = line.oracleId { path.append(.cardIn(o, .list(listId))) }
        } label: {
            CardRow(printing: line.printing, title: sub ? (line.printing?.setLabel ?? line.name) : line.name, detail: detail,
                    finish: line.finish, hero: !sub && HeroesStore.shared.isHero(line.oracleId, heroScope)) {
                Text("\(line.qty)").font(T1.mono(17)).monospacedDigit().foregroundStyle(short || issue != nil ? T1.error : T1.text)
            }
        }.buttonStyle(.plain)
    }

    /// Edit mode: − and + change the count; tapping the card offers moving it between sections or removing it.
    private func editRow(_ line: ListLine, list: CardList) -> some View {
        let store = ListsStore.shared
        return HStack(spacing: 1) {
            Button {
                let others = list.kind == .deck ? ["main", "side", "maybe"] : ["main", "maybe"]
                T1Overlays.shared.showMenu(line.name, others.filter { $0 != line.board }.map { b in
                    T1MenuItem(title: "Move to \(list.boardTitle(b))") {
                        store.move(listId: list.id, cardId: line.cardId, finish: line.finish, from: line.board, to: b)
                    }
                } + [T1MenuItem(title: "Change printing or finish", detail: "Or split copies between finishes") {
                    path.append(.linePrinting(list.id, line.cardId, line.board, line.finish))
                }] + (line.oracleId.map { o in
                    let on = HeroesStore.shared.isHero(o, .list(list.id))
                    return [T1MenuItem(title: on ? "Not a hero card" : "Make it a hero card",
                                       detail: on ? "Stop highlighting it" : "Highlighted here and in your \(list.kind == .deck ? "decks" : "cubes")") {
                        if !HeroesStore.shared.toggle(o, .list(list.id)) {
                            ListsStore.shared.error = "\(list.name) has \(HeroesStore.limit) hero cards already."
                        }
                    }]
                } ?? []) + [T1MenuItem(title: "Remove from \(list.boardTitle(line.board))", destructive: true) {
                    store.remove(listId: list.id, cardId: line.cardId, board: line.board, finish: line.finish)
                }])
            } label: {
                CardRow(printing: line.printing, title: line.name,
                        detail: [line.finishLabel, "Tap to move, change or remove"].compactMap { $0 }.joined(separator: " · "),
                        finish: line.finish, hero: HeroesStore.shared.isHero(line.oracleId, .list(list.id))) {
                    Text("\(line.qty)").font(T1.mono(17)).monospacedDigit()
                }
            }.buttonStyle(.plain)
            stepper("−") { store.add(listId: list.id, cardId: line.cardId, board: line.board, finish: line.finish, delta: -1) }
            stepper("+") { store.add(listId: list.id, cardId: line.cardId, board: line.board, finish: line.finish, delta: 1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stepper(_ glyph: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(T1.mono(22)).frame(width: 52).frame(maxHeight: .infinity).background(T1.surfaceHover)
        }.buttonStyle(.plain)
    }

    /// The grid keeps the list's organization: a header per section, then a sub-header per type (decks) or
    /// color (cubes), each followed by that group's cards.
    private func gridBody(_ list: CardList, rows: [ListLine], shown: [ListLine], owned: [String: Int], issues: [String: String]) -> some View {
        GeometryReader { geo in
            let width = ((geo.size.width - 2) / 3).rounded(.down)
            ScrollView {
                LazyVStack(spacing: 1) {
                    if query.isEmpty { top(list, owned: owned, rows: rows, issues: issues) }
                    ForEach(list.boards.filter { b in query.isEmpty || shown.contains { $0.board == b } }, id: \.self) { board in
                        let lines = shown.filter { $0.board == board }
                        BoardHeader(title: list.boardTitle(board), count: lines.reduce(0) { $0 + $1.qty })
                        // Ids carry the section: the lazy stack flattens these, and a bare group name ("Creature")
                        // in the sideboard would reuse the main deck's grid for that group.
                        ForEach(ListLine.groups(lines, by: grouping), id: \.self) { g in
                            let inGroup = lines.filter { $0.group == g }
                            Section1("\(grouping.label(g)) · \(inGroup.reduce(0) { $0 + $1.qty })").id("h|\(board)|\(g)")
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1), count: 3), spacing: 1) {
                                ForEach(tiles(inGroup, owned: owned, issues: issues)) { c in
                                    Button(action: c.open) {
                                        CardTile(printing: c.printing, name: c.name, qty: c.qty, warn: c.warn, width: width, finish: c.finish, hero: c.hero)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .id("g|\(board)|\(g)")
                        }
                    }
                }
            }
        }
    }
}

extension ListDetailView {
    /// Grid and stack cards for one group: one per card, or with every printing expanded, one per line.
    fileprivate func tiles(_ lines: [ListLine], owned: [String: Int], issues: [String: String]) -> [StackCard] {
        LineGroup.of(lines).flatMap { cg -> [StackCard] in
            let hero = HeroesStore.shared.isHero(cg.lead.oracleId, .list(listId))
            let open = { if let o = cg.lead.oracleId { path.append(.cardIn(o, .list(listId))) } }
            func warn(_ ls: [ListLine]) -> Bool {
                (cg.lead.board != "maybe" && ls.contains { (owned[$0.ownKey] ?? 0) < $0.qty }) || issues[cg.key] != nil
            }
            guard printings.all, cg.lines.count > 1 else {
                return [StackCard(id: cg.id, printing: cg.lead.printing, name: cg.lead.name, qty: cg.qty, warn: warn(cg.lines),
                                  finish: cg.lead.finish, hero: hero, open: open)]
            }
            return cg.lines.map { l in
                StackCard(id: l.id, printing: l.printing, name: l.name, qty: l.qty, warn: warn([l]), finish: l.finish, hero: hero, open: open)
            }
        }
    }

    /// Stacks keep the list's organization too: a header per section, then a stack per type (decks) or
    /// color (cubes), two to a row.
    fileprivate func stacksBody(_ list: CardList, rows: [ListLine], shown: [ListLine], owned: [String: Int], issues: [String: String]) -> some View {
        GeometryReader { geo in
            let width = ((geo.size.width - 1) / 2).rounded(.down)
            ScrollView {
                LazyVStack(spacing: 1) {
                    if query.isEmpty { top(list, owned: owned, rows: rows, issues: issues) }
                    ForEach(list.boards.filter { b in query.isEmpty || shown.contains { $0.board == b } }, id: \.self) { board in
                        let lines = shown.filter { $0.board == board }
                        BoardHeader(title: list.boardTitle(board), count: lines.reduce(0) { $0 + $1.qty })
                        let stacks = ListLine.groups(lines, by: grouping).map { g in
                            let inGroup = lines.filter { $0.group == g }
                            return (id: "s|\(board)|\(g)|\(printings.all)", title: Optional("\(grouping.label(g)) · \(inGroup.reduce(0) { $0 + $1.qty })"),
                                    cards: tiles(inGroup, owned: owned, issues: issues))
                        }
                        StackRows(stacks: stacks, width: width).id("st|\(board)")
                    }
                }
            }
        }
    }
}

// MARK: version history

struct ListVersionsView: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        T1Screen {
            Bar(title: "Version history", subtitle: list?.name, back: { dismiss() })
            if let list {
                HairlineList {
                    ForEach(Array(list.versions.enumerated().reversed()), id: \.element.number) { i, v in
                        let changes = CardList.diff(i > 0 ? list.versions[i - 1] : nil, v)
                        let added = changes.filter { $0.delta > 0 }.reduce(0) { $0 + $1.delta }
                        let removed = -changes.filter { $0.delta < 0 }.reduce(0) { $0 + $1.delta }
                        let parts: [String?] = [v.at.formatted(shortDate), i == 0 ? "first version" : "+\(added) −\(removed)",
                                                v.number == list.current?.number ? "current" : nil]
                        Button { path.append(.version(listId, v.number)) } label: {
                            ListRow(title: "v\(v.number) · \(v.note)", detail: parts.compactMap { $0 }.joined(separator: " · "))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct ListVersionView: View {
    let listId: String
    let number: Int
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var cards: [String: ListLine] = [:]
    @State private var restored: Int?

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let version = list?.version(number)
        let index = list?.versions.firstIndex { $0.number == number } ?? 0
        let previous = index > 0 ? list?.versions[index - 1] : nil
        let changes = version.map { CardList.diff(previous, $0) } ?? []
        T1Screen {
            Bar(title: "v\(number) · \(version?.note ?? "")", subtitle: list?.name, back: { dismiss() })
            if let restored { Notice("Restored as v\(restored). Every earlier version is still here.") }
            if let list, let version {
                HairlineList {
                    HStack(spacing: 0) {
                        statCell(list.kind == .deck ? "Main" : "Cards", version.entries.filter { $0.board == "main" }.reduce(0) { $0 + $1.qty })
                        if list.kind == .deck { statCell("Side", version.entries.filter { $0.board == "side" }.reduce(0) { $0 + $1.qty }) }
                        statCell("Considering", version.entries.filter { $0.board == "maybe" }.reduce(0) { $0 + $1.qty })
                    }
                    .padding(.vertical, 16).background(T1.surface)
                    ListRow(title: version.at.formatted(.dateTime.month(.wide).day().year()),
                            detail: previous.map { "Changes from v\($0.number)" } ?? "First version")
                    if previous != nil && changes.isEmpty { ListRow(title: "No card changes") }
                    if previous != nil {
                        ForEach(CardList.boardOrder.filter { b in changes.contains { $0.board == b } }, id: \.self) { board in
                            Section1(list.boardTitle(board))
                            ForEach(changes.filter { $0.board == board }, id: \.self) { c in changeRow(c) }
                        }
                    }
                    if number != list.current?.number {
                        BigAction(text: "Restore v\(number)") {
                            restored = ListsStore.shared.restore(listId: listId, version: number)?.number
                        }
                    }
                }
            }
        }
        .task(id: "\(catalog.generation)-\(listId)-\(number)") {
            catalog.load(userInitiated: true)
            guard let db = catalog.db, let list = ListsStore.shared.list(id: listId) else { return }
            let entries = changes.map { CardList.Entry(cardId: $0.cardId, board: $0.board, qty: abs($0.delta), finish: $0.finish) }
            let kind = list.kind
            let lines = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: kind, db) }.value
            cards = Dictionary(lines.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func changeRow(_ c: CardList.Change) -> some View {
        let card = cards[c.cardId]
        return Button { if let o = card?.oracleId { path.append(.card(o)) } } label: {
            CardRow(printing: card?.printing, title: card?.name ?? "…",
                    detail: [c.delta > 0 ? "Added" : "Removed", c.finish == "nonfoil" ? nil : c.finish.capitalized].compactMap { $0 }.joined(separator: " · ")) {
                Text(c.delta > 0 ? "+\(c.delta)" : "−\(-c.delta)").font(T1.mono(17)).monospacedDigit()
                    .foregroundStyle(c.delta > 0 ? T1.text : T1.error)
            }
        }.buttonStyle(.plain)
    }
}

/// The catalog's state as a row while it loads; nothing once it's ready.
struct CatalogStatusRow: View {
    let catalog: CatalogStore
    var body: some View {
        switch catalog.phase {
        case .ready: EmptyView()
        case .failed(let message): Notice(message, error: true)
        case .idle, .loading:
            LabelText("Loading card data…").frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 16).background(T1.surface)
        }
    }
}

// MARK: creating and adding

/// The panel for a new deck or cube: a name and a format.
struct NewListPanel: View {
    let kind: CardList.Kind
    let created: (String) -> Void
    /// Decks only: opens the deck finder instead.
    var find: (() -> Void)? = nil
    /// Opens the import screen (a link or a pasted list).
    var importList: (() -> Void)? = nil
    @State private var name = ""
    @State private var format = "modern"

    private var formats: [(String, String)] {
        kind == .deck
            ? [("modern", "Modern"), ("pioneer", "Pioneer"), ("standard", "Standard"), ("legacy", "Legacy"),
               ("vintage", "Vintage"), ("pauper", "Pauper"), ("commander", "Commander"), ("canlander", "Canlander"), ("other", "Other")]
            : [("vintage", "Vintage"), ("legacy", "Legacy"), ("pauper", "Pauper"), ("peasant", "Peasant"), ("other", "Other")]
    }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: kind == .deck ? "New deck" : "New cube") { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            Field(label: "Name", text: $name)
            T1Segmented(options: Array(formats.prefix(4)), selection: $format)
            if formats.count > 4 { T1Segmented(options: Array(formats.dropFirst(4)), selection: $format) }
            BigAction(text: kind == .deck ? "Create deck" : "Create cube",
                      enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                let l = ListsStore.shared.create(kind: kind, name: String(name.trimmingCharacters(in: .whitespaces).prefix(60)), format: format)
                T1Overlays.shared.dismissPanel()
                created(l.id)
            }
            if let importList {
                Button {
                    T1Overlays.shared.dismissPanel()
                    importList()
                } label: {
                    ListRow(title: "Import from a link or list",
                            detail: kind == .deck ? "Moxfield, ManaBox, Archidekt, MTGGoldfish" : "Cube Cobra, or a pasted list")
                }.buttonStyle(.plain)
            }
            if kind == .deck, let find {
                Button {
                    T1Overlays.shared.dismissPanel()
                    find()
                } label: {
                    ListRow(title: "Find a deck online", detail: "Describe it; we load a recent tournament list")
                }.buttonStyle(.plain)
            }
        }
        .onAppear { if kind == .cube { format = "vintage" } }
    }
}

/// Add, remove or replace, like Cube Cobra's edit panel: an Add box (the catalog, Scryfall syntax, or the scanner) and
/// a Remove or replace box (only the list's own cards) on one screen. Pick a card in either box; with only Remove
/// picked the button removes one copy, with both picked it replaces that copy with the added card in the same section,
/// as one edit (so the history shows a swap). Each card goes in as its original paper printing unless a search or
/// scan named another; change it from the card page.
struct ListAddCardsView: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var addQuery = ""
    @State private var removeQuery = ""
    @State private var board = "main"
    @State private var result: CardSearchEngine.Result?
    /// The list's lines with names, for Remove or replace.
    @State private var lines: [ListLine] = []
    @State private var addPick: (oracle: CatalogOracle, printing: CatalogPrinting)?
    @State private var removePick: ListLine?
    @State private var note: String?
    @FocusState private var addFocused: Bool
    @FocusState private var removeFocused: Bool

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let sections = list?.kind == .cube ? ["main", "maybe"] : ["main", "side", "maybe"]
        T1Screen {
            Bar(title: "Edit \(list?.name ?? "list")", subtitle: list.map { "v\($0.current?.number ?? 1)" }) { BarButton("Done") { dismiss() } }
            CatalogStatusRow(catalog: catalog)
            if let list {
                if let note { Notice(note) }
                Section1("Add to")
                T1Segmented(options: sections.map { ($0, list.boardTitle($0)) }, selection: $board)
                if let pick = addPick {
                    picked(pick.printing, pick.oracle.name, list.boardTitle(removePick?.board ?? board)) { addPick = nil; addQuery = ""; addFocused = true }
                } else {
                    CardSearchBar(query: $addQuery, prompt: "Card to add", scan: { scan(list) }, focused: $addFocused) { pickTopHit() }
                }
                Section1("Remove or replace")
                if let r = removePick {
                    picked(r.printing, r.name, [list.boardTitle(r.board), r.finishLabel].compactMap { $0 }.joined(separator: " · ")) {
                        removePick = nil; removeQuery = ""; removeFocused = true
                    }
                } else {
                    T1SearchField(text: $removeQuery, prompt: list.kind == .cube ? "Card in this cube" : "Card in this deck")
                        .focused($removeFocused).onSubmit { if let first = ListLine.matching(lines, removeQuery).first { pickRemove(first) } }
                }
                actions(list)
                HairlineList {
                    if showingRemove { removeRows(list) } else { addRows(list) }
                }
            }
        }
        .onAppear {
            catalog.load(userInitiated: true)
            addFocused = true
        }
        .task(id: "\(addQuery)-\(catalog.generation)") {
            guard let db = catalog.db, addPick == nil else { return }
            let q = addQuery
            try? await Task.sleep(for: CardSearchEngine.debounce(q))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { await CardSearchEngine.run(q, db) }.value
            if !Task.isCancelled { result = found }
        }
        .task(id: "\(catalog.generation)-\(list?.current?.number ?? 0)-\(list?.entries.count ?? 0)-\(list?.entries.reduce(0) { $0 + $1.qty } ?? 0)") {
            guard let db = catalog.db, let list else { return }
            let entries = list.entries, kind = list.kind
            lines = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: kind, db) }.value
        }
    }

    /// The list shows the box being typed in: the list's own cards while Remove or replace is in use.
    private var showingRemove: Bool { removePick == nil && (removeFocused || (!removeQuery.isEmpty && addQuery.isEmpty)) }

    /// Add, and Remove (Replace once a card to add is picked too).
    private func actions(_ list: CardList) -> some View {
        let replacing = addPick != nil && removePick != nil
        return HStack(spacing: 1) {
            editAction("Add", enabled: addPick != nil) { add(list) }
            editAction(replacing ? "Replace" : "Remove", enabled: removePick != nil) { removeOrReplace(list) }
        }
    }

    /// White when it can run, the flat disabled fill when it can't.
    private func editAction(_ text: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(text.uppercased()).font(T1.mono(13, .bold)).tracking(3).foregroundStyle(T1.ink)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(enabled ? T1.text : T1.disabled)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .sensoryFeedback(.impact, trigger: note)
    }

    /// A picked card in place of its box, with Clear.
    private func picked(_ p: CatalogPrinting?, _ name: String, _ detail: String, clear: @escaping () -> Void) -> some View {
        CardRow(printing: p, title: name, detail: detail) { BarButton("Clear", action: clear) }
    }

    private func pickTopHit() {
        guard let o = result?.hits.first, let p = result?.covers[o.idx] else { return }
        pickAdd(o, p)
    }

    private func pickAdd(_ o: CatalogOracle, _ p: CatalogPrinting) {
        addPick = (o, p)
        addQuery = o.name
        addFocused = false
    }

    private func pickRemove(_ line: ListLine) {
        removePick = line
        removeQuery = line.name
        removeFocused = false
    }

    private func finish(_ p: CatalogPrinting) -> String { p.finishList.first?.rawValue ?? "nonfoil" }

    private func add(_ list: CardList) {
        guard let a = addPick else { return }
        ListsStore.shared.add(listId: listId, cardId: a.printing.cardId, board: board, finish: finish(a.printing), delta: 1)
        Telemetry.capture("list_card_added", ["kind": list.kind.rawValue, "from": "edit"])
        note = "Added 1 \(a.oracle.name) to \(list.boardTitle(board))"
        reset()
    }

    private func removeOrReplace(_ list: CardList) {
        guard let r = removePick else { return }
        if let a = addPick {
            ListsStore.shared.replaceCard(listId: listId, cardId: r.cardId, board: r.board, finish: r.finish,
                                          with: a.printing.cardId, toFinish: finish(a.printing))
            note = "Replaced \(r.name) with \(a.oracle.name) in \(list.boardTitle(r.board))"
        } else {
            ListsStore.shared.add(listId: listId, cardId: r.cardId, board: r.board, finish: r.finish, delta: -1)
            Telemetry.capture("list_card_removed", ["kind": list.kind.rawValue])
            note = "Removed 1 \(r.name) from \(list.boardTitle(r.board))"
        }
        reset()
    }

    private func reset() {
        addPick = nil
        removePick = nil
        addQuery = ""
        removeQuery = ""
        addFocused = true
    }

    /// Scanned cards go into the chosen section as one edit, each in the printing and finish the scanner read.
    private func scan(_ list: CardList) {
        addFocused = false
        removeFocused = false
        let target = board
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: "Scan into \(list.boardTitle(target))", doneLabel: "Add", onDone: { cards in
                Telemetry.capture("scan_session_ended", ["context": list.kind.rawValue, "cards": cards.count,
                                                         "exact": cards.filter(\.exact).count, "cancelled": false])
                T1Overlays.shared.dismissPanel()
                guard !cards.isEmpty else { return }
                ListsStore.shared.addMany(listId: list.id, board: target, cards: cards.map { ($0.printing.cardId, $0.finish) })
                note = "Added \(cards.count) scanned card\(cards.count == 1 ? "" : "s") to \(list.boardTitle(target))"
            }, onCancel: {
                Telemetry.capture("scan_session_ended", ["context": list.kind.rawValue, "cards": 0, "exact": 0, "cancelled": true])
                T1Overlays.shared.dismissPanel()
            })
            .screen("card_scanner")
        }
    }

    /// Catalog hits: tap to pick (then Add or Replace), or + to add one straight away.
    @ViewBuilder private func addRows(_ list: CardList) -> some View {
        if addPick == nil {
            CardSearchStatus(query: addQuery, result: result)
            if addQuery.isEmpty && removeQuery.isEmpty {
                Notice("Pick a card to add, a card to remove, or both: with both, Replace swaps them in the same section. + adds a card at once.")
            }
            let target = board
            ForEach(addQuery.isEmpty ? [] : result?.hits ?? [], id: \.idx) { o in
                let p = result?.covers[o.idx]
                let inList = p.map { pc in list.entries.filter { $0.cardId == pc.cardId && $0.board == target }.reduce(0) { $0 + $1.qty } } ?? 0
                HStack(spacing: 1) {
                    Button { if let p { pickAdd(o, p) } } label: {
                        CardRow(printing: p, title: o.name, detail: inList > 0 ? "\(inList) in \(list.boardTitle(target))" : o.typeLine)
                    }.buttonStyle(.plain)
                    Button {
                        guard let p else { return }
                        ListsStore.shared.add(listId: listId, cardId: p.cardId, board: target, finish: finish(p), delta: 1)
                        Telemetry.capture("list_card_added", ["kind": list.kind.rawValue, "from": "quick"])
                        note = "Added 1 \(o.name) to \(list.boardTitle(target))"
                    } label: {
                        Text("+").font(T1.mono(22)).foregroundStyle(p == nil ? T1.disabled : T1.text)
                            .frame(width: 52).frame(maxHeight: .infinity).background(T1.surfaceHover)
                    }
                    .buttonStyle(.plain).disabled(p == nil)
                    .accessibilityLabel("Add \(o.name)")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Only the list's own cards; tap one to pick it for Remove or Replace.
    @ViewBuilder private func removeRows(_ list: CardList) -> some View {
        let found = ListLine.matching(lines, removeQuery)
        if CardName.norm(removeQuery).isEmpty {
            Notice("Search the cards in \(list.name). Remove takes one copy out; with a card picked to add, Replace swaps it in the same section.")
        } else if found.isEmpty {
            ListRow(title: "No card in \(list.name) matches")
        }
        ForEach(found) { line in
            let qty = list.entries.first { $0.cardId == line.cardId && $0.board == line.board && $0.finish == line.finish }?.qty ?? line.qty
            Button { pickRemove(line) } label: {
                CardRow(printing: line.printing, title: line.name,
                        detail: [list.boardTitle(line.board), line.finishLabel, qty > 1 ? "\(qty) copies" : nil].compactMap { $0 }.joined(separator: " · "),
                        finish: line.finish)
            }.buttonStyle(.plain)
        }
    }
}

// MARK: deck finder

/// The deck-finder function's answer (contract/deck-finder-2026-10-15.md).
struct DeckFinderResult: Decodable {
    struct Line: Decodable, Hashable { let qty: Int; let name: String }
    struct Deck: Decodable {
        let name: String
        let archetype: String
        let format: String
        let event: String
        let date: String
        let placement: String
        let player: String
        let sourceUrl: String
        let notes: String
        let main: [Line]
        let side: [Line]
    }
    let status: String
    var question: String?
    var options: [String]?
    var message: String?
    var deck: Deck?
    var error: String?

    enum CodingKeys: String, CodingKey { case status, question, options, message, deck, error }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "error"
        question = try c.decodeIfPresent(String.self, forKey: .question)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? error
        deck = try c.decodeIfPresent(Deck.self, forKey: .deck)
    }
}

/// Describe a deck in plain words; an agent finds a recent tournament list, asks when the request is
/// ambiguous, and the list is created with each card's original paper printing.
struct DeckFinderView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    private struct Answer: Encodable { let question: String; let answer: String }
    private struct Request: Encodable { let query: String; let format: String; let answers: [Answer] }

    @State private var query = ""
    @State private var format = "modern"
    @State private var answers: [Answer] = []
    @State private var searching = false
    @State private var result: DeckFinderResult?
    @State private var reply = ""
    /// Card names resolved to printings; names missing from the card data are listed so nothing is dropped silently.
    @State private var resolved: [String: CatalogPrinting] = [:]
    @FocusState private var focused: Bool

    private let formats: [(String, String)] = [("modern", "Modern"), ("pioneer", "Pioneer"), ("standard", "Standard"), ("legacy", "Legacy"),
                                               ("vintage", "Vintage"), ("pauper", "Pauper"), ("commander", "Commander"), ("premodern", "Premodern")]

    var body: some View {
        T1Screen {
            Bar(title: "Find a deck", subtitle: "Recent tournament lists", back: { dismiss() })
            CatalogStatusRow(catalog: catalog)
            HairlineList {
                Field(label: "Describe the deck", text: $query).focused($focused)
                T1Segmented(options: Array(formats.prefix(4)), selection: $format)
                T1Segmented(options: Array(formats.dropFirst(4)), selection: $format)
                if result == nil || result?.status != "deck" {
                    BigAction(text: searching ? "Searching…" : "Find deck", enabled: !searching && query.trimmingCharacters(in: .whitespaces).count >= 3) {
                        answers = []
                        Task { await search() }
                    }
                }
                if searching {
                    Notice("Searching mtgdecks, melee.gg, MTGGoldfish and MTGO results for the newest strong finishes. This can take a minute or two.")
                }
                if let r = result, !searching { resultBody(r) }
            }
        }
        .onAppear { catalog.load(userInitiated: true); focused = true }
    }

    @ViewBuilder private func resultBody(_ r: DeckFinderResult) -> some View {
        switch r.status {
        case "question":
            Section1(r.question ?? "Which deck?")
            ForEach(r.options ?? [], id: \.self) { option in
                Button { answer(option) } label: { ListRow(title: option) }.buttonStyle(.plain)
            }
            Field(label: "Or type an answer", text: $reply)
            BigAction(text: "Answer", enabled: !reply.trimmingCharacters(in: .whitespaces).isEmpty) { answer(reply) }
        case "deck":
            if let d = r.deck { deckBody(d) }
        default:
            Notice(r.message ?? "Nothing turned up. Try naming the archetype.", error: true)
        }
    }

    @ViewBuilder private func deckBody(_ d: DeckFinderResult.Deck) -> some View {
        let names = (d.main + d.side).map(\.name)
        let missing = Array(Set(names.filter { resolved[$0] == nil })).sorted()
        let mainCount = d.main.reduce(0) { $0 + $1.qty }, sideCount = d.side.reduce(0) { $0 + $1.qty }
        ListRow(title: d.name, detail: [d.placement, d.event, d.date].filter { !$0.isEmpty }.joined(separator: " · "))
        if !d.player.isEmpty || !d.notes.isEmpty {
            Notice([d.player.isEmpty ? nil : "Played by \(d.player).", d.notes.isEmpty ? nil : d.notes].compactMap { $0 }.joined(separator: " "))
        }
        if let url = URL(string: d.sourceUrl), !d.sourceUrl.isEmpty {
            Link(destination: url) { ListRow(title: "Source", detail: url.host() ?? d.sourceUrl) }
        }
        if !missing.isEmpty {
            Notice("Not in the card data, left out: \(missing.joined(separator: ", "))", error: true)
        }
        BigAction(text: "Create deck · \(mainCount) + \(sideCount)", enabled: catalog.db != nil && resolved.count > 0) { create(d) }
        Button { result = nil } label: { ListRow(title: "Search again") }.buttonStyle(.plain)
        Section1("Main deck · \(mainCount)")
        ForEach(d.main, id: \.self) { line in
            CardRow(printing: resolved[line.name], title: line.name, detail: resolved[line.name] == nil ? "Not found" : nil) {
                Text("\(line.qty)").font(T1.mono(17)).monospacedDigit()
            }
        }
        if !d.side.isEmpty {
            Section1("Sideboard · \(sideCount)")
            ForEach(d.side, id: \.self) { line in
                CardRow(printing: resolved[line.name], title: line.name, detail: resolved[line.name] == nil ? "Not found" : nil) {
                    Text("\(line.qty)").font(T1.mono(17)).monospacedDigit()
                }
            }
        }
    }

    private func answer(_ text: String) {
        guard let q = result?.question else { return }
        answers.append(Answer(question: q, answer: text.trimmingCharacters(in: .whitespaces)))
        reply = ""
        Task { await search() }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        let req = Request(query: query.trimmingCharacters(in: .whitespaces), format: format, answers: answers)
        do {
            let r: DeckFinderResult = try await supabase.functions.invoke("deck-finder", options: FunctionInvokeOptions(body: req)) { data, _ in
                try JSONDecoder.snake.decode(DeckFinderResult.self, from: data)
            }
            if let d = r.deck, let db = catalog.db {
                let names = (d.main + d.side).map(\.name)
                resolved = await Task.detached(priority: .userInitiated) { db.printings(names: names) }.value
                if FormatsCheck.known.contains(d.format) { format = d.format }
            }
            Telemetry.capture("deck_finder_used", ["found": r.deck != nil])
            result = r
        } catch FunctionsError.httpError(_, let data) {
            result = (try? JSONDecoder.snake.decode(DeckFinderResult.self, from: data))
                ?? (try? JSONDecoder.snake.decode(DeckFinderResult.self, from: Data(#"{"status":"error","error":"The deck finder couldn't search just now."}"#.utf8)))
        } catch {
            result = try? JSONDecoder.snake.decode(DeckFinderResult.self,
                                                   from: JSONEncoder().encode(["status": "error", "error": error.localizedDescription]))
        }
    }

    private func create(_ d: DeckFinderResult.Deck) {
        var entries: [CardList.Entry] = []
        for (board, lines) in [("main", d.main), ("side", d.side)] {
            for line in lines {
                guard let p = resolved[line.name] else { continue }
                if let i = entries.firstIndex(where: { $0.cardId == p.cardId && $0.board == board }) {
                    entries[i] = .init(cardId: p.cardId, board: board, qty: entries[i].qty + line.qty)
                } else {
                    entries.append(.init(cardId: p.cardId, board: board, qty: line.qty))
                }
            }
        }
        let source = [d.placement, d.event, d.date].filter { !$0.isEmpty }.joined(separator: ", ")
        let l = ListsStore.shared.create(kind: .deck, name: String(d.name.prefix(60)), format: format, entries: entries,
                                         note: source.isEmpty ? "Found online" : String("Found: \(source)".prefix(120)), from: "finder")
        path.removeLast()
        path.append(.list(l.id))
    }
}

private enum FormatsCheck {
    static let known: Set<String> = Set(CatalogPack.legalityFormats)
}

private extension JSONDecoder {
    static let snake: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: import from a link or a pasted list

/// The list-import function's answer (contract/list-import-2026-10-15.md).
struct ImportedList: Decodable {
    struct Line: Decodable, Hashable {
        let qty: Int
        let board: String
        let name: String
        var set: String?
        var cn: String?
        var scryfallId: String?
        var finish: String?
    }
    var kind: String?
    var name: String?
    var format: String?
    var sourceUrl: String?
    var entries: [Line]?
    var error: String?
}

/// A deck or cube from a link (Cube Cobra, Archidekt, MTGGoldfish, ManaBox and other pages) or a pasted list
/// (Moxfield, ManaBox, Arena, MTGO exports). Lines resolve to exact printings when the source names them,
/// else to the card's original paper printing.
struct ListImportView: View {
    let kind: CardList.Kind
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }

    @State private var link = ""
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var result: ImportedList?
    @State private var name = ""
    @State private var format = "modern"
    @State private var entries: [CardList.Entry] = []
    @State private var printings: [String: CatalogPrinting] = [:]
    @State private var missing: [String] = []

    private var formats: [(String, String)] {
        kind == .deck
            ? [("modern", "Modern"), ("pioneer", "Pioneer"), ("standard", "Standard"), ("legacy", "Legacy"),
               ("vintage", "Vintage"), ("pauper", "Pauper"), ("commander", "Commander"), ("canlander", "Canlander"), ("other", "Other")]
            : [("vintage", "Vintage"), ("legacy", "Legacy"), ("pauper", "Pauper"), ("peasant", "Peasant"), ("other", "Other")]
    }

    var body: some View {
        T1Screen {
            Bar(title: kind == .deck ? "Import deck" : "Import cube", subtitle: "From a link or a pasted list", back: { dismiss() })
            CatalogStatusRow(catalog: catalog)
            if let error { Notice(error, error: true) }
            HairlineList {
                if result == nil {
                    Field(label: kind == .deck ? "Link (ManaBox, Archidekt, MTGGoldfish…)" : "Cube Cobra link", text: $link, url: true)
                    VStack(alignment: .leading, spacing: 4) {
                        LabelText("Or paste a list")
                        TextEditor(text: $text)
                            .font(T1.mono(13)).tint(T1.accent)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 160)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
                    Notice(kind == .deck
                           ? "Moxfield doesn't share decks with other apps: in Moxfield choose Export, copy the list as text and paste it here."
                           : "Cube Cobra: paste the cube's link. Any one-card-per-line list works too.")
                    BigAction(text: busy ? "Reading…" : "Import", enabled: !busy && catalog.db != nil
                              && !(link.trimmingCharacters(in: .whitespaces).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) {
                        Task { await read() }
                    }
                } else {
                    preview
                }
            }
        }
        .onAppear {
            catalog.load(userInitiated: true)
            if kind == .cube { format = "vintage" }
        }
    }

    @ViewBuilder private var preview: some View {
        let count = { (b: String) in entries.filter { $0.board == b }.reduce(0) { $0 + $1.qty } }
        Field(label: "Name", text: $name)
        T1Segmented(options: Array(formats.prefix(4)), selection: $format)
        if formats.count > 4 { T1Segmented(options: Array(formats.dropFirst(4)), selection: $format) }
        let parts = kind == .deck
            ? ["\(count("main")) main", count("side") > 0 ? "\(count("side")) sideboard" : nil, count("maybe") > 0 ? "\(count("maybe")) considering" : nil,
               count("commander") > 0 ? "\(count("commander")) commander" : nil]
            : ["\(count("main")) cards", count("maybe") > 0 ? "\(count("maybe")) considering" : nil]
        ListRow(title: parts.compactMap { $0 }.joined(separator: " · "), detail: result?.sourceUrl.flatMap { URL(string: $0)?.host() })
        if !missing.isEmpty {
            Notice("Not in the card data, left out: \(missing.prefix(12).joined(separator: ", "))\(missing.count > 12 ? " and \(missing.count - 12) more" : "")", error: true)
        }
        BigAction(text: kind == .deck ? "Create deck" : "Create cube",
                  enabled: !entries.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty) { create() }
        Button { result = nil; error = nil } label: { ListRow(title: "Start over") }.buttonStyle(.plain)
        ForEach(CardList.boardOrder.filter { b in entries.contains { $0.board == b } }, id: \.self) { b in
            Section1(boardTitle(b))
            ForEach(entries.filter { $0.board == b }, id: \.self) { e in
                let p = printings[e.cardId]
                CardRow(printing: p, title: lineNames[e.cardId] ?? "",
                        detail: [p?.setLabel, e.finish == "nonfoil" ? nil : e.finish.capitalized].compactMap { $0 }.joined(separator: " · ")) {
                    Text("\(e.qty)").font(T1.mono(17)).monospacedDigit()
                }
            }
        }
    }

    @State private var lineNames: [String: String] = [:]

    private func boardTitle(_ b: String) -> String {
        switch b {
        case "commander": "Commander"
        case "main": kind == .deck ? "Main deck" : "Main"
        case "side": "Sideboard"
        default: "Considering"
        }
    }

    private func read() async {
        busy = true
        error = nil
        defer { busy = false }
        let body: [String: String] = link.trimmingCharacters(in: .whitespaces).isEmpty ? ["text": text] : ["url": link.trimmingCharacters(in: .whitespaces)]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let r: ImportedList = try await supabase.functions.invoke("list-import", options: FunctionInvokeOptions(body: body)) { data, _ in
                try decoder.decode(ImportedList.self, from: data)
            }
            guard let lines = r.entries, !lines.isEmpty, let db = catalog.db else { error = r.error ?? "No cards in that list."; return }
            let k = kind
            let resolved = await Task.detached(priority: .userInitiated) { Self.resolve(lines, kind: k, db) }.value
            entries = resolved.entries
            printings = resolved.printings
            lineNames = resolved.names
            missing = resolved.missing
            name = String((r.name ?? "").prefix(60))
            if let f = r.format, formats.contains(where: { $0.0 == f }) { format = f }
            result = r
        } catch FunctionsError.httpError(_, let data) {
            error = (try? decoder.decode(ImportedList.self, from: data))?.error ?? "That list couldn't be read."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Scryfall id, then set + collector number, then the name's original printing. A finish carries over only
    /// when that printing comes in it. Cubes have no sideboard or commander: those go to the main list.
    nonisolated static func resolve(_ lines: [ImportedList.Line], kind: CardList.Kind, _ db: CatalogDB)
        -> (entries: [CardList.Entry], printings: [String: CatalogPrinting], names: [String: String], missing: [String]) {
        let byId = db.printings(ids: lines.compactMap { $0.scryfallId?.lowercased() })
        let bySet = db.printings(setCns: lines.compactMap { l in l.set.flatMap { s in l.cn.map { (s, $0) } } })
        let byName = db.printings(names: lines.map(\.name))
        var entries: [CardList.Entry] = [], printings: [String: CatalogPrinting] = [:], names: [String: String] = [:], missing: [String] = []
        for l in lines {
            let p = l.scryfallId.flatMap { byId[$0.lowercased()] }
                ?? l.set.flatMap { s in l.cn.flatMap { bySet["\(s)|\($0)"] } }
                ?? byName[l.name]
            guard let p else { missing.append(l.name); continue }
            let finish = l.finish.flatMap { f in p.finishList.contains { $0.rawValue == f } ? f : nil } ?? "nonfoil"
            var board = ["main", "side", "maybe", "commander"].contains(l.board) ? l.board : "main"
            if kind == .cube && (board == "side" || board == "commander") { board = "main" }
            printings[p.cardId] = p
            names[p.cardId] = l.name
            if let i = entries.firstIndex(where: { $0.cardId == p.cardId && $0.board == board && $0.finish == finish }) {
                entries[i] = .init(cardId: p.cardId, board: board, qty: min(999, entries[i].qty + l.qty), finish: finish)
            } else {
                entries.append(.init(cardId: p.cardId, board: board, qty: l.qty, finish: finish))
            }
        }
        return (entries, printings, names, Array(Set(missing)).sorted())
    }

    private func create() {
        let host = result?.sourceUrl.flatMap { URL(string: $0)?.host() }
        let l = ListsStore.shared.create(kind: kind, name: String(name.trimmingCharacters(in: .whitespaces).prefix(60)), format: format,
                                         entries: entries, note: host.map { "Imported from \($0)" } ?? "Imported", from: "import")
        Telemetry.capture("list_imported", ["kind": kind.rawValue, "from": result?.sourceUrl == nil ? "paste" : "link",
                                            "cards": entries.reduce(0) { $0 + $1.qty }])
        path.removeLast()
        path.append(.list(l.id))
    }
}
