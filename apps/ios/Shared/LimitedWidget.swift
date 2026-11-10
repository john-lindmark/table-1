import AppIntents
import Foundation
import Supabase
import WidgetKit

/* The Limited cards widget (contract/widgets-2026-10-22.md § Limited cards widget): a set's best cards in draft from
   its public Limited pack (the file Insights → Limited reads), cut by the widget's own Set, Rarity, Color and Sort.
   The order and the numbers are the app's Top cards (LimitedFilter.cards / LimitedFilter.value); shared cases
   testdata/insights/limited-home.json, which LimitedHomeTests checks against this file too. */

/// What the Top cards order needs of a card; the app's Insights.LCard and the widget's card both have it.
protocol LimitedSortable {
    var n: String { get }
    var r: String? { get }
    var col: String? { get }
    var gih: Double? { get }
    var gih_n: Int { get }
    var oh: Double? { get }
    var iwd: Double? { get }
    var ata: Double? { get }
}

extension LimitedFilter {
    /// The sorts, in the pickers' order: key, name, column code.
    static let sorts: [(key: String, label: String, code: String)] = [
        ("gih", "Win rate in hand", "GIH WR"), ("oh", "Win rate in opening hand", "OH WR"),
        ("iwd", "Improvement when drawn", "IWD"), ("ata", "Average pick taken", "ATA"),
    ]

    /// The cards the filters keep, best first: the sort's value high to low (ATA low to high), cards without one last;
    /// ties by games in hand, then name. A cube's cards have no rarity, so the rarity filter is ignored there.
    static func cards<T: LimitedSortable>(_ cards: [T], sort: String, rarity: [String], color: [String]) -> [T] {
        let rated = cards.contains { $0.r != nil }
        let kept = cards.filter { keepsRarity($0.r, rarity, rated: rated) && keepsColor($0.col, color) }
        func key(_ c: T) -> Double? {
            switch sort { case "oh": c.oh; case "iwd": c.iwd; case "ata": c.ata.map { -$0 }; default: c.gih }
        }
        return kept.sorted { a, b in
            switch (key(a), key(b)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.gih_n != b.gih_n ? a.gih_n > b.gih_n : a.n < b.n
            }
        }
    }

    /// A row's number for the sort, and for the win rates how far it sits from the view's average, in points.
    static func value<T: LimitedSortable>(_ c: T, sort: String, average: Double) -> (value: String, vs: String?) {
        switch sort {
        case "ata": return (c.ata.map { String(format: "%.1f", $0) } ?? "–", nil)
        case "iwd": return (c.iwd.map { InsightCharts.delta($0) } ?? "–", nil)
        default:
            let x = sort == "oh" ? c.oh : c.gih
            return (InsightCharts.pct1(x), x.map { InsightCharts.delta($0 - average) })
        }
    }
}

/// The parts of a Limited pack the widget reads (contract/insights-2026-10-24.md § Limited pack).
struct LimitedWidgetPack: Decodable {
    struct Card: Decodable, LimitedSortable {
        let n: String; let r: String?; let col: String?
        let gih: Double?; let gih_n: Int; let oh: Double?; let iwd: Double?; let ata: Double?
    }
    struct View: Decodable { let games: Int; let wr: Double; let cards: [Card] }
    struct Event: Decodable { let groups: [String: View] }
    let set_code: String
    let name: String?
    let events: [String: Event]

    static let eventOrder = ["PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed"]
    /// Premier draft when the set has it, else the first event the pack carries; all players.
    var view: View? {
        let ev = Self.eventOrder.first { events[$0] != nil } ?? events.keys.sorted().first
        return ev.flatMap { events[$0]?.groups["all"] }
    }
}

enum LimitedWidgets {
    struct Row: Equatable { let place: Int; let name: String; let col: String; let rarity: String?; let value: String; let vs: String?; let above: Bool }

    /// The widget's rows: the first `n` for the picks, with the sort's number.
    static func rows(_ pack: LimitedWidgetPack, sort: String, rarity: [String], color: [String], n: Int) -> [Row] {
        guard let v = pack.view else { return [] }
        return LimitedFilter.cards(v.cards, sort: sort, rarity: rarity, color: color).prefix(n).enumerated().map { i, c in
            let x = LimitedFilter.value(c, sort: sort, average: v.wr)
            let raw = sort == "oh" ? c.oh : c.gih
            return Row(place: i + 1, name: c.n, col: c.col.flatMap { $0.isEmpty ? nil : $0 } ?? "C",
                       rarity: c.r.map { String($0.prefix(1)).uppercased() }, value: x.value, vs: x.vs,
                       above: raw.map { $0 >= v.wr } ?? false)
        }
    }

    /// Opens Insights → Limited on the set; with `picks`, on the widget's Sort, Rarity and Color too (empty = Any):
    /// `table1://insights/limited/FRA?sort=gih&rarity=common&color=W,U&src=widget_limited`.
    static func link(_ set: String?, src: String, picks: LimitedPicks? = nil) -> URL {
        var c = URLComponents(string: "table1://insights/limited\(set.map { "/\($0)" } ?? "")")!
        var q: [URLQueryItem] = []
        if let picks {
            q += [URLQueryItem(name: "sort", value: picks.sort), URLQueryItem(name: "rarity", value: picks.rarity.joined(separator: ",")),
                  URLQueryItem(name: "color", value: picks.color.joined(separator: ","))]
        }
        c.queryItems = q + [URLQueryItem(name: "src", value: src)]
        return c.url!
    }

    /// The widget's one-tap buttons step through one pick at a time (contract § Limited cards widget "Buttons"):
    /// Any → the first option → … → the last → Any. Several picks from the widget's settings step to Any.
    static func next(_ picked: [String], in options: [String]) -> [String] {
        let shown = options.filter { picked.contains($0) }
        if shown.isEmpty { return options.first.map { [$0] } ?? [] }
        guard shown.count == 1, let i = options.firstIndex(of: shown[0]) else { return [] }
        return i + 1 < options.count ? [options[i + 1]] : []
    }

    /// The set after `current` in the device's Limited sets, round to the first; `current` when there's no other.
    static func nextSet(_ current: String?, in sets: [String]) -> String? {
        guard let first = sets.first else { return current }
        guard let current, let i = sets.firstIndex(of: current) else { return first }
        return sets[(i + 1) % sets.count]
    }

    /// The Rarity button: Any rarity, the one picked (Common), or the picks' letters (C · U). Compact widgets (medium)
    /// always use letters, every letter for Any, as the Color button shows every pip; small ones say All for Any.
    static func rarityButton(_ rarity: [String], small: Bool, tiny: Bool = false) -> String {
        let picked = LimitedFilter.rarities.filter { rarity.contains($0) }
        if picked.isEmpty { return tiny ? "All" : small ? "C·U·R·M" : "Any rarity" }
        if picked.count == 1, !small { return picked[0].capitalized }
        return picked.map { String($0.prefix(1)).uppercased() }.joined(separator: small ? "·" : " · ")
    }
}

/// What a widget's buttons picked, kept in the App Group per widget settings (an intent can't name the widget it's
/// on, so two widgets with the same settings share it). Editing a widget's settings starts it over from them.
enum LimitedWidgetSelection {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: T1Shared.appGroup) }

    /// A widget's settings as a key: the set it names (blank = the newest), sort, rarities, colors.
    static func key(set: String?, sort: String, rarity: [String], color: [String]) -> String {
        [set ?? "", sort, LimitedFilter.rarities.filter { rarity.contains($0) }.joined(separator: ","),
         LimitedFilter.colors.filter { color.contains($0) }.joined(separator: ",")].joined(separator: "|")
    }

    static func get(_ key: String) -> [String: String] {
        defaults?.dictionary(forKey: "limited.sel.\(key)") as? [String: String] ?? [:]
    }

    static func set(_ key: String, _ what: String, _ value: String) {
        var d = get(key)
        d[what] = value
        defaults?.set(d, forKey: "limited.sel.\(key)")
    }

    /// The settings' picks with the buttons' over them.
    static func applied(_ picks: LimitedPicks, _ sel: [String: String]) -> LimitedPicks {
        var p = picks
        func list(_ s: String) -> [String] { s.split(separator: ",").map(String.init) }
        if let s = sel["set"], !s.isEmpty { p.set = s }
        if let r = sel["rarity"] { p.rarity = LimitedFilter.rarities.filter { list(r).contains($0) } }
        if let c = sel["color"] { p.color = LimitedFilter.colors.filter { list(c).contains($0) } }
        return p
    }
}

/// A tap on one of the widget's buttons (Set, Rarity, Color): saves the next pick, and the widget redraws. A new set's
/// pack is fetched before the redraw. Runs in the widget, which has no telemetry of its own (like the Meta widgets' taps).
struct LimitedPickIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch a Limited cards widget"
    static var isDiscoverable = false

    @Parameter(title: "Key") var key: String
    /// set, rarity or color
    @Parameter(title: "What") var what: String
    /// The set code, or the picks joined with commas (blank = Any).
    @Parameter(title: "Value") var value: String

    init() {}
    init(key: String, what: String, value: String) { self.key = key; self.what = what; self.value = value }

    func perform() async throws -> some IntentResult {
        LimitedWidgetSelection.set(key, what, value)
        if what == "set", !value.isEmpty { _ = await LimitedPackStore.fresh(value) }
        return .result()
    }
}

/// The Limited sets the widget can show (Insights' index: kind limited), kept in the App Group: written by the app when
/// it loads Insights and by the widget's set picker, which asks for the index itself when signed in.
enum LimitedSetsStore {
    struct Set: Codable, Hashable { let key: String; let name: String }
    private static var defaults: UserDefaults? { UserDefaults(suiteName: T1Shared.appGroup) }
    private static let key = "limited.sets.v1"

    static func load() -> [Set] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Set].self, from: data)) ?? []
    }

    static func save(_ sets: [Set]) {
        guard !sets.isEmpty, let data = try? JSONEncoder().encode(sets) else { return }
        defaults?.set(data, forKey: key)
    }

    /// The index's Limited sets, newest first as the index lists them; the held list when signed out or offline.
    static func fresh() async -> [Set] {
        struct Entry: Decodable { let kind: String; let key: String; let name: String }
        if let rows: [Entry] = try? await T1Shared.client.rpc("insights_index").execute().value {
            let sets = rows.filter { $0.kind == "limited" }.map { Set(key: $0.key, name: $0.name) }
            save(sets)
            if !sets.isEmpty { return sets }
        }
        return load()
    }
}

enum LimitedPackStore {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: T1Shared.appGroup) }
    private static func file(_ set: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: T1Shared.appGroup)?
            .appending(path: "limited", directoryHint: .isDirectory).appending(path: "\(set).json")
    }

    static func url(_ set: String) -> URL {
        T1Shared.supabaseURL.appending(path: "storage/v1/object/public/catalog/insights/limited/\(set).json")
    }

    static func decode(_ data: Data) -> LimitedWidgetPack? { try? JSONDecoder().decode(LimitedWidgetPack.self, from: data) }

    static func load(_ set: String) -> LimitedWidgetPack? {
        guard let f = file(set), let data = try? Data(contentsOf: f) else { return nil }
        return decode(data)
    }

    /// The held pack, refreshed first when it's older than `maxAge`; the held one when the network fails.
    static func fresh(_ set: String, maxAge: TimeInterval = 6 * 3600) async -> LimitedWidgetPack? {
        let at = defaults?.double(forKey: "limited.\(set).at") ?? 0
        let held = load(set)
        if held != nil, Date.now.timeIntervalSince1970 - at < maxAge { return held }
        var req = URLRequest(url: url(set), timeoutInterval: 8)
        if held != nil, let tag = defaults?.string(forKey: "limited.\(set).etag") { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await T1Shared.session.data(for: req), let http = response as? HTTPURLResponse else { return held }
        if http.statusCode == 304, held != nil {
            defaults?.set(Date.now.timeIntervalSince1970, forKey: "limited.\(set).at")
            return held
        }
        guard http.statusCode == 200, let pack = decode(data), let f = file(set) else { return held }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: f, options: .atomic)
        defaults?.set(Date.now.timeIntervalSince1970, forKey: "limited.\(set).at")
        defaults?.set(http.value(forHTTPHeaderField: "ETag"), forKey: "limited.\(set).etag")
        return pack
    }
}
