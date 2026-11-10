import Foundation

/// The Limited page's Rarity and Color filters, several picks each (contract/insights-2026-10-24.md § The Limited page
/// "Rarity and Color"): the app's Top cards and the Limited cards widget use the same rule. Shared cases:
/// testdata/insights/limited-home.json (`filters`, `labels`), reference testdata/insights/make_limited_home.py.
enum LimitedFilter {
    /// The pickers' "Any" option: clears the picks.
    static let any = "all"
    static let rarities = ["common", "uncommon", "rare", "mythic"]
    /// W U B R G, then Multicolor (M) and Colorless (C).
    static let colors = ["W", "U", "B", "R", "G", "M", "C"]

    /// A multi-pick after a tap: Any clears, another option goes in or out.
    static func toggle(_ picked: [String], _ v: String) -> [String] {
        if v == any { return [] }
        return picked.contains(v) ? picked.filter { $0 != v } : picked + [v]
    }

    /// Rarity keeps a card of any picked rarity (none picked: all). A cube's cards have no rarity: `rated` false.
    static func keepsRarity(_ r: String?, _ rarity: [String], rated: Bool) -> Bool {
        !rated || rarity.isEmpty || rarity.contains(r ?? "")
    }

    /// Color keeps a colorless card when C is picked, a one-color card when its color is, and a multicolor card when
    /// Multi is picked or every one of its colors is (W + U keeps white, blue and Azorius gold cards).
    static func keepsColor(_ col: String?, _ color: [String]) -> Bool {
        if color.isEmpty { return true }
        let c = col.flatMap { $0.isEmpty ? nil : $0 } ?? "C"
        if c == "C" { return color.contains("C") }
        if c.count == 1 { return color.contains(c) }
        return color.contains("M") || c.allSatisfy { color.contains(String($0)) }
    }

    /// The Rarity cell: Any rarity, the one picked, or the picks' first letters in rarity order (C · U).
    static func rarityLabel(_ rarity: [String]) -> String {
        let picked = rarities.filter { rarity.contains($0) }
        if picked.isEmpty { return "Any rarity" }
        if picked.count == 1 { return picked[0].capitalized }
        return picked.map { String($0.prefix(1)).uppercased() }.joined(separator: " · ")
    }

    /// The Color cell: Any color, Multi or Colorless alone, else the colors in WUBRG order then Multi and C (WU · Multi).
    static func colorLabel(_ color: [String]) -> String {
        let picked = colors.filter { color.contains($0) }
        if picked.isEmpty { return "Any color" }
        let letters = picked.filter { "WUBRG".contains($0) }.joined()
        let rest = picked.filter { $0 == "M" || $0 == "C" }.map { $0 == "M" ? "Multi" : "C" }
        if letters.isEmpty && rest.count == 1 { return rest[0] == "Multi" ? "Multi" : "Colorless" }
        return ((letters.isEmpty ? [] : [letters]) + rest).joined(separator: " · ")
    }
}
