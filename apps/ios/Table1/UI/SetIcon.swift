import SVGView
import SwiftUI

/// A set's Scryfall symbol (SVG), tinted to the text colour. Icons are fetched once per launch and
/// kept in memory; URLSession's cache keeps them across launches.
struct SetIcon: View {
    let code: String
    var uri: String?
    var size: CGFloat = 18
    var color: Color = T1.text

    @State private var svg: Data?

    /// Scryfall serves every set's icon at this path; draftable_sets rows carry the exact one.
    private var url: URL? {
        URL(string: uri ?? "https://svgs.scryfall.io/sets/\(code.lowercased()).svg")
    }

    var body: some View {
        ZStack {
            if let svg {
                color.mask { SVGView(data: svg).aspectRatio(contentMode: .fit) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            svg = await SetIconCache.shared.data(for: url)
        }
    }
}

actor SetIconCache {
    static let shared = SetIconCache()
    private var cache: [URL: Data] = [:]
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    func data(for url: URL) async -> Data? {
        if let hit = cache[url] { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<Data?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        if let data { cache[url] = data }
        return data
    }
}
