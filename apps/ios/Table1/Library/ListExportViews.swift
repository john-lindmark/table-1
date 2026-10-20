import SwiftUI
import UIKit

/* Export for a deck or cube (contract/lists-2026-10-15.md, Export): the list as text first, in the format picked
   above it, then the ways out: to Arena (copied: Arena imports from the clipboard) and MTGO (a .txt file) for decks,
   to Cube Cobra (a CSV file) for cubes, and Download / Copy of the text shown. Your own lists and decks or cubes
   shared with you on a profile use the same screen. */

struct ListExportPanel: View {
    let name: String
    let kind: CardList.Kind
    let entries: [CardList.Entry]
    /// Telemetry: own / profile.
    let from: String
    private var catalog: CatalogStore { CatalogStore.shared }
    @State var format: ListExport.Format = .text
    @State private var texts: [ListExport.Format: String] = [:]
    @State private var cards = 0
    @State private var left = 0
    @State private var share: ShareFile?
    @State private var note: String?
    @State private var error: String?

    private var formats: [ListExport.Format] { [.text] + ListExport.Format.formats(kind).filter { $0 != .text } }

    var body: some View {
        T1Screen {
            Bar(title: "Export", subtitle: name, back: { T1Overlays.shared.dismissPanel() })
            T1Segmented(options: formats.map { ($0, $0.short) }, selection: $format)
            Notice(format.detail)
            ScrollView([.vertical]) {
                Text(texts[format] ?? (catalog.db == nil ? "Waiting for the card data…" : ""))
                    .font(T1.mono(13)).lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: .infinity)
            .background(T1.surface)
            if let error { Notice(error, error: true) }
            if let n = note ?? ListExport.leftOutNote(left) { Notice(n) }
            HStack(spacing: 1) {
                if kind == .deck {
                    Ghost(text: "To Arena", accent: true) { copy(.arena, note: "Copied for MTG Arena. In Arena: Decks → Import.") }
                    Ghost(text: "To MTGO", accent: true) { download(.mtgo) }
                } else {
                    Ghost(text: "To Cube Cobra", accent: true) { download(.cubecobra) }
                }
            }
            HStack(spacing: 1) {
                Ghost(text: "Download .\(format.fileExtension ?? "txt")") { download(format) }
                Ghost(text: "Copy text") { copy(format, note: "Copied.") }
            }
            .padding(.bottom, 1)
        }
        .disabled(texts.isEmpty)
        .sheet(item: $share) { ShareSheet(share: $0).ignoresSafeArea() }
        .task(id: catalog.generation) {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let (entries, kind, formats) = (entries, kind, formats)
            let r = await Task.detached(priority: .userInitiated) { () -> ([ListExport.Format: String], Int, Int) in
                let r = ListExport.lines(entries, db)
                var out: [ListExport.Format: String] = [:]
                for f in formats { out[f] = ListExport.render(r.lines, kind: kind, format: f) }
                return (out, r.lines.reduce(0) { $0 + $1.qty }, r.left)
            }.value
            (texts, cards, left) = r
        }
        .onChange(of: format) { note = nil }
    }

    private func copy(_ f: ListExport.Format, note: String) {
        guard let text = texts[f] else { return }
        UIPasteboard.general.string = text
        self.note = note
        sent(f, "copy")
    }

    /// A file (.txt, or .csv for Cube Cobra) to the share sheet: Save to Files, AirDrop, or another app.
    private func download(_ f: ListExport.Format) {
        guard let text = texts[f] else { return }
        do {
            share = ShareFile(url: try ListExport.file(text, name: name, kind: kind, format: f))
            note = nil
            error = nil
            sent(f, "download")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sent(_ f: ListExport.Format, _ how: String) {
        Telemetry.capture("list_exported", ["kind": kind.rawValue, "format": f.rawValue, "cards": cards, "left": left, "from": from, "how": how])
    }
}

extension ListExport.Format {
    /// The picker's label.
    var short: String {
        switch self {
        case .arena: "Arena"
        case .moxfield: "Moxfield"
        case .mtgo: "MTGO"
        case .text: "Text"
        case .cubecobra: "Cube Cobra"
        }
    }
}
