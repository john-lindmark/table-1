import Foundation
import Supabase

/// Current market prices for printings, fetched on demand (card_prices_get) and kept for the session.
/// USD is TCGplayer's market price as Scryfall publishes it; EUR is Cardmarket's. Prices are for near-mint
/// copies; other conditions show the same figure.
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

    /// One copy's USD price in a finish, nil when there's no market price.
    func usd(_ cardId: String, _ finish: String) -> Double? {
        guard let r = rows[cardId] else { return nil }
        let i = finish == "foil" ? 1 : finish == "etched" ? 2 : 0
        return i < r.count ? r[i] : nil
    }

    static func text(_ usd: Double?) -> String? {
        usd.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
    }
}
