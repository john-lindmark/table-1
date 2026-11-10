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
        case "M": Color(red: 0xE0 / 255, green: 0xC4 / 255, blue: 0x6C / 255)
        default: Color(red: 0xCA / 255, green: 0xC5 / 255, blue: 0xC0 / 255)
        }
    }
}

/// A card's colors as small pips (one grey pip for colorless).
struct LimitedPips: View {
    let col: String
    var size: CGFloat = 7
    var tinted = false
    /// The most pips the width is kept for.
    var max: Int = 3
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(col.enumerated()), id: \.offset) { _, c in
                Circle().fill(tinted ? Color.white.opacity(0.7) : LimitedLook.pip(c)).frame(width: size, height: size)
            }
        }
        .frame(width: CGFloat(Swift.max(1, Swift.min(col.count, max))) * (size + 2), alignment: .leading)
        .accessibilityHidden(true)
    }
}

struct LimitedCardsWidgetView: View {
    let family: WidgetFamily
    let pack: LimitedWidgetPack?
    let picks: LimitedPicks
    /// The widget settings' key the buttons save under (LimitedWidgetSelection).
    var key = ""
    /// The sets the Set button steps through; the device's Limited sets.
    var sets: [String] = LimitedSetsStore.load().map(\.key)
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
                header(pack, tinted: tinted)
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

    /// Set · Rarity · Color buttons, each a tap to the next pick (contract § Limited cards widget "Buttons"), and the
    /// sort's code. Small widgets put the sort on a line of its own.
    @ViewBuilder private func header(_ pack: LimitedWidgetPack, tinted: Bool) -> some View {
        let small = family == .systemSmall
        // Small and medium widgets use codes on the buttons, large ones words.
        let compact = family != .systemLarge
        let rated = pack.view?.cards.contains { $0.r != nil } ?? false
        let sortCode = LimitedFilter.sorts.first { $0.key == picks.sort }?.code ?? picks.sort.uppercased()
        let buttons = HStack(spacing: 4) {
            button("set", LimitedWidgets.nextSet(pack.set_code, in: sets) ?? pack.set_code, tinted: tinted) {
                WLabel(pack.set_code, color: W1.text)
            }
            if rated {
                button("rarity", LimitedWidgets.next(picks.rarity, in: LimitedFilter.rarities).joined(separator: ","), tinted: tinted) {
                    WLabel(LimitedWidgets.rarityButton(picks.rarity, small: compact, tiny: small), color: W1.text)
                }
            }
            button("color", LimitedWidgets.next(picks.color, in: LimitedFilter.colors).joined(separator: ","), tinted: tinted) {
                colorLabel(small: compact, tinted: tinted)
            }
        }
        if small {
            VStack(alignment: .leading, spacing: 3) {
                buttons
                WLabel(sortCode)
            }
        } else {
            HStack(spacing: 6) {
                buttons
                Spacer(minLength: 4)
                WLabel(sortCode)
            }
        }
    }

    /// One header button: a hairline box around its pick.
    private func button(_ what: String, _ value: String, tinted: Bool, @ViewBuilder _ label: () -> some View) -> some View {
        Button(intent: LimitedPickIntent(key: key, what: what, value: value)) {
            label()
                .padding(.horizontal, 5)
                .frame(height: 18)
                .overlay(Rectangle().strokeBorder(tinted ? W1.text.opacity(0.6) : W1.muted.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The Color button: the five pips for Any, else the pick's pip (gold for Multi) and its code (W, M, C).
    @ViewBuilder private func colorLabel(small: Bool, tinted: Bool) -> some View {
        let picked = LimitedFilter.colors.filter { picks.color.contains($0) }
        if picked.isEmpty {
            HStack(spacing: 4) {
                if !small { WLabel("Any", color: W1.text) }
                LimitedPips(col: "WUBRG", size: 5, tinted: tinted, max: 5)
            }
            .accessibilityLabel("Any color")
        } else if picked.count == 1 {
            HStack(spacing: 3) {
                LimitedPips(col: picked[0] == "M" ? "M" : picked[0], size: 6, tinted: tinted)
                WLabel(picked[0], color: W1.text)
            }
        } else {
            WLabel(LimitedFilter.colorLabel(picked), color: W1.text)
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
