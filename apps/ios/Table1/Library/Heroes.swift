import Supabase
import SwiftUI

// Hero cards (contract/library-heroes-2026-10-19.md): the few cards that stand for a deck, a cube, a binder or the
// whole collection. Picked by card (oracle id), so changing a printing keeps the hero; the art shown is the
// printing the list or binder holds. Heroes are highlighted where those places are listed and in their own screens.

enum HeroScope: Hashable {
    case collection
    case list(String) // list id
    case binder(String) // binder id; Unsorted has no heroes

    /// Key in `HeroesStore.heroes` and the cache.
    var key: String {
        switch self {
        case .collection: "collection"
        case .list(let id): "list:\(id)"
        case .binder(let id): "binder:\(id)"
        }
    }

    var wire: (scope: String, id: String?) {
        switch self {
        case .collection: ("collection", nil)
        case .list(let id): ("list", id)
        case .binder(let id): ("binder", id)
        }
    }

    /// From a card detail's context: a deck/cube, a binder (not Unsorted), or the collection.
    init?(_ context: CardContext?) {
        switch context {
        case .list(let id): self = .list(id)
        case .binder(let id): if id == BinderRoute.unsorted { return nil } else { self = .binder(id) }
        case nil: self = .collection
        }
    }
}

@MainActor
@Observable
final class HeroesStore {
    static let shared = HeroesStore()
    static let limit = 10

    /// Scope key → oracle ids, in the order they were picked.
    private(set) var heroes: [String: [String]] = [:]
    var error: String?
    @ObservationIgnored private var userId: String?
    @ObservationIgnored private var demo = false

    func heroes(_ scope: HeroScope) -> [String] { heroes[scope.key] ?? [] }
    func isHero(_ oracleId: String?, _ scope: HeroScope) -> Bool { oracleId.map { heroes(scope).contains($0) } ?? false }

    func start(userId: String) async {
        if self.userId != userId {
            demo = false
            self.userId = userId
            heroes = Self.loadCache(userId)
        }
        await refresh()
    }

    func stop() {
        userId = nil
        heroes = [:]
        error = nil
    }

    #if DEBUG
    func startDemo(_ seed: [String: [String]] = [:]) {
        userId = nil
        demo = true
        heroes = seed
    }
    #endif

    private struct Row: Decodable {
        let scope: String
        let targetId: String?
        let oracleIds: [String]
        var key: String {
            switch scope {
            case "list": "list:\(targetId?.lowercased() ?? "")"
            case "binder": "binder:\(targetId?.lowercased() ?? "")"
            default: "collection"
            }
        }
    }

    /// All of the account's heroes (a few rows, so no cursor).
    func refresh() async {
        guard let user = userId, !demo else { return }
        do {
            let rows: [Row] = try await supabase.rpc("library_heroes").execute().value
            guard userId == user else { return }
            heroes = Dictionary(rows.map { ($0.key, $0.oracleIds.map { $0.lowercased() }) }, uniquingKeysWith: { a, _ in a })
            Self.saveCache(user, heroes)
            error = nil
        } catch {
            if userId == user { self.error = error.localizedDescription }
        }
    }

    /// Makes the card a hero of the scope, or stops it being one. Shown at once; the server's answer replaces it.
    /// False when the scope already has `limit` heroes.
    @discardableResult
    func toggle(_ oracleId: String, _ scope: HeroScope) -> Bool {
        var ids = heroes(scope)
        let adding = !ids.contains(oracleId)
        if adding {
            guard ids.count < Self.limit else { return false }
            ids.append(oracleId)
        } else {
            ids.removeAll { $0 == oracleId }
        }
        set(ids, scope)
        Telemetry.capture(adding ? "hero_added" : "hero_removed", ["scope": scope.wire.scope, "count": ids.count])
        return true
    }

    private func set(_ ids: [String], _ scope: HeroScope) {
        heroes[scope.key] = ids.isEmpty ? nil : ids
        guard let user = userId, !demo else { return }
        Self.saveCache(user, heroes)
        let w = scope.wire
        Task {
            do {
                let row: Row = try await supabase.rpc("library_heroes_set", params: [
                    "p_scope": AnyJSON.string(w.scope), "p_target_id": w.id.map { .string($0) } ?? .null,
                    "p_oracle_ids": .array(ids.map { .string($0) }),
                ]).execute().value
                guard userId == user else { return }
                heroes[row.key] = row.oracleIds.isEmpty ? nil : row.oracleIds.map { $0.lowercased() }
                Self.saveCache(user, heroes)
                error = nil
            } catch {
                self.error = error.localizedDescription
                await refresh()
            }
        }
    }

    // MARK: device cache

    nonisolated private static func cacheURL(_ userId: String) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "heroes-\(userId).json")
    }

    private static func loadCache(_ userId: String) -> [String: [String]] {
        guard let data = try? Data(contentsOf: cacheURL(userId)) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private static func saveCache(_ userId: String, _ heroes: [String: [String]]) {
        if let data = try? JSONEncoder().encode(heroes) { try? data.write(to: cacheURL(userId), options: .atomic) }
    }
}

enum HeroArt {
    /// The printings to show for these heroes: the one the place holds (`held`, card ids, most first), else the
    /// card's cover. Hero order is kept; heroes the card data doesn't know are left out.
    nonisolated static func printings(_ heroes: [String], held: [String], _ db: CatalogDB) -> [CatalogPrinting] {
        guard !heroes.isEmpty else { return [] }
        let oracles = heroes.compactMap { db.oracle(id: $0) }
        let wanted = Set(oracles.map(\.idx))
        var byOracle: [Int: CatalogPrinting] = [:]
        let heldPrintings = db.printings(ids: held)
        for id in held { if let p = heldPrintings[id], wanted.contains(p.oracleIdx), byOracle[p.oracleIdx] == nil { byOracle[p.oracleIdx] = p } }
        let covers = db.covers(oracleIdxs: oracles.map(\.idx).filter { byOracle[$0] == nil })
        return oracles.compactMap { byOracle[$0.idx] ?? covers[$0.idx] }
    }
}

/// Up to three hero cards fanned at the left of a row that lists a deck, cube, binder or the collection.
struct HeroThumbs: View {
    let printings: [CatalogPrinting]
    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(printings.prefix(3).enumerated()), id: \.offset) { i, p in
                p.art(width: 36).offset(x: CGFloat(i) * 10)
            }
        }
        .frame(width: 36 + CGFloat(max(0, min(printings.count, 3) - 1)) * 10, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A row for a deck, cube, binder or the collection: its heroes (when it has any) left of the title.
struct HeroListRow<Trailing: View>: View {
    let heroes: [CatalogPrinting]
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if heroes.isEmpty {
            ListRow(title: title, detail: detail) { trailing }
        } else {
            HStack(spacing: 12) {
                HeroThumbs(printings: heroes)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(T1.mono(14)).lineLimit(1)
                    if let detail { LabelText(detail) }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(T1.surface)
            .contentShape(Rectangle())
        }
    }
}
