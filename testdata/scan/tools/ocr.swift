// Reads every photo in testdata/scan/photos.tsv with Apple Vision and writes testdata/scan/ocr.json: for each photo,
// the text lines top of the frame first (the order CardTextScanner hands the matcher) in four reads:
//   accurate  .accurate recognition at full size (close to VisionKit live text on a steady frame)
//   fast      .fast recognition (a quick or blurry frame)
//   small     .accurate at half size (the card further from the camera)
//   multi     .accurate with automatic language detection (Japanese, Chinese, Korean, Cyrillic read as such; the
//             scanner reads like this only once it asks for those languages, see testdata/scan/README.md)
//   title     the card's title bar read on its own, then `multi`: the card rectangle (VNDetectRectanglesRequest),
//             deskewed, its top 14% left of the mana cost cropped, upscaled 2x and read like `multi`. When no
//             card-shaped rectangle is found it is `multi` as is.
// The unit tests on iOS and Android run the matcher over these lines, so OCR runs once here, not in the tests.
//
// With `motion`, it writes testdata/scan/motion.json instead: for each photo, a 2.4 s clip of 12 frames (one every
// 200 ms) of a hand moving the card on all three axes, each frame read like `accurate`. The clip pans the card in x/y
// (sometimes partly out of frame), moves it toward and away from the camera, rolls and tilts it, and blurs each frame
// along its motion. Every third clip settles (moves in, then holds), every third shakes (tremor and slow drift), every
// third sweeps (large continuous movement). Paths are seeded by file name, so reruns give the same frames.
//
// Run from the repo root:  swift testdata/scan/tools/ocr.swift [motion]
import AppKit
import CoreImage
import Foundation
import Vision

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["T1_SCAN_ROOT"] ?? "testdata/scan")
let rows = try String(contentsOf: root.appending(path: "photos.tsv"), encoding: .utf8)
    .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }

func read(_ image: CGImage, level: VNRequestTextRecognitionLevel, detectLanguage: Bool = false) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.usesLanguageCorrection = level == .accurate
    request.automaticallyDetectsLanguage = detectLanguage
    try VNImageRequestHandler(cgImage: image).perform([request])
    let observations = request.results ?? []
    // Vision's origin is bottom-left: the top of the frame has the largest maxY.
    return observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        .compactMap { $0.topCandidates(1).first?.string }
}

func scaled(_ image: CGImage, _ s: Double) -> CGImage {
    let w = Int(Double(image.width) * s), h = Int(Double(image.height) * s)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

// MARK: title bar

let ci = CIContext(options: [.cacheIntermediates: false])

/// The card in the photo (the largest card-shaped rectangle), deskewed to an upright 630×880 image.
func card(_ image: CGImage) throws -> CIImage? {
    let r = VNDetectRectanglesRequest()
    r.minimumAspectRatio = 0.6
    r.maximumAspectRatio = 0.85
    r.minimumSize = 0.2
    r.maximumObservations = 4
    r.quadratureTolerance = 20
    try VNImageRequestHandler(cgImage: image).perform([r])
    guard let o = (r.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
    else { return nil }
    let w = CGFloat(image.width), h = CGFloat(image.height)
    var (tl, tr, br, bl) = (o.topLeft, o.topRight, o.bottomRight, o.bottomLeft)
    // A card lying sideways: the long side is its height.
    if hypot((tr.x - tl.x) * w, (tr.y - tl.y) * h) > hypot((tl.x - bl.x) * w, (tl.y - bl.y) * h) { (tl, tr, br, bl) = (tr, br, bl, tl) }
    let f = CIFilter(name: "CIPerspectiveCorrection")!
    f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    for (key, p) in [("inputTopLeft", tl), ("inputTopRight", tr), ("inputBottomRight", br), ("inputBottomLeft", bl)] {
        f.setValue(CIVector(x: p.x * w, y: p.y * h), forKey: key)
    }
    guard let out = f.outputImage else { return nil }
    let e = out.extent
    return out.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .transformed(by: CGAffineTransform(scaleX: 630 / e.width, y: 880 / e.height))
}

/// The title bar of a deskewed card: the top 14%, left of the mana cost, upscaled 2x.
func titleBar(_ card: CIImage) -> CGImage? {
    let rect = CGRect(x: 630 * 0.04, y: 880 * 0.86, width: 630 * 0.76, height: 880 * 0.14)
    let crop = card.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
    return ci.createCGImage(crop, from: crop.extent)
}

func readTitle(_ image: CGImage) throws -> [String] {
    guard let c = try card(image), let bar = titleBar(c) else { return [] }
    return try read(bar, level: .accurate, detectLanguage: true)
}

// MARK: movement

/// Deterministic per-file random numbers (SplitMix64 seeded from the file name).
struct Seeded {
    var state: UInt64
    init(_ s: String) { state = s.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 } }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

/// Where the hand holds the card at time t: pan (fractions of the frame), zoom, roll (radians), tilt (fractions).
struct Pose { var x = 0.0, y = 0.0, z = 1.0, roll = 0.0, pitch = 0.0, yaw = 0.0 }

/// One axis of movement: two sine waves plus a drift, scaled by an envelope.
struct Wave {
    let a1, f1, p1, a2, f2, p2, drift: Double
    init(_ r: inout Seeded, amplitude: Double) {
        a1 = amplitude * r.range(0.5, 1); f1 = r.range(0.3, 1.2); p1 = r.range(0, 2 * .pi)
        a2 = amplitude * r.range(0.02, 0.05); f2 = r.range(3, 7); p2 = r.range(0, 2 * .pi) // hand tremor
        drift = amplitude * r.range(-0.4, 0.4)
    }
    func at(_ t: Double, envelope e: Double) -> Double {
        e * a1 * sin(2 * .pi * f1 * t + p1) + a2 * sin(2 * .pi * f2 * t + p2) + drift * t / 2.4
    }
}

func path(_ file: String, kind: Int) -> (Double) -> Pose {
    var r = Seeded(file)
    // settle: large, decaying; shake: small throughout; sweep: large throughout.
    let scale = [1.0, 0.2, 1.0][kind]
    let x = Wave(&r, amplitude: 0.14 * scale), y = Wave(&r, amplitude: 0.12 * scale)
    let z = Wave(&r, amplitude: 0.22 * scale), roll = Wave(&r, amplitude: 0.16 * scale)
    let pitch = Wave(&r, amplitude: 0.07 * scale), yaw = Wave(&r, amplitude: 0.07 * scale)
    return { t in
        let e = kind == 0 ? exp(-t / 0.6) : 1
        return Pose(x: x.at(t, envelope: e), y: y.at(t, envelope: e), z: 1 + z.at(t, envelope: e),
                    roll: roll.at(t, envelope: e), pitch: pitch.at(t, envelope: e), yaw: yaw.at(t, envelope: e))
    }
}

/// The frame the camera sees for a pose, blurred along the card's movement since the previous frame.
func frame(_ image: CGImage, _ p: Pose, previous q: Pose) -> CGImage {
    let w = Double(image.width), h = Double(image.height)
    func corner(_ u: Double, _ v: Double, _ p: Pose) -> CGPoint {
        // u, v in -0.5...0.5 around the centre; tilt moves opposite edges toward/away from the camera.
        let persp = 1 + p.pitch * v * 2 + p.yaw * u * 2
        var px = u * w * p.z * persp, py = v * h * p.z * persp
        (px, py) = (px * cos(p.roll) - py * sin(p.roll), px * sin(p.roll) + py * cos(p.roll))
        return CGPoint(x: w / 2 + px + p.x * w, y: h / 2 + py + p.y * h)
    }
    let src = CIImage(cgImage: image)
    let filter = CIFilter(name: "CIPerspectiveTransform")!
    filter.setValue(src, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgPoint: corner(-0.5, 0.5, p)), forKey: "inputTopLeft")
    filter.setValue(CIVector(cgPoint: corner(0.5, 0.5, p)), forKey: "inputTopRight")
    filter.setValue(CIVector(cgPoint: corner(0.5, -0.5, p)), forKey: "inputBottomRight")
    filter.setValue(CIVector(cgPoint: corner(-0.5, -0.5, p)), forKey: "inputBottomLeft")
    // Whatever the photo moved away from shows the same surface, smeared: the photo itself, blurred, behind it.
    let behind = src.clampedToExtent().applyingGaussianBlur(sigma: 24)
    guard let moved = filter.outputImage else { fatalError("perspective failed") }
    var out = moved.composited(over: behind)
    // About a 1/60 s exposure against 200 ms between frames: the blur is a twelfth of the distance moved.
    let dx = (p.x - q.x) * w, dy = (p.y - q.y) * h
    let spin = abs(p.roll - q.roll) * h / 2 + abs(p.z - q.z) * h / 2
    let radius = (hypot(dx, dy) + spin) / 12
    if radius > 0.5 {
        out = out.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(dy, dx)])
    }
    guard let cg = ci.createCGImage(out, from: src.extent) else { fatalError("render failed") }
    return cg
}

if CommandLine.arguments.dropFirst().first == "motion" {
    var clips: [String: [[String]]] = [:]
    for (i, row) in rows.enumerated() {
        let file = row[0]
        guard let ns = NSImage(contentsOf: root.appending(path: "photos/\(file)")),
              let image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let pose = path(file, kind: i % 3)
        clips[file] = try (0..<12).map { k in
            let t = Double(k) * 0.2
            let f = frame(image, pose(t), previous: pose(max(0, t - 0.2)))
            if let dump = ProcessInfo.processInfo.environment["T1_DUMP_FRAMES"], i < 3 { // to look at the clips
                let rep = NSBitmapImageRep(cgImage: f)
                try rep.representation(using: .jpeg, properties: [:])!.write(to: URL(fileURLWithPath: "\(dump)/\(i)-\(k).jpg"))
            }
            return try read(f, level: .accurate)
        }
        if ProcessInfo.processInfo.environment["T1_DUMP_FRAMES"] != nil, i == 2 { exit(0) }
        FileHandle.standardError.write("\(file)\n".data(using: .utf8)!)
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(clips).write(to: root.appending(path: "motion.json"))
    print("\(clips.count) clips")
    exit(0)
}

var out: [String: [String: [String]]] = [:]
for row in rows {
    let file = row[0]
    guard let ns = NSImage(contentsOf: root.appending(path: "photos/\(file)")),
          let image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("can't read \(file)\n".data(using: .utf8)!)
        continue
    }
    let multi = try read(image, level: .accurate, detectLanguage: true)
    out[file] = [
        "accurate": try read(image, level: .accurate),
        "fast": try read(image, level: .fast),
        "small": try read(scaled(image, 0.5), level: .accurate),
        "multi": multi,
        "title": try readTitle(image) + multi,
    ]
    FileHandle.standardError.write("\(file): \(out[file]!["accurate"]!.first ?? "-")\n".data(using: .utf8)!)
}
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try enc.encode(out).write(to: root.appending(path: "ocr.json"))
print("\(out.count) photos")
