import XCTest
@testable import Table1

/* Collection CSV import and export (contract/collection-import-2026-10-17.md). Same cases as
   table-1-events-web/src/lib/collectionCsv.test.ts. The fixtures in testdata/collection-import are the same 24 cards
   as seven apps export them; matching runs against the real catalog pack in testdata/scan (shortened ids, so lines
   match by set + collector number or set + name there, as they would on a phone without Scryfall ids). */

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/collection-import").standardized
private let scan = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/scan").standardized

private func fixture(_ name: String) throws -> String { try String(contentsOf: fixtures.appending(path: name), encoding: .utf8) }

private struct Expected: Decodable {
    struct Card: Decodable {
        let set: String, cn: String, name: String, finish: String, condition: String, lang: String, qty: Int
    }
    let unmatched: String
    let cards: [Card]
    static func load() throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: Data(contentsOf: fixtures.appending(path: "expected.json")))
    }
}

/// One catalog built from the test pack for every matching test in the run.
enum TestCatalog {
    static let db: CatalogDB = {
        let path = FileManager.default.temporaryDirectory.appending(path: "import-test-catalog.sqlite").path
        let pack = try! CatalogPack.gunzip(Data(contentsOf: scan.appending(path: "catalog.tsv.gz")))
        let header = try! CatalogDB.build(pack: pack, at: path)
        return try! CatalogDB(path: path, version: header.version)
    }()
    static let setNames: [(code: String, name: String)] = {
        struct Row: Decodable { let code: String; let name: String }
        let rows = try! JSONDecoder().decode([Row].self, from: Data(contentsOf: fixtures.appending(path: "sets.json")))
        return rows.map { ($0.code, $0.name) }
    }()
}

final class CollectionCSVParseTests: XCTestCase {
    func testQuotingLineEndsAndBOM() throws {
        let text = "\u{FEFF}Name,Set code,Collector number,Quantity\r\n\"Aragorn, the Uniter\",LTR,192,1\r\n\"Say \"\"Hi\"\"\nTwice\",M11,149,2\r\n\r\n"
        let p = try CollectionCSV.parse(text)
        XCTAssertEqual(p.rows.map(\.name), ["Aragorn, the Uniter", "Say \"Hi\"\nTwice"])
        XCTAssertEqual(p.rows.map(\.setCode), ["ltr", "m11"])
        XCTAssertEqual(p.rows.map(\.qty), [1, 2])
        XCTAssertEqual(p.rows.map(\.line), [2, 3])
    }

    func testDelimiters() throws {
        let tab = try CollectionCSV.parse("Name\tSet\tQuantity\nLightning Bolt\tm11\t3\n")
        XCTAssertEqual(tab.rows.first?.qty, 3)
        XCTAssertEqual(tab.rows.first?.setCode, "m11")
        let semi = try CollectionCSV.parse("Name;Edition;Count\nLightning Bolt;Magic 2011;2\n")
        XCTAssertEqual(semi.rows.first?.setName, "Magic 2011")
        XCTAssertEqual(semi.rows.first?.qty, 2)
        let sep = try CollectionCSV.parse("\"sep=;\"\nName;Quantity\nShock;4\n")
        XCTAssertEqual(sep.rows.first?.name, "Shock")
        XCTAssertEqual(sep.rows.first?.line, 3)
    }

    func testNoNameColumnIsRefused() {
        XCTAssertThrowsError(try CollectionCSV.parse("Set,Quantity\nm11,1\n")) {
            XCTAssertEqual(($0 as? CollectionCSV.Failure)?.message, "This file has no card name column.")
        }
        XCTAssertThrowsError(try CollectionCSV.parse(""))
    }

    func testDetectsEveryFixture() throws {
        let cases: [(String, CSVFormat)] = [
            ("manabox.csv", .manabox), ("moxfield.csv", .moxfield), ("archidekt.csv", .archidekt), ("deckbox.csv", .deckbox),
            ("dragonshield.csv", .dragonshield), ("tcgplayer.csv", .tcgplayer), ("delverlens.csv", .delverlens),
        ]
        for (file, format) in cases {
            let p = try CollectionCSV.parse(try fixture(file))
            XCTAssertEqual(p.format, format, file)
            XCTAssertEqual(p.rows.count, 25, file) // 24 cards and the unknown line
        }
        XCTAssertEqual(try CollectionCSV.parse("Card,Qty\nShock,1\n").format, .other)
    }

    func testQuantities() {
        XCTAssertEqual(CollectionCSV.quantity("2x"), 2)
        XCTAssertEqual(CollectionCSV.quantity(" 12 "), 12)
        XCTAssertEqual(CollectionCSV.quantity(""), 1)
        XCTAssertNil(CollectionCSV.quantity("lots"))
        XCTAssertNil(CollectionCSV.quantity("-1"))
    }

    func testBadQuantityIsAProblemAndZeroIsSkipped() throws {
        let p = try CollectionCSV.parse("Name,Quantity\nShock,lots\nBolt,0\nOpt,\n")
        XCTAssertEqual(p.rows.map(\.name), ["Shock", "Opt"])
        XCTAssertEqual(p.rows[0].problem, "Quantity isn't a number")
        XCTAssertEqual(p.rows[1].qty, 1)
    }

    func testFinishes() {
        for (v, f) in [("", "nonfoil"), ("normal", "nonfoil"), ("Normal", "nonfoil"), ("Non-foil", "nonfoil"), ("false", "nonfoil"),
                       ("foil", "foil"), ("Foil", "foil"), ("Double Rainbow Foil", "foil"), ("true", "foil"), ("1", "foil"),
                       ("etched", "etched"), ("Foil Etched", "etched")] {
            XCTAssertEqual(CollectionCSV.finish(v), f, v)
        }
    }

    func testConditionScales() {
        let us: [(String, String)] = [("Mint", "NM"), ("Near Mint", "NM"), ("NM", "NM"), ("", "NM"), ("weird", "NM"),
                                      ("Lightly Played", "LP"), ("Good (Lightly Played)", "LP"), ("Excellent", "LP"),
                                      ("Moderately Played", "MP"), ("Played", "MP"), ("Heavily Played", "HP"),
                                      ("Damaged", "DMG"), ("Poor", "DMG"), ("D", "DMG")]
        for (v, c) in us { XCTAssertEqual(CollectionCSV.condition(v, cardmarket: false), c, v) }
        let cardmarket: [(String, String)] = [("mint", "NM"), ("near_mint", "NM"), ("NearMint", "NM"), ("excellent", "LP"),
                                              ("good", "LP"), ("light_played", "MP"), ("LightPlayed", "MP"), ("played", "HP"),
                                              ("Played", "HP"), ("poor", "DMG"), ("Damaged", "DMG")]
        for (v, c) in cardmarket { XCTAssertEqual(CollectionCSV.condition(v, cardmarket: true), c, v) }
    }

    func testLanguages() {
        for (v, l) in [("English", "en"), ("EN", "en"), ("de", "de"), ("German", "de"), ("Japanese", "ja"), ("jp", "ja"),
                       ("Korean", "ko"), ("Chinese Simplified", "zhs"), ("Simplified Chinese", "zhs"), ("zh_CN", "zhs"),
                       ("Traditional Chinese", "zht"), ("zh-TW", "zht"), ("Portuguese (Brazil)", "pt"), ("Klingon", "en"), ("", "en")] {
            XCTAssertEqual(CollectionCSV.language(v), l, v)
        }
    }

    func testFormatSpecificColumns() throws {
        // Moxfield's Edition is a code; Deckbox's and Delver Lens's are names; TCGplayer's Set is a name.
        XCTAssertEqual(try CollectionCSV.parse(try fixture("moxfield.csv")).rows[0].setCode, "m11")
        let deckbox = try CollectionCSV.parse(try fixture("deckbox.csv")).rows[0]
        XCTAssertEqual(deckbox.setName, "Magic 2011")
        XCTAssertEqual(deckbox.setCode, "m11")
        XCTAssertEqual(try CollectionCSV.parse(try fixture("delverlens.csv")).rows[0].setName, "Magic 2011")
        let tcg = try CollectionCSV.parse(try fixture("tcgplayer.csv")).rows
        XCTAssertEqual(tcg[3].name, "Brazen Borrower") // Simple Name, not "Brazen Borrower // Petty Theft"
        XCTAssertEqual(tcg.first { $0.cn == "300" }?.finish, "etched") // "(Foil Etched)" in Name
        // Dragon Shield's guild kit codes and TCGplayer seller grades.
        let ds = try CollectionCSV.parse("\"sep=,\"\nFolder Name,Quantity,Card Name,Set Code,Card Number,Printing\nA,1,Azorius Herald,GK2_AZORIU,2,Normal\n")
        XCTAssertEqual(ds.rows[0].setCode, "gk2")
        let seller = try CollectionCSV.parse("TCGplayer Id,Product Name,Set Name,Number,Condition,Total Quantity\n1,Shock,M19,156,Near Mint Foil,2\n")
        XCTAssertEqual(seller.format, .tcgplayer)
        XCTAssertEqual(seller.rows[0].finish, "foil")
        XCTAssertEqual(seller.rows[0].condition, "NM")
        XCTAssertEqual(seller.rows[0].qty, 2)
    }

    func testExportLayoutsReadBack() throws {
        let cards = try Expected.load().cards.map {
            CollectionCSV.ExportCard(name: $0.name, set: $0.set, setName: "Set \($0.set)", cn: $0.cn, rarity: "r", cardId: "id-\($0.set)-\($0.cn)",
                                     finish: $0.finish, condition: $0.condition, lang: $0.lang, qty: $0.qty)
        }
        for layout in CollectionCSV.Layout.allCases {
            let text = CollectionCSV.export(cards, layout: layout)
            let p = try CollectionCSV.parse(text)
            XCTAssertEqual(p.format, layout == .moxfield ? .moxfield : .manabox)
            func key(_ s: String, _ cn: String?, _ f: String, _ c: String, _ l: String, _ q: Int) -> String { "\(s)|\(cn ?? "")|\(f)|\(c)|\(l)|\(q)" }
            XCTAssertEqual(Set(p.rows.map { key($0.setCode ?? "", $0.cn, $0.finish, $0.condition, $0.lang, $0.qty) }),
                           Set(cards.map { key($0.set, $0.cn, $0.finish, $0.condition, $0.lang, $0.qty) }), layout.rawValue)
            XCTAssertEqual(Set(p.rows.map(\.name)), Set(cards.map(\.name)))
            if layout == .manabox { XCTAssertEqual(Set(p.rows.compactMap(\.scryfallId)), Set(cards.map { $0.cardId.lowercased() })) }
        }
        XCTAssertTrue(CollectionCSV.export(cards, layout: .moxfield).hasPrefix("\"Count\",\"Tradelist Count\",\"Name\",\"Edition\""))
        XCTAssertTrue(CollectionCSV.export(cards, layout: .manabox).hasPrefix("Name,Set code,Set name,Collector number,Foil,Rarity,Quantity"))
    }
}

final class CollectionImportMatchTests: XCTestCase {
    private func resolve(_ file: String) throws -> (matched: [ResolvedLine], unmatched: [ImportRow]) {
        let p = try CollectionCSV.parse(try fixture(file))
        return ImportResolver(db: TestCatalog.db, setNames: TestCatalog.setNames).resolve(p.rows)
    }

    /// Files with set codes and collector numbers land on exactly the printing, finish, condition and language.
    func testExactFormats() throws {
        let want = try Expected.load()
        for file in ["manabox.csv", "moxfield.csv", "archidekt.csv", "deckbox.csv", "dragonshield.csv", "tcgplayer.csv"] {
            let r = try resolve(file)
            XCTAssertEqual(r.unmatched.map(\.name), [want.unmatched], file)
            XCTAssertEqual(r.matched.count, want.cards.count, file)
            for (got, card) in zip(r.matched, want.cards) {
                let label = "\(file) line \(got.row.line)"
                XCTAssertEqual("\(got.printing.set) \(got.printing.cn)", "\(card.set) \(card.cn)", label)
                XCTAssertEqual(got.finish, card.finish, label)
                XCTAssertEqual(got.row.condition, card.condition, label)
                XCTAssertEqual(got.row.lang, card.lang, label)
                XCTAssertEqual(got.row.qty, card.qty, label)
            }
        }
    }

    /// Delver Lens's own CSV has set names but no collector numbers (and no ids that match the shortened test pack):
    /// set + name finds the card in the right set; its foil column can't say etched.
    func testDelverLensBySetName() throws {
        let want = try Expected.load()
        let r = try resolve("delverlens.csv")
        XCTAssertEqual(r.unmatched.map(\.name), [want.unmatched])
        XCTAssertEqual(r.matched.count, want.cards.count)
        let db = TestCatalog.db
        for (got, card) in zip(r.matched, want.cards) {
            XCTAssertEqual(got.how, .setName, card.name)
            XCTAssertEqual(got.printing.set, card.set, card.name)
            XCTAssertEqual(db.oracles(idxs: [got.printing.oracleIdx]).values.first?.name, card.name)
            XCTAssertEqual(got.finish, card.finish == "etched" ? "foil" : card.finish, card.name)
            XCTAssertEqual(got.row.qty, card.qty)
        }
    }

    func testMatchOrder() throws {
        let resolver = ImportResolver(db: TestCatalog.db, setNames: TestCatalog.setNames)
        func row(_ name: String, set: String? = nil, setName: String? = nil, cn: String? = nil, finish: String = "nonfoil", lang: String = "en") -> ImportRow {
            ImportRow(line: 2, name: name, setCode: set, setName: setName, cn: cn, scryfallId: nil, qty: 1, finish: finish,
                      condition: "NM", lang: lang)
        }
        let db = TestCatalog.db
        func name(_ l: ResolvedLine?) -> String? { l.flatMap { db.oracles(idxs: [$0.printing.oracleIdx]).values.first?.name } }
        // set + number
        let bolt = resolver.resolve(row("Lightning Bolt", set: "m11", cn: "149"))
        XCTAssertEqual(bolt?.how, .setNumber)
        XCTAssertEqual(bolt?.printing.cn, "149")
        // a wrong number for the name falls through to set + name
        let wrong = resolver.resolve(row("Lightning Bolt", set: "m11", cn: "1"))
        XCTAssertEqual(wrong?.how, .setName)
        XCTAssertEqual(wrong?.printing.cn, "149")
        // set by name, a face of a split card, leading zeros
        XCTAssertEqual(resolver.resolve(row("Armed", setName: "Dragon's Maze", cn: "0122"))?.printing.cn, "122")
        // name only → the original printing
        let named = resolver.resolve(row("Brazen Borrower"))
        XCTAssertEqual(named?.how, .name)
        XCTAssertEqual(name(named), "Brazen Borrower // Petty Theft")
        XCTAssertTrue(named?.printing.original ?? false)
        // decorations
        XCTAssertEqual(name(resolver.resolve(row("Abbey Matron [Version 2]"))), "Abbey Matron")
        XCTAssertEqual(name(resolver.resolve(row("Lightning Bolt (Borderless)"))), "Lightning Bolt")
        XCTAssertEqual(name(resolver.resolve(row("Clue Token", set: "tmh2", cn: "14"))), "Clue")
        // an unknown set code still matches by name; nothing matches nonsense
        XCTAssertEqual(resolver.resolve(row("Lightning Bolt", set: "zzz", cn: "1"))?.how, .name)
        XCTAssertNil(resolver.resolve(row("Totally Not A Card", set: "zzz")))
        // a finish the printing lacks: etched → foil, foil → the printing's first finish
        XCTAssertEqual(resolver.resolve(row("Blasphemous Act", set: "2xm", cn: "117", finish: "etched"))?.finish, "foil")
        // fixing a line by hand
        let fixed = resolver.resolve(row("Totally Not A Card", set: "m11"), oracleIdx: bolt!.printing.oracleIdx)
        XCTAssertEqual(fixed?.how, .fixed)
        XCTAssertEqual(fixed?.printing.set, "m11")
    }

    func testItemsMergeSameCopies() throws {
        let r = try resolve("manabox.csv")
        let doubled = ImportResolver.items(r.matched + r.matched)
        XCTAssertEqual(doubled.count, ImportResolver.items(r.matched).count)
        XCTAssertEqual(doubled.reduce(0) { $0 + $1.qty }, 2 * r.matched.reduce(0) { $0 + $1.row.qty })
    }
}

/* Budgets for a 20,000-line ManaBox file (Debug, Simulator, John's Mac), ~3x what it measured on 2026-10-17: parse
   210 ms; match 150 ms by Scryfall id, 470 ms by set + collector number. A per-line Set.subtracting over every id in
   the file once made matching take 12 s; these catch that kind of slip. */
private enum ImportBudget {
    static let parseMs = 650.0
    static let resolveMs = 1_500.0
}

final class CollectionImportPerfTests: XCTestCase {
    /// 20,000 real printings from the test pack written as a ManaBox export.
    private static let bigFile: String = {
        let pack = String(decoding: try! CatalogPack.gunzip(Data(contentsOf: scan.appending(path: "catalog.tsv.gz"))), as: UTF8.self)
        var names: [Int: String] = [:]
        var lines = ["Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency"]
        var n = 0
        for l in pack.split(separator: "\n") where n < 20_000 {
            let c = l.split(separator: "\t", omittingEmptySubsequences: false)
            if c[0] == "O" { names[Int(c[1])!] = String(c[3]) }
            if c[0] == "P", c[5] == "en", let name = names[Int(c[2])!] {
                let q = name.contains(",") || name.contains("\"") ? "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : name
                lines.append("Binder,binder,\(q),\(c[3].uppercased()),Some Set,\(c[4]),\(c[7].contains("f") && n % 5 == 0 ? "foil" : "normal"),common,\(n % 4 + 1),\(n),\(c[1]),0.10,false,false,near_mint,en,USD")
                n += 1
            }
        }
        return lines.joined(separator: "\n")
    }()

    func testParseAndResolve20kLines() throws {
        let text = Self.bigFile
        let t0 = CFAbsoluteTimeGetCurrent()
        let parsed = try CollectionCSV.parse(text)
        let parseMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertEqual(parsed.rows.count, 20_000)
        _ = TestCatalog.db
        let t1 = CFAbsoluteTimeGetCurrent()
        let r = ImportResolver(db: TestCatalog.db, setNames: TestCatalog.setNames).resolve(parsed.rows)
        let resolveMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        print("perf ios import parse 20k lines: \(Int(parseMs)) ms (budget \(Int(ImportBudget.parseMs)))")
        print("perf ios import match 20k lines: \(Int(resolveMs)) ms (budget \(Int(ImportBudget.resolveMs)))")
        XCTAssertGreaterThan(r.matched.count, 19_900)
        XCTAssertLessThan(parseMs, ImportBudget.parseMs, "parsing a 20k-line CSV got slower")
        XCTAssertLessThan(resolveMs, ImportBudget.resolveMs, "matching a 20k-line CSV got slower")
    }

    /// The same file without Scryfall ids: every line matches by set + collector number.
    func testResolve20kLinesBySetNumber() throws {
        var rows = try CollectionCSV.parse(Self.bigFile).rows
        for i in rows.indices { rows[i].scryfallId = nil }
        _ = TestCatalog.db
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = ImportResolver(db: TestCatalog.db, setNames: TestCatalog.setNames).resolve(rows)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("perf ios import match 20k lines by set + number: \(Int(ms)) ms (budget \(Int(ImportBudget.resolveMs)))")
        XCTAssertGreaterThan(r.matched.count, 19_900)
        XCTAssertLessThan(ms, ImportBudget.resolveMs, "matching a 20k-line CSV by set + number got slower")
    }
}
