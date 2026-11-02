import AppIntents
import Foundation
import SwiftUI

/* The Insights home screen widgets (contract/widgets-2026-10-22.md § Meta widgets): Meta breakdown, Matchup grid and
   one archetype's matchups. What they show comes from the format's public Insights pack (the same file the Insights tab
   reads), cut to the picked events and window by MetaWidgets: the same answers as the Python reference
   testdata/meta-widgets/make_cases.py and Android's MetaWidgetData.kt (MetaWidgetTests checks this file). */

/// The parts of a constructed Insights pack the widgets read (contract/insights-2026-10-24.md § Constructed pack).
struct MetaPack: Decodable {
    struct Archetype: Decodable { let id: Int; let name: String }
    struct Share: Decodable { let a: Int; let share: Double; let prev: Double?; let wr: Double?; let rec: [Int]? }
    struct Grid: Decodable { let archetypes: [Int]; let cells: [[Int]]; let rows: [Int]? }
    struct Window: Decodable { let decks: Int; let share: [Share]; let matchups: Grid? }
    struct Line: Decodable { let a: Int; let v: [Double?] }
    struct Series: Decodable { let from: String; let days: Int; let lines: [Line] }
    struct View: Decodable { let windows: [String: Window]; let series: Series? }

    let format: String
    let name: String
    let through: String
    let archetypes: [Archetype]
    let tiers: [String: View]
    let matchups: Grid

    func window(_ tier: String, _ days: Int) -> Window? { tiers[tier]?.windows[String(days)] }
    func name(_ id: Int) -> String { archetypes.first { $0.id == id }?.name ?? "Other" }
}

/// The formats Insights covers, in its order.
enum MetaFormats {
    static let all: [(key: String, name: String)] = [
        ("standard", "Standard"), ("pioneer", "Pioneer"), ("modern", "Modern"), ("legacy", "Legacy"),
        ("vintage", "Vintage"), ("pauper", "Pauper"), ("canlander", "Canadian Highlander"),
    ]
    static func name(_ key: String) -> String { all.first { $0.key == key }?.name ?? key.capitalized }
    /// Short, for a widget's label: "Canlander" stays one word.
    static func short(_ key: String) -> String { key == "canlander" ? "Canlander" : name(key) }
}

enum MetaWidgets {
    /// The categorical palette's colors (validated on Table 1's #171725); archetypes past the eighth are grey.
    static let slots = 8

    /// The picked tier when its window has decks, else All events.
    static func tierFor(_ pack: MetaPack, want: String, days: Int) -> String {
        (pack.window(want, days)?.decks ?? 0) > 0 ? want : "all"
    }

    /// Color slot per archetype: the eight largest named archetypes of the window, largest first; Other has none.
    static func slots(_ pack: MetaPack, _ tier: String, _ days: Int) -> [Int: Int] {
        let named = (pack.window(tier, days)?.share ?? []).filter { $0.a != 0 }.prefix(slots)
        return Dictionary(uniqueKeysWithValues: named.enumerated().map { ($0.element.a, $0.offset) })
    }

    struct Row: Equatable { let a: Int; let name: String; let share: Double; let delta: Double?; let wr: Double?; let slot: Int? }
    struct Breakdown: Equatable { let decks: Int; let rows: [Row]; let rest: Double }

    /// The n largest named archetypes with share, change on the window before and win rate; `rest` is the remainder.
    static func breakdown(_ pack: MetaPack, _ tier: String, _ days: Int, n: Int) -> Breakdown? {
        guard let w = pack.window(tier, days) else { return nil }
        let s = slots(pack, tier, days)
        let rows = w.share.filter { $0.a != 0 }.prefix(n).map { r in
            Row(a: r.a, name: pack.name(r.a), share: r.share, delta: r.prev.map { r.share - $0 }, wr: r.wr, slot: s[r.a])
        }
        return Breakdown(decks: w.decks, rows: rows, rest: max(0, 1 - rows.reduce(0) { $0 + $1.share }))
    }

    struct ChartLine: Equatable { let a: Int; let slot: Int?; let v: [Double?] }
    struct Chart: Equatable {
        let days: Int; let lines: [ChartLine]; let top: Double
        /// Axis labels from the series' first day (InsightCharts.window).
        var labels: [(Int, String)] = []
        static func == (l: Chart, r: Chart) -> Bool { l.days == r.days && l.lines == r.lines && l.top == r.top }
    }

    /// The share lines of `ids` over the window; archetypes with no line, or no value in it, are left out.
    static func chart(_ pack: MetaPack, _ tier: String, _ days: Int, ids: [Int]) -> Chart {
        guard let s = pack.tiers[tier]?.series else { return Chart(days: 0, lines: [], top: 0) }
        let offset = max(0, s.days - days)
        let sl = slots(pack, tier, days)
        let lines = ids.compactMap { a -> ChartLine? in
            guard let line = s.lines.first(where: { $0.a == a }) else { return nil }
            let v = Array(line.v.dropFirst(offset))
            return v.contains { $0 != nil } ? ChartLine(a: a, slot: sl[a], v: v) : nil
        }
        let top = lines.flatMap { $0.v.compactMap { $0 } }.max() ?? 0
        let labels = InsightCharts.window(from: s.from, days: s.days, keep: days).labels
        return Chart(days: s.days - offset, lines: lines, top: top, labels: labels)
    }

    private static func words(_ name: String) -> [String] {
        name.replacingOccurrences(of: "'s", with: "").split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    /// Short column names: initials (one word: its first three letters); a clash takes the first word's first two
    /// letters and the other initials, then a number.
    static func codes(_ names: [String]) -> [String] {
        var out: [String] = []
        for n in names {
            let w = words(n)
            var c = w.isEmpty ? "?" : w.count == 1 ? String(w[0].prefix(3)).uppercased() : w.prefix(3).map { String($0.prefix(1)) }.joined().uppercased()
            if out.contains(c) {
                c = w.count > 1 ? (String(w[0].prefix(2)) + w.dropFirst().prefix(2).map { String($0.prefix(1)) }.joined()).uppercased()
                    : w.isEmpty ? "?" : String(w[0].prefix(4)).uppercased()
                let base = c
                var k = 2
                while out.contains(c) { c = "\(base)\(k)"; k += 1 }
            }
            out.append(c)
        }
        return out
    }

    /// The window's grid, else the pack's 90-day All events grid (the Insights tab's rule), with its title.
    static func gridOf(_ pack: MetaPack, _ tier: String, _ days: Int) -> (MetaPack.Grid, String) {
        if let m = pack.window(tier, days)?.matchups { return (m, "\(tier == "big" ? "Big events" : "All events"), last \(days) days") }
        return (pack.matchups, "All events, last 90 days")
    }

    static func rowIds(_ m: MetaPack.Grid) -> [Int] { (m.rows?.isEmpty == false ? m.rows : nil) ?? m.archetypes }

    /// a against b: wins, losses, draws from a's side.
    static func cell(_ m: MetaPack.Grid, _ a: Int, _ b: Int) -> (Int, Int, Int)? {
        for c in m.cells where c.count >= 5 {
            if c[0] == a && c[1] == b { return (c[2], c[3], c[4]) }
            if c[0] == b && c[1] == a { return (c[3], c[2], c[4]) }
        }
        return nil
    }

    struct Col: Equatable { let a: Int; let name: String; let code: String; let slot: Int? }
    struct GridRow: Equatable { let a: Int; let name: String; let slot: Int? }
    struct GridView: Equatable { let title: String; let cols: [Col]; let rows: [GridRow]; let cells: [[InsightCharts.Heat?]] }

    /// The top-left of the matchup grid that fits: the most played columns and the first rows. A row's own column is
    /// nil; a pair with no matches has tone "none".
    static func grid(_ pack: MetaPack, _ tier: String, _ days: Int, rows maxRows: Int, cols maxCols: Int) -> GridView {
        let (m, title) = gridOf(pack, tier, days)
        let sl = slots(pack, tier, days)
        let cols = Array(m.archetypes.prefix(max(0, maxCols)))
        let rows = Array(rowIds(m).prefix(max(0, maxRows)))
        let names = cols.map(pack.name)
        let codes = codes(names)
        let cells = rows.map { r in
            cols.map { c -> InsightCharts.Heat? in
                guard r != c else { return nil }
                let x = cell(m, r, c) ?? (0, 0, 0)
                return InsightCharts.heat(wins: x.0, losses: x.1)
            }
        }
        return GridView(title: title,
                        cols: cols.indices.map { Col(a: cols[$0], name: names[$0], code: codes[$0], slot: sl[cols[$0]]) },
                        rows: rows.map { GridRow(a: $0, name: pack.name($0), slot: sl[$0]) }, cells: cells)
    }

    struct MatchupRow: Equatable {
        let vs: Int; let name: String; let slot: Int?; let wins: Int; let losses: Int; let draws: Int; let wr: Double
        let heat: InsightCharts.Heat
    }
    struct Matchups: Equatable {
        let a: Int; let name: String; let slot: Int?; let title: String; let share: Double?; let wr: Double?; let record: [Int]?
        let rows: [MatchupRow]; let good: [Int]; let bad: [Int]
    }

    /// One archetype against every other row of the grid, most played first; pairs with no decided match are left
    /// out. Good / bad against: 20+ decided matches above / below 50%, three each, best (worst) first, then most
    /// matches (the deck screen's rule), never Other. Share, win rate and record from the window's Meta now row.
    static func matchups(_ pack: MetaPack, _ tier: String, _ days: Int, archetype a: Int) -> Matchups {
        let (m, title) = gridOf(pack, tier, days)
        let sl = slots(pack, tier, days)
        let me = pack.window(tier, days)?.share.first { $0.a == a }
        let ids = rowIds(m)
        let rows: [MatchupRow] = ids.contains(a) ? ids.compactMap { b in
            guard b != a, let x = cell(m, a, b), x.0 + x.1 > 0 else { return nil }
            return MatchupRow(vs: b, name: pack.name(b), slot: sl[b], wins: x.0, losses: x.1, draws: x.2,
                              wr: Double(x.0) / Double(x.0 + x.1), heat: InsightCharts.heat(wins: x.0, losses: x.1))
        } : []
        let decided = rows.filter { $0.wins + $0.losses >= 20 && $0.vs != 0 }
        let good = decided.filter { $0.wr > 0.5 }.sorted { ($0.wr, $0.wins + $0.losses) > ($1.wr, $1.wins + $1.losses) }.prefix(3)
        let bad = decided.filter { $0.wr < 0.5 }.sorted { ($0.wr, -($0.wins + $0.losses)) < ($1.wr, -($1.wins + $1.losses)) }.prefix(3)
        return Matchups(a: a, name: pack.name(a), slot: sl[a], title: title, share: me?.share, wr: me?.wr, record: me?.rec,
                        rows: rows, good: good.map(\.vs), bad: bad.map(\.vs))
    }

    struct CellDetail: Equatable { let title: String; let line: String; let record: String }

    /// A tapped square, worded as the Insights tab's grid: "A vs B", the win rate with its likely range from 30
    /// matches (else "Only N matches: too few to say"), and the record. Nil when a row meets itself or the pair has
    /// no decided match.
    static func cellDetail(_ pack: MetaPack, _ tier: String, _ days: Int, _ a: Int, _ b: Int) -> CellDetail? {
        guard a != b, let x = cell(gridOf(pack, tier, days).0, a, b), x.0 + x.1 > 0 else { return nil }
        let n = x.0 + x.1
        let ci = InsightCharts.wilson(wins: x.0, n: n)
        let line = n >= 30 ? "\(InsightCharts.pct1(Double(x.0) / Double(n))) · likely \(InsightCharts.pct(ci.lo))–\(InsightCharts.pct(ci.hi))"
            : "Only \(n) matches: too few to say"
        return CellDetail(title: "\(pack.name(a)) vs \(pack.name(b))", line: line,
                          record: "\(x.0)-\(x.1)" + (x.2 > 0 ? "-\(x.2)" : ""))
    }

    /// The archetypes a widget can follow: the 90-day grid's rows (they have matchups), then the other named ones by
    /// name. Never Other.
    static func choices(_ pack: MetaPack) -> [Int] {
        let rows = rowIds(pack.matchups).filter { $0 != 0 }
        let rest = pack.archetypes.filter { $0.id != 0 && !rows.contains($0.id) }.sorted { $0.name < $1.name }.map(\.id)
        return rows + rest
    }
}

/// The eight categorical colors (dataviz reference palette, dark steps, checked against #171725 with its validator:
/// lightness, chroma, color-blind and normal-vision separation, 3:1 contrast), and grey past them.
enum MetaPalette {
    static let colors: [Color] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9, 0xE66767].map {
        Color(red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }
    static let none = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x7E / 255)
    static func color(_ slot: Int?) -> Color { slot.flatMap { colors.indices.contains($0) ? colors[$0] : nil } ?? none }
}

/// The packs on the device, in the App Group: fetched by the widgets themselves (the pack is public), at most every
/// 3 hours (packs are rebuilt every 6), with If-None-Match, 8 s.
enum MetaPackStore {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: T1Shared.appGroup) }
    private static func file(_ format: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: T1Shared.appGroup)?
            .appending(path: "meta", directoryHint: .isDirectory).appending(path: "\(format).json")
    }

    static func url(_ format: String) -> URL {
        T1Shared.supabaseURL.appending(path: "storage/v1/object/public/catalog/insights/constructed/\(format).json")
    }

    static func decode(_ data: Data) -> MetaPack? { try? JSONDecoder().decode(MetaPack.self, from: data) }

    static func load(_ format: String) -> MetaPack? {
        guard let f = file(format), let data = try? Data(contentsOf: f) else { return nil }
        return decode(data)
    }

    /// The held pack, refreshed first when it's older than `maxAge`; the held one when the network fails.
    static func fresh(_ format: String, maxAge: TimeInterval = 3 * 3600) async -> MetaPack? {
        let at = defaults?.double(forKey: "meta.\(format).at") ?? 0
        let held = load(format)
        if held != nil, Date.now.timeIntervalSince1970 - at < maxAge { return held }
        var req = URLRequest(url: url(format), timeoutInterval: 8)
        if held != nil, let tag = defaults?.string(forKey: "meta.\(format).etag") { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await T1Shared.session.data(for: req), let http = response as? HTTPURLResponse else { return held }
        if http.statusCode == 304, held != nil {
            defaults?.set(Date.now.timeIntervalSince1970, forKey: "meta.\(format).at")
            return held
        }
        guard http.statusCode == 200, let pack = decode(data), let f = file(format) else { return held }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: f, options: .atomic)
        defaults?.set(Date.now.timeIntervalSince1970, forKey: "meta.\(format).at")
        defaults?.set(http.value(forHTTPHeaderField: "ETag"), forKey: "meta.\(format).etag")
        return pack
    }
}

/// What's tapped in an Insights widget: a grid square ("12:4") or a Meta row ("12"), per widget kind and picks
/// (a widget's intent can't name the widget it's on, so two widgets with the same picks share it). A second tap
/// on the same thing lets it go.
enum MetaSelection {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: T1Shared.appGroup) }

    static func key(_ kind: String, _ picks: MetaPicks) -> String { "\(kind)|\(picks.format)|\(picks.tier)|\(picks.days)" }

    static func get(_ key: String) -> String? { defaults?.string(forKey: "meta.sel.\(key)") }

    /// The new selection after tapping `value` while `current` is selected.
    static func toggled(_ current: String?, _ value: String) -> String? { current == value ? nil : value }

    static func toggle(_ key: String, _ value: String) {
        defaults?.set(toggled(get(key), value), forKey: "meta.sel.\(key)")
    }

    /// "12:4" → (12, 4).
    static func cell(_ s: String?) -> (Int, Int)? {
        let p = (s ?? "").split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }
}

/// A tap on a grid square or a Meta row: picks it (or lets it go) and the widget redraws. Runs in the widget.
struct MetaSelectIntent: AppIntent {
    static var title: LocalizedStringResource = "Pick in an Insights widget"
    static var isDiscoverable = false

    @Parameter(title: "Key") var key: String
    @Parameter(title: "Value") var value: String

    init() {}
    init(key: String, value: String) { self.key = key; self.value = value }

    func perform() async throws -> some IntentResult {
        MetaSelection.toggle(key, value)
        return .result()
    }
}
