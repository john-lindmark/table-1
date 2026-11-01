import AVFoundation
import CoreImage
import SwiftUI
import Vision

/* Card scanning (camera). On-device only: Vision reads the text on the card (in whatever script it detects), the
   name is matched against the local catalog pack, and the set code / collector number printed at the bottom picks
   the printing. A card is accepted once the same name has held steady across frames; it isn't taken again until it
   leaves the frame. The Scryfall API is never called per frame. */

/// One card the scanner accepted.
struct ScannedCard: Identifiable, Hashable {
    let id = UUID()
    var oracle: CatalogOracle
    var printing: CatalogPrinting
    var finish: String
    var condition: String
    /// Read from the card's set code and collector number, not a fallback to the default printing.
    let exact: Bool
    /// The OCR lines of the frames that led to the take, oldest first (sent with a correction, ScanReports).
    var frames: [[String]] = []
    /// What the matcher picked; stays as it was when the user fixes the row.
    var matched: Matched? = nil
    /// The user fixed this row: the printing is theirs, not a guess.
    var fixed = false
    /// The language the copy goes in as: its printing's when that isn't English, else the language of the printed
    /// name read (Languages.forScan), else the one picked for adds.
    var lang = "en"

    struct Matched: Hashable { let cardId: String; let exact: Bool }
}

/// Live camera text reader. Calls `onLines` with the text it sees, top of the frame first, about five times a second;
/// `onLines` says whether the lines named a card. Vision's accurate recognizer reads as the phone does (the `accurate`
/// read in testdata/scan) until text in view names no card for a while (ScanLanguage), then with automatic language
/// detection (the `multi` read), so Japanese, Chinese and Korean cards read in their own script; nobody picks a
/// language. VisionKit's DataScanner can't switch like that: it reads with the first language it's given only, and
/// English first turns CJK into noise while Japanese first breaks Korean and Cyrillic.
struct CardTextScanner: UIViewRepresentable {
    /// One frame's lines, top first, and whether they're from inside a card found in the frame; returns true when
    /// they name a card.
    let onLines: ([String], Bool) -> Bool

    static var isAvailable: Bool {
        Coordinator.camera() != nil && ![.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let coordinator = context.coordinator
        view.onSize = { coordinator.viewSize($0) }
        view.preview.session = context.coordinator.session
        view.preview.videoGravity = .resizeAspectFill
        context.coordinator.start()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onLines = onLines
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLines: onLines) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onSize: ((CGSize) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onSize?(bounds.size)
        }
    }

    /// Runs the capture session and Vision on its own queue, one frame at a time (late frames are dropped).
    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        // Main thread only.
        var onLines: ([String], Bool) -> Bool
        private var language = ScanLanguage(readers: 1)
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "site.table1.card-text", qos: .userInitiated)
        // On `queue` only.
        private var configured = false
        private var last = Date.distantPast
        private var detect = false
        /// Whether the main thread is still matching the last frame handed to it: a frame that arrives meanwhile is
        /// dropped like a late video frame, so a slow match never builds a backlog that lags the rest of the session
        /// (2026-10-31: frames were queued on the main thread faster than the matcher cleared them).
        private var matching = false
        private let latin = Coordinator.request(detect: false)
        private let anyScript = Coordinator.request(detect: true)
        private let cards = Coordinator.cardRequest()
        /// The card's bottom strip, read on its own (see `bottomLines`).
        private let strip = Coordinator.request(detect: false)
        private let ci = CIContext(options: [.cacheIntermediates: false])
        /// The preview's size (main thread writes it through `queue`), to place the guide box in the image.
        private var view: CGSize = .zero

        init(onLines: @escaping ([String], Bool) -> Bool) { self.onLines = onLines }

        func viewSize(_ size: CGSize) { queue.async { [self] in view = size } }

        /// Card-shaped rectangles (a card, sleeve or toploader is 0.63–0.75 wide for its height), a fifth of the frame
        /// or more. A few milliseconds, run in the same pass as the text.
        private static func cardRequest() -> VNDetectRectanglesRequest {
            let r = VNDetectRectanglesRequest()
            r.minimumAspectRatio = 0.6
            r.maximumAspectRatio = 0.85
            r.minimumSize = 0.2
            r.maximumObservations = 4
            r.quadratureTolerance = 20
            r.minimumConfidence = 0.6
            return r
        }

        /// The upright card-shaped rectangle (a landscape one is usually the art box) in the guide box, nearest its
        /// centre (`ScanRegion.pick`), so cards lying around the one being scanned are never read; the largest when
        /// the guide isn't placed yet. Grown 10% from its centre so the title and bottom line are inside even when
        /// the frame inside the border is what was found.
        private static func card(_ found: [VNRectangleObservation], guide: CGRect?, image: CGSize) -> VNRectangleObservation? {
            // Normalized to the portrait frame: compare the sides in pixels.
            func len(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot((a.x - b.x) * image.width, (a.y - b.y) * image.height) }
            let upright = found.filter { len($0.topLeft, $0.bottomLeft) > len($0.topLeft, $0.topRight) }
            if let guide {
                return ScanRegion.pick(upright.map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] }, guide: guide, image: image)
                    .map { upright[$0] }
            }
            return upright.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        }

        private static func grown(_ o: VNRectangleObservation) -> [CGPoint] {
            let q = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft]
            let c = CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
            return q.map { CGPoint(x: c.x + ($0.x - c.x) * 1.1, y: c.y + ($0.y - c.y) * 1.1) }
        }

        /// The card's bottom strip read on its own (2026-10-28): the card deskewed to 630 × 880, its bottom 11% cropped
        /// and upscaled 2x, then read. That strip holds the set code, collector number, copyright year and the
        /// "Illus." credit, printed too small for the whole-frame read to get on most frames: retro-frame reprints
        /// (MH2's fetchlands) went in as their first printing with "Check printing" because only the name and rules
        /// text read. A few tens of milliseconds; measured on the photo set as the `bottom` read in testdata/scan.
        private func bottomLines(_ pixels: CVPixelBuffer, _ o: VNRectangleObservation, image: CGSize) -> [String] {
            let f = CIFilter(name: "CIPerspectiveCorrection")!
            // Upright like Vision's results, with its origin at zero so the normalized corners scale onto it.
            let src = CIImage(cvPixelBuffer: pixels).oriented(.right)
            f.setValue(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), forKey: kCIInputImageKey)
            for (key, p) in [("inputTopLeft", o.topLeft), ("inputTopRight", o.topRight), ("inputBottomRight", o.bottomRight), ("inputBottomLeft", o.bottomLeft)] {
                f.setValue(CIVector(x: p.x * image.width, y: p.y * image.height), forKey: key)
            }
            guard let card = f.outputImage else { return [] }
            let e = card.extent
            let upright = card.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: 630 / e.width, y: 880 / e.height))
            let crop = upright.cropped(to: CGRect(x: 0, y: 0, width: 630, height: 880 * 0.11)).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            guard let cg = ci.createCGImage(crop, from: crop.extent),
                  (try? VNImageRequestHandler(cgImage: cg).perform([strip])) != nil else { return [] }
            return (strip.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }.compactMap { $0.topCandidates(1).first?.string }
        }

        /// Whether p is inside the convex quad q.
        private static func inside(_ p: CGPoint, _ q: [CGPoint]) -> Bool {
            var sign: CGFloat = 0
            for i in 0..<4 {
                let a = q[i], b = q[(i + 1) % 4]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
            }
            return true
        }

        private static func request(detect: Bool) -> VNRecognizeTextRequest {
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = .accurate
            r.usesLanguageCorrection = true
            r.automaticallyDetectsLanguage = detect
            return r
        }

        /// The back camera; on phones with an ultra wide, the virtual device that switches to it up close, since a
        /// card held near the lens is inside the wide camera's minimum focus distance.
        static func camera() -> AVCaptureDevice? {
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
                mediaType: .video, position: .back
            ).devices.first
        }

        func start() {
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                guard granted else { return }
                queue.async { [self] in
                    if !configured { configure() }
                    if configured && !session.isRunning { session.startRunning() }
                }
            }
        }

        func stop() {
            queue.async { [self] in if session.isRunning { session.stopRunning() } }
        }

        private func configure() {
            guard let device = Self.camera(), let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .hd1920x1080
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            if (try? device.lockForConfiguration()) != nil {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
                // A virtual device starts on its widest lens; frame like the wide camera and let it switch down close.
                if let wide = device.virtualDeviceSwitchOverVideoZoomFactors.first { device.videoZoomFactor = CGFloat(truncating: wide) }
                device.unlockForConfiguration()
            }
            configured = true
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            // Frames about 200 ms apart, like the movement clips ScanSteadiness was tuned on.
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.18, !matching, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            last = now
            // The sensor is landscape; the app is portrait only.
            let request = detect ? anyScript : latin
            let image = CGSize(width: CVPixelBufferGetHeight(pixels), height: CVPixelBufferGetWidth(pixels))
            let guide = view.width > 0 ? ScanRegion.normalized(ScanRegion.viewBox(view), view: view, image: image) : nil
            // Text is read only around the guide (a card held a little off it still fits): fewer pixels per frame,
            // so frames come faster. Rectangles are found in the whole frame; they cost little.
            request.regionOfInterest = guide.map(ScanRegion.reading) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            guard (try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right).perform([cards, request])) != nil else { return }
            // With a card in the guide, only the text on it: a keyboard, a screen or another card beside it can't name
            // a card. Without one, only the text inside the guide.
            let found = Self.card(cards.results ?? [], guide: guide, image: image)
            let card = found.map(Self.grown)
            let reading = guide.map { ScanRegion.grown($0, 0.1) }
            // Vision's origin is bottom-left: the top of the frame has the largest maxY.
            var lines = (request.results ?? [])
                .filter { o in
                    let c = CGPoint(x: o.boundingBox.midX, y: o.boundingBox.midY)
                    if let card { return Self.inside(c, card) }
                    return reading?.contains(c) ?? true
                }
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
            if let found { lines += bottomLines(pixels, found, image: image) }
            let onCard = card != nil
            matching = true
            DispatchQueue.main.async { [self] in
                language.feed(matched: onLines(lines, onCard), text: !lines.isEmpty)
                let cjk = language.mode != .latin
                queue.async { [self] in detect = cjk; matching = false }
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
    /// Owned-only: printing id → finishes in for-trade binders, preferred when the text doesn't settle the printing.
    var preferred: [String: Set<String>] = [:]
    let onDone: ([ScannedCard]) -> Void
    let onCancel: () -> Void

    init(title: String, doneLabel: String, owned: [String: Set<String>]? = nil, preferred: [String: Set<String>] = [:],
         scanned: [ScannedCard] = [], onDone: @escaping ([ScannedCard]) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.doneLabel = doneLabel
        self.owned = owned
        self.preferred = preferred
        self.onDone = onDone
        self.onCancel = onCancel
        // Rows already taken (the redraw measurement in ScannerPerfTests).
        _cards = State(initialValue: scanned)
    }

    @AppStorage("library.addCondition") private var condition = "NM"
    @AppStorage("library.addLang") private var addLang = "en"
    @State private var cards: [ScannedCard] = []
    /// The row whose language is being changed; the camera is off meanwhile, like `fixing`.
    @State private var languageFor: UUID?
    @State private var matcher: CardMatcher?
    @State private var reading: String?
    /// What every camera frame feeds; the body never reads it, so no frame redraws the screen.
    @State private var feed = Feed()
    /// Cards taken this session, deleted ones included (a session with none is a miss if a card is then added by hand).
    @State private var taken = 0
    /// The row whose printing is being changed; the camera is off meanwhile, so nothing is taken behind it.
    @State private var fixing: UUID?
    @State private var listHeight: CGFloat = 0
    private var catalog: CatalogStore { CatalogStore.shared }

    /// The steadiness and frame memory every camera frame feeds, in a class: as `@State` structs, written about five
    /// times a second, each frame re-evaluated the whole body, the scanned rows included, so a frame cost more for
    /// every card taken (2026-11-01; `reading` had been given the same care on 2026-10-31, but these two were still
    /// written). A class held in `@State` is one instance for the screen's life, and writes to its properties redraw
    /// nothing. Kept internal for the test that pins this.
    final class Feed {
        var steady = ScanSteadiness()
        var frames = ScanFrames()
    }

    var body: some View {
        if let id = fixing, let card = cards.first(where: { $0.id == id }) {
            ScanPrintingView(card: card, owned: owned, onPick: { p in
                ScanReports.printingChanged(card, to: p.cardId, ownedOnly: owned != nil)
                matcher?.picked(p)
                if let i = cards.firstIndex(where: { $0.id == id }) {
                    cards[i].printing = p
                    cards[i].fixed = true
                    if p.lang != "en" { cards[i].lang = p.lang }
                    if !p.finishList.contains(where: { $0.rawValue == cards[i].finish }) { cards[i].finish = matcher?.defaultFinish(p) ?? cards[i].finish }
                }
                closePrinting()
            }, onClose: closePrinting)
        } else if let id = languageFor, let card = cards.first(where: { $0.id == id }) {
            LanguagePicker(current: card.lang, subtitle: card.oracle.name, pick: { lang in
                if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].lang = lang }
                languageFor = nil
                closePrinting()
            }, cancel: { languageFor = nil; closePrinting() })
        } else {
            scanner
        }
    }

    private func cancel() {
        ScanReports.scannerClosed(taken: taken, frames: feed.frames, ownedOnly: owned != nil)
        onCancel()
    }

    private func closePrinting() {
        fixing = nil
        feed.steady = ScanSteadiness()
        feed.frames = ScanFrames()
    }

    private var scanner: some View {
        T1Screen {
            Bar(title: title, subtitle: cards.isEmpty ? (owned == nil ? "Hold a card flat in the frame" : "Matching cards you own")
                                                      : "\(count) scanned", back: cancel)
            if !CardTextScanner.isAvailable {
                Notice("The camera isn't available. Allow camera access for Table 1 in Settings, or search by name instead.", error: true)
                Spacer(minLength: 0)
            } else if catalog.phase != .ready {
                CatalogStatusRow(catalog: catalog)
                Spacer(minLength: 0)
            } else {
                // The camera takes whatever the header, condition picker, scanned list and footer leave.
                CardTextScanner { lines, onCard in see(lines, onCard: onCard) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { ScanGuide(reading: reading) }
                    .clipped()
                    // Keep the screen on while the camera is reading; picking a printing or language turns it off.
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            }
            if owned == nil {
                T1Segmented(options: Conditions.all.map { ($0, $0) }, selection: $condition)
            }
            if !cards.isEmpty {
                // Sized to its rows, up to about three, so the camera keeps most of the screen.
                // Not HairlineList: that is a lazy ScrollView of its own, which only laid out new rows once scrolled.
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach($cards) { $card in row($card) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, 210))
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
        let owned = owned, preferred = preferred
        Task { matcher = await Task.detached(priority: .userInitiated) { CardMatcher(db: db, owned: owned, preferred: preferred) }.value }
    }

    private var count: Int { cards.count }

    /// One frame's lines; true when they name a card. Without a card found in the frame, the text must look like a
    /// card's: a type line, or a set code and number that agree with the name. Otherwise a keyboard's "option" key
    /// is Opt (its French name) and a decklist on a screen is a card.
    private func see(_ lines: [String], onCard: Bool) -> Bool {
        guard let matcher else { return false }
        var m = matcher.match(lines)
        if !onCard, m?.exact != true, !CardMatcher.hasTypeLine(lines) { m = nil }
        feed.frames.add(lines, named: m != nil)
        // Set only when it changes: every frame redrew the screen, scanned rows included.
        let name = m.map { $0.oracle.name }
        if reading != name { reading = name }
        guard let taken = feed.steady.feed(m), let m else { return m != nil }
        var card = ScannedCard(oracle: m.oracle, printing: taken.0, finish: matcher.defaultFinish(taken.0),
                               condition: owned == nil ? condition : "NM", exact: taken.1)
        // Owned-only scans (giving in a trade) keep the owned copy's language.
        card.lang = owned == nil ? Languages.forScan(taken.0, read: m.langs, picked: addLang) : Languages.forNew(taken.0, picked: addLang)
        card.frames = feed.frames.frames
        card.matched = .init(cardId: taken.0.cardId, exact: taken.1)
        feed.frames.took()
        matcher.took()
        self.taken += 1
        cards.insert(card, at: 0)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    private func row(_ card: Binding<ScannedCard>) -> some View {
        let c = card.wrappedValue
        let finishes = c.printing.finishList
        return HStack(spacing: 1) {
            // Tap the card to change its printing (a misread set code or collector number).
            Button { fixing = c.id } label: {
                CardRow(printing: c.printing, title: c.oracle.name,
                        detail: [c.printing.setLabel, Finish(rawValue: c.finish)?.label, owned == nil ? c.condition : nil,
                                 owned == nil && c.lang != "en" ? c.lang.uppercased() : nil,
                                 c.exact || c.fixed ? nil : "Check printing"].compactMap { $0 }.joined(separator: " · "),
                        finish: c.finish) {
                    LabelText("Printing", color: c.exact || c.fixed ? T1.muted : T1.text)
                }
            }.buttonStyle(.plain)
            if owned == nil {
                // The language: the printing's or the printed name's the scanner read, else the add default.
                Button { languageFor = c.id } label: {
                    LabelText(c.lang.uppercased(), color: T1.text)
                        .padding(.horizontal, 12).frame(maxHeight: .infinity).background(T1.surfaceHover)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Language, \(Languages.name(c.lang))")
            }
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
            Button {
                ScanReports.removed(c, ownedOnly: owned != nil)
                cards.removeAll { $0.id == c.id }
            } label: {
                Text("×").font(T1.mono(20)).frame(width: 52).frame(maxHeight: .infinity).background(T1.surfaceHover)
            }.buttonStyle(.plain).accessibilityLabel("Remove")
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(T1.surface)
    }
}

/// Where the scanner looks: the guide box drawn over the camera, and where it lands in the camera image.
enum ScanRegion {
    /// The guide box in the camera view: 72% of the width (or what the height allows), card-shaped, centred.
    static func viewBox(_ size: CGSize) -> CGRect {
        let w = max(0, min(size.width * 0.72, (size.height - 96) * CardArt.aspect))
        let h = w / CardArt.aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// A rect in the preview (which fills the view with the upright image, cropping the overflow) in Vision's
    /// normalized image coordinates (origin bottom-left).
    static func normalized(_ r: CGRect, view: CGSize, image: CGSize) -> CGRect {
        let s = max(view.width / image.width, view.height / image.height)
        let ox = (view.width - image.width * s) / 2, oy = (view.height - image.height * s) / 2
        let x = (r.minX - ox) / s / image.width, w = r.width / s / image.width
        let top = (r.minY - oy) / s / image.height, h = r.height / s / image.height
        return CGRect(x: x, y: 1 - top - h, width: w, height: h)
    }

    static func grown(_ r: CGRect, _ f: CGFloat) -> CGRect { r.insetBy(dx: -r.width * f / 2, dy: -r.height * f / 2) }

    /// Where text is read: the guide grown by half, inside the image, so a card whose centre is anywhere `pick`
    /// accepts (the guide grown by a quarter) is read whole, and the rest of the frame costs nothing.
    static func reading(_ guide: CGRect) -> CGRect {
        grown(guide, 0.5).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Of card-shaped quads (normalized corners), the one to read: its centre inside the guide grown by a quarter
    /// (a card held a little off still counts), nearest the guide's centre in pixels. Nil when none is in the guide.
    static func pick(_ quads: [[CGPoint]], guide: CGRect, image: CGSize) -> Int? {
        let zone = grown(guide, 0.25)
        func centre(_ q: [CGPoint]) -> CGPoint { CGPoint(x: q.map(\.x).reduce(0, +) / CGFloat(q.count), y: q.map(\.y).reduce(0, +) / CGFloat(q.count)) }
        func dist(_ p: CGPoint) -> CGFloat { hypot((p.x - guide.midX) * image.width, (p.y - guide.midY) * image.height) }
        return quads.indices.filter { zone.contains(centre(quads[$0])) }.min { dist(centre(quads[$0])) < dist(centre(quads[$1])) }
    }
}

/// What to point at: a card-sized outline with where the scanner reads (the name at the top, the set code and
/// collector number at the bottom left). The outline turns accent while a name is being read.
private struct ScanGuide: View {
    let reading: String?

    var body: some View {
        GeometryReader { geo in
            // The same box the scanner reads inside (ScanRegion).
            let box = ScanRegion.viewBox(geo.size)
            let w = box.width, h = box.height
            let line = reading == nil ? T1.text.opacity(0.7) : T1.accent
            VStack(spacing: 12) {
                tip(reading == nil ? "One card, upright, filling the outline" : reading!, color: reading == nil ? T1.text : T1.accent)
                ZStack {
                    Rectangle().strokeBorder(line, lineWidth: 1)
                    VStack {
                        mark("Name")
                        Spacer()
                        HStack { mark("Set · number"); Spacer() }
                    }
                    .padding(8)
                }
                .frame(width: w, height: h)
                tip("Light from above, no glare", color: T1.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private func tip(_ text: String, color: Color) -> some View {
        LabelText(text, color: color).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4).background(T1.bg.opacity(0.8))
    }

    private func mark(_ text: String) -> some View {
        LabelText(text, color: T1.muted).padding(.horizontal, 6).padding(.vertical, 2).background(T1.bg.opacity(0.6))
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
