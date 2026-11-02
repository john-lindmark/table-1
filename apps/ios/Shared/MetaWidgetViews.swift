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

    /* Tinted Home Screens (and clear ones) drop every color and keep only how opaque each thing is, so a strong
       teal square became solid white under white text. Tinted, archetypes step down in opacity by place, winning
       squares fill faintly (never past a third), losing ones are outlined instead, and text stays full. */

    /// An archetype's color: its slot's, or tinted a white that fades with its place.
    static func slot(_ slot: Int?, tinted: Bool) -> Color {
        guard tinted else { return MetaPalette.color(slot) }
        return Color.white.opacity(slot.map { max(0.35, 1 - Double($0) * 0.09) } ?? 0.25)
    }

    static func fill(_ h: InsightCharts.Heat, tinted: Bool = false) -> Color {
        if tinted {
            switch h.tone {
            case "none": return .white.opacity(0.05)
            case "even": return .white.opacity(0.1)
            case "up": return .white.opacity(0.12 + 0.2 * h.strength)
            default: return .white.opacity(0.03)
            }
        }
        switch h.tone {
        case "none": return W1.surface
        case "even": return surfaceHover
        default: return (h.tone == "up" ? W1.accent : down).opacity(h.strength)
        }
    }

    /// Tinted, a losing square is outlined (its fill can't tell it from a winning one).
    static func outline(_ h: InsightCharts.Heat, tinted: Bool) -> Color {
        tinted && h.tone == "down" ? .white.opacity(0.3 + 0.4 * h.strength) : .clear
    }

    static func ink(_ h: InsightCharts.Heat, tinted: Bool = false) -> Color {
        if tinted { return .white.opacity(h.dim ? 0.55 : 1) }
        return h.ink ? W1.ink : h.dim ? W1.muted : W1.text
    }

    /// The heat's color as text on the background: accent above even, pink below.
    static func tone(_ h: InsightCharts.Heat, tinted: Bool = false) -> Color {
        tinted ? W1.text : h.tone == "up" ? W1.accent : h.tone == "down" ? down : W1.text
    }

    static func label(_ picks: MetaPicks, tier: String) -> String {
        "\(MetaFormats.short(picks.format)) · \(tier == "big" ? "Big" : "All") · \(picks.days)D"
    }
}

struct Swatch: View {
    let slot: Int?
    var size: CGFloat = 8
    var tinted = false
    var body: some View { Rectangle().fill(MetaLook.slot(slot, tinted: tinted)).frame(width: size, height: size) }
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

/// Shares as one bar: each archetype in its color, the rest grey, 2 pt apart; a highlighted one stays full.
struct ShareBar: View {
    let rows: [MetaWidgets.Row]
    let rest: Double
    var focus: Int? = nil
    var tinted = false
    var body: some View {
        GeometryReader { g in
            let parts = rows.map { ($0.share, MetaLook.slot($0.slot, tinted: tinted), focus == nil || focus == $0.a) }
                + [(rest, tinted ? Color.white.opacity(0.12) : W1.surface, focus == nil)]
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            let total = max(1e-9, parts.reduce(0) { $0 + $1.0 })
            HStack(spacing: 2) {
                ForEach(parts.indices, id: \.self) { i in
                    Rectangle().fill(parts[i].1).opacity(parts[i].2 ? 1 : 0.25)
                        .frame(width: max(0, (g.size.width - gaps) * CGFloat(parts[i].0 / total)))
                }
            }
        }
    }
}

/// Share lines over the window, each in its archetype's color; hairline gridlines and their labels, a few dates.
/// A highlighted archetype's line is drawn on top at full strength and the others fade.
struct MetaChart: View {
    let chart: MetaWidgets.Chart
    var dates = true
    var focus: Int? = nil
    var tinted = false

    var body: some View {
        GeometryReader { g in
            let left: CGFloat = 26, bottom: CGFloat = dates ? 12 : 0
            let w = max(1, g.size.width - left), h = max(1, g.size.height - bottom - 4)
            let ticks = InsightCharts.ticks(0, max(chart.top, 0.05), count: 2)
            let yMax = ticks.last ?? 1
            let x = { (i: Int) in left + w * CGFloat(i) / CGFloat(max(1, chart.days - 1)) }
            let y = { (v: Double) in 4 + h * (1 - CGFloat(v / max(1e-9, yMax))) }
            let grid = tinted ? Color.white.opacity(0.15) : W1.surface
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { t in
                    Path { p in p.move(to: .init(x: left, y: y(t))); p.addLine(to: .init(x: left + w, y: y(t))) }
                        .stroke(grid, lineWidth: 1)
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
                // the largest on top, and a highlighted one over everything
                let order = chart.lines.indices.reversed().sorted { (chart.lines[$0].a == focus ? 1 : 0) < (chart.lines[$1].a == focus ? 1 : 0) }
                ForEach(order, id: \.self) { k in
                    let line = chart.lines[k]
                    let on = focus == nil || focus == line.a
                    Path { p in
                        for seg in InsightCharts.segments(line.v) {
                            for (n, pt) in seg.enumerated() {
                                let q = CGPoint(x: x(pt.0), y: y(pt.1))
                                if n == 0 { p.move(to: q) } else { p.addLine(to: q) }
                            }
                        }
                    }
                    .stroke(MetaLook.slot(line.slot, tinted: tinted).opacity(on ? 1 : 0.2),
                            style: StrokeStyle(lineWidth: focus == line.a ? 2 : 1.5, lineCap: .round, lineJoin: .round))
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
    /// The archetype whose row was tapped (medium and up): its line leads, the rest fade.
    var focus: Int? = nil
    /// The gallery's stand-in for a tinted Home Screen.
    var tintedPreview: Bool? = nil
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let tinted = tintedPreview ?? (mode == .accented)
        if let pack, let tier = Optional(picks.tier(in: pack)),
           let b = MetaWidgets.breakdown(pack, tier, picks.days, n: family == .systemLarge ? 8 : 5),
           !b.rows.isEmpty {
            let chart = MetaWidgets.chart(pack, tier, picks.days, ids: b.rows.map(\.a))
            let focus = b.rows.contains { $0.a == focus } ? focus : nil
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 7) {
                    WLabel(MetaLook.label(picks, tier: tier))
                    ShareBar(rows: b.rows, rest: b.rest, tinted: tinted).frame(height: 6)
                    VStack(alignment: .leading, spacing: 5) { ForEach(b.rows, id: \.a) { row($0, size: 11, tinted: tinted) } }
                    Spacer(minLength: 0)
                }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 8) {
                    header(tier, b)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            ShareBar(rows: b.rows, rest: b.rest, focus: focus, tinted: tinted).frame(height: 5)
                            ForEach(b.rows, id: \.a) { r in tap(r) { row(r, size: 10, tinted: tinted).opacity(dim(r, focus)) } }
                        }
                        .frame(width: 148)
                        .frame(maxHeight: .infinity, alignment: .top)
                        MetaChart(chart: chart, focus: focus, tinted: tinted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    header(tier, b)
                    MetaChart(chart: chart, focus: focus, tinted: tinted).frame(height: 140)
                    ShareBar(rows: b.rows, rest: b.rest, focus: focus, tinted: tinted).frame(height: 6)
                    VStack(spacing: 5) {
                        ForEach(b.rows, id: \.a) { r in
                            tap(r) {
                                HStack(spacing: 6) {
                                    Swatch(slot: r.slot, tinted: tinted)
                                    Text(r.name).font(W1.mono(11)).foregroundStyle(W1.text).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(r.delta.map { ($0 >= 0 ? "▲" : "▼") + InsightCharts.delta($0).dropFirst() } ?? "")
                                        .font(W1.mono(10)).foregroundStyle(tinted ? W1.text : (r.delta ?? 0) >= 0 ? W1.accent : MetaLook.down)
                                        .frame(width: 40, alignment: .trailing)
                                    Text(r.wr.map { "W \(Int(($0 * 100).rounded()))%" } ?? "")
                                        .font(W1.mono(10)).foregroundStyle(W1.muted).frame(width: 44, alignment: .trailing)
                                    Text(InsightCharts.pct(r.share)).font(W1.mono(11, .semibold)).foregroundStyle(W1.text)
                                        .frame(width: 38, alignment: .trailing)
                                }
                                .opacity(dim(r, focus))
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

    private func dim(_ r: MetaWidgets.Row, _ focus: Int?) -> Double { focus == nil || focus == r.a ? 1 : 0.4 }

    /// A legend row: tap to highlight its line, again to let go.
    private func tap(_ r: MetaWidgets.Row, @ViewBuilder _ content: () -> some View) -> some View {
        Button(intent: MetaSelectIntent(key: MetaSelection.key("meta", picks), value: String(r.a))) {
            content().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func header(_ tier: String, _ b: MetaWidgets.Breakdown) -> some View {
        HStack {
            WLabel(MetaLook.label(picks, tier: tier))
            Spacer(minLength: 4)
            WLabel("\(b.decks.formatted()) decks")
        }
    }

    private func row(_ r: MetaWidgets.Row, size: CGFloat, tinted: Bool) -> some View {
        HStack(spacing: 6) {
            Swatch(slot: r.slot, tinted: tinted)
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
    /// The tapped square, as (row archetype, column archetype): outlined, its names lit, its record on top.
    var selected: (Int, Int)? = nil
    var tintedPreview: Bool? = nil
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let tinted = tintedPreview ?? (mode == .accented)
        if let pack {
            let tier = picks.tier(in: pack)
            let large = family == .systemLarge
            let g = MetaWidgets.grid(pack, tier, picks.days, rows: large ? 12 : family == .systemMedium ? 5 : 4,
                                     cols: large ? 7 : family == .systemMedium ? 6 : 3)
            let nameWidth: CGFloat = family == .systemSmall ? 30 : large ? 104 : 96
            // a pick is only shown while its square is on the widget
            let sel = selected.flatMap { s in g.rows.contains { $0.a == s.0 } && g.cols.contains { $0.a == s.1 } ? s : nil }
            let detail = sel.flatMap { MetaWidgets.cellDetail(pack, tier, picks.days, $0.0, $0.1) }
            let lit = tinted ? Color.white.opacity(0.14) : MetaLook.surfaceHover
            VStack(alignment: .leading, spacing: 4) {
                if let detail {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(detail.title).font(W1.mono(9, .semibold)).foregroundStyle(W1.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(detail.record).font(W1.mono(9)).foregroundStyle(W1.text)
                    }
                    if large { WLabel(detail.line) }
                } else {
                    HStack {
                        WLabel(family == .systemSmall ? MetaFormats.short(picks.format) : "Matchups · " + MetaLook.label(picks, tier: tier))
                        Spacer(minLength: 0)
                    }
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
                                    Text(c.code).font(W1.mono(8)).foregroundStyle(sel?.1 == c.a ? W1.text : W1.muted)
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                    Rectangle().fill(MetaLook.slot(c.slot, tinted: tinted)).frame(height: 2)
                                }
                                .background(sel?.1 == c.a ? lit : .clear)
                            }
                        }
                        ForEach(g.rows.indices, id: \.self) { i in
                            GridRow {
                                HStack(spacing: 4) {
                                    Swatch(slot: g.rows[i].slot, size: 6, tinted: tinted)
                                    Text(family == .systemSmall ? MetaWidgets.codes([g.rows[i].name])[0] : g.rows[i].name)
                                        .font(W1.mono(9)).foregroundStyle(W1.text).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(width: nameWidth)
                                .frame(maxHeight: .infinity)
                                .background(sel?.0 == g.rows[i].a ? lit : .clear)
                                ForEach(g.cells[i].indices, id: \.self) { j in
                                    if let h = g.cells[i][j] {
                                        let on = sel?.0 == g.rows[i].a && sel?.1 == g.cols[j].a
                                        Button(intent: MetaSelectIntent(key: MetaSelection.key("grid", picks), value: "\(g.rows[i].a):\(g.cols[j].a)")) {
                                            Text(h.label).font(W1.mono(9, h.ink || on ? .semibold : .regular)).foregroundStyle(MetaLook.ink(h, tinted: tinted))
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .background(MetaLook.fill(h, tinted: tinted))
                                                .overlay(Rectangle().strokeBorder(MetaLook.outline(h, tinted: tinted), lineWidth: 1))
                                                .overlay(Rectangle().strokeBorder(on ? W1.text : .clear, lineWidth: 1.5))
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
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
    var tintedPreview: Bool? = nil
    @Environment(\.widgetRenderingMode) private var mode
    private var tinted: Bool { tintedPreview ?? (mode == .accented) }

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
                    Rectangle().fill(tinted ? Color.white.opacity(0.2) : W1.surface).frame(height: 1)
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
                Swatch(slot: m.slot, tinted: tinted)
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
            Swatch(slot: r.slot, size: 6, tinted: tinted)
            Text(MetaWidgets.codes([r.name])[0]).font(W1.mono(10)).foregroundStyle(W1.text)
            Spacer(minLength: 2)
            Text("\(r.heat.label)%").font(W1.mono(10, .semibold)).foregroundStyle(MetaLook.tone(r.heat, tinted: tinted))
        }
    }

    private func matchup(_ r: MetaWidgets.MatchupRow) -> some View {
        HStack(spacing: 5) {
            Swatch(slot: r.slot, size: 6, tinted: tinted)
            Text(r.name).font(W1.mono(10)).foregroundStyle(W1.text).lineLimit(1)
            Spacer(minLength: 2)
            Text("\(r.heat.label)%").font(W1.mono(10, .semibold)).foregroundStyle(MetaLook.tone(r.heat, tinted: tinted))
        }
    }

    /// One matchup as a bar from 50%: right in the accent when it wins, left in pink when it loses (25–75% full).
    private func bar(_ r: MetaWidgets.MatchupRow) -> some View {
        HStack(spacing: 6) {
            Swatch(slot: r.slot, size: 6, tinted: tinted)
            Text(r.name).font(W1.mono(10)).foregroundStyle(W1.text).lineLimit(1)
            Spacer(minLength: 2)
            GeometryReader { g in
                let half = g.size.width / 2
                let d = CGFloat(min(0.25, abs(r.wr - 0.5)) / 0.25) * half
                ZStack(alignment: .leading) {
                    Rectangle().fill(tinted ? Color.white.opacity(0.3) : W1.surface).frame(width: 1).offset(x: half)
                    // tinted, a losing bar is the fainter one
                    Rectangle().fill(tinted ? Color.white.opacity(r.wr >= 0.5 ? 1 : 0.45) : r.wr >= 0.5 ? W1.accent : MetaLook.down)
                        .opacity(r.heat.dim ? 0.5 : 1)
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
