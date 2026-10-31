import CryptoKit
import Foundation
import Supabase

// The offline card catalog (contract/catalog-2026-10-14.md): one gzipped TSV pack, downloaded only when its
// version changes, verified, and loaded into a local SQLite file. Search, the collection list and card detail
// all read from here; the server is only asked for prices and history.

struct CatalogInfo: Decodable {
    let version: String
    let format: Int
    let url: String
    let bytes: Int
    let sha256: String
}

struct CatalogOracle: Hashable, Sendable {
    let idx: Int
    let oracleId: String
    let name: String
    let norm: String
    let typeLine: String
    let manaCost: String
    let printings: Int
    /// Legality code (`CatalogPack.legalityFormats`); empty in packs built before it existed.
    var legal: String = ""
    /// Canadian Highlander points (0 = none).
    var points: Int = 0
    /// Mana value and colors (WUBRG letters, empty = colorless), for deck and cube stats.
    var cmc: Double = 0
    var colors: String = ""
    /// Mana it makes (letters from WUBRGCF), nil when the pack doesn't say; the token cards it makes (O-line idx).
    var produced: String? = nil
    var tokens: [Int] = []
    /// Who it shares the command zone with (`CommandZone.Mate`), nil when the pack doesn't say.
    var pair: String? = nil
    /// Color identity (WUBRG letters, empty = colorless), nil when the pack doesn't say.
    var identity: String? = nil

    /// Legality in a deck format: "legal", "restricted", "banned", "not_legal", or nil when the format isn't checked.
    func legality(_ format: String) -> String? { CatalogPack.legality(legal, format) }
}

struct CatalogPrinting: Hashable, Sendable {
    let cardId: String
    let oracleIdx: Int
    /// Position in the pack; within a card, lower is newer.
    let ord: Int
    let set: String
    let cn: String
    let lang: String
    let rarity: String
    let finishes: String
    let releasedAt: String
    let imageTs: String
    let imageFaces: Int
    let printedName: String
    /// The card's original paper printing, the one adds use by default.
    var original: Bool = false
    /// The illustrator and the frame ("1993", "1997", "2003", "2015", "future"), empty when the pack doesn't say.
    var artist: String = ""
    var frame: String = ""

    var setLabel: String { "\(set.uppercased()) #\(cn)" }
    /// Finishes this printing comes in: non-foil, foil, etched (in that order).
    var finishList: [Finish] {
        let have = Set(finishes.compactMap { CatalogPack.finishName[$0].flatMap(Finish.init(rawValue:)) })
        return Finish.allCases.filter(have.contains)
    }
    /// Card detail lists printings by release, earliest first (the pack's order is newest first).
    static func oldestFirst(_ a: CatalogPrinting, _ b: CatalogPrinting) -> Bool {
        a.releasedAt != b.releasedAt ? a.releasedAt < b.releasedAt : a.ord > b.ord
    }

    func imageURL(_ size: String = "normal") -> URL? {
        imageFaces == 0 ? nil : CatalogPack.imageURL(cardId: cardId, imageTs: imageTs, size: size)
    }
}

/// One installed pack. Read-only after it's built; queries are serialized by the connection's lock.
final class CatalogDB: @unchecked Sendable {
    let version: String
    private let db: SQLiteDB

    init(path: String, version: String) throws {
        db = try SQLiteDB(path: path, readOnly: true)
        self.version = version
    }

    func close() { db.close() }

    /// Every card and every printing, read once for advanced search (CardQuery) and kept while the pack is open.
    private let cacheLock = NSLock()
    private var oracleCache: [CatalogOracle]?
    private var printingCache: [CatalogPrinting]?

    func allOracles() -> [CatalogOracle] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let oracleCache { return oracleCache }
        let rows = (try? db.query("SELECT \(Self.oracleCols) FROM oracles", [], Self.oracle)) ?? []
        oracleCache = rows
        return rows
    }

    /// In pack order (newest first within a card).
    func allPrintings() -> [CatalogPrinting] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let printingCache { return printingCache }
        let rows = (try? db.query("SELECT \(Self.printingCols) FROM printings ORDER BY ord", [], Self.printing)) ?? []
        printingCache = rows
        return rows
    }

    private var basicCache: Set<String>?

    /// Every printing of a basic land (the Basic supertype), read once while the pack is open: basics never count as
    /// missing from a deck or cube (contract/basics-2026-10-24.md).
    func basicCardIds() -> Set<String> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let basicCache { return basicCache }
        let ids = (try? db.query("""
            SELECT card_id FROM printings WHERE oracle_idx IN
              (SELECT idx FROM oracles WHERE type_line LIKE 'Basic %' OR type_line LIKE '% Basic %')
            """, [], { $0.text(0) })) ?? []
        let out = Set(ids)
        basicCache = out
        return out
    }

    private var cardKeyCache: [String: String] = [:]

    /// Each printing's card ("oracle_idx" as text), remembered while the pack is open; ids the pack doesn't have are
    /// left out (contract/owned-by-card-2026-10-31.md).
    func cardKeys(_ ids: some Collection<String>) -> [String: String] {
        cacheLock.lock()
        var out: [String: String] = [:]
        var todo: [String] = []
        for id in ids { if let k = cardKeyCache[id] { out[id] = k } else { todo.append(id) } }
        cacheLock.unlock()
        guard !todo.isEmpty else { return out }
        var found: [String: String] = [:]
        for chunk in Self.chunks(todo) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = (try? db.query("SELECT card_id, oracle_idx FROM printings WHERE card_id IN (\(marks))",
                                      chunk.map { .text($0) }, { ($0.text(0), String($0.int(1))) })) ?? []
            for (id, k) in rows { found[id] = k }
        }
        cacheLock.lock()
        for (id, k) in found { cardKeyCache[id] = k; out[id] = k }
        cacheLock.unlock()
        return out
    }

    private static let oracleCols = "idx, oracle_id, name, name_norm, type_line, mana_cost, pcount, legal, points, cmc, colors, produced, tokens, pair, identity"
    private static func oracle(_ r: SQLiteDB.Row) -> CatalogOracle {
        CatalogOracle(idx: r.int(0), oracleId: r.text(1), name: r.text(2), norm: r.text(3), typeLine: r.text(4),
                      manaCost: r.text(5), printings: r.int(6), legal: r.text(7), points: r.int(8), cmc: r.double(9), colors: r.text(10),
                      produced: r.isNull(11) ? nil : r.text(11), tokens: r.text(12).split(separator: ",").compactMap { Int($0) },
                      pair: r.isNull(13) ? nil : r.text(13), identity: r.isNull(14) ? nil : r.text(14))
    }

    private static let printingCols =
        "card_id, oracle_idx, ord, set_code, cn, lang, rarity, finishes, released_at, image_ts, image_faces, printed_name, original, artist, frame"
    private static func printing(_ r: SQLiteDB.Row) -> CatalogPrinting {
        CatalogPrinting(cardId: r.text(0), oracleIdx: r.int(1), ord: r.int(2), set: r.text(3), cn: r.text(4), lang: r.text(5),
                        rarity: r.text(6), finishes: r.text(7), releasedAt: r.text(8), imageTs: r.text(9),
                        imageFaces: r.int(10), printedName: r.text(11), original: r.int(12) != 0,
                        artist: r.text(13), frame: r.text(14))
    }

    /// Card name search, ranked like the web client.
    func search(_ query: String, limit: Int = 40) -> [CatalogOracle] {
        let q = CardName.norm(query)
        guard q.count >= 2 else { return [] }
        let rows = (try? db.query("SELECT \(Self.oracleCols) FROM oracles WHERE instr(name_norm, ?) > 0", [.text(q)], Self.oracle)) ?? []
        let byIdx = Dictionary(rows.map { ($0.idx, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = CatalogPack.rank(rows.map { .init(idx: $0.idx, norm: $0.norm, type: $0.typeLine, printings: $0.printings) },
                                      query: q, limit: limit)
        return ranked.compactMap { byIdx[$0] }
    }

    /// Every card's name, type line and printing count, for the scanner's name index (ScanNames).
    func scanNames() -> [(idx: Int, name: String, norm: String, typeLine: String, printings: Int)] {
        (try? db.query("SELECT idx, name, name_norm, type_line, pcount FROM oracles", [], {
            (idx: $0.int(0), name: $0.text(1), norm: $0.text(2), typeLine: $0.text(3), printings: $0.int(4))
        })) ?? []
    }

    /// Printed names in other languages (N lines), normalized, one row per card, language and name; empty for older packs.
    func scanForeignNames() -> [(idx: Int, lang: String, norm: String)] {
        (try? db.query("SELECT DISTINCT oracle_idx, lang, name_norm FROM names", [], { (idx: $0.int(0), lang: $0.text(1), norm: $0.text(2)) })) ?? []
    }

    /// Every set code in the pack.
    func setCodes() -> Set<String> {
        Set((try? db.query("SELECT DISTINCT set_code FROM printings", [], { $0.text(0) })) ?? [])
    }

    /// Every card's normalized name and face names, for matching imported names (ImportResolver).
    func importNames() -> [(idx: Int, norm: String, faces: String, token: Bool, printings: Int)] {
        (try? db.query("SELECT idx, name_norm, face_names, type_line, pcount FROM oracles", [], {
            (idx: $0.int(0), norm: $0.text(1), faces: $0.text(2), token: $0.text(3).hasPrefix("Token"), printings: $0.int(4))
        })) ?? []
    }

    /// Every printing in one set, newest card first.
    func printings(set: String) -> [CatalogPrinting] {
        (try? db.query("SELECT \(Self.printingCols) FROM printings WHERE set_code = ?", [.text(set)], Self.printing)) ?? []
    }

    /// Printings by set code and collector number, any card (the scanner reading a card's bottom line).
    func printings(set: String, cn: String) -> [CatalogPrinting] {
        (try? db.query("SELECT \(Self.printingCols) FROM printings WHERE set_code = ? AND cn = ? ORDER BY lang = 'en' DESC",
                       [.text(set), .text(cn)], Self.printing)) ?? []
    }

    func oracle(id: String) -> CatalogOracle? {
        try? db.query("SELECT \(Self.oracleCols) FROM oracles WHERE oracle_id = ?", [.text(id)], Self.oracle).first
    }

    /// Every printing of a card: the original paper printing (the default for adds) first, then newest first.
    func printings(oracleIdx: Int) -> [CatalogPrinting] {
        (try? db.query("SELECT \(Self.printingCols) FROM printings WHERE oracle_idx = ? ORDER BY original DESC, ord", [.int(oracleIdx)], Self.printing)) ?? []
    }

    func printings(ids: [String]) -> [String: CatalogPrinting] {
        var out: [String: CatalogPrinting] = [:]
        for chunk in Self.chunks(ids) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = (try? db.query("SELECT \(Self.printingCols) FROM printings WHERE card_id IN (\(marks))",
                                      chunk.map { .text($0) }, Self.printing)) ?? []
            for p in rows { out[p.cardId] = p }
        }
        return out
    }

    /// One printing per card, shown as its picture and used when it's added: its original paper printing (flagged
    /// in the pack), else the newest English printing with an image, else the newest.
    func covers(oracleIdxs: [Int]) -> [Int: CatalogPrinting] {
        var out: [Int: CatalogPrinting] = [:]
        for chunk in Self.chunks(oracleIdxs) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = (try? db.query("""
                SELECT \(Self.printingCols) FROM printings WHERE oracle_idx IN (\(marks))
                ORDER BY oracle_idx, original DESC, (lang = 'en' AND image_faces > 0) DESC, ord
                """, chunk.map { .int($0) }, Self.printing)) ?? []
            for p in rows where out[p.oracleIdx] == nil { out[p.oracleIdx] = p }
        }
        return out
    }

    /// Default printings for card names as decklists print them: exact names, or the front face of a split or
    /// double-faced card ("Delver of Secrets" finds "Delver of Secrets // Insectile Aberration"). Names that
    /// match no card are left out.
    func printings(names: [String]) -> [String: CatalogPrinting] {
        var idxByName: [String: Int] = [:]
        for name in Set(names) {
            let q = CardName.norm(name)
            if let o = try? db.query("SELECT idx FROM oracles WHERE name_norm = ? LIMIT 1", [.text(q)], { $0.int(0) }).first {
                idxByName[name] = o
            } else if let o = try? db.query("SELECT idx FROM oracles WHERE name LIKE ? ORDER BY pcount DESC LIMIT 1",
                                             [.text(name.replacingOccurrences(of: "%", with: "") + " // %")], { $0.int(0) }).first {
                idxByName[name] = o
            }
        }
        let covers = covers(oracleIdxs: Array(Set(idxByName.values)))
        return idxByName.compactMapValues { covers[$0] }
    }

    /// Printings by set code and collector number ("set|cn"), English first when a set has several languages.
    func printings(setCns: [(set: String, cn: String)]) -> [String: CatalogPrinting] {
        var out: [String: CatalogPrinting] = [:]
        for (set, cn) in setCns where out["\(set)|\(cn)"] == nil {
            if let p = try? db.query("SELECT \(Self.printingCols) FROM printings WHERE set_code = ? AND cn = ? ORDER BY lang = 'en' DESC LIMIT 1",
                                     [.text(set.lowercased()), .text(cn)], Self.printing).first {
                out["\(set)|\(cn)"] = p
            }
        }
        return out
    }

    /// Cards by Oracle id (lowercase keys); ids the pack doesn't know are left out.
    func oracles(oracleIds: [String]) -> [String: CatalogOracle] {
        var out: [String: CatalogOracle] = [:]
        for chunk in Self.chunks(oracleIds.map { $0.lowercased() }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = (try? db.query("SELECT \(Self.oracleCols) FROM oracles WHERE oracle_id IN (\(marks))",
                                      chunk.map { .text($0) }, Self.oracle)) ?? []
            for o in rows { out[o.oracleId.lowercased()] = o }
        }
        return out
    }

    func oracles(idxs: [Int]) -> [Int: CatalogOracle] {
        var out: [Int: CatalogOracle] = [:]
        for chunk in Self.chunks(idxs) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = (try? db.query("SELECT \(Self.oracleCols) FROM oracles WHERE idx IN (\(marks))",
                                      chunk.map { .int($0) }, Self.oracle)) ?? []
            for o in rows { out[o.idx] = o }
        }
        return out
    }

    private static func chunks<T>(_ xs: [T]) -> [ArraySlice<T>] {
        stride(from: 0, to: xs.count, by: 500).map { xs[$0..<min($0 + 500, xs.count)] }
    }

    // MARK: building

    /// Builds a SQLite file from a gunzipped pack in one transaction; indexes are created after the inserts.
    static func build(pack: Data, at path: String) throws -> PackHeader {
        try? FileManager.default.removeItem(atPath: path)
        let db = try SQLiteDB(path: path)
        defer { db.close() }
        try db.exec("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE oracles (idx INTEGER PRIMARY KEY, oracle_id TEXT NOT NULL, name TEXT NOT NULL,
              name_norm TEXT NOT NULL, type_line TEXT, mana_cost TEXT, cmc REAL, colors TEXT, face_names TEXT,
              pcount INTEGER NOT NULL DEFAULT 0, legal TEXT NOT NULL DEFAULT '', points INTEGER NOT NULL DEFAULT 0,
              produced TEXT, tokens TEXT NOT NULL DEFAULT '', pair TEXT, identity TEXT);
            CREATE TABLE printings (card_id TEXT PRIMARY KEY, oracle_idx INTEGER NOT NULL, ord INTEGER NOT NULL,
              set_code TEXT, cn TEXT, lang TEXT, rarity TEXT, finishes TEXT, released_at TEXT, image_ts TEXT,
              image_faces INTEGER, printed_name TEXT, original INTEGER NOT NULL DEFAULT 0,
              artist TEXT NOT NULL DEFAULT '', frame TEXT NOT NULL DEFAULT '');
            CREATE TABLE names (oracle_idx INTEGER NOT NULL, lang TEXT NOT NULL, name TEXT NOT NULL, name_norm TEXT NOT NULL);
            """)
        let header: PackHeader = try db.transaction {
            let insO = try db.prepare("INSERT INTO oracles (idx, oracle_id, name, name_norm, type_line, mana_cost, cmc, colors, face_names, legal, points, produced, tokens, pair, identity) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            let insP = try db.prepare("INSERT OR REPLACE INTO printings VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            let insN = try db.prepare("INSERT INTO names VALUES (?,?,?,?)")
            var ord = 0
            let h = try CatalogPack.parse(pack, oracle: { o in
                try insO.run([.int(o.idx), .text(o.oracleId), .text(o.name), .text(o.nameNorm), .text(o.typeLine),
                              .text(o.manaCost), .double(o.cmc), .text(o.colors), .text(o.faceNames), .text(o.legal), .int(o.points),
                              o.produced.map { .text($0) } ?? .null, .text(o.tokens), o.pair.map { .text($0) } ?? .null,
                              o.identity.map { .text($0) } ?? .null])
            }, printing: { p in
                try insP.run([.text(p.cardId), .int(p.oracleIdx), .int(ord), .text(p.set), .text(p.cn), .text(p.lang),
                              .text(p.rarity), .text(p.finishes), .text(p.releasedAt), .text(p.imageTs), .int(p.imageFaces),
                              .text(p.printedName), .int(p.original ? 1 : 0), .text(p.artist), .text(p.frame)])
                ord += 1
            }, name: { n in
                // Normalized here, once per pack, so the scanner's name index loads without normalizing 160k names.
                let norm = CardName.norm(n.name)
                if !norm.isEmpty { try insN.run([.int(n.oracleIdx), .text(n.lang), .text(n.name), .text(norm)]) }
            })
            try db.exec("""
                CREATE INDEX printings_oracle ON printings (oracle_idx, ord);
                CREATE INDEX printings_set_cn ON printings (set_code, cn, lang);
                CREATE INDEX oracles_norm ON oracles (name_norm);
                CREATE INDEX oracles_id ON oracles (oracle_id);
                UPDATE oracles SET pcount = (SELECT count(*) FROM printings WHERE oracle_idx = oracles.idx);
                """)
            try db.run("INSERT INTO meta VALUES ('version', ?)", [.text(h.version)])
            return h
        }
        return header
    }
}

/// Owns the installed pack: opens it at launch, checks `catalog_info` at most once a day, and swaps in a new
/// version atomically (the old one stays in use until the new one is built).
@MainActor
@Observable
final class CatalogStore {
    static let shared = CatalogStore()

    enum Phase: Equatable { case idle, loading, ready, failed(String) }
    private(set) var phase: Phase = .idle
    /// Bumped whenever a pack is opened or replaced; views re-query on it.
    private(set) var generation = 0
    @ObservationIgnored private(set) var db: CatalogDB?
    /// Basic land printings in the open pack; empty until one is open. Reads `generation` so views redraw when a
    /// pack opens.
    var basics: Set<String> { _ = generation; return db?.basicCardIds() ?? [] }
    /// Each printing's card, for owning a card in any printing; empty until a pack is open.
    func cardKeys(_ ids: some Collection<String>) -> [String: String] { _ = generation; return db?.cardKeys(ids) ?? [:] }
    @ObservationIgnored private var running: Task<Void, Never>?
    /// With a pack installed, a failed update (offline, cellular) waits an hour before the next try.
    @ObservationIgnored private var lastAttempt: Date?

    private let fileKey = "catalog.file"
    /// Bumped when the local SQLite schema changes; a file built by an older schema is rebuilt from a fresh pack.
    private static let schema = "s9"   // s6: oracles.produced and oracles.tokens; s7: oracles.pair; s8: oracles.identity; s9: printings.artist and frame
    private let checkedKey = "catalog.checkedAt"
    private let dir: URL = {
        let d = URL.applicationSupportDirectory.appending(path: "Catalog", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// `userInitiated`: the Library is on screen. A first pack then downloads on any network; otherwise (at
    /// launch, or when a pack is already installed) only on Wi-Fi / unmetered networks.
    func load(userInitiated: Bool) {
        if db == nil { openInstalled() }
        if running != nil { return }
        if db != nil, let at = UserDefaults.standard.object(forKey: checkedKey) as? Date, Date().timeIntervalSince(at) < 86_400 { return }
        if db != nil, let at = lastAttempt, Date().timeIntervalSince(at) < 3_600 { return }
        lastAttempt = Date()
        running = Task {
            await refresh(anyNetwork: db == nil && userInitiated)
            running = nil
        }
    }

    private func openInstalled() {
        guard let file = UserDefaults.standard.string(forKey: fileKey) else { return }
        let url = dir.appending(path: file)
        guard file.hasSuffix(".\(Self.schema).sqlite"), FileManager.default.fileExists(atPath: url.path),
              let version = file.split(separator: ".").first.map({ String($0.dropFirst("catalog-".count)) }),
              let opened = try? CatalogDB(path: url.path, version: version) else { return }
        db = opened
        phase = .ready
        generation += 1
    }

    private func refresh(anyNetwork: Bool) async {
        let hadPack = db != nil
        if !hadPack { phase = .loading }
        do {
            let info: CatalogInfo? = try await supabase.rpc("catalog_info").execute().value
            guard let info else {
                if !hadPack { phase = .failed("Card data isn't available yet") }
                return
            }
            if info.version == db?.version {
                UserDefaults.standard.set(Date(), forKey: checkedKey)
                return
            }
            guard info.format == 1 else {
                if !hadPack { phase = .failed("Update Table 1 to load the latest card data") }
                return
            }
            if !hadPack && !anyNetwork { phase = .idle; return } // waits for the Library to open
            let file = "catalog-\(info.version).\(Self.schema).sqlite"
            let path = dir.appending(path: file).path
            let tmp = dir.appending(path: "building.sqlite").path
            let started = Date()
            try await Task.detached(priority: .utility) {
                try await Self.install(info, anyNetwork: anyNetwork, building: tmp, final: path)
            }.value
            let opened = try CatalogDB(path: path, version: info.version)
            let old = db
            db = opened
            phase = .ready
            generation += 1
            UserDefaults.standard.set(file, forKey: fileKey)
            UserDefaults.standard.set(Date(), forKey: checkedKey)
            old?.close()
            removeOtherPacks(keep: file)
            Telemetry.capture("catalog_pack_installed", ["seconds": Int(Date().timeIntervalSince(started)), "first": !hadPack])
        } catch {
            // With a pack installed, keep using it quietly and try again next launch.
            if !hadPack { phase = .failed(error.localizedDescription) }
            if !(error is URLError) { Telemetry.error(error, "catalog_pack") }   // offline is expected
        }
    }

    nonisolated private static func install(_ info: CatalogInfo, anyNetwork: Bool, building: String, final: String) async throws {
        guard let url = URL(string: info.url) else { throw CatalogPack.Failure.format }
        var req = URLRequest(url: url)
        req.allowsExpensiveNetworkAccess = anyNetwork
        req.allowsConstrainedNetworkAccess = anyNetwork
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SQLiteDB.Failure(message: "Card data \(http.statusCode)")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256.lowercased() else { throw CatalogPack.Failure.checksum }
        let pack = try CatalogPack.gunzip(data)
        _ = try CatalogDB.build(pack: pack, at: building)
        let fm = FileManager.default
        try? fm.removeItem(atPath: final)
        try fm.moveItem(atPath: building, toPath: final)
    }

    private func removeOtherPacks(keep: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != keep && name.hasPrefix("catalog-") {
            try? fm.removeItem(at: dir.appending(path: name))
        }
    }
}

/// Searching inside a screen (a cube, a binder, all binders, wants) and among one card's printings. Same rules on
/// every platform; cases in testdata/library-search/cases.json.
enum CardSearch {
    /// Every word of the query is in the card's name or its type line (normalized like card names, so "jace" finds
    /// "Jace, the Mind Sculptor" and "legendary creature" finds legends). An empty query matches everything.
    static func matches(_ query: String, name: String, type: String) -> Bool {
        let words = CardName.norm(query).split(separator: " ")
        if words.isEmpty { return true }
        let hay = CardName.norm(name) + " | " + CardName.norm(type)
        return words.allSatisfy { hay.contains($0) }
    }

    /// One printing by set code, collector number or year: every word starts one of them ("mh2", "mh2 130",
    /// "2021", "130").
    static func matches(_ query: String, set: String, cn: String, releasedAt: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "#" })
        let hay = [set.lowercased(), cn.lowercased(), String(releasedAt.prefix(4))]
        return words.allSatisfy { w in hay.contains { $0.hasPrefix(w) } }
    }
}
