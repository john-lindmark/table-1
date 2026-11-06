import Foundation

/* The Buy screen's rules (contract/buy-2026-11-06.md): which copies of a deck, cube, Wants or Missing go into a
   TCGplayer cart, what they cost, and the tcgplayer_cart calls that build it. Cases in testdata/buy/cases.json
   (BuyListTests). */
enum BuyList {
    /// One line offered for buying. `unit` is one copy's price in cents; `any` marks a want for any printing (sent by
    /// `oracleId`, priced and drawn by `cardId`).
    struct Line: Hashable, Sendable {
        let cardId: String
        var oracleId: String?
        var any = false
        let board: String
        var finish = "nonfoil"
        let qty: Int
        var unit: Int?
        var basic = false
    }

    struct Options: Equatable, Sendable {
        var skipOwned = true
        var anyPrinting = true
        var exact = false
        var boards: Set<String> = ["commander", "main", "side"]
    }

    struct Row: Hashable, Sendable {
        let line: Line
        let owned: Int
        var buy: Int { line.qty - owned }
    }

    struct Totals: Equatable, Sendable {
        var cards = 0, owned = 0, buy = 0, price = 0, ownedValue = 0, total = 0, unpriced = 0
    }

    struct Call: Equatable, Sendable {
        let products: Bool
        let items: [TCGplayerCart.Item]
    }

    /// One row per line in a picked board with copies, in line order. Skip owned leaves basic lands out, then a line's
    /// own printing and finish cover it first and, with Any printing, the card's other copies, lines in order, each
    /// copy once. Without Skip owned nothing is owned.
    static func rows(_ lines: [Line], _ h: Holdings, _ o: Options) -> [Row] {
        let inc = lines.filter { o.boards.contains($0.board) && $0.qty > 0 && !(o.skipOwned && $0.basic) }
        guard o.skipOwned else { return inc.map { Row(line: $0, owned: 0) } }
        var exact = h.byPrinting, spare = h.byCard
        var cov = Array(repeating: 0, count: inc.count)
        for (i, l) in inc.enumerated() {
            let k = "\(l.cardId)|\(l.finish)"
            let c = min(l.qty, exact[k] ?? 0)
            exact[k, default: 0] -= c
            spare[h.card(l.cardId), default: 0] -= c
            cov[i] = c
        }
        if o.anyPrinting {
            for (i, l) in inc.enumerated() {
                let card = h.card(l.cardId)
                let c = min(l.qty - cov[i], max(0, spare[card] ?? 0))
                spare[card, default: 0] -= c
                cov[i] += c
            }
        }
        return zip(inc, cov).map { Row(line: $0, owned: $1) }
    }

    /// Money in cents: price over every row's copies, the owned copies at their line's price, the total bought.
    static func totals(_ rows: [Row]) -> Totals {
        var t = Totals()
        for r in rows {
            t.cards += r.line.qty
            t.owned += r.owned
            t.buy += r.buy
            if let u = r.line.unit {
                t.price += r.line.qty * u
                t.ownedValue += r.owned * u
                t.total += r.buy * u
            } else {
                t.unpriced += r.buy
            }
        }
        return t
    }

    /// The tcgplayer_cart calls: tokens always to their product pages, everything else by Exact printings; copies
    /// summed per key in row order; one call when both agree, none when nothing's bought.
    static func calls(_ rows: [Row], exact: Bool) -> [Call] {
        var groups: [Bool: [(key: String, item: TCGplayerCart.Item)]] = [:]
        for r in rows where r.buy > 0 {
            let products = r.line.board == "tokens" ? true : exact
            let any = r.line.any && r.line.oracleId != nil
            let key = any ? "o:\(r.line.oracleId!)" : "c:\(r.line.cardId)"
            var g = groups[products] ?? []
            if let i = g.firstIndex(where: { $0.key == key }) {
                g[i].item.qty += r.buy
            } else {
                g.append((key, any ? TCGplayerCart.Item(oracleId: r.line.oracleId, qty: r.buy) : TCGplayerCart.Item(cardId: r.line.cardId, qty: r.buy)))
            }
            groups[products] = g
        }
        return [exact, !exact].compactMap { p in groups[p].map { Call(products: p, items: $0.map(\.item)) } }
    }

    /// Two calls' answers as one: Mass Entry parts in order, then every product page by name, set and number.
    static func merge(_ answers: [TCGplayerCart.Answer]) -> TCGplayerCart.Answer {
        var out = TCGplayerCart.Answer(enabled: answers.allSatisfy(\.enabled), lines: 0, unknown: 0, urls: [], products: [])
        for a in answers {
            out.lines += a.lines
            out.unknown += a.unknown
            out.urls += a.urls
            out.products += a.products
        }
        out.products.sort { ($0.name, $0.set, $0.number) < ($1.name, $1.set, $1.number) }
        return out
    }

    /// Cents from a market price.
    static func cents(_ usd: Double?) -> Int? { usd.map { Int(($0 * 100).rounded()) } }

    /// "$1,441.95".
    static func money(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// Board order on screen.
    static let boardOrder = ["commander", "main", "side", "maybe", "tokens"]
}
