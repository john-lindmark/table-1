import Foundation
import Supabase

/* Want prices (contract/want-prices-2026-10-26.md): each want's price now, a week back and its 30-day average,
   the trend shown on Wanted rows, and the account's price alerts switch. */

/// One want's prices from wants_prices: the cheapest near-mint price among what the want takes.
struct WantPrice: Decodable, Hashable, Sendable {
    let oracleId: String
    var cardId: String?
    var finish: String?
    var now: Double?
    var nowCardId: String?
    var nowFinish: String?
    var then: Double?
    var thenDays: Int?
    var avg30: Double?
    var key: String { Want.key(oracleId, cardId, finish) }
}

/// The shared rules (testdata/want-prices/cases.json). Whole cents throughout, so a half percent rounds the same
/// on every platform.
enum WantPrices {
    struct Trend: Equatable, Sendable {
        let dir: String   // up / down / flat
        let text: String
    }

    static func cents(_ v: Double) -> Int { Int((v * 100).rounded()) }

    static func money(_ v: Double) -> String {
        let c = cents(v)
        return "$\(c / 100).\(String(format: "%02d", c % 100))"
    }

    private static func period(_ days: Int) -> String {
        days >= 7 ? "this week" : days == 1 ? "since yesterday" : "in \(days) days"
    }

    /// Now against the oldest price of the last 7 days, `days` ago. Nil without both prices.
    static func trend(now: Double?, then: Double?, days: Int?) -> Trend? {
        guard let now, let then, let days, days >= 1 else { return nil }
        let n = cents(now), t = cents(then)
        guard t > 0 else { return nil }
        let diff = n - t
        let pct = (abs(diff) * 200 + t) / (2 * t)
        if abs(diff) < 5 || pct == 0 { return Trend(dir: "flat", text: "Flat \(period(days))") }
        return diff > 0 ? Trend(dir: "up", text: "▲ \(pct)% \(period(days))") : Trend(dir: "down", text: "▼ \(pct)% \(period(days))")
    }

    /// A Wanted row's detail: which printing · Max $X · Now $Y (From for any printing). The trend has its own line.
    static func detail(which: String, max: Double?, now: Double?, any: Bool) -> String {
        [which.isEmpty ? nil : which, max.map { "Max \(money($0))" }, now.map { "\(any ? "From" : "Now") \(money($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class WantPricesStore {
    static let shared = WantPricesStore()
    /// By want key.
    private(set) var items: [String: WantPrice] = [:]
    /// Price alerts on for the account; nil until loaded (and signed out).
    private(set) var alerts: Bool?
    var error: String?
    #if DEBUG
    @ObservationIgnored private var demoAlerts = true
    #endif

    func trend(_ w: Want) -> WantPrices.Trend? {
        items[w.id].flatMap { WantPrices.trend(now: $0.now, then: $0.then, days: $0.thenDays) }
    }

    func load(_ wants: [Want]) async {
        #if DEBUG
        if CollectionStore.shared.demo != nil { loadDemo(wants); return }
        #endif
        struct Answer: Decodable { let alerts: Bool; let items: [WantPrice] }
        do {
            let a: Answer = try await supabase.rpc("wants_prices").execute().value
            items = Dictionary(a.items.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
            alerts = a.alerts
            let trends = a.items.compactMap { WantPrices.trend(now: $0.now, then: $0.then, days: $0.thenDays) }
            Telemetry.capture("want_prices_loaded", ["wants": a.items.count, "with_trend": trends.count,
                                                     "down": trends.filter { $0.dir == "down" }.count, "up": trends.filter { $0.dir == "up" }.count])
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    func setAlerts(_ on: Bool) async {
        let was = alerts
        alerts = on
        #if DEBUG
        if CollectionStore.shared.demo != nil { demoAlerts = on; Telemetry.capture("want_alerts_changed", ["on": on]); return }
        #endif
        struct Answer: Decodable { let alerts: Bool }
        do {
            let a: Answer = try await supabase.rpc("want_alerts_set", params: ["p_on": AnyJSON.bool(on)]).execute().value
            alerts = a.alerts
            Telemetry.capture("want_alerts_changed", ["on": a.alerts])
        } catch {
            alerts = was
            self.error = error.localizedDescription
        }
    }

    #if DEBUG
    /// Demo: the session's prices for the want's printing (its cover printing for any printing), and a made-up
    /// week back from the card id, so rows show every kind of trend.
    private func loadDemo(_ wants: [Want]) {
        var out: [String: WantPrice] = [:]
        for w in wants {
            let card = w.cardId ?? WantPricesStore.demoCover[w.oracleId]
            guard let card else { continue }
            let seed = card.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            // The fixture prices only its own cards: others get a made-up one.
            let now = PriceBook.shared.usd(card, w.finish ?? "nonfoil") ?? Double(25 + seed * 37 % 4000) / 100
            let h = seed % 41 - 20   // −20 … +20 %
            out[w.id] = WantPrice(oracleId: w.oracleId, cardId: w.cardId, finish: w.finish, now: now, nowCardId: card,
                                  nowFinish: w.finish ?? "nonfoil", then: (now * 100 / Double(100 + h) * 100).rounded() / 100,
                                  thenDays: 7, avg30: now)
        }
        items = out
        alerts = demoAlerts
    }

    /// Demo: the printing a want's row shows, so any-printing wants get a price too (WantsView fills it).
    static var demoCover: [String: String] = [:]
    #endif
}
