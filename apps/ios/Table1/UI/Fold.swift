import SwiftUI
import UIKit

/// Foldables (contract/foldables-2026-11-10.md): one rule for every container, from its own size and the folds
/// crossing it. Never the screen, the device or the orientation (Apple's iPhone Duo guidance).
struct Fold: Equatable, Hashable {
    var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    /// Runs top to bottom (book), else across (tabletop).
    var vertical: Bool
    /// Splits the display in two right now (an active `.division` reserved region).
    var separating: Bool = true
    var margin: CGFloat = 0

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct FoldLayout: Equatable {
    enum Mode: String { case single, wide, tabletop, book }
    enum SizeClass: String { case compact, medium, expanded }

    var width: SizeClass
    var height: SizeClass
    var mode: Mode
    /// One rect (single) or two (first, second) in the container's space; the fold's band belongs to neither.
    var panes: [CGRect]
    /// The tab bar runs down the side.
    var rail: Bool
    /// The app turns with the device (the window's shorter side is 600 or more).
    var rotates: Bool

    static let clear: CGFloat = 8
    static let minPane: CGFloat = 120
    static let wide: CGFloat = 840
    static let heightMin: CGFloat = 480

    var twoPanes: Bool { panes.count == 2 }
    var posture: String { mode == .tabletop || mode == .book ? mode.rawValue : "flat" }

    static func widthClass(_ w: CGFloat) -> SizeClass { w < 600 ? .compact : w < 840 ? .medium : .expanded }
    static func heightClass(_ h: CGFloat) -> SizeClass { h < 480 ? .compact : h < 900 ? .medium : .expanded }

    static func of(_ size: CGSize, folds: [Fold]) -> FoldLayout {
        let w = size.width, h = size.height
        var mode = Mode.single
        var panes = [CGRect(x: 0, y: 0, width: w, height: h)]
        for f in folds where f.separating {
            let clear = max(Self.clear, f.margin)
            if f.vertical {
                let a = f.x - clear, b = f.x + f.w + clear
                if a >= minPane && w - b >= minPane {
                    mode = .book
                    panes = [CGRect(x: 0, y: 0, width: a, height: h), CGRect(x: b, y: 0, width: w - b, height: h)]
                    break
                }
            } else {
                let a = f.y - clear, b = f.y + f.h + clear
                if a >= minPane && h - b >= minPane {
                    mode = .tabletop
                    panes = [CGRect(x: 0, y: 0, width: w, height: a), CGRect(x: 0, y: b, width: w, height: h - b)]
                    break
                }
            }
        }
        if mode == .single && w >= wide && h >= heightMin {
            let half = (w - 1) / 2
            mode = .wide
            panes = [CGRect(x: 0, y: 0, width: half, height: h), CGRect(x: half + 1, y: 0, width: w - half - 1, height: h)]
        }
        return FoldLayout(width: widthClass(w), height: heightClass(h), mode: mode, panes: panes,
                          rail: mode != .tabletop && w > h, rotates: min(w, h) >= 600)
    }
}

extension GeometryProxy {
    /// The folds crossing this view, in its own space: the system's active division regions (iOS 27.1+, iPhone Duo
    /// partly open), or in Debug the `-T1Fold` stand-in.
    @MainActor func folds() -> [Fold] {
        var out: [Fold] = []
        if #available(iOS 27.1, *) {
            for region in reservedRegions(kind: .division) where region.isActive {
                let f = region.frame
                let m = region.margins
                out.append(Fold(x: f.minX, y: f.minY, w: f.width, h: f.height, vertical: f.height > f.width,
                                margin: max(m.top, m.bottom, m.leading, m.trailing)))
            }
        }
        #if DEBUG
        if out.isEmpty, let band = FoldDebug.band() {
            let origin = frame(in: .global).origin
            out.append(Fold(x: band.minX - origin.x, y: band.minY - origin.y, w: band.width, h: band.height,
                            vertical: band.height > band.width))
        }
        #endif
        return out
    }

    @MainActor func foldLayout() -> FoldLayout { FoldLayout.of(size, folds: folds()) }
}

#if DEBUG
/// Design QA without a foldable: `-T1Fold tabletop|book` puts a 20 pt division band across the middle of the
/// window, `-T1Fold wide` only makes sure nothing else is simulated (pick a wide window).
enum FoldDebug {
    static let mode: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-T1Fold"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }()

    @MainActor static func band() -> CGRect? {
        guard let mode, mode == "tabletop" || mode == "book" else { return nil }
        let size = WindowFold.shared.size
        guard size.width > 0 else { return nil }
        return mode == "tabletop"
            ? CGRect(x: 0, y: size.height / 2 - 10, width: size.width, height: 20)
            : CGRect(x: size.width / 2 - 10, y: 0, width: 20, height: size.height)
    }
}
#endif

/// The whole window's layout: the tab bar's rail, rotation and posture telemetry. Kept by `.windowFold()` at the root.
@MainActor
@Observable
final class WindowFold {
    static let shared = WindowFold()
    private(set) var layout = FoldLayout.of(CGSize(width: 390, height: 844), folds: [])
    private(set) var size: CGSize = .zero
    /// The edge the system puts vertical bars on (`toolbarVerticalEdge`, iOS 27.1+), when it does.
    var systemEdge: HorizontalEdge?

    /// Tab bar down the side, and on which edge: the system's, else trailing (where iPhone Duo keeps its controls).
    var rail: HorizontalEdge? {
        if let systemEdge, layout.mode != .tabletop { return systemEdge }
        return layout.rail ? .trailing : nil
    }

    func update(_ size: CGSize, folds: [Fold]) {
        let next = FoldLayout.of(size, folds: folds)
        self.size = size
        guard next != layout else { return }
        let posture = layout.posture
        let rotated = layout.rotates
        layout = next
        if next.posture != posture {
            Telemetry.capture("fold_posture", ["posture": next.posture, "width": next.width.rawValue, "height": next.height.rawValue])
        }
        if next.rotates != rotated { Self.refreshOrientations() }
    }

    /// Phones stay portrait; an inner display turns with the device (AppDelegate asks `mask`).
    var mask: UIInterfaceOrientationMask { layout.rotates ? .allButUpsideDown : .portrait }

    static func refreshOrientations() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalEdgeProbe: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    var body: some View {
        Color.clear.onChange(of: edge, initial: true) { _, now in WindowFold.shared.systemEdge = now }
    }
}

extension View {
    /// At the window's root: measures the whole window (safe areas included) for `WindowFold`.
    func windowFold() -> some View {
        background {
            GeometryReader { geo in
                Color.clear
                    .onChange(of: FoldProbe(size: geo.size, folds: geo.folds()), initial: true) { _, now in
                        WindowFold.shared.update(now.size, folds: now.folds)
                    }
            }
            .ignoresSafeArea()
            if #available(iOS 27.1, *) { VerticalEdgeProbe() }
        }
    }
}

private struct FoldProbe: Equatable {
    let size: CGSize
    let folds: [Fold]
}

/// Two panes when the container is wide, or folded into tabletop or book (and the mode is in `allow`); else `single`.
/// The panes are placed at the rule's rects, so nothing lands on the fold's band.
struct FoldSplit<Single: View, First: View, Second: View>: View {
    let screen: String
    var allow: Set<FoldLayout.Mode> = [.wide, .tabletop, .book]
    var enabled = true
    @ViewBuilder let single: () -> Single
    @ViewBuilder let first: (FoldLayout) -> First
    @ViewBuilder let second: (FoldLayout) -> Second

    var body: some View {
        GeometryReader { geo in
            let layout = geo.foldLayout()
            let split = enabled && layout.twoPanes && allow.contains(layout.mode)
            Group {
                if split {
                    let a = layout.panes[0], b = layout.panes[1]
                    ZStack(alignment: .topLeading) {
                        T1.bg
                        if layout.mode == .wide {
                            // The hairline between the panes (the grid's 1 pt of surface).
                            T1.surface.frame(width: 1, height: geo.size.height).offset(x: a.maxX)
                        }
                        first(layout).frame(width: a.width, height: a.height).clipped().offset(x: a.minX, y: a.minY)
                        second(layout).frame(width: b.width, height: b.height).clipped().offset(x: b.minX, y: b.minY)
                    }
                } else {
                    single()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: split ? layout.mode : .single) { _, mode in
                Telemetry.capture("fold_layout", ["mode": mode.rawValue, "screen": screen])
            }
        }
    }
}
