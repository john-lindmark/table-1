import Foundation
import Supabase

/// Current market prices for printings, fetched on demand (card_prices_get) and kept for the session.
/// USD is TCGplayer's market price as Scryfall publishes it; EUR is Cardmarket's. Prices are for near-mint
/// copies; `usd(_:_:_:)` prices a copy in its condition (`Conditions.price`).
@MainActor
@Observable
final class PriceBook {
    static let shared = PriceBook()
    /// [usd, usd_foil, usd_etched, eur, eur_foil]
    private(set) var rows: [String: [Double?]] = [:]
    /// Bumps whenever prices arrive, for views that sort by them.
    private(set) var version = 0
    @ObservationIgnored private var asked: Set<String> = []

    private struct Row: Decodable {
        let id: String
        let values: [Double?]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            id = try c.decode(String.self)
            var v: [Double?] = []
            while !c.isAtEnd { v.append(try c.decodeIfPresent(Double.self)) }
            values = v
        }
    }

    /// Fetches prices not asked for yet this session.
    func load(_ ids: some Sequence<String>) async {
        let missing = Set(ids).subtracting(asked)
        guard !missing.isEmpty else { return }
        asked.formUnion(missing)
        #if DEBUG
        if let demo = CollectionStore.shared.demo {
            for id in missing { rows[id] = demo.prices[id] ?? [] }
            version += 1
            return
        }
        #endif
        let all = Array(missing)
        for start in stride(from: 0, to: all.count, by: 5000) {
            let chunk = Array(all[start..<min(start + 5000, all.count)])
            do {
                let got: [Row] = try await supabase.rpc("card_prices_get", params: ["p_card_ids": AnyJSON.array(chunk.map { .string($0) })]).execute().value
                for r in got { rows[r.id] = r.values }
                for id in chunk where rows[id] == nil { rows[id] = [] } // no price on record
                version += 1
            } catch {
                asked.subtract(chunk) // try again next time
            }
        }
    }

    /// One copy's USD price in a finish and condition, nil when there's no market price.
    func usd(_ cardId: String, _ finish: String, _ condition: String = "NM") -> Double? {
        guard let r = rows[cardId] else { return nil }
        let i = finish == "foil" ? 1 : finish == "etched" ? 2 : 0
        return Conditions.price(i < r.count ? r[i] : nil, condition)
    }

    static func text(_ usd: Double?) -> String? {
        usd.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
    }

    /// A copy's price in its condition, saying what near mint would be when it isn't: "$8.50 · LP (NM $10.00)".
    static func conditionText(_ nearMint: Double?, _ condition: String) -> String? {
        guard let price = text(Conditions.price(nearMint, condition)) else { return nil }
        guard Conditions.percent(condition) != 100, let nm = text(nearMint) else { return price }
        return "\(price) · \(condition.uppercased()) (NM \(nm))"
    }
}

extension Conditions {
    /// The share of the near-mint price a copy in this condition is worth (contract/condition-prices-2026-10-24.md).
    static func percent(_ condition: String) -> Int {
        switch condition.uppercased() {
        case "LP": 85
        case "MP": 70
        case "HP": 50
        case "DMG": 35
        default: 100
        }
    }

    /// One copy's price in its condition from the near-mint price: whole cents, half up, never below a cent.
    static func price(_ nearMint: Double?, _ condition: String) -> Double? {
        guard let nearMint else { return nil }
        let cents = Int((nearMint * 100).rounded())
        guard cents > 0 else { return nearMint }
        return Double(max(1, (cents * percent(condition) + 50) / 100)) / 100
    }

    /// Better condition first: NM before LP … DMG.
    static func better(_ a: String, _ b: String) -> Bool {
        (all.firstIndex(of: a) ?? all.count) < (all.firstIndex(of: b) ?? all.count)
    }
}
