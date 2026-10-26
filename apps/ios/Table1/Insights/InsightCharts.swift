import Foundation

/// Insights chart maths (contract/insights-2026-10-24.md). The same answers as the Python reference
/// testdata/insight-charts/make_cases.py, table-1-events-web/src/lib/insightCharts.ts and Android's InsightCharts.kt;
/// InsightChartsTests checks this file against its cases.
enum InsightCharts {
    /// 1, 2, 2.5 or 5 × a power of ten: the smallest at least `raw`.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let base = pow(10, floor(log10(raw)))
        for m in [1, 2, 2.5, 5, 10] where m * base >= raw - 1e-12 { return (m * base * 1e12).rounded() / 1e12 }
        return 10 * base
    }

    /// Evenly spaced round values covering lo…hi with about `count` intervals; lo == hi widens to one step.
    static func ticks(_ lo0: Double, _ hi0: Double, count: Int) -> [Double] {
        var lo = min(lo0, hi0), hi = max(lo0, hi0)
        if hi == lo { hi = lo + (abs(lo) * 0.1 == 0 ? 1 : abs(lo) * 0.1) }
        let step = niceStep((hi - lo) / Double(max(1, count)))
        let start = floor(lo / step + 1e-9) * step, end = ceil(hi / step - 1e-9) * step
        let n = Int(((end - start) / step).rounded())
        return (0...n).map { ((start + Double($0) * step) * 1e10).rounded() / 1e10 }
    }

    /// Runs of non-null values as (index, value); a null breaks the line.
    static func segments(_ values: [Double?]) -> [[(Int, Double)]] {
        var out: [[(Int, Double)]] = [], cur: [(Int, Double)] = []
        for (i, v) in values.enumerated() {
            if let v { cur.append((i, v)) } else if !cur.isEmpty { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 90% Wilson interval for a win rate; 0…1 with no games.
    /// A matchup grid cell: its number, tone and fill strength. Under `minimum` matches it still shows, dimmed: half
    /// the fill and muted text (testdata/insight-charts make_cases.py `heat`).
    struct Heat: Equatable { let label: String; let tone: String; let strength: Double; let dim: Bool; let ink: Bool }
    static func heat(wins: Int, losses: Int, minimum: Int = 30) -> Heat {
        let n = wins + losses
        guard n > 0 else { return Heat(label: "", tone: "none", strength: 0, dim: false, ink: false) }
        let wr = Double(wins) / Double(n), d = wr - 0.5
        let tone = abs(d) < 0.03 ? "even" : d > 0 ? "up" : "down"
        let dim = n < minimum
        let strength = (tone == "even" ? 0 : min(1, 0.25 + abs(d) * 4)) * (dim ? 0.5 : 1)
        return Heat(label: String(Int(floor(wr * 100 + 0.5))), tone: tone, strength: (strength * 10000).rounded() / 10000, dim: dim,
                    ink: abs(d) >= 0.08 && !dim)
    }

    static func wilson(wins: Int, n: Int, z: Double = 1.6449) -> (lo: Double, hi: Double) {
        guard n > 0 else { return (0, 1) }
        let nn = Double(n), p = Double(wins) / nn, d = 1 + z * z / nn
        let c = (p + z * z / (2 * nn)) / d
        let h = z * sqrt(p * (1 - p) / nn + z * z / (4 * nn * nn)) / d
        return (max(0, c - h), min(1, c + h))
    }

    /// Least-squares line y = a + b·x; nil with fewer than two distinct x.
    static func fit(_ xs: [Double], _ ys: [Double]) -> (a: Double, b: Double)? {
        let n = Double(xs.count)
        guard xs.count >= 2 else { return nil }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx != 0 else { return nil }
        let b = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        return (my - b * mx, b)
    }

    /// End labels at screen ys (down is larger) moved apart to at least `gap` and kept inside lo…hi, in input order.
    static func spread(_ ys: [Double], gap: Double, lo: Double, hi: Double) -> [Double] {
        guard !ys.isEmpty else { return [] }
        let order = ys.indices.sorted { (ys[$0], $0) < (ys[$1], $1) }
        var pos = Array(repeating: 0.0, count: ys.count)
        var prev: Double?
        for i in order {
            let y = prev.map { max(ys[i], $0 + gap) } ?? max(ys[i], lo)
            pos[i] = y
            prev = y
        }
        let over = pos[order.last!] - hi
        if over > 0 {
            var next: Double?
            for i in order.reversed() {
                let y = next.map { min(pos[i], $0 - gap) } ?? pos[i] - over
                pos[i] = max(lo, y)
                next = pos[i]
            }
        }
        return pos
    }

    /// 21% / 3.4% (under 10% keeps one decimal), as the briefs write shares.
    static func pct(_ x: Double?) -> String {
        guard let x else { return "–" }
        return x >= 0.0995 || x == 0 ? "\(Int((x * 100).rounded()))%" : String(format: "%.1f%%", x * 100)
    }

    /// 57.1%: win rates keep one decimal.
    static func pct1(_ x: Double?) -> String {
        guard let x else { return "–" }
        return String(format: "%.1f%%", x * 100)
    }

    /// +2.1 / -12: a change in percentage points; under 10 keeps one decimal.
    static func delta(_ d: Double?) -> String {
        guard let d else { return "" }
        let v = abs(d * 100)
        return (d >= 0 ? "+" : "-") + (v >= 10 ? String(Int(v.rounded())) : String(format: "%.1f", v))
    }

    /// Index and upper-case month of each month's first day in a daily series from `start` (yyyy-mm-dd).
    static func months(from start: String, days: Int) -> [(Int, String)] {
        guard let d0 = day(start) else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        return (0..<max(0, days)).compactMap { i in
            let d = d0.addingTimeInterval(Double(i) * 86400)
            let c = cal.dateComponents([.day, .month], from: d)
            return c.day == 1 ? (i, names[c.month! - 1]) : nil
        }
    }

    struct SeriesWindow { let offset: Int; let from: String; let days: Int; let labels: [(Int, String)] }

    /// The last `keep` days of a daily series of `days` from `start` (the chart follows the picked 7/14/30/90-day
    /// window): where to cut, the new first day, its length and axis labels: months past 45 days, else a day label
    /// every (n + 2) / 4 days counted back from the last day, so the newest day is always labelled.
    static func window(from start: String, days: Int, keep: Int) -> SeriesWindow {
        let offset = max(0, days - keep), n = days - offset
        guard let d0 = day(start)?.addingTimeInterval(Double(offset) * 86400) else { return .init(offset: offset, from: start, days: n, labels: []) }
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.dateFormat = "yyyy-MM-dd"
        let from = iso.string(from: d0)
        if n > 45 { return .init(offset: offset, from: from, days: n, labels: months(from: from, days: n)) }
        let step = max(1, (n + 2) / 4)
        let labels = stride(from: n - 1, through: 0, by: -step).reversed().map { i in
            (i, shortDay(iso.string(from: d0.addingTimeInterval(Double(i) * 86400))))
        }
        return .init(offset: offset, from: from, days: n, labels: labels)
    }

    /// yyyy-mm-dd at midnight UTC.
    static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// "MAY 18" for a yyyy-mm-dd.
    static func shortDay(_ s: String) -> String {
        guard let d = day(s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f.string(from: d).uppercased()
    }
}
