import Photos
import SwiftUI
import UIKit

/* Deck image (contract/deck-image-2026-10-20.md): a deck laid out as card images, the way tournament sites show a
   visual decklist (melee.gg's format), to save to Photos or share: 16:9, a header (deck name; "By" the player; date,
   format, deck and sideboard counts; the Table 1 mark), the main deck as a grid of cards with a count on each, a
   divider labelled Sideboard, and the sideboard as one overlapping column. Stacks instead lays the main deck in
   overlapping columns per group. Group by (type, mana value or color) orders the cards either way. Built on the device from the catalog pack and
   Scryfall's card images; nothing is uploaded. Your own decks and decks shared with you on a profile. */

enum DeckImage {
    /// `grid`: the tournament-site layout (a grid of cards, the sideboard as one column); `stacks`: overlapping
    /// columns per group.
    enum Layout: String, CaseIterable, Sendable { case stacks, grid }

    /// One card on the image: every copy of an Oracle card in a section, shown as its most-held printing.
    struct Card: Hashable, Sendable {
        let key: String
        let name: String
        let qty: Int
        let printing: CatalogPrinting?
        var finish = "nonfoil"
    }

    struct Pile: Hashable, Sendable {
        let title: String
        let cards: [Card]
        var count: Int { cards.reduce(0) { $0 + $1.qty } }
    }

    /// The main deck's groups (a deck's Commander first) and the sideboard's. Considering is left off.
    struct Plan: Hashable, Sendable {
        var main: [Pile]
        var side: [Card]
        var mainCount: Int { main.reduce(0) { $0 + $1.count } }
        var sideCount: Int { side.reduce(0) { $0 + $1.qty } }
    }

    /// Lines → the plan. Cards sort by mana value then name inside a group (the way decks are laid on a table).
    static func plan(_ lines: [ListLine], grouping: CardGrouping) -> Plan {
        func cards(_ ls: [ListLine]) -> [Card] {
            Dictionary(grouping: ls) { $0.oracleId ?? $0.cardId }.values.map { same in
                let lead = same.max { $0.qty != $1.qty ? $0.qty < $1.qty : $0.cardId > $1.cardId }!
                return Card(key: lead.oracleId ?? lead.cardId, name: lead.name, qty: same.reduce(0) { $0 + $1.qty },
                            printing: lead.printing, finish: lead.finish)
            }
            .sorted { a, b in
                let ma = mv(ls, a.key), mb = mv(ls, b.key)
                return ma != mb ? ma < mb : a.name < b.name
            }
        }
        let regrouped = ListLine.regrouped(lines, by: grouping == .none ? .type : grouping)
        let by = grouping == .none ? CardGrouping.type : grouping
        var main: [Pile] = []
        let commander = regrouped.filter { $0.board == "commander" }
        if !commander.isEmpty { main.append(Pile(title: "Commander", cards: cards(commander))) }
        let deck = regrouped.filter { $0.board == "main" }
        for g in ListLine.groups(deck, by: by) {
            main.append(Pile(title: by.label(g), cards: cards(deck.filter { $0.group == g })))
        }
        return Plan(main: main, side: cards(regrouped.filter { $0.board == "side" }))
    }

    private static func mv(_ lines: [ListLine], _ key: String) -> Int {
        guard let l = lines.first(where: { ($0.oracleId ?? $0.cardId) == key }) else { return 0 }
        return l.keys.manaValue == "Lands" ? 99 : Int(l.keys.manaValue.prefix(1)) ?? 7
    }

    /// Stacks: a group taller than `max` cards continues in the next column (untitled).
    static func columns(_ groups: [Pile], max: Int) -> [(title: String?, cards: [Card])] {
        groups.flatMap { g -> [(title: String?, cards: [Card])] in
            stride(from: 0, to: g.cards.count, by: max).map { i in
                (i == 0 ? "\(g.title) · \(g.count)" : nil, Array(g.cards[i..<min(i + max, g.cards.count)]))
            }
        }
    }

    /// Rows of `n` columns.
    static func rows<T>(_ items: [T], _ n: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: n).map { Array(items[$0..<min($0 + n, items.count)]) }
    }

    /// "Izzet Tempo.jpg", from the deck's name.
    static func fileName(_ deck: String) -> String {
        ListExport.fileName(deck, kind: .deck, format: .text).replacingOccurrences(of: ".txt", with: ".jpg")
    }
}

// MARK: canvas

extension DeckImage {
    /// Card sizes for the cards layout: the main deck as a grid (`cols` across, cards `cw` wide), the sideboard as one
    /// overlapping column (`step` between cards) right of a divider. Cards grow as large as the 16:9 canvas allows;
    /// below `minWidth` the canvas grows taller instead.
    struct Fit: Hashable { let cols: Int; let cw: CGFloat; let step: CGFloat; let height: CGFloat }

    static let width: CGFloat = 1200
    static let pad: CGFloat = 40
    static let header: CGFloat = 132
    static let gap: CGFloat = 14
    static let rowGap: CGFloat = 22
    static let sideGutter: CGFloat = 56
    static let aspect: CGFloat = 1.396
    static let minWidth: CGFloat = 72

    static func fit(main: Int, side: Int) -> Fit {
        let height = width * 9 / 16
        let room = height - header - pad
        let flag: CGFloat = side > 0 ? 1 : 0
        // The sideboard column must fit its cards at least 10% of a card apart.
        let sideMax = side > 1 ? room / ((1 + 0.1 * CGFloat(side - 1)) * aspect) : .infinity
        var best = (cols: 1, cw: CGFloat(0))
        for cols in 2...16 {
            let rows = CGFloat((max(main, 1) + cols - 1) / cols)
            let byWidth = (width - 2 * pad - flag * sideGutter - CGFloat(cols - 1) * gap) / (CGFloat(cols) + flag)
            let byHeight = (room - (rows - 1) * rowGap) / (rows * aspect)
            let cw = min(byWidth, byHeight, sideMax).rounded(.down)
            if cw > best.cw { best = (cols, cw) }
        }
        var cw = best.cw, cols = best.cols, total = height
        if cw < minWidth {
            cw = minWidth
            cols = max(1, Int((width - 2 * pad - flag * (sideGutter + cw) + gap) / (cw + gap)))
            let rows = CGFloat((max(main, 1) + cols - 1) / cols)
            total = max(height, header + pad + rows * cw * aspect + (rows - 1) * rowGap)
        }
        let ch = cw * aspect
        let sideRoom = total - header - pad
        let step = side > 1 ? min(ch * 0.19, (sideRoom - ch) / CGFloat(side - 1)) : 0
        return Fit(cols: cols, cw: cw, step: max(step, 0), height: total.rounded(.up))
    }

    /// The cards layout's order: the plan's groups in order (Commander first), each by mana value then name.
    static func ordered(_ plan: Plan) -> [Card] { plan.main.flatMap(\.cards) }
}

/// What the image draws. Card art comes in as decoded bitmaps (ImageRenderer draws one pass and can't wait for
/// downloads).
struct DeckImageCanvas: View {
    let name: String
    let format: String
    let player: String?
    let date: Date
    let plan: DeckImage.Plan
    let layout: DeckImage.Layout
    let showSide: Bool
    let art: [String: UIImage]

    static let width = DeckImage.width
    private var side: [DeckImage.Card] { showSide ? plan.side : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: DeckImage.header, alignment: .top)
            if layout == .grid { cards } else { stacks.padding(.horizontal, DeckImage.pad).padding(.bottom, DeckImage.pad) }
        }
        .frame(width: Self.width, alignment: .topLeading)
        .background(T1.bg)
        .foregroundStyle(T1.text)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(T1.mono(30, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                if let player { Text("By \(player)").font(T1.mono(17, .medium)).lineLimit(1) }
                Text([date.formatted(.dateTime.month(.abbreviated).day().year()), "Format: \(formatName(format))",
                      "Deck: \(plan.mainCount) cards", side.isEmpty ? nil : "Sideboard: \(plan.sideCount) cards"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(T1.mono(14)).foregroundStyle(T1.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                T1Logo().fill(T1.text).aspectRatio(T1Logo.aspect, contentMode: .fit).frame(height: 30)
                Text("TABLE-1.SITE").font(T1.mono(11)).tracking(2.5).foregroundStyle(T1.muted)
            }
        }
        .padding(.horizontal, DeckImage.pad).padding(.top, 36)
    }

    // cards (the tournament-site layout): the main deck as a grid, the sideboard as one overlapping column.

    private var cards: some View {
        let fit = DeckImage.fit(main: DeckImage.ordered(plan).count, side: side.count)
        let ch = fit.cw * DeckImage.aspect
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: DeckImage.rowGap) {
                ForEach(Array(DeckImage.rows(DeckImage.ordered(plan), fit.cols).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: DeckImage.gap) { ForEach(row, id: \.key) { tile($0, width: fit.cw) } }
                }
            }
            Spacer(minLength: 0)
            if !side.isEmpty {
                ZStack {
                    Rectangle().fill(T1.muted.opacity(0.5)).frame(width: 1)
                    Text("SIDEBOARD").font(T1.mono(11)).tracking(2.5).foregroundStyle(T1.muted)
                        .fixedSize().padding(.vertical, 8).background(T1.bg)
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: DeckImage.sideGutter)
                ZStack(alignment: .top) {
                    ForEach(Array(side.enumerated()), id: \.offset) { i, c in tile(c, width: fit.cw).offset(y: CGFloat(i) * fit.step) }
                }
                .frame(width: fit.cw, height: ch + CGFloat(side.count - 1) * fit.step, alignment: .top)
            }
        }
        .padding(.horizontal, DeckImage.pad)
        .frame(width: Self.width, height: fit.height - DeckImage.header, alignment: .top)
    }

    // stacks: columns of overlapping cards per group (Group by), titled; the sideboard down the right.

    private var sideCols: Int { side.isEmpty ? 0 : side.count > 10 ? 2 : 1 }
    private let cw: CGFloat = 140
    private var ch: CGFloat { cw * DeckImage.aspect }
    private var step: CGFloat { ch * 0.118 }
    private var mainPerRow: Int {
        let room = Self.width - 2 * DeckImage.pad - (sideCols > 0 ? CGFloat(sideCols) * (cw + DeckImage.gap) + DeckImage.sideGutter : 0)
        return max(1, Int((room + DeckImage.gap) / (cw + DeckImage.gap)))
    }

    private var stacks: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Array(DeckImage.rows(DeckImage.columns(plan.main, max: 9), mainPerRow).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: DeckImage.gap) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, col in column(col.title, col.cards) }
                    }
                }
            }
            Spacer(minLength: 0)
            if sideCols > 0 {
                Rectangle().fill(T1.muted.opacity(0.5)).frame(width: 1).padding(.horizontal, (DeckImage.sideGutter - 1) / 2)
                HStack(alignment: .top, spacing: DeckImage.gap) {
                    ForEach(Array(DeckImage.rows(side, Int((Double(side.count) / Double(sideCols)).rounded(.up))).enumerated()), id: \.offset) { i, cards in
                        column(i == 0 ? "Sideboard · \(plan.sideCount)" : nil, cards)
                    }
                }
            }
        }
    }

    private func column(_ title: String?, _ cards: [DeckImage.Card]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((title ?? " ").uppercased()).font(T1.mono(12)).tracking(2).foregroundStyle(T1.muted).lineLimit(1)
                .frame(width: cw, alignment: .leading)
            ZStack(alignment: .top) {
                ForEach(Array(cards.enumerated()), id: \.offset) { i, c in tile(c, width: cw).offset(y: CGFloat(i) * step) }
            }
            .frame(width: cw, height: ch + CGFloat(max(0, cards.count - 1)) * step, alignment: .top)
        }
    }

    /// A card with its count on a square badge over the top-right corner.
    private func tile(_ c: DeckImage.Card, width: CGFloat) -> some View {
        let height = width * DeckImage.aspect
        let badge = max(18, width * 0.16)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let img = c.printing.flatMap({ art[$0.cardId] }) {
                    Image(uiImage: img).resizable().interpolation(.high).scaledToFill()
                } else {
                    ZStack(alignment: .topLeading) {
                        T1.surfaceHover
                        Text(c.name).font(T1.mono(11)).padding(8)
                    }
                }
            }
            .frame(width: width, height: height)
            .overlay { if c.finish != "nonfoil" { FoilSheen(etched: c.finish == "etched") } }
            .clipShape(RoundedRectangle(cornerRadius: width * CardCorners.ratio(set: c.printing?.set ?? ""), style: .circular))
            Text("\(c.qty)")
                .font(T1.mono(badge * 0.55, .semibold)).monospacedDigit()
                .frame(minWidth: badge, minHeight: badge)
                .padding(.horizontal, c.qty > 9 ? 3 : 0)
                .background(T1.surface)
                .overlay(Rectangle().stroke(T1.muted.opacity(0.6), lineWidth: 1))
                .offset(x: badge * 0.35, y: -badge * 0.35)
        }
        .frame(width: width, height: height)
    }
}

// MARK: screen

/// Make, save and share: a preview of the image with its options, then Save to Photos and Share.
struct DeckImagePanel: View {
    let name: String
    let format: String
    let entries: [CardList.Entry]
    /// The deck's player: yours on your own decks (switchable), the owner's on a shared one.
    var owner: String?
    /// Telemetry: own / profile.
    let from: String
    private var catalog: CatalogStore { CatalogStore.shared }
    @AppStorage("library.deckImage.layout") private var layoutRaw = DeckImage.Layout.grid.rawValue
    @AppStorage("library.deckImage.grouping") private var groupingRaw = CardGrouping.type.rawValue
    @AppStorage("library.deckImage.sideboard") private var showSide = true
    @AppStorage("library.deckImage.name") private var showName = true
    @State private var lines: [ListLine]?
    @State private var art: [String: UIImage] = [:]
    @State private var myName: String?
    @State private var image: UIImage?
    @State private var progress: (done: Int, of: Int)?
    @State private var share: ShareFile?
    @State private var note: String?
    @State private var error: String?

    private var layout: DeckImage.Layout { DeckImage.Layout(rawValue: layoutRaw) ?? .grid }
    private var grouping: CardGrouping { CardGrouping(rawValue: groupingRaw).flatMap { $0 == .none ? nil : $0 } ?? .type }
    private var player: String? { owner ?? (showName ? myName : nil) }

    var body: some View {
        T1Screen {
            Bar(title: "Deck image", subtitle: name, back: { T1Overlays.shared.dismissPanel() })
            HairlineList {
                T1Segmented(options: [(DeckImage.Layout.grid.rawValue, "Cards"), (DeckImage.Layout.stacks.rawValue, "Stacks")], selection: $layoutRaw)
                T1Segmented(options: [(CardGrouping.type.rawValue, "Type"), (CardGrouping.manaValue.rawValue, "Mana value"),
                                      (CardGrouping.color.rawValue, "Color"), (CardGrouping.identity.rawValue, "Identity")],
                                      selection: $groupingRaw)
                if lines?.contains(where: { $0.board == "side" }) == true { T1Switch(title: "Sideboard", isOn: $showSide) }
                if owner == nil { T1Switch(title: "Your name", detail: myName ?? "Not set", isOn: $showName) }
                if let error { Notice(error, error: true) }
                if let note { Notice(note) }
                if let image {
                    ZoomablePreview(title: "Deck image", subtitle: name, image: image, screen: "deck_image",
                                    actions: MadeImageActions(copy: copy, save: save, share: shareImage))
                } else if let progress {
                    Notice("Getting card images… \(progress.done) of \(progress.of)")
                } else {
                    Notice(catalog.db == nil ? "Waiting for the card data…" : "Laying out the cards…")
                }
            }
            HStack(spacing: 1) {
                Ghost(text: "Save to Photos", accent: true) { Task { await save() } }
                Ghost(text: "Share") { shareImage() }
            }
            .padding(.bottom, 1)
            .disabled(image == nil)
        }
        .sheet(item: $share) { ShareSheet(share: $0).ignoresSafeArea() }
        .task(id: catalog.generation) { await prepare() }
        .task(id: "\(layoutRaw)|\(groupingRaw)|\(showSide)|\(showName)|\(art.count)|\(myName ?? "")|\(lines?.count ?? -1)") { render() }
    }

    /// Resolves the cards and downloads their images once; options only re-render.
    private func prepare() async {
        catalog.load(userInitiated: true)
        guard let db = catalog.db else { return }
        if owner == nil, myName == nil { myName = await Repo.myDisplayName() }
        let entries = entries.filter { $0.board != "maybe" }
        let resolved = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: .deck, db) }.value
        let printings = Dictionary(resolved.compactMap { l in l.printing.map { ($0.cardId, $0) } }, uniquingKeysWith: { a, _ in a })
        progress = (0, printings.count)
        let maxPixel = 360
        var loaded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for (id, p) in printings {
                group.addTask {
                    guard let url = p.imageURL(CardImageSize.covering(pixels: CGFloat(maxPixel)).rawValue) else { return (id, nil) }
                    return (id, await CardImageLoader.shared.image(url, maxPixel: maxPixel))
                }
            }
            for await (id, img) in group {
                if let img { loaded[id] = img }
                progress = (loaded.count, printings.count)
            }
        }
        if loaded.count < printings.count { note = "\(printings.count - loaded.count) card images couldn't be loaded; their names show instead." }
        art = loaded
        lines = resolved
        progress = nil
    }

    private func render() {
        guard let lines else { return }
        let canvas = DeckImageCanvas(name: name, format: format, player: player, date: .now,
                                     plan: DeckImage.plan(lines, grouping: grouping), layout: layout, showSide: showSide, art: art)
        let r = ImageRenderer(content: canvas)
        r.scale = 2
        r.isOpaque = true
        image = r.uiImage
    }

    @discardableResult
    private func save() async -> String {
        guard let image else { return "" }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            error = "Table 1 can't add to Photos. Allow it in Settings → Table 1 → Photos, or use Share → Save Image."
            return error ?? ""
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            error = nil
            note = "Saved to Photos."
            sent("photos")
            return "Saved to Photos."
        } catch {
            self.error = error.localizedDescription
            return error.localizedDescription
        }
    }

    private func copy() -> String {
        guard let image else { return "" }
        let said = MadeImageActions.copy(image)
        error = nil
        note = said
        sent("copy")
        return said
    }

    private func shareImage() {
        guard let data = image?.jpegData(compressionQuality: 0.9) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "deck-image").appending(path: DeckImage.fileName(name))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            share = ShareFile(url: url)
            sent("share")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sent(_ how: String) {
        Telemetry.capture("deck_image_shared", ["layout": layout.rawValue, "grouping": grouping.rawValue, "sideboard": showSide,
                                                "cards": lines?.reduce(0) { $0 + $1.qty } ?? 0, "from": from, "how": how])
    }
}
