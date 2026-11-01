import SwiftUI
import UIKit

/// A feature spot (contract/feature-spots-2026-11-01.md): a piece of Table 1 worth showing, with copy and a phone
/// shot of the real screen. Read from `spots/spots.json`, the folder the app bundles from marketing/bundle/spots
/// (the same file the web and Android read), so copy changes there reach every placement.
struct Spot: Decodable, Identifiable, Equatable {
    let key: String
    let title: String
    let headline: String
    let body: String
    let onboarding: Bool
    var id: String { key }
}

enum Spots {
    struct File: Decodable {
        let updated: String
        let limits: Limits
        let spots: [Spot]
    }
    struct Limits: Decodable { let title: Int; let headline: Int; let body: Int }

    static let file: File? = load()
    static var all: [Spot] { file?.spots ?? [] }
    /// The sign-in carousel's pages, in the file's order.
    static var onboarding: [Spot] { all.filter(\.onboarding) }

    static func load(bundle: Bundle = .main) -> File? {
        guard let url = bundle.url(forResource: "spots", withExtension: "json", subdirectory: "spots"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    /// The spot's phone shot (780×1688), or nil before the first shoot.
    static func shot(_ key: String, bundle: Bundle = .main) -> UIImage? {
        guard let url = bundle.url(forResource: key, withExtension: "png", subdirectory: "spots/shots") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// How long a page stays before the carousel moves on by itself (until the first swipe).
    static let dwell: TimeInterval = 6

    /// The page after `page`, wrapping; the carousel's timer uses it.
    static func next(after page: Int, count: Int) -> Int { count == 0 ? 0 : (page + 1) % count }
}

/// The sign-in screen's carousel: one page per onboarding spot (copy beside its shot), dots under it, moving on by
/// itself every few seconds until the person swipes. Sits between the mark and the sign-in buttons.
struct SpotsCarousel: View {
    let spots: [Spot]
    @State private var page = 0
    @State private var swiped = false
    private let ticks = Timer.publish(every: Spots.dwell, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(spots.enumerated()), id: \.element.id) { i, spot in
                    SpotPage(spot: spot).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in swiped = true })
            HStack(spacing: 6) {
                ForEach(spots.indices, id: \.self) { i in
                    Rectangle().fill(i == page ? T1.accent : T1.disabled).frame(width: i == page ? 18 : 6, height: 3)
                        .animation(.easeInOut(duration: 0.2), value: page)
                }
            }
            .padding(.bottom, 12)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T1.surface)
        .onReceive(ticks) { _ in
            guard !swiped, spots.count > 1 else { return }
            withAnimation { page = Spots.next(after: page, count: spots.count) }
        }
        .onChange(of: page) { _, new in
            guard spots.indices.contains(new) else { return }
            Telemetry.capture("spot_viewed", ["key": spots[new].key, "index": new, "swiped": swiped])
        }
    }
}

private struct SpotPage: View {
    let spot: Spot
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                LabelText(spot.title)
                Text(spot.headline.uppercased()).font(T1.mono(17, .bold)).tracking(1.5).lineSpacing(4)
                Text(spot.body).font(T1.mono(12)).lineSpacing(4).foregroundStyle(T1.muted)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let image = Spots.shot(spot.key) {
                // The whole width of the phone shot, from its top, cut off at the bottom when the page is short.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132)
                    .border(T1.bg, width: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
