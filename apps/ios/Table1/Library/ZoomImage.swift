import SwiftUI
import UIKit

/// What a long press on a made picture offers, in the system's own menu (contract/deck-image-2026-10-20.md § Long press):
/// Copy, Save to Photos, Share. Copy and Save return what to say; Share opens the system share sheet.
struct MadeImageActions {
    let copy: () -> String
    let save: () async -> String
    let share: () -> Void

    /// The picture on the pasteboard, as Messages, Mail and Photos paste it.
    static func copy(_ image: UIImage) -> String {
        UIPasteboard.general.image = image
        return "Copied the image."
    }
}

extension View {
    /// Long press: the system context menu with the picture as its preview. `said` gets Copy's and Save's answer.
    func madeImageMenu(_ image: UIImage, _ actions: MadeImageActions, screen: String, said: @escaping (String) -> Void = { _ in }) -> some View {
        contextMenu {
            Button("Copy") {
                said(actions.copy())
                Telemetry.capture("image_menu", ["screen": screen, "how": "copy"])
            }
            Button("Save to Photos") {
                Task { said(await actions.save()) }
                Telemetry.capture("image_menu", ["screen": screen, "how": "photos"])
            }
            Button("Share…") {
                actions.share()
                Telemetry.capture("image_menu", ["screen": screen, "how": "share"])
            }
        } preview: {
            Image(uiImage: image).resizable().scaledToFit()
        }
    }
}

/// A made picture (deck image, top 100) to look at closely: pinch or double-tap to zoom, drag to pan, long press
/// for Copy, Save to Photos and Share.
struct ZoomImagePanel: View {
    let title: String
    var subtitle: String?
    let image: UIImage
    /// Nil for card art (card detail), which has no long-press menu.
    var actions: MadeImageActions?
    let screen: String
    @State private var said: String?

    var body: some View {
        T1Screen {
            Bar(title: title, subtitle: subtitle, back: { T1Overlays.shared.dismissPanel() })
            if let said { Notice(said) }
            if let actions {
                zoomed.madeImageMenu(image, actions, screen: "\(screen)_zoom") { said = $0 }
            } else {
                zoomed
            }
        }
        .task(id: said) {
            guard said != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            said = nil
        }
    }

    private var zoomed: some View {
        ZoomableImage(image: image, label: [title, subtitle].compactMap { $0 }.joined(separator: ", "))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(T1.bg)
    }

    /// Full screen without the edge swipe: a drag from the left edge pans the picture instead.
    static func present(title: String, subtitle: String?, image: UIImage, actions: MadeImageActions? = nil, screen: String) {
        Telemetry.capture("image_zoomed", ["screen": screen])
        T1Overlays.shared.present(full: true, swipeBack: false) {
            ZoomImagePanel(title: title, subtitle: subtitle, image: image, actions: actions, screen: screen).screen("\(screen)_zoom")
        }
    }
}

/// The preview of a made picture: a tap opens it to zoom, a long press offers Copy, Save to Photos and Share, and a
/// row under it says so.
struct ZoomablePreview: View {
    let title: String
    var subtitle: String?
    let image: UIImage
    let screen: String
    let actions: MadeImageActions

    var body: some View {
        Button { open() } label: {
            VStack(spacing: 1) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .madeImageMenu(image, actions, screen: screen)
                LabelText("Tap to zoom · hold to copy, save or share").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(T1.surface)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens it full screen to zoom")
        .accessibilityAction(named: "Copy") { _ = actions.copy() }
        .accessibilityAction(named: "Save to Photos") { Task { _ = await actions.save() } }
        .accessibilityAction(named: "Share") { actions.share() }
        #if DEBUG
        // Design QA: `-T1Zoom` opens the zoom view once the picture is made.
        .task { if ProcessInfo.processInfo.arguments.contains("-T1Zoom") { open() } }
        #endif
    }

    private func open() { ZoomImagePanel.present(title: title, subtitle: subtitle, image: image, actions: actions, screen: screen) }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let label: String

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView(image: image, label: label) }
    func updateUIView(_ view: ZoomScrollView, context: Context) {}
}

/// UIScrollView zooming: fits the picture on open and on rotation, keeps it centered while smaller than the
/// screen, and double-tap toggles between fitted and 3× around the tap.
final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var fittedFor: CGSize = .zero

    init(image: UIImage, label: String) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = label
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedFor && bounds.width > 0 && bounds.height > 0 { fit() }
        center()
    }

    private func fit() {
        fittedFor = bounds.size
        let size = imageView.image?.size ?? .zero
        guard size.width > 0, size.height > 0 else { return }
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        let fitted = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fitted
        // Far enough in to read a card's text on a phone.
        maximumZoomScale = max(fitted * 8, 2)
        zoomScale = fitted
    }

    private func center() {
        let w = imageView.frame.width, h = imageView.frame.height
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - h) / 2), left: max(0, (bounds.width - w) / 2), bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(minimumZoomScale * 3, maximumZoomScale)
        let p = g.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}
