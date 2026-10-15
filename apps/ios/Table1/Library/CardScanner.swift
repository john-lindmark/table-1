import SwiftUI
import VisionKit

/* Card scanning (camera). On-device only: VisionKit reads the text on the card, the name is matched against the
   local catalog pack, and the set code / collector number printed at the bottom picks the printing. A card is
   accepted once the same name has held steady across frames; it isn't taken again until it leaves the frame.
   The Scryfall API is never called per frame. */

/// One card the scanner accepted.
struct ScannedCard: Identifiable, Hashable {
    let id = UUID()
    let oracle: CatalogOracle
    var printing: CatalogPrinting
    var finish: String
    var condition: String
    /// Read from the card's set code and collector number, not a fallback to the default printing.
    let exact: Bool
}

/// Turns OCR lines into a card. Remembers every lookup, so a steady frame costs no database work.
final class CardMatcher {
    let db: CatalogDB
    /// Owned-only mode (trades: what you give): printing id → finishes owned.
    let owned: [String: Set<String>]?
    private var byNorm: [String: CatalogOracle?] = [:]
    private var printingsByOracle: [Int: [CatalogPrinting]] = [:]

    init(db: CatalogDB, owned: [String: Set<String>]?) {
        self.db = db
        self.owned = owned
    }

    func match(_ lines: [String]) -> (oracle: CatalogOracle, printing: CatalogPrinting, exact: Bool)? {
        // The name is the line that is a card name; OCR often adds a stray mana symbol or two at the end.
        var found: CatalogOracle?
        for line in lines.prefix(12) {
            let words = CardName.norm(line).split(separator: " ")
            guard (1...12).contains(words.count) else { continue }
            for drop in 0...min(2, words.count - 1) {
                let q = words.dropLast(drop).joined(separator: " ")
                guard q.count >= 3 else { continue }
                if let o = lookup(q), allowed(o) { found = o; break }
            }
            if found != nil { break }
        }
        guard let o = found else { return nil }
        let printings = printings(o)
        guard !printings.isEmpty else { return nil }

        // Bottom-of-card text: "0123/280 R", "R 0123", "MH3 • EN".
        var tokens = Set<String>()
        var numbers = Set<String>()
        for line in lines {
            for raw in line.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let t = String(raw)
                if t.allSatisfy(\.isNumber), t.count <= 4 { numbers.insert(String(Int(t) ?? 0)) }
                else if (2...5).contains(t.count) { tokens.insert(t.lowercased()) }
            }
        }
        func score(_ p: CatalogPrinting) -> Int {
            let cn = p.cn.trimmingCharacters(in: .letters)
            return (tokens.contains(p.set) ? 2 : 0) + (numbers.contains(String(Int(cn) ?? -1)) ? 1 : 0)
        }
        let best = printings.max { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa < sb : rank(a) > rank(b)
        } ?? printings[0]
        return (o, best, score(best) >= 2)
    }

    /// The finish a scanned copy starts as: what you own of it in owned-only mode, else non-foil when printed.
    func defaultFinish(_ p: CatalogPrinting) -> String {
        if let have = owned?[p.cardId], let f = Finish.allCases.first(where: { have.contains($0.rawValue) }) { return f.rawValue }
        return (p.finishList.first ?? .nonfoil).rawValue
    }

    private func lookup(_ q: String) -> CatalogOracle? {
        if let hit = byNorm[q] { return hit }
        let o = db.oracle(nameNorm: q)
        byNorm[q] = o
        return o
    }

    private func printings(_ o: CatalogOracle) -> [CatalogPrinting] {
        if let p = printingsByOracle[o.idx] { return p }
        var p = db.printings(oracleIdx: o.idx)
        if let owned { p = p.filter { owned[$0.cardId] != nil } }
        printingsByOracle[o.idx] = p
        return p
    }

    private func allowed(_ o: CatalogOracle) -> Bool { owned == nil || !printings(o).isEmpty }

    /// Tie-break (lower first): the default printing, then newest.
    private func rank(_ p: CatalogPrinting) -> Int { (p.original ? 0 : 1_000_000) + p.ord }
}

/// Live camera text reader. Calls `onLines` with the text it sees, top of the frame first, on every change.
struct CardTextScanner: UIViewControllerRepresentable {
    let onLines: ([String]) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: false
        )
        try? scanner.startScanning()
        context.coordinator.watch(scanner)
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onLines = onLines
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.task?.cancel()
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLines: onLines) }

    @MainActor
    final class Coordinator {
        var onLines: ([String]) -> Void
        var task: Task<Void, Never>?
        init(onLines: @escaping ([String]) -> Void) { self.onLines = onLines }

        func watch(_ scanner: DataScannerViewController) {
            task = Task { [weak self] in
                for await items in scanner.recognizedItems {
                    let lines: [(y: CGFloat, text: String)] = items.compactMap {
                        if case let .text(t) = $0 { return (t.bounds.topLeft.y, t.transcript) }
                        return nil
                    }
                    let sorted = lines.sorted { $0.y < $1.y }.flatMap { $0.text.split(separator: "\n").map(String.init) }
                    self?.onLines(sorted)
                }
            }
        }
    }
}

/// Holds a candidate until it's steady, and keeps a card from being taken twice while it stays in frame.
struct ScanSteadiness {
    private var candidate: (idx: Int, since: Date, best: (CatalogPrinting, Bool))?
    private var lastAccepted: (idx: Int, seen: Date)?

    /// Feed every frame's match (or nil). Returns the printing once a card should be taken.
    mutating func feed(_ m: (oracle: CatalogOracle, printing: CatalogPrinting, exact: Bool)?, at now: Date = .now)
        -> (CatalogPrinting, Bool)? {
        guard let m else {
            candidate = nil
            return nil
        }
        if let last = lastAccepted, last.idx == m.oracle.idx {
            // Still the card just taken; it has to leave the frame for a second before it counts again.
            if now.timeIntervalSince(last.seen) < 1.0 { lastAccepted = (last.idx, now); return nil }
        }
        if candidate?.idx != m.oracle.idx {
            candidate = (m.oracle.idx, now, (m.printing, m.exact))
            return nil
        }
        if m.exact { candidate?.best = (m.printing, true) }
        guard let c = candidate else { return nil }
        let held = now.timeIntervalSince(c.since)
        // Take it quickly once the printing is read; give the small print a little longer otherwise.
        if (c.best.1 && held >= 0.4) || held >= 1.2 {
            candidate = nil
            lastAccepted = (m.oracle.idx, now)
            return c.best
        }
        return nil
    }
}

/// Full-screen scanner used by Add cards and Trades. Collects cards until Done; nothing is written here.
struct CardScanView: View {
    let title: String
    let doneLabel: String
    /// Owned-only matching (cards you give in a trade): printing id → finishes owned.
    var owned: [String: Set<String>]?
    let onDone: ([ScannedCard]) -> Void
    let onCancel: () -> Void

    @AppStorage("library.addCondition") private var condition = "NM"
    @State private var cards: [ScannedCard] = []
    @State private var matcher: CardMatcher?
    @State private var steady = ScanSteadiness()
    @State private var reading: String?
    private var catalog: CatalogStore { CatalogStore.shared }

    var body: some View {
        T1Screen {
            Bar(title: title, subtitle: cards.isEmpty ? (owned == nil ? "Hold a card flat in the frame" : "Matching cards you own")
                                                      : "\(count) scanned", back: onCancel)
            if !CardTextScanner.isAvailable {
                Notice("The camera isn't available. Allow camera access for Table 1 in Settings, or search by name instead.", error: true)
            } else if catalog.phase != .ready {
                CatalogStatusRow(catalog: catalog)
            } else {
                CardTextScanner { lines in see(lines) }
                    .frame(height: 300)
                    .overlay(alignment: .bottomLeading) {
                        if let reading { LabelText(reading, color: T1.text).padding(8).background(T1.bg.opacity(0.8)) }
                    }
                    .clipped()
            }
            if owned == nil {
                T1Segmented(options: Conditions.all.map { ($0, $0) }, selection: $condition)
            }
            ScrollView {
                HairlineList {
                    ForEach($cards) { $card in row($card) }
                }
            }
            BigAction(text: cards.isEmpty ? "Scan a card" : "\(doneLabel) \(count)", enabled: !cards.isEmpty, accent: true) {
                onDone(cards)
            }
        }
        .onAppear {
            catalog.load(userInitiated: true)
            if let db = catalog.db { matcher = CardMatcher(db: db, owned: owned) }
        }
        .onChange(of: catalog.generation) {
            if let db = catalog.db { matcher = CardMatcher(db: db, owned: owned) }
        }
    }

    private var count: Int { cards.count }

    private func see(_ lines: [String]) {
        guard let matcher else { return }
        let m = matcher.match(lines)
        reading = m.map { $0.oracle.name }
        guard let taken = steady.feed(m), let m else { return }
        let card = ScannedCard(oracle: m.oracle, printing: taken.0, finish: matcher.defaultFinish(taken.0),
                               condition: owned == nil ? condition : "NM", exact: taken.1)
        cards.insert(card, at: 0)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func row(_ card: Binding<ScannedCard>) -> some View {
        let c = card.wrappedValue
        let finishes = c.printing.finishList
        return HStack(spacing: 1) {
            CardRow(printing: c.printing, title: c.oracle.name,
                    detail: [c.printing.setLabel, Finish(rawValue: c.finish)?.label, owned == nil ? c.condition : nil,
                             c.exact ? nil : "Check printing"].compactMap { $0 }.joined(separator: " · "))
            if finishes.count > 1 {
                // Foil can't be told from the camera: tap to switch.
                Button {
                    let i = finishes.firstIndex { $0.rawValue == c.finish } ?? 0
                    card.wrappedValue.finish = finishes[(i + 1) % finishes.count].rawValue
                } label: {
                    LabelText(Finish(rawValue: c.finish)?.label ?? c.finish, color: T1.text)
                        .padding(.horizontal, 12).frame(maxHeight: .infinity).background(T1.surfaceHover)
                }.buttonStyle(.plain)
            }
            Button { cards.removeAll { $0.id == c.id } } label: {
                Text("×").font(T1.mono(20)).frame(width: 52).frame(maxHeight: .infinity).background(T1.surfaceHover)
            }.buttonStyle(.plain).accessibilityLabel("Remove")
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(T1.surface)
    }
}

enum Conditions {
    static let all = ["NM", "LP", "MP", "HP", "DMG"]
    static func name(_ c: String) -> String {
        switch c {
        case "NM": "Near mint"
        case "LP": "Lightly played"
        case "MP": "Moderately played"
        case "HP": "Heavily played"
        case "DMG": "Damaged"
        default: c
        }
    }
}
