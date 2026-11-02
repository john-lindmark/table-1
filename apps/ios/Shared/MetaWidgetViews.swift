import SwiftUI
import WidgetKit

/* The Insights widgets' views (contract/widgets-2026-10-22.md § Meta widgets), on a pack passed in so the Debug
   gallery (-T1WidgetsDemo meta|grid|archetype) can draw them. Each archetype keeps its color across the three: its
   place among the window's eight largest (MetaWidgets.slots). */

/// What a widget shows: a format's pack, cut to the picked events and window.
struct MetaPicks: Equatable {
    var format = "modern"
    var tier = "big"
    var days = 30
    /// The archetype widget's; nil = the most played.
    var archetype: Int?

    /// The tier the pack can show (Big events falls back to All events when its window has no decks).
    func tier(in pack: MetaPack) -> String { MetaWidgets.tierFor(pack, want: tier, days: days) }

    /// Opens Insights on the same picks (`what`: nil = the format page, `matchups`, `archetype/<id>`).
    func link(_ what: String?, src: String) -> URL {
        let path = what.map { "/\($0)" } ?? ""
        return URL(string: "table1://insights/\(format)\(path)?tier=\(tier)&days=\(days)&src=\(src)")!
    }
}

enum MetaLook {
    static let surfaceHover = Color(red: 0x33 / 255, green: 0x33 / 255, blue: 0x4A / 255)
    /// Library Error pink, the matchup grid's "down" (as the Insights tab).
    static let down = Color(red: 0xF2 / 255, green: 0xA3 / 255, blue: 0xE5 / 255)

    static func fill(_ h: InsightCharts.Heat) -> Color {
        switch h.tone {
        case "none": W1.surface
        case "even": surfaceHover
        default: (h.tone == "up" ? W1.accent : down).opacity(h.strength)
        }
    }

    static func ink(_ h: InsightCharts.Heat) -> Color { h.ink ? W1.ink : h.dim ? W1.muted : W1.text }

    /// The heat's color as text on the background: accent above even, pink below.
    static func tone(_ h: InsightCharts.Heat) -> Color { h.tone == "up" ? W1.accent : h.tone == "down" ? down : W1.text }

    static func label(_ picks: MetaPicks, tier: String) -> String {
        "\(MetaFormats.short(picks.format)) · \(tier == "big" ? "Big" : "All") · \(picks.days)D"
    }
}

struct Swatch: View {
    let slot: Int?
    var size: CGFloat = 8
    var body: some View { Rectangle().fill(MetaPalette.color(slot)).frame(width: size, height: size) }
}

/// The pack hasn't arrived yet (first run offline).
struct MetaEmpty: View {
    let picks: MetaPicks
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WLabel("Insights", color: W1.accent)
            Spacer(minLength: 0)
            Text("\(MetaFormats.name(picks.format)) loads when you're online").font(W1.mono(13)).foregroundStyle(W1.text).lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Shares as one bar: each archetype in its color, the rest grey, 2 pt apart.
struct ShareBar: View {
    let rows: [MetaWidgets.Row]
    let rest: Double
    var body: some View {
        GeometryReader { g in
            let parts = rows.map { ($0.share, MetaPalette.color($0.slot)) } + [(rest, W1.surface)]
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            let total = max(1e-9, parts.reduce(0) { $0 + $1.0 })
            HStack(spacing: 2) {
                ForEach(parts.indices, id: \.self) { i in
                    Rectangle().fill(parts[i].1).frame(width: max(0, (g.size.width - gaps) * CGFloat(parts[i].0 / total)))
                }
            }
        }
    }
}

/// Share lines over the window, each in its archetype's color; hairline gridlines and their labels, a few dates.
struct MetaChart: View {
    let chart: MetaWidgets.Chart
    var dates = true

    var body: some View {
        GeometryReader { g in
            let left: CGFloat = 26, bottom: CGFloat = dates ? 12 : 0
            let w = max(1, g.size.width - left), h = max(1, g.size.height - bottom - 4)
            let ticks = InsightCharts.ticks(0, max(chart.top, 0.05), count: 2)
            let yMax = ticks.last ?? 1
            let x = { (i: Int) in left + w * CGFloat(i) / CGFloat(max(1, chart.days - 1)) }
            let y = { (v: Double) in 4 + h * (1 - CGFloat(v / max(1e-9, yMax))) }
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { t in
                    Path { p in p.move(to: .init(x: left, y: y(t))); p.addLine(to: .init(x: left + w, y: y(t))) }
                        .stroke(W1.surface, lineWidth: 1)
                    Text(InsightCharts.pct(t)).font(W1.mono(8)).foregroundStyle(W1.muted)
                        .position(x: left / 2 - 2, y: y(t))
                }
                if dates {
                    // newest first, each kept only when it clears the one to its right
                    let kept = chart.labels.reversed().reduce(into: [(Int, String)]()) { out, l in
                        if out.last.map({ x($0.0) - x(l.0) >= 52 }) ?? true { out.append(l) }
                    }
                    ForEach(kept.indices, id: \.self) { k in
                        let (i, l) = kept[k]
                        Text(l).font(W1.mono(8)).foregroundStyle(W1.muted).fixedSize()
                            .position(x: min(max(x(i), left + 16), g.size.width - 16), y: g.size.height - 5)
                    }
                }
                // the largest on top
                ForEach(chart.lines.indices.reversed(), id: \.self) { k in
                    let line = chart.lines[k]
                    Path { p in
                        for seg in InsightCharts.segments(line.v) {
                            for (n, pt) in seg.enumerated() {
                                let q = CGPoint(x: x(pt.0), y: y(pt.1))
                                if n == 0 { p.move(to: q) } else { p.addLine(to: q) }
                            }
                        }
                    }
                    .stroke(MetaPalette.color(line.slot), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - Meta breakdown

struct MetaBreakdownView: View {
    let family: WidgetFamily
    let pack: MetaPack?
    let picks: MetaPicks

    var body: some View {
        if let pack, let tier = Optional(picks.tier(in: pack)),
           let b = MetaWidgets.breakdown(pack, tier, picks.days, n: family == .systemLarge ? 8 : 5),
           !b.rows.isEmpty {
            let chart = MetaWidgets.chart(pack, tier, picks.days, ids: b.rows.map(\.a))
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 7) {
                    WLabel(MetaLook.label(picks, tier: tier))
                    ShareBar(rows: b.rows, rest: b.rest).frame(height: 6)
                    VStack(alignment: .leading, spacing: 5) { ForEach(b.rows, id: \.a) { row($0, size: 11) } }
                    Spacer(minLength: 0)
                }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 8) {
                    header(tier, b)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            ShareBar(rows: b.rows, rest: b.rest).frame(height: 5)
                            ForEach(b.rows, id: \.a) { row($0, size: 10) }
                        }
                        .frame(width: 148)
                        .frame(maxHeight: .infinity, alignment: .top)
                        MetaChart(chart: chart).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    header(tier, b)
                    MetaChart(chart: chart).frame(height: 140)
                    ShareBar(rows: b.rows, rest: b.rest).frame(height: 6)
                    VStack(spacing: 5) {
                        ForEach(b.rows, id: \.a) { r in
                            HStack(spacing: 6) {
                                Swatch(slot: r.slot)
                                Text(r.name).font(W1.mono(11)).foregroundStyle(W1.text).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(r.delta.map { ($0 >= 0 ? "▲" : "▼") + InsightCharts.delta($0).dropFirst() } ?? "")
                                    .font(W1.mono(10)).foregroundStyle((r.delta ?? 0) >= 0 ? W1.accent : MetaLook.down)
                                    .frame(width: 40, alignment: .trailing)
                                Text(r.wr.map { "W \(Int(($0 * 100).rounded()))%" } ?? "")
                                    .font(W1.mono(10)).foregroundStyle(W1.muted).frame(width: 44, alignment: .trailing)
                                Text(InsightCharts.pct(r.share)).font(W1.mono(11, .semibold)).foregroundStyle(W1.text)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            MetaEmpty(picks: picks)
        }
    }

    private func header(_ tier: String, _ b: MetaWidgets.Breakdown) -> some View {
        HStack {
            WLabel(MetaLook.label(picks, tier: tier))
            Spacer(minLength: 4)
            WLabel("\(b.decks.formatted()) decks")
        }
    }

    private func row(_ r: MetaWidgets.Row, size: CGFloat) -> some View {
        HStack(spacing: 6) {
            Swatch(slot: r.slot)
            Text(r.name).font(W1.mono(size)).foregroundStyle(W1.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(InsightCharts.pct(r.share)).font(W1.mono(size, .semibold)).foregroundStyle(W1.text)
        }
    }
}

// MARK: - Matchup grid

struct MatchupGridWidgetView: View {
    let family: WidgetFamily
    let pack: MetaPack?
    let picks: MetaPicks

    var body: some View {
        if let pack {
            let tier = picks.tier(in: pack)
            let large = family == .systemLarge
            let g = MetaWidgets.grid(pack, tier, picks.days, rows: large ? 12 : family == .systemMedium ? 5 : 4,
                                     cols: large ? 7 : family == .systemMedium ? 6 : 3)
            let nameWidth: CGFloat = family == .systemSmall ? 30 : large ? 104 : 96
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    WLabel(family == .systemSmall ? MetaFormats.short(picks.format) : "Matchups · " + MetaLook.label(picks, tier: tier))
                    Spacer(minLength: 0)
                }
                if g.rows.isEmpty || g.cols.isEmpty {
                    Spacer(minLength: 0)
                    Text("No matchups in this window").font(W1.mono(12)).foregroundStyle(W1.muted)
                    Spacer(minLength: 0)
                } else {
                    Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                        GridRow {
                            Color.clear.frame(width: nameWidth, height: 1)
                            ForEach(g.cols, id: \.a) { c in
                                VStack(spacing: 2) {
                                    Text(c.code).font(W1.mono(8)).foregroundStyle(W1.muted).lineLimit(1).minimumScaleFactor(0.7)
                                    Rectangle().fill(MetaPalette.color(c.slot)).frame(height: 2)
                                }
                            }
                        }
                        ForEach(g.rows.indices, id: \.self) { i in
                            GridRow {
                                HStack(spacing: 4) {
                                    Swatch(slot: g.rows[i].slot, size: 6)
                                    Text(family == .systemSmall ? MetaWidgets.codes([g.rows[i].name])[0] : g.rows[i].name)
                                        .font(W1.mono(9)).foregroundStyle(W1.text).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(width: nameWidth)
                                ForEach(g.cells[i].indices, id: \.self) { j in
                                    if let h = g.cells[i][j] {
                                        Text(h.label).font(W1.mono(9, h.ink ? .semibold : .regular)).foregroundStyle(MetaLook.ink(h))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(MetaLook.fill(h))
                                    } else {
                                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        } else {
            MetaEmpty(picks: picks)
        }
    }
}

// MARK: - One archetype's matchups

struct ArchetypeWidgetView: View {
    let family: WidgetFamily
    let pack: MetaPack?
    let picks: MetaPicks

    /// The archetype shown: the picked one when the format has it, else the most played.
    static func archetype(_ pack: MetaPack, _ picks: MetaPicks) -> Int? {
        let choices = MetaWidgets.choices(pack)
        if let a = picks.archetype, choices.contains(a) { return a }
        return pack.window(picks.tier(in: pack), picks.days)?.share.first { $0.a != 0 }?.a ?? choices.first
    }

    var body: some View {
        if let pack, let a = Self.archetype(pack, picks) {
            let tier = picks.tier(in: pack)
            let m = MetaWidgets.matchups(pack, tier, picks.days, archetype: a)
            let byId = Dictionary(m.rows.map { ($0.vs, $0) }, uniquingKeysWith: { l, _ in l })
            let good = m.good.compactMap { byId[$0] }, bad = m.bad.compactMap { byId[$0] }
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 4) {
                    title(m, tier, lines: 2, size: 13)
                    Spacer(minLength: 0)
                    win(m, size: 20)
                    WLabel(sub(m))
                    Spacer(minLength: 2)
                    if let b = good.first { line("Best", b) }
                    if let w = bad.first { line("Worst", w) }
                }
            case .systemMedium:
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        title(m, tier, lines: 2, size: 13)
                        Spacer(minLength: 0)
                        win(m, size: 22)
                        WLabel(sub(m))
                        if let r = m.record, r.count == 3 { WLabel("\(r[0])-\(r[1])-\(r[2])") }
                    }
                    .frame(width: 140, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        WLabel("Good against")
                        if good.isEmpty { none }
                        ForEach(good, id: \.vs) { matchup($0) }
                        Spacer(minLength: 2)
                        WLabel("Bad against")
                        if bad.isEmpty { none }
                        ForEach(bad, id: \.vs) { matchup($0) }
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    title(m, tier, lines: 1, size: 15)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        win(m, size: 24)
                        WLabel(sub(m))
                        Spacer(minLength: 0)
                    }
                    Rectangle().fill(W1.surface).frame(height: 1)
                    if m.rows.isEmpty {
                        Text("Not enough matches against other archetypes yet").font(W1.mono(12)).foregroundStyle(W1.muted)
                    }
                    VStack(spacing: 5) { ForEach(m.rows.prefix(14), id: \.vs) { bar($0) } }
                    Spacer(minLength: 0)
                    WLabel(m.title)
                }
            }
        } else {
            MetaEmpty(picks: picks)
        }
    }

    private var none: some View { Text("Nothing clear yet").font(W1.mono(10)).foregroundStyle(W1.muted) }

    private func title(_ m: MetaWidgets.Matchups, _ tier: String, lines: Int, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WLabel(MetaLook.label(picks, tier: tier))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Swatch(slot: m.slot)
                Text(m.name).font(W1.mono(size, .semibold)).foregroundStyle(W1.text).lineLimit(lines)
            }
        }
    }

    private func win(_ m: MetaWidgets.Matchups, size: CGFloat) -> some View {
        Text(m.wr.map { "Win \(InsightCharts.pct1($0))" } ?? "Win –").font(W1.mono(size, .semibold))
            .foregroundStyle(W1.text).lineLimit(1).minimumScaleFactor(0.6)
    }

    private func sub(_ m: MetaWidgets.Matchups) -> String { m.share.map { "\(InsightCharts.pct($0)) of the meta" } ?? "Not played this window" }

    private func line(_ word: String, _ r: MetaWidgets.MatchupRow) -> some View {
        HStack(spacing: 5) {
            Text(word.uppercased()).font(W1.mono(9)).tracking(1).foregroundStyle(W1.muted).frame(width: 40, alignment: .leading)
            Swatch(slot: r.slot, size: 6)
            Text(MetaWidgets.codes([r.name])[0]).font(W1.mono(10)).foregroundStyle(W1.text)
            Spacer(minLength: 2)
            Text("\(r.heat.label)%").font(W1.mono(10, .semibold)).foregroundStyle(MetaLook.tone(r.heat))
        }
    }

    private func matchup(_ r: MetaWidgets.MatchupRow) -> some View {
        HStack(spacing: 5) {
            Swatch(slot: r.slot, size: 6)
            Text(r.name).font(W1.mono(10)).foregroundStyle(W1.text).lineLimit(1)
            Spacer(minLength: 2)
            Text("\(r.heat.label)%").font(W1.mono(10, .semibold)).foregroundStyle(MetaLook.tone(r.heat))
        }
    }

    /// One matchup as a bar from 50%: right in the accent when it wins, left in pink when it loses (25–75% full).
    private func bar(_ r: MetaWidgets.MatchupRow) -> some View {
        HStack(spacing: 6) {
            Swatch(slot: r.slot, size: 6)
            Text(r.name).font(W1.mono(10)).foregroundStyle(W1.text).lineLimit(1)
            Spacer(minLength: 2)
            GeometryReader { g in
                let half = g.size.width / 2
                let d = CGFloat(min(0.25, abs(r.wr - 0.5)) / 0.25) * half
                ZStack(alignment: .leading) {
                    Rectangle().fill(W1.surface).frame(width: 1).offset(x: half)
                    Rectangle().fill(r.wr >= 0.5 ? W1.accent : MetaLook.down).opacity(r.heat.dim ? 0.5 : 1)
                        .frame(width: max(1, d), height: 6).offset(x: r.wr >= 0.5 ? half : half - d)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 70, height: 12)
            Text("\(r.heat.label)%").font(W1.mono(10, .semibold)).foregroundStyle(r.heat.dim ? W1.muted : W1.text)
                .frame(width: 30, alignment: .trailing)
            Text("\(r.wins + r.losses)").font(W1.mono(9)).foregroundStyle(W1.muted).frame(width: 30, alignment: .trailing)
        }
    }
}
