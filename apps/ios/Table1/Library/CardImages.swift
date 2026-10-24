import ImageIO
import SwiftUI
import UIKit

// Card images from Scryfall's CDN (cards.scryfall.io: no rate limit, no API call). Built for long lists:
//  - the smallest file that covers the on-screen size: "small" (146 px wide, ~10 KB) for thumbnails,
//    "normal" (488 px, ~70 KB) for the grid and card detail;
//  - decoded and downsampled off the main thread with ImageIO to exactly the pixels drawn, so a 40 pt
//    thumbnail holds a 120 px bitmap, not a full-size one;
//  - decoded bitmaps in a memory cache (NSCache: evicted under memory pressure), bytes in a 300 MB disk
//    cache, so scrolling back or reopening a card costs nothing;
//  - one download per image however many views ask, cancelled when the last view asking scrolls away.

/// Card corner radius as a fraction of the card's width, measured from Scryfall's transparent PNG scans
/// (2026-10-15): every printing 4.32% (≈2.7 mm on a 63 mm card), Alpha 6.99% (≈4.4 mm: a rounder cutting die),
/// Collectors' and International Edition square (cut square).
enum CardCorners {
    static func ratio(set: String) -> CGFloat {
        switch set {
        case "lea": 0.0699
        case "ced", "cei": 0
        default: 0.0432
        }
    }
}

enum CardImageSize: String {
    case small, normal, large
    /// Picks the smallest Scryfall rendition at least as wide as `pixels`.
    static func covering(pixels: CGFloat) -> CardImageSize {
        pixels <= 146 ? .small : pixels <= 488 ? .normal : .large
    }
}

actor CardImageLoader {
    static let shared = CardImageLoader()

    /// Decoded bitmaps. NSCache is thread-safe and drops entries under memory pressure.
    private static let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 << 20 // decoded bytes
        return c
    }()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 << 20,
                              directory: URL.cachesDirectory.appending(path: "CardImages", directoryHint: .isDirectory))
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private struct Flight {
        let task: Task<UIImage?, Never>
        var waiters: Int
    }
    private var flights: [String: Flight] = [:]

    /// Synchronous memory lookup, so an image already decoded shows on the first frame (no flash).
    nonisolated func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        Self.memory.object(forKey: Self.key(url, maxPixel) as NSString)
    }

    func image(_ url: URL, maxPixel: Int) async -> UIImage? {
        let key = Self.key(url, maxPixel)
        if let hit = Self.memory.object(forKey: key as NSString) { return hit }
        if var f = flights[key] {
            f.waiters += 1
            flights[key] = f
            return await wait(key, f.task)
        }
        let session = self.session
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  !Task.isCancelled else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        flights[key] = Flight(task: task, waiters: 1)
        return await wait(key, task)
    }

    /// Waits for a shared download; if this caller is cancelled and nobody else is waiting, the download is
    /// cancelled too (a fast scroll doesn't queue hundreds of images nobody will see).
    private func wait(_ key: String, _ task: Task<UIImage?, Never>) async -> UIImage? {
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(key) }
        }
        if let image {
            Self.memory.setObject(image, forKey: key as NSString, cost: Self.cost(image))
            flights[key] = nil
        } else if Task.isCancelled == false {
            flights[key] = nil
        }
        return image
    }

    private func leave(_ key: String) {
        guard var f = flights[key] else { return }
        f.waiters -= 1
        if f.waiters <= 0 {
            f.task.cancel()
            flights[key] = nil
        } else {
            flights[key] = f
        }
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    private static func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    /// Decodes straight to a bitmap no larger than `maxPixel` on its long side.
    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumb = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true, // decode now, here, not on first draw
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// A card image at a fixed width. Picks the rendition, downsamples to the drawn pixels, and shows a flat
/// placeholder until it's in (no spinner: lists stay calm while scrolling).
struct CardArt: View {
    let cardId: String
    let imageTs: String
    var faces = 1
    var set = ""
    let width: CGFloat
    /// nonfoil | foil | etched: foil copies get a light sheen, etched a dimmer one.
    var finish = "nonfoil"
    /// A double-faced card's back (faces == 2).
    var back = false
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    static let aspect: CGFloat = 488 / 680

    private var maxPixel: Int { Int((width / Self.aspect * scale).rounded(.up)) }
    private var url: URL? {
        faces == 0 ? nil : CatalogPack.imageURL(cardId: cardId, imageTs: imageTs,
                                                size: CardImageSize.covering(pixels: width * scale).rawValue, back: back && faces > 1)
    }

    var body: some View {
        Rectangle().fill(T1.bg)
            .frame(width: width, height: width / Self.aspect)
            .overlay {
                if let image { Image(uiImage: image).resizable().interpolation(.medium).scaledToFill() }
            }
            .overlay { if finish != "nonfoil" { FoilSheen(etched: finish == "etched") } }
            .clipShape(RoundedRectangle(cornerRadius: width * CardCorners.ratio(set: set), style: .circular))
            .task(id: url) {
                guard let url else { image = nil; return }
                if let hit = CardImageLoader.shared.cached(url, maxPixel: maxPixel) { image = hit; return }
                image = nil
                image = await CardImageLoader.shared.image(url, maxPixel: maxPixel)
            }
    }
}

extension CatalogPrinting {
    func art(width: CGFloat, finish: String = "nonfoil", back: Bool = false) -> CardArt {
        CardArt(cardId: cardId, imageTs: imageTs, faces: imageFaces, set: set, width: width, finish: finish, back: back)
    }
}

/// A foil's rainbow sheen over the card image: a diagonal spectrum blended into the art plus one soft highlight
/// band. Etched foils are matte, so theirs is dimmer.
struct FoilSheen: View {
    var etched = false

    private static let spectrum: [Color] = [
        Color(red: 1, green: 0.45, blue: 0.75), Color(red: 1, green: 0.85, blue: 0.4), Color(red: 0.45, green: 1, blue: 0.7),
        Color(red: 0.35, green: 0.75, blue: 1), Color(red: 0.75, green: 0.5, blue: 1), Color(red: 1, green: 0.45, blue: 0.75),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: Self.spectrum, startPoint: .topLeading, endPoint: .bottomTrailing)
                .blendMode(.overlay)
                .opacity(etched ? 0.3 : 0.55)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .white.opacity(0.35), location: 0.45),
                                   .init(color: .clear, location: 0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .blendMode(.softLight)
                .opacity(etched ? 0.5 : 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A list row led by a card thumbnail; same layout and type as ListRow.
struct CardRow<Trailing: View>: View {
    let printing: CatalogPrinting?
    let title: String
    var detail: String?
    var finish = "nonfoil"
    /// A hero card of the list, binder or collection on screen: a lighter row with a white edge.
    var hero = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let printing {
                printing.art(width: 36, finish: finish)
            } else {
                RoundedRectangle(cornerRadius: 36 * 0.0432).fill(T1.bg).frame(width: 36, height: 36 / CardArt.aspect)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(T1.mono(14)).lineLimit(1)
                if let detail { LabelText(detail) }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(hero ? T1.surfaceHover : T1.surface)
        .overlay(alignment: .leading) { if hero { HeroEdge() } }
        .contentShape(Rectangle())
    }
}

/// The mark a hero card's row carries on its left edge.
struct HeroEdge: View {
    var body: some View { Rectangle().fill(T1.text).frame(width: 2).accessibilityLabel("Hero card") }
}

/// One cell of a card grid: the image with a quantity tag in the corner.
struct CardTile: View {
    let printing: CatalogPrinting?
    let name: String
    let qty: Int
    var warn = false
    let width: CGFloat
    var finish = "nonfoil"
    var hero = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let printing {
                printing.art(width: width, finish: finish)
            } else {
                RoundedRectangle(cornerRadius: width * 0.0432).fill(T1.surface).frame(width: width, height: width / CardArt.aspect)
                    .overlay { LabelText(name).padding(6) }
            }
            Text("\(qty)")
                .font(T1.mono(13)).monospacedDigit()
                .foregroundStyle(warn ? T1.bg : T1.text)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(warn ? T1.error : T1.bg)
                .padding(width * 0.05) // inset past the rounded corner so the tag never gets clipped
        }
        .overlay { if hero { HeroFrame(width: width) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(qty)\(hero ? ", hero card" : "")")
    }
}

extension CardRow where Trailing == EmptyView {
    init(printing: CatalogPrinting?, title: String, detail: String? = nil, finish: String = "nonfoil", hero: Bool = false) {
        self.printing = printing
        self.title = title
        self.detail = detail
        self.finish = finish
        self.hero = hero
        self.trailing = EmptyView()
    }
}

/// How a card list is drawn: rows, a three-column grid of whole cards, or stacks that show each card's
/// title bar with the last card in full (like cards fanned down a playmat).
enum CardLayout: String, CaseIterable {
    case list, grid, stacks
    var title: String { rawValue.capitalized }

    /// The bar's "View" menu: the three layouts, the current one checked, then expanding or collapsing every card's
    /// printings when the screen has them.
    @MainActor static func menu(_ current: Binding<String>, screen: String, printings: Binding<PrintingsDisclosure>? = nil,
                                extra: [T1MenuItem] = []) {
        var items = allCases.map { l in
            T1MenuItem(title: l.title, checked: current.wrappedValue == l.rawValue) {
                guard current.wrappedValue != l.rawValue else { return }
                current.wrappedValue = l.rawValue
                Telemetry.capture("card_layout_changed", ["layout": l.rawValue, "screen": screen])
            }
        }
        if let printings {
            let all = printings.wrappedValue.all
            items.append(T1MenuItem(title: all ? "Collapse all printings" : "Expand all printings",
                                    detail: all ? "One row per card" : "Every printing and finish on its own row") {
                printings.wrappedValue.setAll(!all)
                Telemetry.capture("printings_toggled", ["expanded": !all, "all": true, "screen": screen])
            })
        }
        T1Overlays.shared.showMenu("View", items + extra)
    }
}

/// Which cards show each printing on its own row. Collapsed by default; Expand all opens every card, and a card's
/// own chevron flips just that card.
struct PrintingsDisclosure: Equatable {
    var all = false
    var flipped: Set<String> = []

    func open(_ id: String) -> Bool { all != flipped.contains(id) }
    mutating func toggle(_ id: String) { if !flipped.insert(id).inserted { flipped.remove(id) } }
    mutating func setAll(_ on: Bool) { all = on; flipped = [] }
}

/// The chevron column at the right of a card with several printings: opens or closes its printings.
struct PrintingsChevron: View {
    let open: Bool
    var hero = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 13, weight: .regular))
                .foregroundStyle(T1.muted)
                .frame(width: 44).frame(maxHeight: .infinity)
                .background(hero ? T1.surfaceHover : T1.surface)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Hide printings" : "Show printings")
    }
}

/// One card in a stack. Only its top `CardStack.peek` shows unless it's the last card.
struct StackCard: Identifiable {
    let id: String
    let printing: CatalogPrinting?
    let name: String
    let qty: Int
    var warn = false
    var finish = "nonfoil"
    var hero = false
    let open: () -> Void
}

/// A hero card's outline in the grid and in stacks.
struct HeroFrame: View {
    let width: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.0432).strokeBorder(T1.text, lineWidth: 2).allowsHitTesting(false)
    }
}

/// Cards laid over each other, each showing just its title bar (name and mana cost); the last shows in full.
/// Later cards draw on top, so a tap on a strip lands on that card.
struct CardStack: View {
    var title: String?
    let cards: [StackCard]
    let width: CGFloat

    /// The share of a card's height left showing: the whole title bar on every modern frame.
    static let peek: CGFloat = 0.118

    var body: some View {
        let height = width / CardArt.aspect
        VStack(alignment: .leading, spacing: 0) {
            if let title { LabelText(title).lineLimit(1).padding(.horizontal, 4).padding(.vertical, 8) }
            VStack(spacing: -(height * (1 - Self.peek))) {
                ForEach(cards) { c in
                    Button(action: c.open) { face(c, height: height) }.buttonStyle(.plain)
                }
            }
        }
        .frame(width: width, alignment: .top)
    }

    private func face(_ c: StackCard, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let p = c.printing {
                p.art(width: width, finish: c.finish)
            } else {
                RoundedRectangle(cornerRadius: width * 0.0432).fill(T1.surface).frame(width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        Text(c.name).font(T1.mono(12)).lineLimit(1).padding(.horizontal, 8).frame(height: height * Self.peek)
                    }
                    .overlay { RoundedRectangle(cornerRadius: width * 0.0432).strokeBorder(T1.bg, lineWidth: 1) }
            }
            // The count sits on the frame's left edge, clear of the name, and only when it says something.
            if c.qty > 1 || c.warn {
                Text("\(c.qty)")
                    .font(T1.mono(11)).monospacedDigit()
                    .foregroundStyle(c.warn ? T1.bg : T1.text)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(c.warn ? T1.error : T1.bg)
                    .frame(height: height * Self.peek)
            }
        }
        .overlay { if c.hero { HeroFrame(width: width) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.name), \(c.qty)\(c.hero ? ", hero card" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// Stacks two to a row, filling the width; rows are built lazily as they scroll.
struct StackRows: View {
    let stacks: [(id: String, title: String?, cards: [StackCard])]
    let width: CGFloat

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1, alignment: .top), count: 2), alignment: .leading, spacing: 16) {
            ForEach(stacks, id: \.id) { s in CardStack(title: s.title, cards: s.cards, width: width) }
        }
        .padding(.bottom, 16)
    }
}
