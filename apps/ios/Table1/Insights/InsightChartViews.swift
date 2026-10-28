import SwiftUI

/// Insights charts in the Table 1 look: hairline axes on the surface, mono labels, no fills or shadows, grey for
/// context and teal only for the series the brief is about. Positions come from InsightCharts (shared maths).

/// Share lines over time with change markers along the axis and labels at the line ends.
struct InsightLineChart: View {
    struct Series: Identifiable { let id: Int; let label: String; let values: [Double?]; let highlighted: Bool }
    struct Marker: Hashable { let index: Int; let label: String; let ban: Bool }
    let series: [Series]
    var markers: [Marker] = []
    var xLabels: [(Int, String)] = []
    var count: Int
    var height: CGFloat = 190
    var format: (Double) -> String = InsightCharts.pct
    var labelWidth: CGFloat = 96
    /// Scale the y axis to the values (and the reference) instead of starting at 0, e.g. win rates around 50%.
    var fit = false
    /// A dashed line across the chart with its own end label, e.g. the average win rate in scope.
    var reference: (label: String, value: Double)?

    var body: some View {
        Canvas { ctx, size in
            let left: CGFloat = 34, right = labelWidth, top: CGFloat = 14, bottom: CGFloat = 18
            let w = max(1, size.width - left - right), h = max(1, size.height - top - bottom)
            let all = series.flatMap { $0.values.compactMap { $0 } } + (reference.map { [$0.value] } ?? [])
            let ticks = fit ? InsightCharts.ticks(all.min() ?? 0, all.max() ?? 1, count: 3)
                            : InsightCharts.ticks(0, max(all.max() ?? 0.1, 0.05), count: 3)
            let yMin = ticks.first ?? 0, yMax = ticks.last ?? 1
            let x = { (i: Int) in left + w * CGFloat(i) / CGFloat(max(1, count - 1)) }
            let y = { (v: Double) in top + h * (1 - CGFloat((v - yMin) / max(1e-9, yMax - yMin))) }
            for t in ticks {
                var p = Path()
                p.move(to: .init(x: left, y: y(t))); p.addLine(to: .init(x: left + w, y: y(t)))
                ctx.stroke(p, with: .color(T1.surfaceHover), lineWidth: 1)
                ctx.draw(Text(format(t)).font(T1.mono(9)).foregroundStyle(T1.muted), at: .init(x: left - 4, y: y(t)), anchor: .trailing)
            }
            for (i, l) in xLabels {
                ctx.draw(Text(l).font(T1.mono(9)).foregroundStyle(T1.muted), at: .init(x: x(i), y: size.height - 2), anchor: .bottom)
            }
            for m in markers where m.index >= 0 && m.index < count {
                var p = Path()
                p.move(to: .init(x: x(m.index), y: top)); p.addLine(to: .init(x: x(m.index), y: top + h))
                ctx.stroke(p, with: .color(m.ban ? T1.warning : T1.disabled), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text(m.label).font(T1.mono(8)).foregroundStyle(m.ban ? T1.warning : T1.muted), at: .init(x: x(m.index) + 2, y: 0), anchor: .topLeading)
            }
            if let r = reference {
                var p = Path()
                p.move(to: .init(x: left, y: y(r.value))); p.addLine(to: .init(x: left + w, y: y(r.value)))
                ctx.stroke(p, with: .color(T1.text), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            for s in series.sorted(by: { !$0.highlighted && $1.highlighted }) {
                for seg in InsightCharts.segments(s.values) {
                    var p = Path()
                    for (k, pt) in seg.enumerated() {
                        let q = CGPoint(x: x(pt.0), y: y(pt.1))
                        if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                    if seg.count == 1 { p.addEllipse(in: CGRect(x: x(seg[0].0) - 1.5, y: y(seg[0].1) - 1.5, width: 3, height: 3)) }
                    ctx.stroke(p, with: .color(s.highlighted ? T1.accent : T1.muted.opacity(0.55)), lineWidth: s.highlighted ? 2 : 1)
                }
            }
            // end labels, kept apart
            var ends = series.compactMap { s -> (String, Double, Color)? in
                s.values.last(where: { $0 != nil }).flatMap { $0 }.map { (s.label, $0, s.highlighted ? T1.accent : T1.muted) }
            }
            if let r = reference { ends.append((r.label, r.value, T1.text)) }
            let ys = InsightCharts.spread(ends.map { Double(y($0.1)) }, gap: 11, lo: Double(top), hi: Double(top + h))
            for (k, e) in ends.enumerated() {
                ctx.draw(Text("\(e.0) \(format(e.1))").font(T1.mono(9)).foregroundStyle(e.2),
                         at: .init(x: left + w + 6, y: ys[k]), anchor: .leading)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(series.map { "\($0.label) \($0.values.last(where: { $0 != nil }).flatMap { $0 }.map(format) ?? "")" }.joined(separator: ", "))
    }
}

/// One horizontal bar with its value and change, e.g. an archetype's share.
struct InsightBar: View {
    let label: String
    let value: Double
    var maxValue: Double
    var detail: String?
    var change: Double?
    var highlighted = false
    var format: (Double) -> String = InsightCharts.pct
    /// A reference line (e.g. the set's average win rate) drawn across the bar.
    var reference: Double?
    var minValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label).font(T1.mono(13)).lineLimit(1)
                Spacer(minLength: 4)
                if let change, abs(change) >= 0.0005 {
                    Text("\(change > 0 ? "▲" : "▼") \(InsightCharts.delta(change).dropFirst())")
                        .font(T1.mono(11)).foregroundStyle(change > 0 ? T1.text : T1.muted)
                }
                Text(format(value)).font(T1.mono(13)).foregroundStyle(highlighted ? T1.accent : T1.text)
            }
            GeometryReader { g in
                let span = max(1e-9, maxValue - minValue)
                let frac = CGFloat(max(0, min(1, (value - minValue) / span)))
                ZStack(alignment: .leading) {
                    Rectangle().fill(T1.surfaceHover)
                    Rectangle().fill(highlighted ? T1.accent : T1.muted).frame(width: g.size.width * frac)
                    if let reference {
                        Rectangle().fill(T1.text).frame(width: 1)
                            .offset(x: g.size.width * CGFloat(max(0, min(1, (reference - minValue) / span))))
                    }
                }
            }
            .frame(height: 4)
            if let detail { LabelText(detail) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(T1.surface)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Before → after for a ban study: one line per archetype between two columns.
struct InsightSlopeChart: View {
    struct Row: Identifiable { let id: Int; let label: String; let before: Double; let after: Double; let highlighted: Bool }
    let rows: [Row]
    let leftTitle: String
    let rightTitle: String
    var height: CGFloat = 200

    var body: some View {
        Canvas { ctx, size in
            let top: CGFloat = 20, bottom: CGFloat = 8, labelW: CGFloat = min(130, size.width * 0.34)
            let x0 = labelW + 4, x1 = size.width - labelW - 4, h = max(1, size.height - top - bottom)
            let maxV = max(0.05, rows.flatMap { [$0.before, $0.after] }.max() ?? 0.05)
            let y = { (v: Double) in top + h * (1 - CGFloat(v / maxV)) }
            ctx.draw(Text(leftTitle.uppercased()).font(T1.mono(9)).foregroundStyle(T1.muted), at: .init(x: x0, y: 0), anchor: .top)
            ctx.draw(Text(rightTitle.uppercased()).font(T1.mono(9)).foregroundStyle(T1.muted), at: .init(x: x1, y: 0), anchor: .top)
            for xx in [x0, x1] {
                var p = Path(); p.move(to: .init(x: xx, y: top)); p.addLine(to: .init(x: xx, y: top + h))
                ctx.stroke(p, with: .color(T1.surfaceHover), lineWidth: 1)
            }
            let ly = InsightCharts.spread(rows.map { Double(y($0.before)) }, gap: 12, lo: Double(top), hi: Double(top + h))
            let ry = InsightCharts.spread(rows.map { Double(y($0.after)) }, gap: 12, lo: Double(top), hi: Double(top + h))
            for (k, r) in rows.enumerated() {
                var p = Path(); p.move(to: .init(x: x0, y: y(r.before))); p.addLine(to: .init(x: x1, y: y(r.after)))
                let c = r.highlighted ? T1.accent : T1.muted.opacity(0.6)
                ctx.stroke(p, with: .color(c), lineWidth: r.highlighted ? 2 : 1)
                let name = r.label.count > 15 ? r.label.prefix(14) + "…" : Substring(r.label)
                ctx.draw(Text("\(name) \(InsightCharts.pct(r.before))").font(T1.mono(9)).foregroundStyle(r.highlighted ? T1.accent : T1.muted),
                         at: .init(x: x0 - 6, y: ly[k]), anchor: .trailing)
                ctx.draw(Text(InsightCharts.pct(r.after)).font(T1.mono(9)).foregroundStyle(r.highlighted ? T1.accent : T1.muted),
                         at: .init(x: x1 + 6, y: ry[k]), anchor: .leading)
            }
        }
        .frame(height: height)
    }
}

/// Win rate against how late a card is taken, with the fitted line: above it is underdrafted.
struct InsightScatter: View {
    struct Point: Identifiable { let id: String; let label: String; let x: Double; let y: Double }
    let points: [Point]
    var xTitle = "Taken at pick"
    var yTitle = "Win rate in hand"
    var height: CGFloat = 240
    var onTap: ((Point) -> Void)?

    private var fit: (a: Double, b: Double)? { InsightCharts.fit(points.map(\.x), points.map(\.y)) }
    /// Residual of a point against the fitted line (positive = better than its pick suggests).
    func residual(_ p: Point) -> Double { fit.map { p.y - ($0.a + $0.b * p.x) } ?? 0 }

    var body: some View {
        GeometryReader { g in
            let left: CGFloat = 36, bottom: CGFloat = 20, top: CGFloat = 8, right: CGFloat = 8
            let w = g.size.width - left - right, h = g.size.height - top - bottom
            let xt = InsightCharts.ticks(points.map(\.x).min() ?? 1, points.map(\.x).max() ?? 14, count: 4)
            let yt = InsightCharts.ticks(points.map(\.y).min() ?? 0.45, points.map(\.y).max() ?? 0.65, count: 4)
            let sx = { (v: Double) in left + w * CGFloat((v - xt.first!) / max(1e-9, xt.last! - xt.first!)) }
            let sy = { (v: Double) in top + h * (1 - CGFloat((v - yt.first!) / max(1e-9, yt.last! - yt.first!))) }
            let ranked = points.sorted { residual($0) > residual($1) }
            let named = Set(ranked.prefix(3).map(\.id) + ranked.suffix(2).map(\.id))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for t in yt {
                        var p = Path(); p.move(to: .init(x: left, y: sy(t))); p.addLine(to: .init(x: left + w, y: sy(t)))
                        ctx.stroke(p, with: .color(T1.surfaceHover), lineWidth: 1)
                        ctx.draw(Text(InsightCharts.pct(t)).font(T1.mono(9)).foregroundStyle(T1.muted), at: .init(x: left - 4, y: sy(t)), anchor: .trailing)
                    }
                    for t in xt {
                        ctx.draw(Text(String(format: t == t.rounded() ? "%.0f" : "%.1f", t)).font(T1.mono(9)).foregroundStyle(T1.muted),
                                 at: .init(x: sx(t), y: top + h + 4), anchor: .top)
                    }
                    if let f = fit {
                        var p = Path()
                        p.move(to: .init(x: sx(xt.first!), y: sy(f.a + f.b * xt.first!)))
                        p.addLine(to: .init(x: sx(xt.last!), y: sy(f.a + f.b * xt.last!)))
                        ctx.stroke(p, with: .color(T1.text), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    for pt in points {
                        let r = residual(pt)
                        let c = r >= 0.02 ? T1.accent : r <= -0.02 ? T1.error : T1.muted.opacity(0.6)
                        ctx.fill(Path(CGRect(x: sx(pt.x) - 2.5, y: sy(pt.y) - 2.5, width: 5, height: 5)), with: .color(c))
                        if named.contains(pt.id) {
                            ctx.draw(Text(pt.label).font(T1.mono(9)).foregroundStyle(c), at: .init(x: sx(pt.x) + 5, y: sy(pt.y)), anchor: .leading)
                        }
                    }
                }
                ForEach(points) { pt in
                    Color.clear.frame(width: 18, height: 18).contentShape(Rectangle())
                        .position(x: sx(pt.x), y: sy(pt.y))
                        .onTapGesture { onTap?(pt) }
                        .accessibilityLabel("\(pt.label), \(InsightCharts.pct1(pt.y)), pick \(String(format: "%.1f", pt.x))")
                }
            }
        }
        .frame(height: height)
    }
}

/// Matchup grid: row archetype's match win rate against each column (named on top, read upwards); below 30 matches a
/// cell still shows, dimmed.
struct InsightHeatmap: View {
    let labels: [String]
    /// cell(row, col) → (wins, losses)
    let cell: (Int, Int) -> (wins: Int, losses: Int)?
    var minMatches = 30
    var onTap: ((Int, Int) -> Void)?

    var body: some View {
        let n = labels.count
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                T1.surface.frame(width: 104, height: 128)
                ForEach(0..<n, id: \.self) { c in
                    T1.surface.frame(maxWidth: .infinity).frame(height: 128)
                        .overlay {
                            // laid out across, then turned to read upwards from the bottom of the header
                            Text(labels[c].uppercased()).font(T1.mono(9)).tracking(0.5).lineLimit(1).truncationMode(.tail)
                                .frame(width: 120, alignment: .leading)
                                .rotationEffect(.degrees(-90))
                        }
                        .clipped()
                        .accessibilityLabel(labels[c])
                }
            }
            ForEach(0..<n, id: \.self) { r in
                HStack(spacing: 1) {
                    Text(labels[r]).font(T1.mono(10)).lineLimit(2).minimumScaleFactor(0.8)
                        .frame(width: 92, height: 34, alignment: .leading).padding(.horizontal, 6).background(T1.surface)
                    ForEach(0..<n, id: \.self) { c in
                        let v = r == c ? nil : cell(r, c)
                        let h = InsightCharts.heat(wins: v?.wins ?? 0, losses: v?.losses ?? 0, minimum: minMatches)
                        ZStack {
                            Rectangle().fill(color(h))
                            Text(h.label).font(T1.mono(10)).foregroundStyle(h.ink ? T1.ink : h.dim ? T1.muted : T1.text)
                        }
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .contentShape(Rectangle())
                        .onTapGesture { if r != c { onTap?(r, c) } }
                    }
                }
            }
        }
    }

    private func color(_ h: InsightCharts.Heat) -> Color {
        switch h.tone {
        case "none": return T1.surface
        case "even": return T1.surfaceHover
        default: return (h.tone == "up" ? T1.accent : T1.error).opacity(h.strength)
        }
    }
}
