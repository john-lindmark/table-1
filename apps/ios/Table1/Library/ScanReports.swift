import SwiftUI
import Supabase

/* Scan reports. Nobody is asked to report a bad scan: what people already do says it.
   - Changed the printing of a scanned card → wrong_printing, at once.
   - Deleted a scanned card → removed; if a card is then added by hand within 3 minutes, that card is the answer
     and it goes as wrong_card instead (the same card added back is a duplicate deleted, and nothing is sent).
   - Closed the scanner with nothing taken, or after 2 s of card text naming nothing since the last take (an old card
     it couldn't read, between ones it could), then added a card by hand within 3 minutes → missed.
   Each carries the OCR lines of the frames the matcher saw (scan_report), and becomes a matcher test case in
   testdata/scan/reports/. Text only, never images. On by default; Account → Improve scanning turns it off.
   Changing the finish isn't reported: the camera can't tell foil. Contract: contract/trades-2026-10-16.md. */

/// The last few frames' OCR lines, oldest first: the matcher's input up to a take.
struct ScanFrames {
    static let keep = 6
    private(set) var frames: [[String]] = []
    /// The last frames that had any text (what a miss is reported with).
    private(set) var withText: [[String]] = []
    /// Since the last take: frames with text that named no card, the last few of them kept.
    private(set) var unnamed = 0
    private(set) var unnamedFrames: [[String]] = []
    /// About 2 s of card text naming nothing: a card the scanner couldn't read.
    static let missed = 10

    mutating func add(_ lines: [String], named: Bool = false) {
        let f = Array(lines.prefix(80))
        frames.append(f)
        if frames.count > Self.keep { frames.removeFirst(frames.count - Self.keep) }
        if !f.isEmpty {
            withText.append(f)
            if withText.count > Self.keep { withText.removeFirst(withText.count - Self.keep) }
            if !named {
                unnamed += 1
                unnamedFrames.append(f)
                if unnamedFrames.count > Self.keep { unnamedFrames.removeFirst(unnamedFrames.count - Self.keep) }
            }
        }
    }

    /// A card was taken: what came before it was read.
    mutating func took() {
        unnamed = 0
        unnamedFrames = []
    }
}

@MainActor
enum ScanReports {
    static let key = "scan.reports"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    enum Kind: String { case wrongCard = "wrong_card", wrongPrinting = "wrong_printing", removed, missed }

    /// A deletion or miss waiting to learn which card it really was.
    private struct Pending {
        let kind: Kind
        let frames: [[String]]
        let matched: ScannedCard.Matched?
        let ownedOnly: Bool
        let at: Date
    }
    private static var pending: [Pending] = []
    private static let window: TimeInterval = 180

    /// The user changed a scanned card's printing.
    static func printingChanged(_ card: ScannedCard, to cardId: String, ownedOnly: Bool) {
        guard let m = card.matched, m.cardId != cardId else { return }
        send(.wrongPrinting, frames: card.frames, matched: m, corrected: cardId, ownedOnly: ownedOnly)
    }

    /// The user deleted a scanned card.
    static func removed(_ card: ScannedCard, ownedOnly: Bool) {
        guard enabled, let m = card.matched else { return }
        hold(Pending(kind: .removed, frames: card.frames, matched: m, ownedOnly: ownedOnly, at: .now))
    }

    /// The scanner closed. Nothing taken but text seen, or card text naming nothing for a while since the last take:
    /// the next card added by hand is probably the one it missed.
    static func scannerClosed(taken: Int, frames: ScanFrames, ownedOnly: Bool) {
        guard enabled else { return }
        if taken == 0, !frames.withText.isEmpty {
            hold(Pending(kind: .missed, frames: frames.withText, matched: nil, ownedOnly: ownedOnly, at: .now))
        } else if frames.unnamed >= ScanFrames.missed {
            hold(Pending(kind: .missed, frames: frames.unnamedFrames, matched: nil, ownedOnly: ownedOnly, at: .now))
        }
    }

    /// A card was added by hand (collection +1, a trade line picked by search). Answers the oldest open deletion or miss.
    static func addedByHand(_ cardId: String) {
        expire()
        guard !pending.isEmpty else { return }
        let p = pending.removeFirst()
        switch p.kind {
        case .removed:
            if p.matched?.cardId == cardId { return } // put back the same printing: a duplicate was deleted
            send(.wrongCard, frames: p.frames, matched: p.matched, corrected: cardId, ownedOnly: p.ownedOnly)
        default:
            send(.missed, frames: p.frames, matched: nil, corrected: cardId, ownedOnly: p.ownedOnly)
        }
    }

    private static func hold(_ p: Pending) {
        expire()
        pending.append(p)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(window + 1))
            expire()
        }
    }

    /// Deletions nobody followed with a card by hand go as plain removals; such misses are dropped (no answer).
    private static func expire() {
        let old = pending.filter { Date.now.timeIntervalSince($0.at) > window }
        pending.removeAll { Date.now.timeIntervalSince($0.at) > window }
        for p in old where p.kind == .removed {
            send(.removed, frames: p.frames, matched: p.matched, corrected: nil, ownedOnly: p.ownedOnly)
        }
    }

    /// Fire and forget: a failed report is dropped and never gets in the way of scanning.
    private static func send(_ kind: Kind, frames: [[String]], matched: ScannedCard.Matched?, corrected: String?, ownedOnly: Bool) {
        guard enabled else { return }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let params: [String: AnyJSON] = [
            "p_kind": .string(kind.rawValue),
            "p_platform": .string("ios"),
            "p_frames": .array(frames.map { .array($0.map { .string($0) }) }),
            "p_matched_card_id": matched.map { .string($0.cardId) } ?? .null,
            "p_matched_exact": .bool(matched?.exact ?? false),
            "p_corrected_card_id": corrected.map { .string($0) } ?? .null,
            "p_app_version": .string(version),
            "p_pack_version": CatalogStore.shared.db.map { .string($0.version) } ?? .null,
            "p_owned_only": .bool(ownedOnly),
        ]
        Task.detached(priority: .utility) {
            _ = try? await supabase.rpc("scan_report", params: params).execute()
        }
    }
}

/// A scanned card's printings: tap one to change it. Owned-only (Trades: what you give) lists only printings you own.
struct ScanPrintingView: View {
    let card: ScannedCard
    var owned: [String: Set<String>]?
    let onPick: (CatalogPrinting) -> Void
    let onClose: () -> Void

    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var printings: [CatalogPrinting] = []

    var body: some View {
        T1Screen {
            Bar(title: "Printing", subtitle: card.oracle.name, back: onClose)
            HairlineList {
                ForEach(printings, id: \.cardId) { p in row(p) }
            }
        }
        .task(id: catalog.generation) {
            guard let db = catalog.db else { return }
            let idx = card.oracle.idx, owned = owned
            printings = await Task.detached(priority: .userInitiated) {
                let all = db.printings(oracleIdx: idx)
                return owned.map { o in all.filter { o[$0.cardId] != nil } } ?? all
            }.value
        }
    }

    private func row(_ p: CatalogPrinting) -> some View {
        let current = p.cardId == card.printing.cardId
        let detail = [CatalogPack.rarityName[p.rarity], p.releasedAt.isEmpty ? nil : String(p.releasedAt.prefix(4)),
                      p.original ? "Original" : nil, p.lang == "en" ? nil : p.lang.uppercased()].compactMap { $0 }.joined(separator: " · ")
        return Button { current ? onClose() : onPick(p) } label: {
            HStack(spacing: 12) {
                p.art(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.setLabel).font(T1.mono(13)).lineLimit(1)
                    LabelText(detail)
                }
                Spacer(minLength: 0)
                LabelText(current ? "Current" : "Pick", color: current ? T1.disabled : T1.text)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(T1.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
