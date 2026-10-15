import AVFoundation
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

    struct Matched: Hashable { let cardId: String; let exact: Bool }
}

/// Live camera text reader. Calls `onLines` with the text it sees, top of the frame first, about five times a second;
/// `onLines` says whether the lines named a card. Vision's accurate recognizer reads as the phone does (the `accurate`
/// read in testdata/scan) until text in view names no card for a while (ScanLanguage), then with automatic language
/// detection (the `multi` read), so Japanese, Chinese and Korean cards read in their own script; nobody picks a
/// language. VisionKit's DataScanner can't switch like that: it reads with the first language it's given only, and
/// English first turns CJK into noise while Japanese first breaks Korean and Cyrillic.
struct CardTextScanner: UIViewRepresentable {
    let onLines: ([String]) -> Bool

    static var isAvailable: Bool {
        Coordinator.camera() != nil && ![.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
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
    }

    /// Runs the capture session and Vision on its own queue, one frame at a time (late frames are dropped).
    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        // Main thread only.
        var onLines: ([String]) -> Bool
        private var language = ScanLanguage(readers: 1)
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "site.table1.card-text", qos: .userInitiated)
        // On `queue` only.
        private var configured = false
        private var last = Date.distantPast
        private var detect = false
        private let latin = Coordinator.request(detect: false)
        private let anyScript = Coordinator.request(detect: true)

        init(onLines: @escaping ([String]) -> Bool) { self.onLines = onLines }

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
            guard now.timeIntervalSince(last) >= 0.18, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            last = now
            // The sensor is landscape; the app is portrait only.
            let request = detect ? anyScript : latin
            guard (try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right).perform([request])) != nil else { return }
            // Vision's origin is bottom-left: the top of the frame has the largest maxY.
            let lines = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { [self] in
                language.feed(matched: onLines(lines), text: !lines.isEmpty)
                let cjk = language.mode != .latin
                queue.async { [self] in detect = cjk }
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
    @State private var frames = ScanFrames()
    /// Cards taken this session, deleted ones included (a session with none is a miss if a card is then added by hand).
    @State private var taken = 0
    /// The row whose printing is being changed; the camera is off meanwhile, so nothing is taken behind it.
    @State private var fixing: UUID?
    private var catalog: CatalogStore { CatalogStore.shared }

    var body: some View {
        if let id = fixing, let card = cards.first(where: { $0.id == id }) {
            ScanPrintingView(card: card, owned: owned, onPick: { p in
                ScanReports.printingChanged(card, to: p.cardId, ownedOnly: owned != nil)
                if let i = cards.firstIndex(where: { $0.id == id }) {
                    cards[i].printing = p
                    cards[i].fixed = true
                    if !p.finishList.contains(where: { $0.rawValue == cards[i].finish }) { cards[i].finish = matcher?.defaultFinish(p) ?? cards[i].finish }
                }
                closePrinting()
            }, onClose: closePrinting)
        } else {
            scanner
        }
    }

    private func cancel() {
        ScanReports.scannerClosed(taken: taken, frames: frames, ownedOnly: owned != nil)
        onCancel()
    }

    private func closePrinting() {
        fixing = nil
        steady = ScanSteadiness()
        frames = ScanFrames()
    }

    private var scanner: some View {
        T1Screen {
            Bar(title: title, subtitle: cards.isEmpty ? (owned == nil ? "Hold a card flat in the frame" : "Matching cards you own")
                                                      : "\(count) scanned", back: cancel)
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

    /// One frame's lines; true when they name a card.
    private func see(_ lines: [String]) -> Bool {
        guard let matcher else { return false }
        frames.add(lines)
        let m = matcher.match(lines)
        reading = m.map { $0.oracle.name }
        guard let taken = steady.feed(m), let m else { return m != nil }
        var card = ScannedCard(oracle: m.oracle, printing: taken.0, finish: matcher.defaultFinish(taken.0),
                               condition: owned == nil ? condition : "NM", exact: taken.1)
        card.frames = frames.frames
        card.matched = .init(cardId: taken.0.cardId, exact: taken.1)
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
                                 c.exact || c.fixed ? nil : "Check printing"].compactMap { $0 }.joined(separator: " · ")) {
                    LabelText("Printing", color: c.exact || c.fixed ? T1.muted : T1.text)
                }
            }.buttonStyle(.plain)
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
