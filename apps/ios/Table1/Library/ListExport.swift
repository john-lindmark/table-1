import Foundation

// Deck and cube export (contract/lists-2026-10-15.md, Export): the current version as Arena, Moxfield, MTGO or plain
// text, or as a Cube Cobra CSV. Same rules and output as table-1-events-web/src/lib/listExport.ts and Android's
// ListExport.kt: testdata/list-export holds the files all three must write for its lists, and list-import's parser
// reads each one back as the same lines (supabase/functions/list-import/parse.test.ts).
//  - Names: double-faced, adventure and flip cards by their front face, split cards (and rooms) by both halves, the
//    way Arena, Moxfield and Cube Cobra name them.
//  - Printings are "(SET) number". A set code or collector number the importers can't read is left off (the line
//    then imports as that card's original printing).
//  - Lines sort by name, then set, collector number and finish.

enum ListExport {
    enum Format: String, CaseIterable, Sendable {
        case arena, moxfield, mtgo, text, cubecobra

        static func formats(_ kind: CardList.Kind) -> [Format] { kind == .deck ? [.arena, .moxfield, .mtgo, .text] : [.cubecobra, .text] }

        var label: String {
            switch self {
            case .arena: "MTG Arena"
            case .moxfield: "Moxfield"
            case .mtgo: "MTGO"
            case .text: "Plain text"
            case .cubecobra: "Cube Cobra"
            }
        }
        var detail: String {
            switch self {
            case .arena: "Deck, sideboard and commander with printings, to paste into Import"
            case .moxfield: "Printings, foils and considering, to paste into Import"
            case .mtgo: "A .txt file: the main deck, then the sideboard"
            case .text: "Counts and card names"
            case .cubecobra: "A CSV for Replace with CSV file upload"
            }
        }
        /// MTGO and Cube Cobra read a file; the others are pasted, so they go out as text.
        var fileExtension: String? {
            switch self {
            case .mtgo: "txt"
            case .cubecobra: "csv"
            default: nil
            }
        }
    }

    struct Card: Hashable, Sendable {
        let name: String
        let typeLine: String
        let cmc: Double
        let colors: String
        let set: String
        let cn: String
        let rarity: String
    }

    struct Line: Hashable, Sendable {
        let card: Card
        let board: String
        let qty: Int
        var finish: String = "nonfoil"
    }

    /// The list's lines with their cards from the catalog; `left` counts copies the catalog doesn't have.
    static func lines(_ entries: [CardList.Entry], _ db: CatalogDB) -> (lines: [Line], left: Int) {
        let printings = db.printings(ids: entries.map(\.cardId))
        let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
        var out: [Line] = [], left = 0
        for e in entries {
            guard let p = printings[e.cardId], let o = oracles[p.oracleIdx] else { left += e.qty; continue }
            out.append(Line(card: Card(name: o.name, typeLine: o.typeLine, cmc: o.cmc, colors: o.colors, set: p.set, cn: p.cn, rarity: p.rarity),
                            board: e.board, qty: e.qty, finish: e.finish))
        }
        return (out, left)
    }

    /// The name other apps know the card by.
    static func name(_ c: Card) -> String {
        let faces = c.name.components(separatedBy: " // ")
        guard faces.count > 1 else { return c.name }
        let split = c.typeLine.components(separatedBy: " // ").allSatisfy { t in
            !t.contains("Adventure") && !t.contains("Omen")
                && (t == "Instant" || t == "Sorcery" || t.hasPrefix("Instant — ") || t.hasPrefix("Sorcery — ") || t == "Enchantment — Room")
        }
        return split ? c.name : faces[0]
    }

    /// "(SET) number", or nil when the importers couldn't read it back.
    static func printing(_ c: Card) -> String? {
        guard c.set.wholeMatch(of: /[A-Za-z0-9]{2,6}/) != nil, c.cn.wholeMatch(of: /[A-Za-z0-9★†Φ_\-]+/) != nil else { return nil }
        return "(\(c.set.uppercased())) \(c.cn)"
    }

    private static let finishRank = ["nonfoil": 0, "foil": 1, "etched": 2]

    /// UTF-16 order, as the web and Android clients sort.
    private static func before(_ a: Line, _ b: Line) -> Bool {
        let ka = [name(a.card), a.card.set, a.card.cn], kb = [name(b.card), b.card.set, b.card.cn]
        for (x, y) in zip(ka, kb) where x != y { return x.utf16.lexicographicallyPrecedes(y.utf16) }
        return (finishRank[a.finish] ?? 3) < (finishRank[b.finish] ?? 3)
    }

    /// Sums lines that print the same, keeping the first one's place.
    private static func merged(_ lines: [Line], _ text: (Line) -> String) -> [String] {
        var order: [String] = [], qty: [String: Int] = [:]
        for l in lines {
            let t = text(l)
            if qty[t] == nil { order.append(t) }
            qty[t, default: 0] += l.qty
        }
        return order.map { "\(qty[$0]!) \($0)" }
    }

    static func render(_ lines: [Line], kind: CardList.Kind, format: Format) -> String {
        let sorted = lines.filter { $0.qty > 0 }.sorted(by: before)
        func board(_ b: String...) -> [Line] { sorted.filter { b.contains($0.board) } }
        func printed(_ l: Line) -> String { [name(l.card), printing(l.card)].compactMap { $0 }.joined(separator: " ") }
        var blocks: [[String]] = []
        switch format {
        case .cubecobra:
            return cubeCobra(sorted)
        case .arena, .moxfield:
            var sections = [("Commander", board("commander")), ("Deck", board("main")), ("Sideboard", board("side"))]
            if format == .moxfield { sections.append(("Maybeboard", board("maybe"))) }
            for (title, ls) in sections where !ls.isEmpty {
                let rows = format == .arena ? merged(ls, printed)
                    : merged(ls) { l in printed(l) + (l.finish == "foil" ? " *F*" : l.finish == "etched" ? " *E*" : "") }
                blocks.append([title] + rows)
            }
        case .mtgo:
            // MTGO has no commander section: the commander goes in the sideboard, as MTGO's Commander decks do.
            blocks = [merged(board("main")) { name($0.card) }, merged(board("side", "commander")) { name($0.card) }]
                .filter { !$0.isEmpty }
        case .text:
            let sections = kind == .deck
                ? [("Commander", board("commander")), ("Deck", board("main")), ("Sideboard", board("side")), ("Considering", board("maybe"))]
                : [("Main", board("main", "side", "commander")), ("Considering", board("maybe"))]
            let filled = sections.filter { !$0.1.isEmpty }
            for (title, ls) in filled {
                let rows = merged(ls) { name($0.card) }
                blocks.append(filled.count > 1 ? [title] + rows : rows)
            }
        }
        return blocks.isEmpty ? "" : blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }

    /// Cube Cobra's own CSV columns and quoting (its export, which its bulk upload reads): one row per copy, the main
    /// list then Considering (maybeboard). Color Category, status, images, notes and tags are left for Cube Cobra.
    static let cubeCobraHeader = "name,CMC,Type,Color,Set,Collector Number,Rarity,Color Category,status,Finish,board,maybeboard,image URL,image Back URL,tags,Notes,MTGO ID,Custom,Voucher,Artist"
    private static let rarities = ["c": "common", "u": "uncommon", "r": "rare", "m": "mythic", "s": "special", "b": "bonus"]

    private static func cubeCobra(_ sorted: [Line]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = [cubeCobraHeader]
        for maybe in [false, true] {
            for l in sorted where (l.board == "maybe") == maybe {
                let c = l.card
                var type = c.typeLine
                if let r = type.range(of: "—") { type.replaceSubrange(r, with: "-") } // Cube Cobra swaps the first dash back
                let cmc = c.cmc == c.cmc.rounded() ? String(Int(c.cmc)) : String(c.cmc)
                let colors = "WUBRG".filter { c.colors.contains($0) }
                let finish = l.finish == "foil" ? "Foil" : l.finish == "etched" ? "Etched" : "Non-foil"
                let row = [q(name(c)), cmc, q(type), String(colors), q(c.set), q(c.cn), rarities[c.rarity] ?? "", "", "", finish,
                           maybe ? "maybeboard" : "mainboard", maybe ? "true" : "false", "", "", q(""), q(""), "", "false", "false", q("")]
                    .joined(separator: ",")
                rows += Array(repeating: row, count: l.qty)
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// "Izzet Tempo.txt": the list's name with only letters, digits, spaces, dashes and underscores.
    static func fileName(_ listName: String, kind: CardList.Kind, format: Format) -> String {
        let kept = String(listName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) })
        let base = kept.split(separator: " ").joined(separator: " ")
        return "\(base.isEmpty ? kind.rawValue : String(base.prefix(60))).\(format.fileExtension ?? "txt")"
    }
}

extension ListExport {
    /// The text as a file named for the list (.txt, or .csv for Cube Cobra), for the share sheet.
    static func file(_ text: String, name: String, kind: CardList.Kind, format: Format) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "list-export")
        let url = dir.appending(path: fileName(name, kind: kind, format: format))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func leftOutNote(_ left: Int) -> String? {
        left > 0 ? "\(left) card\(left == 1 ? "" : "s") newer than the card data \(left == 1 ? "was" : "were") left out." : nil
    }
}
