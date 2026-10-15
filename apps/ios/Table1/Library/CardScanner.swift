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
            makeMatcher()
        }
        .onChange(of: catalog.generation) { makeMatcher() }
    }

    /// The matcher's name index takes a moment to build the first time, so it's built off the main thread.
    private func makeMatcher() {
        guard let db = catalog.db, matcher?.db !== db else { return }
        let owned = owned
        Task { matcher = await Task.detached(priority: .userInitiated) { CardMatcher(db: db, owned: owned) }.value }
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
