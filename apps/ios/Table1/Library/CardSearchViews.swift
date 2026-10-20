import SwiftUI

/* The search row every Add cards screen shares: the box (a name, or Scryfall syntax), Advanced (the form that writes
   the syntax) and Scan (the camera, when the screen can take scanned cards). */

struct CardSearchBar: View {
    @Binding var query: String
    var prompt = "Name, or Scryfall syntax"
    /// Shown when the screen takes scanned cards.
    var scan: (() -> Void)?
    var focused: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?

    var body: some View {
        HStack(spacing: 1) {
            field
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                T1Overlays.shared.present(full: true) {
                    AdvancedSearchPanel(start: query) { query = $0 }.screen("advanced_search")
                }
            } label: { side("Adv") }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced search")
            if let scan { Button(action: scan) { side("Scan") }.buttonStyle(.plain) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var field: some View {
        if let focused {
            T1SearchField(text: $query, prompt: prompt).focused(focused).onSubmit { onSubmit?() }
        } else {
            T1SearchField(text: $query, prompt: prompt).onSubmit { onSubmit?() }
        }
    }

    private func side(_ text: String) -> some View {
        LabelText(text, color: T1.text).padding(.horizontal, 14).frame(maxHeight: .infinity).background(T1.surface)
    }
}

/// A line under the search box saying what an advanced search found, and where.
struct CardSearchStatus: View {
    let query: String
    let result: CardSearchEngine.Result?
    var body: some View {
        if let r = result, CardQuery.hasSyntax(query) {
            if let e = r.error {
                Notice(e, error: true)
            } else {
                let shown = r.hits.count < r.total ? "\(r.hits.count) of \(r.total.formatted())" : r.total.formatted()
                LabelText("\(shown) card\(r.total == 1 ? "" : "s")\(r.remote ? " · from Scryfall" : "")")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(T1.surface)
            }
        }
    }
}

/// Scryfall's advanced search, kept to what players filter by. The fields are written as syntax into the search
/// box, so the search can be edited there afterwards.
struct AdvancedSearchPanel: View {
    let start: String
    let apply: (String) -> Void
    @State private var f = AdvancedSearchFields()

    private static let formats: [(String, String)] = [("", "Any"), ("standard", "Standard"), ("pioneer", "Pioneer"),
        ("modern", "Modern"), ("legacy", "Legacy"), ("vintage", "Vintage"), ("pauper", "Pauper"), ("commander", "Commander"),
        ("premodern", "Premodern")]

    var body: some View {
        T1Screen {
            Bar(title: "Advanced search", subtitle: "Scryfall syntax", back: { T1Overlays.shared.dismissPanel() }) {
                BarButton("Clear") { f = AdvancedSearchFields() }
            }
            ScrollView {
                VStack(spacing: 1) {
                    Field(label: "Card name", text: $f.name)
                    Field(label: "Text · needs a connection", text: $f.text)
                    Field(label: "Type line · e.g. legendary creature", text: $f.type)
                    Section1("Colors")
                    toggles(["W", "U", "B", "R", "G", "C"], selected: $f.colors)
                    if !f.colors.isEmpty && !f.colors.contains("C") {
                        T1Segmented(options: [("exactly", "Exactly"), ("including", "Including"), ("atMost", "At most")],
                                    selection: Binding(get: { f.colorMode.rawValue },
                                                       set: { f.colorMode = AdvancedSearchFields.ColorMode(rawValue: $0) ?? .including }))
                    }
                    Section1("Mana value")
                    HStack(spacing: 1) {
                        T1Segmented(options: [("=", "="), ("<", "<"), ("<=", "≤"), (">", ">"), (">=", "≥")], selection: $f.mvOp)
                        TextField("", text: $f.mv, prompt: Text("3").foregroundStyle(T1.muted))
                            .font(T1.mono(15)).tint(T1.accent).keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 64).frame(maxHeight: .infinity).background(T1.surface)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Section1("Rarity")
                    toggles(["c", "u", "r", "m"], selected: $f.rarities, label: { ["c": "Common", "u": "Uncommon", "r": "Rare", "m": "Mythic"][$0] ?? $0 })
                    Field(label: "Set code · e.g. mh3", text: $f.set, url: true)
                    Section1("Legal in")
                    T1Segmented(options: Array(Self.formats.prefix(5)), selection: $f.format)
                    T1Segmented(options: Array(Self.formats.dropFirst(5)), selection: $f.format)
                    let q = f.query
                    Notice(q.isEmpty ? "Fill any field. Everything but card text searches the card data on this phone." : q)
                }
            }
            BigAction(text: "Search", enabled: !f.query.isEmpty) {
                let q = f.query
                Telemetry.capture("advanced_search_used", ["text": !f.text.isEmpty, "colors": f.colors.count, "mv": !f.mv.isEmpty,
                                                          "rarity": f.rarities.count, "set": !f.set.isEmpty, "format": f.format])
                T1Overlays.shared.dismissPanel()
                apply(q)
            }
        }
        .onAppear { if !CardQuery.hasSyntax(start) { f.name = start } }
    }

    private func toggles(_ keys: [Character], selected: Binding<Set<Character>>, label: @escaping (String) -> String = { $0 }) -> some View {
        HStack(spacing: 1) {
            ForEach(keys, id: \.self) { k in
                let on = selected.wrappedValue.contains(k)
                Button {
                    var s = selected.wrappedValue
                    if on { s.remove(k) } else {
                        // Colorless and colors don't mix.
                        if k == "C" { s = [] } else { s.remove("C") }
                        s.insert(k)
                    }
                    selected.wrappedValue = s
                } label: {
                    LabelText(label(String(k)), color: on ? T1.ink : T1.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(on ? T1.text : T1.surface)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
