import SwiftUI
import UIKit
import WidgetKit

// The card icon widget (contract/icon-widget-2026-11-06.md): the Table 1 mark over a card's art, like the app icon
// with a card behind it. Cards are picked on a card's page (details → Icon widget) and kept on this device in the
// App Group, newest first, with their art saved beside them; each widget shows the one picked in its settings, else
// the newest. Pure parts are checked against testdata/icon-widget/cases.json in IconCardsTests.

struct IconCard: Codable, Hashable, Identifiable {
    /// The printing's Scryfall id: its art crop is the background.
    let id: String
    let name: String
    /// "MH2 · 438".
    let set: String
}

enum IconCards {
    static let limit = 12
    static let kind = "site.table1.icon"
    /// The mark's width on the app icon (Figma "App icons" 19726:2784).
    static let logoShare: CGFloat = 479 / 1024

    /// The card goes first; picking it again moves it up; the oldest past `limit` drop off.
    static func add(_ cards: [IconCard], _ card: IconCard) -> [IconCard] {
        Array(([card] + cards.filter { $0.id != card.id }).prefix(limit))
    }

    static func remove(_ cards: [IconCard], _ id: String) -> [IconCard] { cards.filter { $0.id != id } }

    /// The card picked in a widget's settings while it's still on the list, else the newest; nil → the plain icon.
    static func shown(_ cards: [IconCard], chosen: String?) -> IconCard? {
        chosen.flatMap { c in cards.first { $0.id == c } } ?? cards.first
    }

    static func logoWidth(_ width: CGFloat) -> CGFloat { (width * logoShare).rounded() }
}

/// The list and the art in the App Group.
enum IconCardStore {
    private static let defaults = UserDefaults(suiteName: T1Shared.appGroup)
    private static let key = "iconCards.v1"
    /// Big enough for a large widget at 3x; a widget's whole budget is a few tens of MB.
    static let maxPixel: CGFloat = 640

    static func load() -> [IconCard] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IconCard].self, from: data)) ?? []
    }

    private static func save(_ cards: [IconCard]) {
        if let data = try? JSONEncoder().encode(cards) { defaults?.set(data, forKey: key) }
    }

    static func contains(_ id: String) -> Bool { load().contains { $0.id == id } }

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: T1Shared.appGroup)?
            .appendingPathComponent("icon-cards", isDirectory: true)
    }

    static func artURL(_ id: String) -> URL? { folder?.appendingPathComponent("\(id).jpg") }

    static func art(_ id: String) -> UIImage? {
        guard let url = artURL(id), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Saves the art (already downloaded by the app) and puts the card first. Returns false when the art couldn't be
    /// written, so nothing changes.
    @discardableResult
    static func add(_ card: IconCard, image: UIImage) -> Bool {
        guard let folder, let url = artURL(card.id) else { return false }
        let scaled = downsized(image)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try jpeg.write(to: url, options: .atomic)
        } catch { return false }
        let before = load()
        let after = IconCards.add(before, card)
        for gone in before where !after.contains(where: { $0.id == gone.id }) { deleteArt(gone.id) }
        save(after)
        WidgetCenter.shared.reloadTimelines(ofKind: IconCards.kind)
        return true
    }

    static func remove(_ id: String) {
        save(IconCards.remove(load(), id))
        deleteArt(id)
        WidgetCenter.shared.reloadTimelines(ofKind: IconCards.kind)
    }

    private static func deleteArt(_ id: String) {
        if let url = artURL(id) { try? FileManager.default.removeItem(at: url) }
    }

    private static func downsized(_ image: UIImage) -> UIImage {
        let side = max(image.size.width * image.scale, image.size.height * image.scale)
        guard side > maxPixel else { return image }
        let k = maxPixel / side
        let size = CGSize(width: (image.size.width * image.scale * k).rounded(), height: (image.size.height * image.scale * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// The widget's face: the art under the 60% scrim with the mark centered at the app icon's size; with no card (or
/// its art missing), the plain icon.
struct IconCardView: View {
    let art: UIImage?

    var body: some View {
        GeometryReader { geo in
            T1Logo().fill(W1.text)
                .frame(width: IconCards.logoWidth(geo.size.width), height: IconCards.logoWidth(geo.size.width) / T1Logo.aspect)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityLabel("Table 1")
    }

    /// Drawn as the widget's container background, so it runs edge to edge.
    @ViewBuilder static func background(_ art: UIImage?) -> some View {
        ZStack {
            W1.bg
            if let art {
                Image(uiImage: art).resizable().scaledToFill()
                W1.bg.opacity(0.6)
            }
        }
    }
}

/// The Table 1 mark: eleven tiles on a 6 × 3 grid, scaled from the library's "Table 1 Logo" vector
/// (393 × 192.69). Fill it and give it the width; the height follows the aspect ratio.
struct T1Logo: Shape {
    static let aspect: CGFloat = 393 / 192.69
    /// (column, row) of each tile.
    private static let tiles: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
        (1, 1), (4, 1),
        (1, 2), (3, 2), (4, 2), (5, 2),
    ]

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 393, sy = rect.height / 192.69
        var p = Path()
        for (c, r) in Self.tiles {
            p.addRect(CGRect(x: rect.minX + CGFloat(c) * 65.8036 * sx, y: rect.minY + CGFloat(r) * 64.8302 * sy,
                             width: 63.982 * sx, height: 63.0294 * sy))
        }
        return p
    }
}

