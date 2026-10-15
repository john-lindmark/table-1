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
    }
    enum Kind: String, Sendable { case deck, cube }

    let id: String
    let kind: Kind
    let name: String
    let format: String
    /// Oldest first; never empty.
    let versions: [Version]

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
        for e in older?.entries ?? [] { qty["\(e.board)|\(e.cardId)", default: 0] -= e.qty }
        for e in newer.entries { qty["\(e.board)|\(e.cardId)", default: 0] += e.qty }
        return qty.compactMap { k, d -> Change? in
            guard d != 0 else { return nil }
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            return Change(cardId: parts[1], board: parts[0], delta: d)
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
        return next
    }

    /// The version an editing session is filling: edits within 10 minutes of each other share one version.
    /// The server applies the same rule; this keeps the screen in step until its answer arrives.
    @ObservationIgnored private var openEdit: [String: (number: Int, at: Date)] = [:]

    @discardableResult
    func create(kind: CardList.Kind, name: String, format: String) -> CardList {
        let l = CardList(id: UUID().uuidString.lowercased(), kind: kind, name: name, format: format,
                         versions: [CardList.Version(number: 1, at: .now, note: "Created", entries: [])])
        lists.append(l)
        send("list_create", ["p_id": .string(l.id), "p_kind": .string(kind.rawValue), "p_name": .string(name),
                             "p_format": .string(format), "p_entries": .array([]), "p_note": .string("Created")])
        return l
    }

    func delete(listId: String) {
        lists.removeAll { $0.id == listId }
        send("list_delete", ["p_list_id": .string(listId)])
    }

    func add(listId: String, cardId: String, board: String, delta: Int) {
        edit(listId, op: ["card_id": .string(cardId), "board": .string(board), "delta": .integer(delta)]) { entries in
            if let i = entries.firstIndex(where: { $0.cardId == cardId && $0.board == board }) {
                let q = entries[i].qty + delta
                if q > 0 { entries[i] = .init(cardId: cardId, board: board, qty: q) } else { entries.remove(at: i) }
            } else if delta > 0 {
                entries.append(.init(cardId: cardId, board: board, qty: delta))
            }
        }
    }

    /// Moves every copy of a line to another section (merging with copies already there).
    func move(listId: String, cardId: String, from: String, to: String) {
        guard from != to else { return }
        edit(listId, op: ["card_id": .string(cardId), "from": .string(from), "to": .string(to)]) { entries in
            guard let i = entries.firstIndex(where: { $0.cardId == cardId && $0.board == from }) else { return }
            let q = entries.remove(at: i).qty
            if let j = entries.firstIndex(where: { $0.cardId == cardId && $0.board == to }) {
                entries[j] = .init(cardId: cardId, board: to, qty: entries[j].qty + q)
            } else {
                entries.append(.init(cardId: cardId, board: to, qty: q))
            }
        }
    }

    func remove(listId: String, cardId: String, board: String) {
        edit(listId, op: ["card_id": .string(cardId), "board": .string(board), "qty": .integer(0)]) {
            $0.removeAll { $0.cardId == cardId && $0.board == board }
        }
    }

    private func edit(_ listId: String, op: [String: AnyJSON], _ change: (inout [CardList.Entry]) -> Void) {
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
        send("list_edit", ["p_list_id": .string(listId), "p_ops": .array([.object(op)])])
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

    var list: CardList? {
        guard let kind, let name, let format, let versions, !versions.isEmpty else { return nil }
        return CardList(id: id, kind: kind == "cube" ? .cube : .deck, name: name, format: format,
                        versions: versions.map { v in
                            CardList.Version(number: v.version, at: Date(timeIntervalSince1970: v.at), note: v.note,
                                             entries: v.entries.map { CardList.Entry(cardId: $0[0].text, board: $0[1].text, qty: $0[2].int) })
                        })
    }

    init(_ l: CardList) {
        id = l.id
        kind = l.kind.rawValue
        name = l.name
        format = l.format
        deleted = false
        versions = l.versions.map { v in
            VersionDTO(version: v.number, note: v.note, at: v.at.timeIntervalSince1970,
                       entries: v.entries.map { [.text($0.cardId), .text($0.board), .int($0.qty)] })
        }
    }
}

private struct ListsPage: Decodable {
    let lists: [ListDTO]
    let next: Int
    let more: Bool
}

/// Copies owned of each printing, over every finish, condition and language.
@MainActor
func ownedByPrinting() -> [String: Int] {
    var out: [String: Int] = [:]
    for it in CollectionStore.shared.items.values { out[it.cardId, default: 0] += it.qty }
    return out
}

/// Copies a list still needs. A line counts as covered only by the printing it names; Considering is excluded.
@MainActor
func missing(in list: CardList, owned: [String: Int]) -> Int {
    var need: [String: Int] = [:]
    for e in list.entries where e.board != "maybe" { need[e.cardId, default: 0] += e.qty }
    return need.reduce(0) { $0 + max(0, $1.value - (owned[$1.key] ?? 0)) }
}

private let shortDate: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()

private func statCell(_ label: String, _ value: Int) -> some View {
    VStack(spacing: 2) {
        LabelText(label)
        Text(value.formatted()).font(T1.mono(22)).monospacedDigit()
    }.frame(maxWidth: .infinity)
}

// MARK: lists of one kind

struct ListsView: View {
    let kind: CardList.Kind
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: ListsStore { ListsStore.shared }

    var body: some View {
        let lists = store.lists(kind)
        let owned = ownedByPrinting()
        T1Screen {
            Bar(title: kind == .deck ? "Decks" : "Cubes", subtitle: "\(lists.count)") { BarButton("Back") { dismiss() } }
            HairlineList {
                Button {
                    T1Overlays.shared.present { NewListPanel(kind: kind) { id in path.append(.list(id)) } }
                } label: {
                    ListRow(title: kind == .deck ? "New deck" : "New cube", detail: "Name it, then add cards")
                }.buttonStyle(.plain)
                ForEach(lists) { l in
                    let miss = missing(in: l, owned: owned)
                    Button { path.append(.list(l.id)) } label: {
                        ListRow(title: l.name, detail: detail(l, missing: miss)) {
                            Text(l.count("main").formatted()).font(T1.mono(17)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func detail(_ l: CardList, missing: Int) -> String {
        let side = l.count("side"), maybe = l.count("maybe")
        let parts: [String?] = [l.format.capitalized, side > 0 ? "\(side) sideboard" : nil, maybe > 0 ? "\(maybe) considering" : nil,
                                missing == 0 ? "All owned" : "\(missing) missing", "v\(l.current?.number ?? 1)"]
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
    let group: String
    let board: String
    let qty: Int

    static let typeOrder = ["Creatures", "Planeswalkers", "Instants", "Sorceries", "Artifacts", "Enchantments", "Battles", "Lands", "Other"]
    static let colorOrder = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"]

    /// Decks group by card type; cubes by color (from mana cost; lands in their own group).
    nonisolated static func resolve(_ entries: [CardList.Entry], kind: CardList.Kind, _ db: CatalogDB) -> [ListLine] {
        let printings = db.printings(ids: entries.map(\.cardId))
        let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
        return entries.enumerated().map { i, e in
            let o = printings[e.cardId].flatMap { oracles[$0.oracleIdx] }
            let type = o?.typeLine.components(separatedBy: " // ").first ?? ""
            let group = kind == .deck ? typeGroup(type) : (type.contains("Land") ? "Lands" : colorGroup(o?.manaCost ?? ""))
            return ListLine(id: "\(e.board)-\(i)", cardId: e.cardId, printing: printings[e.cardId], oracleId: o?.oracleId,
                            name: o?.name ?? "Unknown card", group: group, board: e.board, qty: e.qty)
        }
        .sorted { $0.name < $1.name }
    }

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

    static func groups(_ lines: [ListLine], kind: CardList.Kind) -> [String] {
        let order = kind == .deck ? typeOrder : colorOrder
        return Array(Set(lines.map(\.group))).sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }
}

/// A section title that reads above the group headers: "MAIN DECK · 60".
private struct BoardHeader: View {
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
    @AppStorage("library.list.grid") private var grid = false

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let owned = ownedByPrinting()
        let rows = list.map { lines(for: $0) } ?? []
        T1Screen {
            Bar(title: list?.name ?? "List", subtitle: list.map(subtitle)) {
                HStack(spacing: 20) {
                    BarButton(editing ? "Done" : "Edit") { editing.toggle() }
                    if !editing { BarButton(grid ? "List" : "Grid") { grid.toggle() } }
                    BarButton("Back") { dismiss() }
                }
            }
            CatalogStatusRow(catalog: catalog)
            if let error = ListsStore.shared.error { Notice(error, error: true) }
            if let list {
                if grid && !editing {
                    gridBody(list, rows: rows, owned: owned)
                } else {
                    HairlineList {
                        top(list, owned: owned)
                        ForEach(list.boards, id: \.self) { board in
                            let lines = rows.filter { $0.board == board }
                            BoardHeader(title: list.boardTitle(board), count: lines.reduce(0) { $0 + $1.qty })
                            ForEach(ListLine.groups(lines, kind: list.kind), id: \.self) { g in
                                let inGroup = lines.filter { $0.group == g }
                                Section1("\(g) · \(inGroup.reduce(0) { $0 + $1.qty })")
                                ForEach(inGroup) { line in
                                    if editing { editRow(line, list: list) } else { lineRow(line, owned: owned[line.cardId] ?? 0) }
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
    }

    /// The list's current lines: live quantities and sections, with card details from `meta`.
    private func lines(for list: CardList) -> [ListLine] {
        list.entries.compactMap { e in
            guard let m = meta[e.cardId] else { return nil }
            return ListLine(id: "\(e.board)|\(e.cardId)", cardId: e.cardId, printing: m.printing, oracleId: m.oracleId,
                            name: m.name, group: m.group, board: e.board, qty: e.qty)
        }
        .sorted { $0.name < $1.name }
    }

    /// Summary, Add cards and Version history: the same in list and grid views.
    @ViewBuilder private func top(_ list: CardList, owned: [String: Int]) -> some View {
        stats(list, owned: owned)
        if editing {
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
        Button { path.append(.listAdd(list.id)) } label: {
            ListRow(title: "Add cards", detail: list.kind == .deck ? "To the main deck, sideboard or considering" : "To the cube or considering")
        }.buttonStyle(.plain)
        historyRow(list)
        if list.entries.isEmpty { ListRow(title: "No cards yet", detail: "Add cards to start this list") }
    }

    private func subtitle(_ l: CardList) -> String {
        "\(l.format.capitalized) \(l.kind == .deck ? "deck" : "cube") · v\(l.current?.number ?? 1)"
    }

    private func stats(_ list: CardList, owned: [String: Int]) -> some View {
        HStack(spacing: 0) {
            statCell(list.kind == .deck ? "Main" : "Cards", list.count("main"))
            if list.kind == .deck { statCell("Side", list.count("side")) }
            statCell("Considering", list.count("maybe"))
            statCell("Missing", missing(in: list, owned: owned))
        }
        .padding(.vertical, 16).background(T1.surface)
    }

    private func historyRow(_ list: CardList) -> some View {
        Button { path.append(.versions(list.id)) } label: {
            ListRow(title: "Version history", detail: list.current.map { "v\($0.number) · \($0.note) · \($0.at.formatted(shortDate))" }) {
                Text("\(list.versions.count)").font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }

    private func lineRow(_ line: ListLine, owned: Int) -> some View {
        let considering = line.board == "maybe"
        let short = !considering && owned < line.qty
        let detail = considering ? (owned > 0 ? "Owned \(owned)" : "Not owned")
            : short ? "Owned \(owned) · missing \(line.qty - owned)" : "Owned \(owned)"
        return Button {
            if let o = line.oracleId { path.append(.card(o)) }
        } label: {
            CardRow(printing: line.printing, title: line.name, detail: detail) {
                Text("\(line.qty)").font(T1.mono(17)).monospacedDigit().foregroundStyle(short ? T1.error : T1.text)
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
                    T1MenuItem(title: "Move to \(list.boardTitle(b))") { store.move(listId: list.id, cardId: line.cardId, from: line.board, to: b) }
                } + [T1MenuItem(title: "Remove from \(list.boardTitle(line.board))", destructive: true) {
                    store.remove(listId: list.id, cardId: line.cardId, board: line.board)
                }])
            } label: {
                CardRow(printing: line.printing, title: line.name, detail: "Tap to move or remove") {
                    Text("\(line.qty)").font(T1.mono(17)).monospacedDigit()
                }
            }.buttonStyle(.plain)
            stepper("−") { store.add(listId: list.id, cardId: line.cardId, board: line.board, delta: -1) }
            stepper("+") { store.add(listId: list.id, cardId: line.cardId, board: line.board, delta: 1) }
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
    private func gridBody(_ list: CardList, rows: [ListLine], owned: [String: Int]) -> some View {
        GeometryReader { geo in
            let width = ((geo.size.width - 2) / 3).rounded(.down)
            ScrollView {
                LazyVStack(spacing: 1) {
                    top(list, owned: owned)
                    ForEach(list.boards, id: \.self) { board in
                        let lines = rows.filter { $0.board == board }
                        BoardHeader(title: list.boardTitle(board), count: lines.reduce(0) { $0 + $1.qty })
                        ForEach(ListLine.groups(lines, kind: list.kind), id: \.self) { g in
                            let inGroup = lines.filter { $0.group == g }
                            Section1("\(g) · \(inGroup.reduce(0) { $0 + $1.qty })")
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1), count: 3), spacing: 1) {
                                ForEach(inGroup) { line in
                                    let have = owned[line.cardId] ?? 0
                                    Button { if let o = line.oracleId { path.append(.card(o)) } } label: {
                                        CardTile(printing: line.printing, name: line.name, qty: line.qty,
                                                 warn: board != "maybe" && have < line.qty, width: width)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
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
            Bar(title: "Version history", subtitle: list?.name) { BarButton("Back") { dismiss() } }
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
            Bar(title: "v\(number) · \(version?.note ?? "")", subtitle: list?.name) { BarButton("Back") { dismiss() } }
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
            let entries = changes.map { CardList.Entry(cardId: $0.cardId, board: $0.board, qty: abs($0.delta)) }
            let kind = list.kind
            let lines = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: kind, db) }.value
            cards = Dictionary(lines.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func changeRow(_ c: CardList.Change) -> some View {
        let card = cards[c.cardId]
        return Button { if let o = card?.oracleId { path.append(.card(o)) } } label: {
            CardRow(printing: card?.printing, title: card?.name ?? "…", detail: c.delta > 0 ? "Added" : "Removed") {
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
    @State private var name = ""
    @State private var format = "modern"

    private var formats: [(String, String)] {
        kind == .deck
            ? [("modern", "Modern"), ("pioneer", "Pioneer"), ("standard", "Standard"), ("legacy", "Legacy"),
               ("vintage", "Vintage"), ("pauper", "Pauper"), ("commander", "Commander"), ("other", "Other")]
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
        }
        .onAppear { if kind == .cube { format = "vintage" } }
    }
}

/// Search the catalog and add cards straight into a section of a list. Each card goes in as its newest
/// English printing (change the printing from the card page).
struct ListAddCardsView: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var board = "main"
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        let list = ListsStore.shared.list(id: listId)
        let sections = list?.kind == .cube ? ["main", "maybe"] : ["main", "side", "maybe"]
        T1Screen {
            Bar(title: "Add to \(list?.name ?? "list")", subtitle: list.map { "v\($0.current?.number ?? 1)" }) { BarButton("Done") { dismiss() } }
            CatalogStatusRow(catalog: catalog)
            if let list {
                T1Segmented(options: sections.map { ($0, list.boardTitle($0)) }, selection: $board)
                T1SearchField(text: $query, prompt: "Card name").focused($focused)
                HairlineList {
                    ForEach(hits, id: \.idx) { o in
                        let p = covers[o.idx]
                        let inList = p.map { pc in list.entries.filter { $0.cardId == pc.cardId && $0.board == board }.reduce(0) { $0 + $1.qty } } ?? 0
                        HStack(spacing: 1) {
                            Button { path.append(.card(o.oracleId)) } label: {
                                CardRow(printing: p, title: o.name, detail: inList > 0 ? "\(inList) in \(list.boardTitle(board))" : o.typeLine)
                            }.buttonStyle(.plain)
                            Button {
                                if let p { ListsStore.shared.add(listId: listId, cardId: p.cardId, board: board, delta: 1) }
                            } label: {
                                LabelText("+ Add", color: p == nil ? T1.disabled : T1.text)
                                    .padding(.horizontal, 16).frame(maxHeight: .infinity).background(T1.surfaceHover)
                            }.buttonStyle(.plain).disabled(p == nil)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear {
            catalog.load(userInitiated: true)
            focused = true
        }
        .task(id: "\(query)-\(catalog.generation)") {
            guard let db = catalog.db else { hits = []; return }
            let q = query
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { () -> ([CatalogOracle], [Int: CatalogPrinting]) in
                let h = db.search(q)
                return (h, db.covers(oracleIdxs: h.map(\.idx)))
            }.value
            if !Task.isCancelled { hits = found.0; covers = found.1 }
        }
    }
}
