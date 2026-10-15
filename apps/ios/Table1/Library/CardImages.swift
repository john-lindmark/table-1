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
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    static let aspect: CGFloat = 488 / 680

    private var maxPixel: Int { Int((width / Self.aspect * scale).rounded(.up)) }
    private var url: URL? {
        faces == 0 ? nil : CatalogPack.imageURL(cardId: cardId, imageTs: imageTs,
                                                size: CardImageSize.covering(pixels: width * scale).rawValue)
    }

    var body: some View {
        Rectangle().fill(T1.bg)
            .frame(width: width, height: width / Self.aspect)
            .overlay {
                if let image { Image(uiImage: image).resizable().interpolation(.medium).scaledToFill() }
            }
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
    func art(width: CGFloat) -> CardArt { CardArt(cardId: cardId, imageTs: imageTs, faces: imageFaces, set: set, width: width) }
}

/// A list row led by a card thumbnail; same layout and type as ListRow.
struct CardRow<Trailing: View>: View {
    let printing: CatalogPrinting?
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let printing {
                printing.art(width: 36)
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
        .background(T1.surface)
        .contentShape(Rectangle())
    }
}

/// One cell of a card grid: the image with a quantity tag in the corner.
struct CardTile: View {
    let printing: CatalogPrinting?
    let name: String
    let qty: Int
    var warn = false
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let printing {
                printing.art(width: width)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(qty)")
    }
}

extension CardRow where Trailing == EmptyView {
    init(printing: CatalogPrinting?, title: String, detail: String? = nil) {
        self.printing = printing
        self.title = title
        self.detail = detail
        self.trailing = EmptyView()
    }
}
