import SwiftUI

/* Card detail (contract/card-detail-2026-10-23.md, Figma 318:10810): the card, one row of attributes and one bottom
   bar. Opened in a scope (CardContext: nil = the collection, a deck or cube, a binder, or search); the attribute
   row changes the copies in view, the stepper counts them, and Add to puts the version on screen anywhere else. The
   list icon flips to the info view: rules text, details, and the rest of what the old screen had. */

struct CardDetailView: View {
    let oracleId: String
    var path: Binding<[LibraryRoute]>?
    var context: CardContext?
    @Environment(\.dismiss) private var dismiss
    private var col: CollectionStore { CollectionStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    private var lists: ListsStore { ListsStore.shared }
    private var binders: BindersStore { BindersStore.shared }

    @State private var oracle: CatalogOracle?
    @State private var printings: [CatalogPrinting] = []
    @State private var looked = false
    /// The grid tile picked (a version id); edits then change only it.
    @State private var selected: String?
    /// The version on screen when the scope holds none (search, or every copy removed).
    @State private var draft: CardVersion?
    /// A new edition from a long press on +: shown dimmed and selected, written once a pick makes it different.
    @State private var edition: CardVersion?
    @State private var info = false
    @State private var back = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var last: CardUndo?
    /// Condition and language new copies go in as (shared with the scanner and binder adds).
    @AppStorage("library.addCondition") private var addCondition = "NM"
    @AppStorage("library.addLang") private var addLang = "en"

    private var byId: [String: CatalogPrinting] { Dictionary(printings.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a }) }

    /// `selected` when the new edition is the picked tile.
    private static let editionId = "new-edition"

    private var listId: String? { if case .list(let id) = context { id } else { nil } }
    private var binderId: String? { if case .binder(let id) = context { id } else { nil } }
    private var isSearch: Bool { context == .search }
    private var scopeName: String {
        switch context {
        case nil: "collection"
        case .list: "list"
        case .binder: "binder"
        case .search: "search"
        }
    }

    /// The scope's versions of this card, in grid order.
    private var versions: [CardVersion] {
        let ids = Set(printings.map(\.cardId))
        let raw: [CardVersion]
        switch context {
        case nil:
            raw = col.items.values.filter { ids.contains($0.cardId) }.map { CardVersion($0) }
        case .binder(let b):
            let _ = binders.version
            raw = col.items.values.filter { ids.contains($0.cardId) }.compactMap { it in
                let q = PrintingChange.places(it).first { $0.place == b }?.qty ?? 0
                return q > 0 ? CardVersion(it, qty: q) : nil
            }
        case .list(let l):
            raw = (lists.list(id: l)?.entries ?? []).filter { ids.contains($0.cardId) }.map(CardVersion.init)
        case .search:
            raw = []
        }
        return CardDetailRules.ordered(raw, printings: printings)
    }

    var body: some View {
        let versions = versions
        let chosen = selected == Self.editionId ? edition : versions.first { $0.id == selected }
        let inView = chosen.map { [$0] } ?? versions
        let current = chosen ?? CardDetailRules.main(versions) ?? draft ?? fresh
        T1Screen {
            // Foldables (contract/foldables-2026-11-10.md § The screens): wide, tabletop or book put the card alone in
            // the first pane and everything you do with it in the second; Details then keeps the card in view.
            FoldSplit(screen: "card_detail", enabled: oracle != nil && current != nil) {
                VStack(spacing: 1) {
                    bar(current, inView: inView)
                    notices
                    if let oracle, let current {
                        if info {
                            status
                            infoView(oracle, current: current, versions: versions)
                        } else {
                            cardArea(versions, current: current)
                            status
                            controls(versions, chosen: chosen, inView: inView, current: current)
                        }
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            } first: { _ in
                if let current { cardArea(versions, current: current) }
            } second: { _ in
                VStack(spacing: 1) {
                    bar(current, inView: inView)
                    notices
                    if let oracle, let current {
                        status
                        if info {
                            infoView(oracle, current: current, versions: versions)
                        } else {
                            Spacer(minLength: 0)
                            controls(versions, chosen: chosen, inView: inView, current: current)
                        }
                    }
                }
            }
        }
        .task(id: catalog.generation) {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let id = oracleId
            let found = await Task.detached(priority: .userInitiated) { () -> (CatalogOracle?, [CatalogPrinting]) in
                guard let o = db.oracle(id: id) else { return (nil, []) }
                return (o, db.printings(oracleIdx: o.idx))
            }.value
            oracle = found.0
            printings = found.1.sorted(by: CatalogPrinting.oldestFirst)
            looked = true
            await PriceBook.shared.load(found.1.map(\.cardId))
        }
        .onChange(of: versions.map(\.id)) { _, ids in
            if let s = selected, s != Self.editionId, !ids.contains(s) { selected = nil }
        }
    }

    @ViewBuilder private var notices: some View {
        if let message = error ?? col.error { Notice(message, error: true) }
        CatalogStatusRow(catalog: catalog)
        if looked && oracle == nil && catalog.phase == .ready { Notice("That card isn't in the card data.", error: true) }
    }

    private func infoView(_ oracle: CatalogOracle, current: CardVersion, versions: [CardVersion]) -> some View {
        CardInfoView(oracle: oracle, printing: byId[current.cardId], version: current, printings: printings,
                     context: context, path: path, versions: versions,
                     report: { label, undo in report(label, undo) })
    }

    /// Match collection, the attribute row and the stepper (or Add to): under the card, or the second pane.
    @ViewBuilder private func controls(_ versions: [CardVersion], chosen: CardVersion?, inView: [CardVersion], current: CardVersion) -> some View {
        if last == nil, let list = listId.flatMap({ lists.list(id: $0) }) { matchRow(list) }
        attributes(inView.isEmpty ? [current] : inView, owned: !versions.isEmpty)
        if isSearch {
            BigBarButton(text: "Add to") { openAddTo([current]) }
        } else {
            stepper(versions, chosen: chosen, inView: inView, current: current)
        }
    }

    /// A new version: the card's original printing in the condition and language picked for adds.
    private var fresh: CardVersion? {
        // A deck or cube line starts near mint: its condition comes only from copies added from your collection.
        CardDetailRules.fresh(printings, condition: listId == nil ? addCondition : "NM", lang: addLang, board: listId == nil ? nil : "main")
    }

    // MARK: bar

    private func bar(_ current: CardVersion?, inView: [CardVersion]) -> some View {
        let price = current.flatMap {
            PriceBook.marked(PriceBook.text(PriceBook.shared.usd($0.cardId, $0.finish, $0.condition)),
                             converted: PriceBook.shared.converted($0.cardId, $0.finish))
        }
        return HStack(spacing: 0) {
            CardBarButton(label: "Back", action: { dismiss() }) { BackArrow().fill(T1.text) }
            HStack(spacing: 2) {
                Text(oracle?.name ?? "Card").font(T1.mono(12)).lineLimit(1)
                Spacer(minLength: 8)
                if let price { Text(price).font(T1.mono(12)).tracking(1.5).foregroundStyle(T1.muted).lineLimit(1) }
            }
            .padding(.horizontal, 4)
            if !isSearch, oracle != nil, let current {
                CardBarButton(label: "Add to") { addTo(inView, current: current) } icon: { PlusIcon().fill(T1.text) }
            }
            CardBarButton(label: info ? "Card" : "Details") {
                info.toggle()
                if info { Telemetry.capture("card_info_opened", ["scope": scopeName]) }
            } icon: {
                if info { TuneIcon().fill(T1.text) } else { ListIcon().fill(T1.text) }
            }
        }
        .frame(height: 50)
        .background(T1.bg)
    }

    // MARK: the card

    @ViewBuilder private func cardArea(_ versions: [CardVersion], current: CardVersion) -> some View {
        GeometryReader { geo in
            if versions.count + (edition == nil ? 0 : 1) > 1 {
                let tile = ((min(geo.size.width - 64, 376 * geo.size.width / 440) - 1) / 2).rounded(.down)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.fixed(tile), spacing: 1), GridItem(.fixed(tile), spacing: 1)], spacing: 1) {
                        ForEach(versions) { v in versionTile(v, width: tile) }
                        if let edition { versionTile(edition, width: tile, key: Self.editionId) }
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            } else {
                let flips = (byId[current.cardId]?.imageFaces ?? 1) > 1
                let width = min(geo.size.width - 64, (geo.size.height - 32 - (flips ? 44 : 0)) * CardArt.aspect).rounded(.down)
                VStack(spacing: 0) {
                    if let p = byId[current.cardId] {
                        Button { zoom(p, finish: current.finish) } label: {
                            p.art(width: width, finish: current.finish, back: back).id("\(p.cardId)|\(back)")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(oracle?.name ?? "Card"), \(p.setLabel). Zoom")
                    }
                    if flips {
                        Button {
                            back.toggle()
                            Telemetry.capture("card_flipped")
                        } label: {
                            LabelText(back ? "Front" : "Flip", color: T1.text).frame(width: 120, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(maxHeight: .infinity)
        .background(T1.bg)
    }

    /// One grid tile. The new edition (`key` editionId) is dimmed: it isn't written until it differs.
    private func versionTile(_ v: CardVersion, width: CGFloat, key: String? = nil) -> some View {
        let id = key ?? v.id
        let on = id == selected
        let dim = key == Self.editionId
        let p = byId[v.cardId]
        return Button {
            selected = on ? nil : id
            if !on { Telemetry.capture("card_version_selected", ["versions": versions.count]) }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let p { p.art(width: width, finish: v.finish) } else { Rectangle().fill(T1.surface).frame(width: width, height: width / CardArt.aspect) }
                if dim { T1.bg.opacity(0.6) }
                if v.qty > 1 {
                    Text("\(v.qty)").font(T1.mono(13)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(T1.bg)
                        .padding(width * 0.05)
                }
            }
            .overlay { if on { Rectangle().stroke(T1.accent, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel([p?.setLabel, Finish(rawValue: v.finish)?.label, v.board.flatMap { lists.list(id: listId ?? "")?.boardTitle($0) },
                             listId == nil ? v.condition : nil, "\(v.qty)", dim ? "new, not added yet" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func zoom(_ p: CatalogPrinting, finish: String) {
        guard let url = CatalogPack.imageURL(cardId: p.cardId, imageTs: p.imageTs, size: "large", back: back && p.imageFaces > 1) else { return }
        let name = oracle?.name ?? "Card"
        Task {
            guard let image = await CardImageLoader.shared.image(url, maxPixel: 1400) else { return }
            ZoomImagePanel.present(title: name, subtitle: p.setLabel, image: image, screen: "card_detail")
        }
    }

    // MARK: Match collection (contract/owned-by-card-2026-10-31.md § 2)

    @ViewBuilder private func matchRow(_ list: CardList) -> some View {
        let owned = MatchCollection.versions(printings)
        let ids = Set(printings.map(\.cardId))
        if !MatchCollection.sections(list, ids: ids, versions: owned).isEmpty {
            HStack(spacing: 12) {
                LabelText(MatchCollection.detail(list, ids: ids, versions: owned))
                Spacer(minLength: 0)
                BarButton("Match collection") { MatchCollection.present(list: list, printings: printings) { l, u in report(l, u) } }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
        }
    }

    // MARK: undo strip

    @ViewBuilder private var status: some View {
        if let last {
            HStack(spacing: 12) {
                LabelText(last.label)
                Spacer(minLength: 0)
                BarButton(busy ? "Undoing…" : "Undo") { undo() }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
        } else if let notice {
            Notice(notice)
        }
    }

    // MARK: attributes

    private func attributes(_ shown: [CardVersion], owned: Bool) -> some View {
        let list = listId.flatMap { lists.list(id: $0) }
        let shared = { (f: (CardVersion) -> String) in CardDetailRules.shared(shown, f) }
        let set = shared(\.cardId)
        let printing = set.flatMap { byId[$0] }
        var cells: [(CardAttribute, String, Bool)] = [(.set, printing?.set.uppercased() ?? "Mix", true)]
        // A non-English printing's language is its own. Deck and cube lines record a language and condition, but the
        // card page opened from a deck or cube shows neither (John, 2026-11-01): they come from the copies added to it.
        if list == nil {
            cells.append((.language, shared(\.lang)?.uppercased() ?? "Mix", printing.map { $0.lang == "en" } ?? true))
            cells.append((.condition, shared(\.condition) ?? "Mix", true))
        }
        if CardDetailRules.showsFinish(shown, printings: byId) {
            let f = shared(\.finish)
            cells.append((.finish, f.map(Self.finishCode) ?? "Mix", printing.map { $0.finishList.count > 1 } ?? true))
        }
        if let list { cells.append((.section, shared { $0.board ?? "main" }.map { Self.sectionCode($0, list) } ?? "Mix", true)) }
        return HStack(spacing: 1) {
            ForEach(cells, id: \.0) { a, value, opens in
                Button { if opens && !busy { open(a, shown: shown, list: list) } } label: {
                    Text(value.uppercased()).font(T1.mono(12)).tracking(1.5).foregroundStyle(T1.muted).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(a.rawValue.capitalized): \(value)")
            }
        }
        .background(T1.bg)
    }

    static func finishCode(_ f: String) -> String {
        switch f { case "foil": "F"; case "etched": "E"; default: "NF" }
    }

    static func sectionCode(_ b: String, _ list: CardList) -> String {
        switch b { case "side": "Side"; case "maybe": "Maybe"; case "commander": "Cmdr"; default: "Main" }
    }

    /// Opens the picker for one attribute; the current value (when the copies agree) is outlined.
    private func open(_ a: CardAttribute, shown: [CardVersion], list: CardList?) {
        let current = { (f: (CardVersion) -> String) in CardDetailRules.shared(shown, f) }
        let done: (String) -> Void = { value in
            T1Overlays.shared.dismissPanel()
            pick(a, value)
        }
        let options: [SelectorOption]
        switch a {
        case .set:
            T1Overlays.shared.present {
                PrintingPickerPanel(printings: printings, current: current(\.cardId), pick: done)
            }
            return
        case .language:
            options = Languages.all.map { SelectorOption(value: $0.code, label: $0.name) }
        case .condition:
            options = Conditions.all.map { SelectorOption(value: $0, label: $0) }
        case .finish:
            let have = Set(shown.compactMap { byId[$0.cardId] }.flatMap(\.finishList))
            options = Finish.allCases.filter(have.contains).map { SelectorOption(value: $0.rawValue, label: $0.label) }
        case .section:
            guard let list else { return }
            let boards = list.kind == .deck ? ["main", "side", "maybe"] : ["main", "maybe"]
            let zone = list.boards.contains(CommandZone.board) || (list.kind == .deck && CommandZone.formats.contains(list.format))
            options = ((zone ? [CommandZone.board] : []) + boards).map { SelectorOption(value: $0, label: list.boardTitle($0)) }
        }
        let value: String? = switch a {
        case .language: current(\.lang)
        case .condition: current(\.condition)
        case .finish: current(\.finish)
        case .section: current { $0.board ?? "main" }
        case .set: nil
        }
        T1Overlays.shared.present {
            SelectorPanel(options: options, current: value, pick: done).screen("card_\(a.rawValue)_picker")
        }
    }

    /// A pick: changes the copies in view (asking first when more than one would change), or with nothing in view,
    /// the version on screen.
    private func pick(_ a: CardAttribute, _ value: String) {
        let versions = versions
        let printing = a == .set ? byId[value] : nil
        // The new edition: written as soon as it is a version the scope doesn't hold, until then just redrawn.
        if selected == Self.editionId, let e = edition {
            let to = CardDetailRules.repoint(e, a, to: value, printing: printing)
            if CardDetailRules.isNew(to, among: versions) { addEdition(to, attribute: a) } else { edition = to }
            return
        }
        let chosen = versions.first { $0.id == selected }
        let targets = chosen.map { [$0] } ?? versions
        guard !targets.isEmpty else {
            if let base = draft ?? fresh { draft = CardDetailRules.repoint(base, a, to: value, printing: printing) }
            return
        }
        let changing = targets.filter { CardDetailRules.repoint($0, a, to: value, printing: printing) != $0 }
        guard !changing.isEmpty else { return }
        let total = changing.reduce(0) { $0 + $1.qty }
        let what = Self.valueName(a, value, printing: printing, list: listId.flatMap { lists.list(id: $0) })
        func run(one: Bool) { apply(a, value, printing: printing, targets: changing, one: one, label: what, selectedVersion: chosen) }
        if changing.count > 1 {
            T1Overlays.shared.ask("Change all \(total) to \(what)?", message: "Every copy in view changes. Undo puts them back.",
                                  action: "Change all") { run(one: false) }
        } else if total > 1 {
            T1Overlays.shared.showMenu("Change to \(what)", [
                T1MenuItem(title: "One copy") { run(one: true) },
                T1MenuItem(title: "All \(total) copies") { run(one: false) },
            ])
        } else {
            run(one: false)
        }
    }

    static func valueName(_ a: CardAttribute, _ value: String, printing: CatalogPrinting?, list: CardList?) -> String {
        switch a {
        case .set: printing?.setLabel ?? value.uppercased()
        case .language: Languages.name(value)
        case .condition: value
        case .finish: Finish(rawValue: value)?.label ?? value
        case .section: list?.boardTitle(value) ?? value
        }
    }

    private func apply(_ a: CardAttribute, _ value: String, printing: CatalogPrinting?, targets: [CardVersion], one: Bool,
                       label: String, selectedVersion: CardVersion?) {
        let copies = one ? 1 : targets.reduce(0) { $0 + $1.qty }
        let props: [String: Any] = ["attribute": a.rawValue, "scope": scopeName, "copies": copies, "mix": targets.count > 1,
                                    "selected": selectedVersion != nil]
        let text = "Changed \(copies) to \(label)"
        if let listId {
            var undo: [() -> Void] = []
            for v in targets {
                let to = CardDetailRules.repoint(v, a, to: value, printing: printing)
                let board = v.board ?? "main", n = one ? 1 : v.qty
                if a == .section {
                    let toBoard = to.board ?? "main"
                    lists.add(listId: listId, cardId: v.cardId, board: board, finish: v.finish, lang: v.lang, cond: v.condition, delta: -n)
                    lists.add(listId: listId, cardId: v.cardId, board: toBoard, finish: v.finish, lang: v.lang, cond: v.condition, delta: n)
                    undo.append {
                        lists.add(listId: listId, cardId: v.cardId, board: toBoard, finish: v.finish, lang: v.lang, cond: v.condition, delta: -n)
                        lists.add(listId: listId, cardId: v.cardId, board: board, finish: v.finish, lang: v.lang, cond: v.condition, delta: n)
                    }
                } else {
                    lists.swap(listId: listId, cardId: v.cardId, board: board, finish: v.finish, lang: v.lang, cond: v.condition, toCardId: to.cardId,
                               toFinish: to.finish, toLang: to.lang, toCond: to.condition, qty: n)
                    undo.append { lists.swap(listId: listId, cardId: to.cardId, board: board, finish: to.finish, lang: to.lang, cond: to.condition,
                                             toCardId: v.cardId, toFinish: v.finish, toLang: v.lang, toCond: v.condition, qty: n) }
                }
                if selectedVersion != nil, !one || v.qty == 1 { selected = to.id }
            }
            Telemetry.capture("card_attribute_changed", props)
            report(text, CardUndo(label: text) { undo.forEach { $0() } })
            return
        }
        var ops: [CollectionOp] = []
        var moved: [CardVersion] = []
        for v in targets {
            guard let item = col.items[v.itemKey] else { continue }
            let to = CardDetailRules.repoint(v, a, to: value, printing: printing)
            let places = PrintingChange.places(item).map { (place: $0.place, qty: $0.qty) }
            if let o = CardDetailRules.ops(item, places: places, to: to, qty: one ? 1 : v.qty, from: binderId) {
                ops += o
                moved.append(to)
            }
        }
        guard !ops.isEmpty else { return }
        if let selectedVersion, let to = moved.first, !one || selectedVersion.qty == 1 { selected = to.id }
        write(ops, label: text) { Telemetry.capture("card_attribute_changed", props) }
    }

    // MARK: stepper

    /// − count + for the copies in view: the selected version's when one is (the new edition's before it's written),
    /// else the one held most of. A long press on + starts a new edition of that version.
    private func stepper(_ versions: [CardVersion], chosen: CardVersion?, inView: [CardVersion], current: CardVersion) -> some View {
        let count = inView.reduce(0) { $0 + $1.qty }
        let onEdition = selected == Self.editionId && edition != nil
        let target = chosen ?? CardDetailRules.main(versions) ?? current
        let canStart = !versions.isEmpty && edition == nil && !busy
        return HStack(spacing: 1) {
            StepCell(label: "Remove one", enabled: !busy && count > 0) { onEdition ? stepEdition(-1) : step(target, -1) } content: {
                MinusIcon().fill(count > 0 ? T1.text : T1.disabled).frame(width: 18, height: 18)
            }
            Text("\(count)").font(T1.mono(15, .semibold)).tracking(4).monospacedDigit()
                .foregroundStyle(T1.text)
                .frame(height: 18).padding(.top, 24)
                .frame(maxWidth: .infinity).frame(height: 54, alignment: .top)
                .background(T1.surface.ignoresSafeArea(edges: .bottom))
                .accessibilityLabel("\(count) copies")
            StepCell(label: "Add one", enabled: !busy, longPress: canStart ? { startEdition(target) } : nil,
                     longPressLabel: "Add a different version") { onEdition ? stepEdition(1) : step(target, 1) } content: {
                PlusIcon().fill(T1.text).frame(width: 18, height: 18)
            }
        }
    }

    // MARK: new edition

    /// Long press on +: a copy of `v` to change into another version, selected and dimmed until it differs.
    private func startEdition(_ v: CardVersion) {
        edition = CardDetailRules.newEdition(from: v)
        selected = Self.editionId
        last = nil
        notice = listId == nil ? "Change its set, language, condition or finish to add it." : "Change its set, finish or section to add it."
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Telemetry.capture("card_edition_started", ["scope": scopeName, "versions": versions.count])
    }

    /// The stepper on an unwritten edition only changes how many it will add; at 0 it's gone.
    private func stepEdition(_ delta: Int) {
        guard var e = edition else { return }
        e.qty += delta
        if e.qty > 0 { edition = e; return }
        edition = nil
        selected = nil
        notice = nil
    }

    /// The edition now differs from every version in view: add its copies (into the binder or the line's section in
    /// those scopes) and select the version it became.
    private func addEdition(_ v: CardVersion, attribute: CardAttribute) {
        edition = nil
        selected = v.id
        notice = nil
        let text = "Added \(v.qty) \(versionName(v))"
        let props: [String: Any] = ["scope": scopeName, "attribute": attribute.rawValue, "copies": v.qty]
        if let listId {
            let board = v.board ?? "main"
            lists.add(listId: listId, cardId: v.cardId, board: board, finish: v.finish, lang: v.lang, cond: v.condition, delta: v.qty)
            Telemetry.capture("card_edition_added", props)
            report(text, CardUndo(label: text) { lists.add(listId: listId, cardId: v.cardId, board: board, finish: v.finish, lang: v.lang, cond: v.condition, delta: -v.qty) })
            return
        }
        write([CardDetailRules.step(v, delta: v.qty, binderId: binderId)], label: text) {
            Telemetry.capture("card_edition_added", props)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// "MH2 · Foil · LP": what sets a version apart, for the Undo strip.
    private func versionName(_ v: CardVersion) -> String {
        let list = listId.flatMap { lists.list(id: $0) }
        var parts = [byId[v.cardId]?.setLabel ?? oracle?.name ?? "card"]
        if v.finish != Finish.nonfoil.rawValue { parts.append(Finish(rawValue: v.finish)?.label ?? v.finish) }
        if let list {
            if let b = v.board, b != "main" { parts.append(list.boardTitle(b)) }
        } else if v.condition != "NM" {
            parts.append(v.condition)
        }
        if v.lang != "en", byId[v.cardId]?.lang == "en" { parts.append(Languages.name(v.lang)) }
        return parts.joined(separator: " · ")
    }

    private func step(_ v: CardVersion, _ delta: Int) {
        let name = byId[v.cardId]?.setLabel ?? oracle?.name ?? "card"
        let text = delta > 0 ? "Added 1 \(name)" : "Removed 1 \(name)"
        let props: [String: Any] = ["scope": scopeName, "delta": delta]
        // At 0 the screen keeps this version, so + puts it back.
        if delta < 0 && v.qty <= 1 { draft = CardVersion(cardId: v.cardId, finish: v.finish, condition: v.condition, lang: v.lang, board: v.board) }
        if let listId {
            let board = v.board ?? "main"
            lists.add(listId: listId, cardId: v.cardId, board: board, finish: v.finish, lang: v.lang, cond: v.condition, delta: delta)
            Telemetry.capture("card_stepped", props)
            report(text, CardUndo(label: text) { lists.add(listId: listId, cardId: v.cardId, board: board, finish: v.finish, lang: v.lang, cond: v.condition, delta: -delta) })
            return
        }
        write([CardDetailRules.step(v, delta: delta, binderId: binderId)], label: text) {
            Telemetry.capture("card_stepped", props)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: writing

    private func write(_ ops: [CollectionOp], label: String, then: @escaping () -> Void = {}) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let res = try await col.apply(ops)
                then()
                report(label, CardUndo(label: label) { _ = try await CollectionStore.shared.undo(batchId: res.batchId) })
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// What the last change did, with its Undo (nil: a notice only).
    private func report(_ label: String, _ undo: CardUndo?) {
        error = nil
        if let undo { last = undo; notice = nil } else { last = nil; notice = label }
    }

    private func undo() {
        guard let last, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await last.run()
                self.last = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: add to

    /// The bar's +: asks one copy or all of them first when more than one is in view (the selected version's copies when
    /// one is selected).
    private func addTo(_ inView: [CardVersion], current: CardVersion) {
        let total = inView.reduce(0) { $0 + $1.qty }
        guard total > 1 else { openAddTo(CardDetailRules.addLines(inView, current: current, all: false)); return }
        T1Overlays.shared.showMenu("Add to", message: selected == nil ? nil : "This version only", [
            T1MenuItem(title: "One copy") { openAddTo(CardDetailRules.addLines(inView, current: current, all: false)) },
            T1MenuItem(title: "All \(total) copies") { openAddTo(CardDetailRules.addLines(inView, current: current, all: true)) },
        ])
    }

    private func openAddTo(_ lines: [CardVersion]) {
        guard let oracle, !lines.isEmpty else { return }
        T1Overlays.shared.present {
            AddToPanel(oracle: oracle, printings: byId, lines: lines, scope: scopeName, path: path) { label, undo in
                report(label, undo)
            }
            .screen("card_add_to")
        }
    }
}

/// An Undo for the strip: a collection batch, or the reverse list edits.
struct CardUndo {
    let label: String
    let run: () async throws -> Void
}

// MARK: pieces

/// A 50 × 50 icon button in card detail's bar (Figma Bar: back, +, list / tune).
private struct CardBarButton<Icon: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder let icon: Icon
    var body: some View {
        Button(action: action) {
            icon.frame(width: 18, height: 18).frame(width: 50, height: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One third of the stepper: 88 pt in Figma including the home indicator, the glyph 24 pt from the top.
private struct StepCell<Content: View>: View {
    let label: String
    let enabled: Bool
    /// A long press's action (+ starts a new edition); nil: taps only.
    var longPress: (() -> Void)?
    var longPressLabel = ""
    let action: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        // Not .disabled: that dims the label, and disabled is drawn as the flat disabled color (design rule).
        // Gestures rather than a Button, so a held press doesn't also count as a tap.
        content.frame(height: 18).padding(.top, 24)
            .frame(maxWidth: .infinity).frame(height: 54, alignment: .top)
            .background(T1.surface.ignoresSafeArea(edges: .bottom))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .onLongPressGesture(minimumDuration: 0.45) { if enabled { (longPress ?? action)() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(enabled ? .isButton : .isStaticText)
            .accessibilityAction { if enabled { action() } }
            .accessibilityActions {
                if let longPress, enabled { Button(longPressLabel, action: longPress) }
            }
    }
}

/// The full-width bottom button (Figma "Add to"): surface fill, wide-tracked label.
struct BigBarButton: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text.uppercased()).font(T1.mono(15, .semibold)).tracking(4).foregroundStyle(T1.text)
                .frame(height: 18).padding(.top, 24)
                .frame(maxWidth: .infinity).frame(height: 54, alignment: .top)
                .background(T1.surface.ignoresSafeArea(edges: .bottom))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: pickers (Figma Selector)

struct SelectorOption: Identifiable {
    let value: String
    let label: String
    var detail: String?
    var id: String { value }
}

/// Selector rows: centred uppercase labels; pressed rows fill with surface; the current value is outlined in accent.
struct SelectorRows: View {
    let options: [SelectorOption]
    let current: String?
    let pick: (String) -> Void
    var body: some View {
        ForEach(options) { o in
            let on = o.value == current
            Button { pick(o.value) } label: {
                VStack(spacing: 2) {
                    Text(o.label.uppercased()).font(T1.mono(12)).tracking(1.5).foregroundStyle(on ? T1.text : T1.muted).lineLimit(1)
                    if let d = o.detail { Text(d.uppercased()).font(T1.mono(8)).tracking(1.5).foregroundStyle(T1.disabled).lineLimit(1) }
                }
                .frame(maxWidth: .infinity).frame(height: o.detail == nil ? 50 : 62)
                .overlay { if on { Rectangle().stroke(T1.accent, lineWidth: 1) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(SelectorPress())
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

private struct SelectorPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? T1.surface : Color.clear)
    }
}

/// A bottom panel of Selector rows, scrolling when there are many (languages).
struct SelectorPanel: View {
    var title: String?
    var back: (() -> Void)?
    let options: [SelectorOption]
    let current: String?
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || back != nil { DrillHeader(title: title ?? "", back: back) }
            let rows = options.reduce(0) { $0 + ($1.detail == nil ? 50 : 62) }
            ScrollView {
                VStack(spacing: 0) { SelectorRows(options: options, current: current, pick: pick) }
            }
            .frame(height: CGFloat(min(rows, 400)))
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(16)
        .background(T1.bg)
    }
}

/// "← DECK": the step a drilldown is on, with the way back.
struct DrillHeader: View {
    let title: String
    var back: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            if let back {
                Button(action: back) { BackArrow().fill(T1.text).frame(width: 18, height: 18).padding(8).contentShape(Rectangle()) }
                    .buttonStyle(.plain).padding(-8)
                    .accessibilityLabel("Back")
            }
            Text(title.uppercased()).font(T1.mono(12)).tracking(1.5).foregroundStyle(T1.muted)
        }
        .frame(height: 18)
    }
}

/// Every printing, four per row, earliest first; the current one outlined.
struct PrintingPickerPanel: View {
    let printings: [CatalogPrinting]
    let current: String?
    let pick: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = ((geo.size.width - 5) / 4).rounded(.down)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: 1), count: 4), spacing: 1) {
                    ForEach(printings, id: \.cardId) { p in
                        let on = p.cardId == current
                        Button { pick(p.cardId) } label: {
                            p.art(width: w)
                                .overlay { if on { Rectangle().stroke(T1.accent, lineWidth: 1) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(p.setLabel)\(p.lang == "en" ? "" : ", \(Languages.name(p.lang))")")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(1)
            }
        }
        .frame(height: min(490, CGFloat((printings.count + 3) / 4) * 156 + 2))
        .background(T1.bg)
        .screen("card_printing_picker")
    }
}

// MARK: icons (Material, weight 300, from the Figma bar and stepper)

struct ListIcon: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 18
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: r.minX + x * s, y: r.minY + y * s, width: w * s, height: h * s) }
        var p = Path()
        for y in [5.668, 8.4375, 11.207] {
            p.addRect(rect(5.495, y, 9.88, 1.125))
            p.addEllipse(in: rect(2.625, y - 0.043, 1.212, 1.212))
        }
        return p
    }
}

struct TuneIcon: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 18
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: r.minX + (2.4375 + x) * s, y: r.minY + (2.4375 + y) * s, width: w * s, height: h * s)
        }
        var p = Path()
        // Three sliders: a line each side of a knob.
        p.addRect(rect(0, 1.5, 7.125, 1.125)); p.addRect(rect(9, 0, 1.125, 4.125)); p.addRect(rect(10.125, 1.5, 3, 1.125))
        p.addRect(rect(0, 6, 3, 1.125)); p.addRect(rect(3, 4.5, 1.125, 4.125)); p.addRect(rect(6, 6, 7.125, 1.125))
        p.addRect(rect(0, 10.5, 4.125, 1.125)); p.addRect(rect(6, 9, 1.125, 4.125)); p.addRect(rect(7.125, 10.5, 6, 1.125))
        return p
    }
}

struct PlusIcon: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 18
        var p = Path()
        p.addRect(CGRect(x: r.minX + 4.125 * s, y: r.minY + 8.4375 * s, width: 9.75 * s, height: 1.125 * s))
        p.addRect(CGRect(x: r.minX + 8.4375 * s, y: r.minY + 4.125 * s, width: 1.125 * s, height: 9.75 * s))
        return p
    }
}

struct MinusIcon: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 18
        return Path(CGRect(x: r.minX + 4.125 * s, y: r.minY + 8.4375 * s, width: 9.75 * s, height: 1.125 * s))
    }
}
