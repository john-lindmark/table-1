import SwiftUI

/* Card language (contract/card-language-2026-10-19.md). Every owned copy, binder copy and trade line has a language
   (Scryfall's codes); it can be changed wherever such a copy shows. Changing owned copies moves them to the new
   language in the same places (binders, Unsorted), as one undoable batch. Deck and cube lines and wants have no
   language of their own: a line's language is its printing's (Change printing lists every language's printings). */

enum Languages {
    /// Scryfall's language codes: the eleven most printed first, then the rest.
    static let all: [(code: String, name: String)] = [
        ("en", "English"), ("de", "German"), ("fr", "French"), ("it", "Italian"), ("es", "Spanish"), ("pt", "Portuguese"),
        ("ja", "Japanese"), ("ko", "Korean"), ("ru", "Russian"), ("zhs", "Chinese Simplified"), ("zht", "Chinese Traditional"),
        ("he", "Hebrew"), ("la", "Latin"), ("grc", "Ancient Greek"), ("ar", "Arabic"), ("sa", "Sanskrit"), ("ph", "Phyrexian"),
        ("qya", "Quenya"),
    ]
    static let common = 11

    static func name(_ code: String) -> String { all.first { $0.code == code }?.name ?? code.uppercased() }

    /// The language new copies go in as: a non-English printing is in its own language; otherwise the one picked for adds.
    static func forNew(_ p: CatalogPrinting, picked: String) -> String { p.lang != "en" ? p.lang : picked }

    /// The language a scanned copy goes in as: a non-English printing's own; else the one the card's text says
    /// (`read`: the code by its set code, or the languages of the printed name read; the one picked for adds when
    /// that's one of them, a name several languages print alike); else the one picked. Empty `read` doesn't tell.
    static func forScan(_ p: CatalogPrinting, read: [String], picked: String) -> String {
        if p.lang != "en" { return p.lang }
        return read.isEmpty || read.contains(picked) ? picked : read[0]
    }
}

enum LanguageChange {
    /// Moves `qty` copies of an item to another language, each copy staying where it is: from `from` when given (a binder
    /// id or `BinderRoute.unsorted`), else Unsorted first, then binders in the order given. Nil when nothing would change.
    static func ops(_ item: CollectionItem, places: [(place: String, qty: Int)], to lang: String, qty: Int,
                    from: String? = nil) -> [CollectionOp]? {
        guard lang != item.lang, qty > 0, qty <= item.qty else { return nil }
        let order = from.map { f in places.filter { $0.place == f } }
            ?? (places.filter { $0.place == BinderRoute.unsorted } + places.filter { $0.place != BinderRoute.unsorted })
        var left = qty
        var ops: [CollectionOp] = []
        for p in order where left > 0 {
            let n = min(left, p.qty)
            guard n > 0 else { continue }
            let binderId = p.place == BinderRoute.unsorted ? nil : p.place
            ops.append(CollectionOp(cardId: item.cardId, finish: item.finish, condition: item.condition, lang: item.lang, delta: -n, binderId: binderId))
            ops.append(CollectionOp(cardId: item.cardId, finish: item.finish, condition: item.condition, lang: lang, delta: n, binderId: binderId))
            left -= n
        }
        return left == 0 ? ops : nil
    }

    /// Changes owned copies' language in place, asking "one copy or all" when there are several, and reports the
    /// batch for Undo.
    @MainActor
    static func start(_ item: CollectionItem, label: String, from: String? = nil, done: @escaping (Result<(String, String), Error>) -> Void) {
        LanguagePicker.present(current: item.lang, subtitle: label) { lang in
            let places = PrintingChange.places(item).map { (place: $0.place, qty: $0.qty) }
            let here = from.map { f in places.first { $0.place == f }?.qty ?? 0 } ?? item.qty
            func run(_ n: Int) {
                guard let ops = ops(item, places: places, to: lang, qty: n, from: from) else { return }
                Task {
                    do {
                        let res = try await CollectionStore.shared.apply(ops)
                        Telemetry.capture("language_changed", ["where": "owned", "copies": n])
                        done(.success((res.batchId, "Moved \(n) \(label) to \(Languages.name(lang))")))
                    } catch { done(.failure(error)) }
                }
            }
            if here <= 1 { run(1); return }
            T1Overlays.shared.showMenu("Mark as \(Languages.name(lang))", [
                T1MenuItem(title: "One copy") { run(1) },
                T1MenuItem(title: "All \(here) copies") { run(here) },
            ])
        }
    }
}

/// Every language, current one marked; picking closes it.
struct LanguagePicker: View {
    let current: String
    var subtitle: String?
    let pick: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        T1Screen {
            Bar(title: "Language", subtitle: subtitle, back: cancel)
            HairlineList {
                ForEach(Array(Languages.all.enumerated()), id: \.element.code) { i, l in
                    if i == Languages.common { Section1("Other") }
                    Button { pick(l.code) } label: {
                        ListRow(title: l.name, detail: l.code.uppercased()) {
                            if l.code == current { LabelText("Selected", color: T1.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(l.code == current ? .isSelected : [])
                }
            }
        }
    }

    /// As a full-screen panel over whatever is showing.
    @MainActor
    static func present(current: String, subtitle: String? = nil, pick: @escaping (String) -> Void) {
        T1Overlays.shared.present(full: true) {
            LanguagePicker(current: current, subtitle: subtitle, pick: { lang in
                T1Overlays.shared.dismissPanel()
                if lang != current { pick(lang) }
            }, cancel: { T1Overlays.shared.dismissPanel() })
            .screen("language_picker")
        }
    }
}

/// "Language · English" with Change: what a copy is in, and the way to change it.
struct LanguageRow: View {
    let lang: String
    var title = "Language"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ListRow(title: "\(title) · \(Languages.name(lang))") { LabelText("Change", color: T1.text) }
        }.buttonStyle(.plain)
    }
}
