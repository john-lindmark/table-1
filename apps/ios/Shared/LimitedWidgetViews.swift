import SwiftUI
import WidgetKit

/* The Limited cards widget's views (contract/widgets-2026-10-22.md § Limited cards widget), on a pack passed in so the
   Debug gallery (-T1WidgetsDemo limited) can draw them. */

/// What a Limited cards widget shows: a set, the sort, and the Rarity and Color picks (empty = any).
struct LimitedPicks: Equatable {
    var set: String?
    var sort = "gih"
    var rarity: [String] = []
    var color: [String] = []
}

enum LimitedLook {
    /// The five colors' pips, as Scryfall's mana symbols draw them; gold and colorless in their own tones.
    static func pip(_ c: Character) -> Color {
        switch c {
        case "W": Color(red: 0xF8 / 255, green: 0xF6 / 255, blue: 0xD8 / 255)
        case "U": Color(red: 0xC1 / 255, green: 0xD7 / 255, blue: 0xE9 / 255)
        case "B": Color(red: 0xBA / 255, green: 0xB1 / 255, blue: 0xAB / 255)
        case "R": Color(red: 0xE4 / 255, green: 0x99 / 255, blue: 0x77 / 255)
        case "G": Color(red: 0xA3 / 255, green: 0xC0 / 255, blue: 0x95 / 255)
        default: Color(red: 0xCA / 255, green: 0xC5 / 255, blue: 0xC0 / 255)
        }
    }
}

/// A card's colors as small pips (one grey pip for colorless).
struct LimitedPips: View {
    let col: String
    var size: CGFloat = 7
    var tinted = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(col.enumerated()), id: \.offset) { _, c in
                Circle().fill(tinted ? Color.white.opacity(0.7) : LimitedLook.pip(c)).frame(width: size, height: size)
            }
        }
        .frame(width: CGFloat(max(1, min(col.count, 3))) * (size + 2), alignment: .leading)
        .accessibilityHidden(true)
    }
}

struct LimitedCardsWidgetView: View {
    let family: WidgetFamily
    let pack: LimitedWidgetPack?
    let picks: LimitedPicks
    /// The gallery's stand-in for a tinted Home Screen.
    var tintedPreview: Bool? = nil
    @Environment(\.widgetRenderingMode) private var mode

    private var count: Int {
        switch family {
        case .systemSmall: 4
        case .systemLarge: 12
        default: 6
        }
    }

    var body: some View {
        let tinted = tintedPreview ?? (mode == .accented)
        if let pack, pack.view != nil {
            let rows = LimitedWidgets.rows(pack, sort: picks.sort, rarity: picks.rarity, color: picks.color, n: count)
            VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 6) {
                header(pack)
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    Text("No card matches these filters.").font(W1.mono(10)).foregroundStyle(W1.muted)
                    Spacer(minLength: 0)
                } else {
                    VStack(spacing: family == .systemLarge ? 6 : 4) {
                        ForEach(rows, id: \.place) { row($0, tinted: tinted) }
                    }
                    Spacer(minLength: 0)
                }
                // 17Lands' data is credited wherever it shows (CC BY 4.0).
                Text("DATA FROM 17LANDS").font(W1.mono(7)).tracking(1).foregroundStyle(W1.muted.opacity(0.7)).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WLabel("Limited cards")
                Spacer(minLength: 0)
                Text(picks.set == nil ? "Open Insights → Limited in the app once, then pick a set in this widget's settings."
                     : "Loading \(picks.set ?? "")…")
                    .font(W1.mono(10)).foregroundStyle(W1.muted).lineLimit(4)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func header(_ pack: LimitedWidgetPack) -> some View {
        let caption = LimitedWidgets.caption(sort: picks.sort, rarity: picks.rarity, color: picks.color)
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 2) {
                WLabel(pack.set_code, color: W1.text)
                WLabel(caption)
            }
        } else {
            HStack(spacing: 6) {
                WLabel(pack.set_code, color: W1.text)
                if let name = pack.name, family == .systemLarge { WLabel(name) }
                Spacer(minLength: 4)
                WLabel(caption)
            }
        }
    }

    private func row(_ r: LimitedWidgets.Row, tinted: Bool) -> some View {
        let small = family == .systemSmall
        return HStack(spacing: 5) {
            if !small {
                Text("\(r.place)").font(W1.mono(9)).foregroundStyle(W1.muted).frame(width: 14, alignment: .trailing)
            }
            LimitedPips(col: r.col, size: small ? 6 : 7, tinted: tinted)
            Text(r.name).font(W1.mono(small ? 10 : 11)).foregroundStyle(W1.text).lineLimit(1)
            Spacer(minLength: 3)
            if !small, let rarity = r.rarity { Text(rarity).font(W1.mono(9)).foregroundStyle(W1.muted) }
            if !small, let vs = r.vs {
                Text(vs).font(W1.mono(9)).foregroundStyle(tinted ? W1.text : r.above ? W1.text : W1.muted).frame(width: 30, alignment: .trailing)
            }
            Text(r.value).font(W1.mono(small ? 10 : 11, .semibold)).foregroundStyle(tinted ? W1.text : W1.accent)
                .frame(width: small ? 40 : 46, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
