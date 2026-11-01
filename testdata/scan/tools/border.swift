// Border colour of old-frame cards, read from the photos in testdata/scan/photos.tsv, and the luma samples the
// scanners' border rule (`ScanBorder`, apps/ios/Table1/Library/CardScanner.swift / apps/android/.../library/
// ScanBorder.kt) reads, written to testdata/scan/border.json so the unit tests on both platforms run the same rule
// over the same samples without images.
//
// Alpha, Beta and Foreign Black Border cards have black borders; Unlimited and Revised white ones, and nothing printed
// on a 1993–94 card tells them apart (README § Printings). So each photo is sampled two ways:
// border.json keeps `quad`, `dim.quad`, `g100` and `dim.g100` (the scale-1 guide); the others are only tallied here.
//   quad    as the iOS scanner reads: the card-shaped rectangle Vision finds (the largest upright one, the same
//           request as CardTextScanner), luma just inside each side (1.5% and 3% of the card's width, six points a
//           side) and just outside (the same, outward).
//   guide   as the Android scanner reads, where ML Kit finds no rectangle: the guide box stands for the card, here
//           the rectangle's bounding box scaled 0.94 / 1.0 / 1.06 and shifted a little (the card never fills the
//           outline exactly), and along each side a luma profile from 12% outside to 12% inside finds the card's edge
//           (the strongest step), then the same inside/outside samples around it.
// Both again on a dim, low-contrast copy of the photo (`dim`: contrast 0.55, brightness −0.12, a little blur), the
// kind of frame a phone sees in a dim room.
//
// Expected border: `white-border` in the photo's tags → white, `borderless` → none (skipped), else black (every other
// card, modern ones included, has a black border). Luma is 0.299 R + 0.587 G + 0.114 B of the JPEG (full range, as the
// phones' Y plane is scaled to).
//
// Run from the repo root:  swift testdata/scan/tools/border.swift [check]
//   check   also runs the classification in this file (the reference copy of ScanBorder.classify) over the samples
//           and prints accuracy per read, and checks the orientation mapping the iOS scanner uses to read the camera's
//           landscape pixel buffer from Vision's upright, normalized rectangle.
import AppKit
import CoreImage
import CoreVideo
import Foundation
import Vision

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["T1_SCAN_ROOT"] ?? "testdata/scan")
let rows = try String(contentsOf: root.appending(path: "photos.tsv"), encoding: .utf8)
    .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
let check = CommandLine.arguments.dropFirst().first == "check"
let ci = CIContext(options: [.cacheIntermediates: false])

// MARK: luma

/// A photo's luma, one byte per pixel, origin top-left.
struct Luma {
    let width: Int, height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width; height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = (0..<(width * height)).map { i in
            let r = Double(rgba[i * 4]), g = Double(rgba[i * 4 + 1]), b = Double(rgba[i * 4 + 2])
            return UInt8(max(0, min(255, (0.299 * r + 0.587 * g + 0.114 * b).rounded())))
        }
    }

    /// Luma at a pixel, clamped to the image.
    func at(_ p: CGPoint) -> Int {
        let x = max(0, min(width - 1, Int(p.x.rounded()))), y = max(0, min(height - 1, Int(p.y.rounded())))
        return Int(bytes[y * width + x])
    }
}

// MARK: the rule (reference copy of ScanBorder on iOS and Android; change all three together)

/// Where a side's samples are taken: six points along it, 15–85% of its length.
let along: [Double] = [0.15, 0.29, 0.43, 0.57, 0.71, 0.85]
/// Offsets from the edge, as fractions of the card's width: a 1993–94 border is about 4.5% wide.
let depths: [Double] = [0.015, 0.03]
/// Further out, past where a border would end: the table, when the rectangle was the card's edge; sampled to tell a
/// border plateau outside a rectangle that was the frame inside the border (a step between the two) from a table
/// that just goes on (no step).
let farDepths: [Double] = [0.065, 0.09]

/// Luma just inside and just outside each side of a quad (top, right, bottom, left; corners TL, TR, BR, BL in pixels,
/// origin top-left): twelve samples a side.
func quadSamples(_ q: [CGPoint], _ luma: Luma) -> (inside: [[Int]], outside: [[Int]], far: [[Int]]) {
    let w = (hypot(q[1].x - q[0].x, q[1].y - q[0].y) + hypot(q[2].x - q[3].x, q[2].y - q[3].y)) / 2
    let c = CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
    var inside: [[Int]] = [], outside: [[Int]] = [], far: [[Int]] = []
    for k in 0..<4 {
        let a = q[k], b = q[(k + 1) % 4]
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let len = max(1, hypot(c.x - mid.x, c.y - mid.y))
        let n = CGPoint(x: (c.x - mid.x) / len, y: (c.y - mid.y) / len) // inward
        var ins: [Int] = [], outs: [Int] = [], fars: [Int] = []
        for t in along {
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            for d in depths {
                ins.append(luma.at(CGPoint(x: p.x + n.x * w * d, y: p.y + n.y * w * d)))
                outs.append(luma.at(CGPoint(x: p.x - n.x * w * d, y: p.y - n.y * w * d)))
            }
            for d in farDepths { fars.append(luma.at(CGPoint(x: p.x - n.x * w * d, y: p.y - n.y * w * d))) }
        }
        inside.append(ins); outside.append(outs); far.append(fars)
    }
    return (inside, outside, far)
}

/// Where the card's text box is sampled, as fractions of the card's width and height (u right, v down): paper and
/// ink there are the frame's own white and black (the text box of every 1993–2003 card is light with dark text).
let innerU: [Double] = [0.2, 0.32, 0.44, 0.56, 0.68, 0.8]
let innerV: [Double] = [0.66, 0.72, 0.78, 0.84]

/// Luma at points inside a quad (bilinear in its corners TL, TR, BR, BL).
func innerSamples(_ q: [CGPoint], _ luma: Luma) -> [Int] {
    innerV.flatMap { v in innerU.map { u in
        let top = CGPoint(x: q[0].x + (q[1].x - q[0].x) * u, y: q[0].y + (q[1].y - q[0].y) * u)
        let bottom = CGPoint(x: q[3].x + (q[2].x - q[3].x) * u, y: q[3].y + (q[2].y - q[3].y) * u)
        return luma.at(CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v))
    } }
}

func boxQuad(_ g: CGRect) -> [CGPoint] {
    [CGPoint(x: g.minX, y: g.minY), CGPoint(x: g.maxX, y: g.minY), CGPoint(x: g.maxX, y: g.maxY), CGPoint(x: g.minX, y: g.maxY)]
}

/// The profile's steps, as the Android scanner walks them: from 12% outside the guide's side to 12% inside, in
/// steps of 1% of the guide's width (25 samples), at each of the six points along the side.
let profileSteps = 25
let profileSpan = 0.12

/// Luma along each side of an axis-aligned guide box (x, y, w, h in pixels): six profiles a side, outside first.
func guideProfiles(_ g: CGRect, _ luma: Luma) -> [[[Int]]] {
    let sides: [(CGPoint, CGPoint, CGPoint)] = [ // start, end, inward unit
        (CGPoint(x: g.minX, y: g.minY), CGPoint(x: g.maxX, y: g.minY), CGPoint(x: 0, y: 1)),
        (CGPoint(x: g.maxX, y: g.minY), CGPoint(x: g.maxX, y: g.maxY), CGPoint(x: -1, y: 0)),
        (CGPoint(x: g.maxX, y: g.maxY), CGPoint(x: g.minX, y: g.maxY), CGPoint(x: 0, y: -1)),
        (CGPoint(x: g.minX, y: g.maxY), CGPoint(x: g.minX, y: g.minY), CGPoint(x: 1, y: 0)),
    ]
    return sides.map { a, b, n in
        along.map { t in
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            return (0..<profileSteps).map { k in
                let d = (-profileSpan + Double(k) * (2 * profileSpan) / Double(profileSteps - 1)) * g.width
                return luma.at(CGPoint(x: p.x + n.x * d, y: p.y + n.y * d))
            }
        }
    }
}

/// From a side's profiles, the inside and outside samples around the card's edge: in each profile the strongest step
/// is the edge; the two samples inward of it are "inside" (about 1–2% in), the two outward "outside".
func edgeSamples(_ profiles: [[Int]]) -> (inside: [Int], outside: [Int], far: [Int]) {
    var inside: [Int] = [], outside: [Int] = [], far: [Int] = []
    for s in profiles {
        var e = profileSteps / 2, best = 0
        for k in 2..<(profileSteps - 2) where abs(s[k] - s[k - 1]) > best { best = abs(s[k] - s[k - 1]); e = k }
        inside += [s[min(profileSteps - 1, e + 1)], s[min(profileSteps - 1, e + 2)]]
        outside += [s[max(0, e - 2)], s[max(0, e - 3)]]
        far += [s[max(0, e - 7)], s[max(0, e - 9)]]
    }
    return (inside, outside, far)
}

enum Border: String { case black, white, unknown }

/// Luma at or under this is black, at or over the other white, whatever the card (a phone's auto exposure keeps a
/// card about this bright); in between, the card's own text box decides (below), so a dim, low-contrast frame still
/// reads: its black is `ink`, its white `paper`.
let blackAtMost = 70, whiteAtLeast = 165
/// Relative to the text box (0 = its ink, 1 = its paper): a border this far below the paper is black, this far
/// above the ink white, within these absolute bounds (so a lit black border or a greyed white one still counts, but
/// not frame texture), when the text box has this much contrast.
let blackBelow = 0.25, whiteAbove = 0.9, blackAbsMax = 115, whiteAbsMin = 140, textBoxContrast = 50
/// A border plateau outside the rectangle found ends in a step this big (relative to the text box; in luma when it
/// has no contrast) to the table beyond it; a table just goes on.
let plateauStep = 0.3, plateauStepLuma = 45

func upperMedian(_ a: [Int]) -> Int { a.sorted()[a.count / 2] }

/// The border from the samples around a card's edge (`ScanBorder.classify` on iOS and Android; change all three
/// together): at least three of the four sides one colour just inside the edge and none the other; else, when the
/// inside is mostly neither (the rectangle was the frame inside the border), the same just outside, counting only
/// sides where the outside band steps to what lies beyond it (a border ends; a table doesn't).
func classify(inside: [[Int]], outside: [[Int]], far: [[Int]], inner: [Int]) -> Border {
    let sorted = inner.sorted()
    let ink = sorted.first ?? 0, paper = sorted[min(sorted.count - 1, sorted.count * 3 / 4)]
    let ref = paper - ink >= textBoxContrast
    func norm(_ m: Int) -> Double { Double(m - ink) / Double(paper - ink) }
    func shade(_ samples: [Int]) -> Border {
        let m = upperMedian(samples)
        if m <= blackAtMost || (ref && norm(m) <= blackBelow && m <= blackAbsMax) { return .black }
        if m >= whiteAtLeast || (ref && norm(m) >= whiteAbove && m >= whiteAbsMin) { return .white }
        return .unknown
    }
    func agree(_ shades: [Border]) -> Border {
        let black = shades.filter { $0 == .black }.count, white = shades.filter { $0 == .white }.count
        if black >= 3 && white == 0 { return .black }
        if white >= 3 && black == 0 { return .white }
        return .unknown
    }
    let ins = inside.map(shade)
    let a = agree(ins)
    if a != .unknown { return a }
    guard ins.filter({ $0 == .unknown }).count >= 3 else { return .unknown }
    let outs = (0..<4).map { k -> Border in
        let o = upperMedian(outside[k]), f = upperMedian(far[k])
        let step = ref ? abs(norm(o) - norm(f)) >= plateauStep : abs(o - f) >= plateauStepLuma
        return step ? shade(outside[k]) : .unknown
    }
    return agree(outs)
}

// MARK: rectangles

func rectangles(_ image: CGImage) throws -> [[CGPoint]] {
    let r = VNDetectRectanglesRequest()
    r.minimumAspectRatio = 0.6
    r.maximumAspectRatio = 0.85
    r.minimumSize = 0.2
    r.maximumObservations = 4
    r.quadratureTolerance = 20
    r.minimumConfidence = 0.6
    try VNImageRequestHandler(cgImage: image).perform([r])
    let w = CGFloat(image.width), h = CGFloat(image.height)
    func len(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot((a.x - b.x) * w, (a.y - b.y) * h) }
    // Upright ones only, largest first; Vision's origin is bottom-left, pixels are top-left.
    return (r.results ?? []).filter { len($0.topLeft, $0.bottomLeft) > len($0.topLeft, $0.topRight) }
        .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        .map { o in [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) } }
}

func bounds(_ q: [CGPoint]) -> CGRect {
    let xs = q.map(\.x), ys = q.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

/// The guide boxes standing for a card: the rectangle's bounds scaled and shifted a little (fractions of its width).
let guides: [(name: String, scale: Double, dx: Double, dy: Double)] = [("g094", 0.94, 0.02, -0.015), ("g100", 1, 0, 0), ("g106", 1.06, -0.02, 0.02)]
/// The reads kept in border.json for the unit tests (the others are only tallied here).
let kept: Set<String> = ["quad", "dim.quad", "g100", "dim.g100"]

func guide(_ b: CGRect, _ g: (name: String, scale: Double, dx: Double, dy: Double)) -> CGRect {
    let w = b.width * g.scale, h = b.height * g.scale
    return CGRect(x: b.midX - w / 2 + b.width * g.dx, y: b.midY - h / 2 + b.width * g.dy, width: w, height: h)
}

// MARK: dim copy

func dim(_ image: CGImage) -> CGImage {
    let src = CIImage(cgImage: image)
    let out = src.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.55, kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 0.8])
        .clampedToExtent().applyingGaussianBlur(sigma: 0.8).cropped(to: src.extent)
    return ci.createCGImage(out, from: src.extent)!
}

// MARK: orientation check (the iOS scanner's mapping from Vision's normalized upright point to the landscape buffer)

/// The iOS scanner's rule (CardTextScanner.Coordinator.bufferPixel): Vision's normalized point (origin bottom-left) in
/// the upright image of size `upright`, to a pixel of the camera's landscape buffer read with orientation .right
/// (buffer height = upright width).
func bufferPixel(_ p: CGPoint, upright: CGSize) -> (x: Int, y: Int) {
    let ux = p.x * upright.width, uy = (1 - p.y) * upright.height
    return (Int(uy.rounded()), Int((upright.width - 1 - ux).rounded()))
}

func orientationCheck(_ image: CGImage) throws {
    // The buffer a camera held in landscape fills, read with orientation .right: filled pixel by pixel with the
    // mapping under test, so if Vision finds the card at the same normalized corners as in the upright photo, the
    // scanner reads the pixels Vision's rectangle means.
    let W = image.width, H = image.height
    var rgba = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &rgba, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, H, W, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let buffer else { fatalError("no buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for uy in 0..<H {
        for ux in 0..<W {
            let b = bufferPixel(CGPoint(x: Double(ux) / Double(W), y: 1 - Double(uy) / Double(H)), upright: CGSize(width: W, height: H))
            let src = (uy * W + ux) * 4, dst = b.y * stride + b.x * 4
            base[dst] = rgba[src + 2]; base[dst + 1] = rgba[src + 1]; base[dst + 2] = rgba[src]; base[dst + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    func request() -> VNDetectRectanglesRequest {
        let r = VNDetectRectanglesRequest()
        r.minimumAspectRatio = 0.6; r.maximumAspectRatio = 0.85; r.minimumSize = 0.2; r.maximumObservations = 1
        r.quadratureTolerance = 20; r.minimumConfidence = 0.6
        return r
    }
    let a = request(), b = request()
    try VNImageRequestHandler(cgImage: image).perform([a])
    try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([b])
    guard let qa = a.results?.first, let qb = b.results?.first else { print("orientation check: no rectangle"); return }
    let pa = [qa.topLeft, qa.topRight, qa.bottomRight, qa.bottomLeft], pb = [qb.topLeft, qb.topRight, qb.bottomRight, qb.bottomLeft]
    let worst = zip(pa, pb).map { max(abs($0.x - $1.x), abs($0.y - $1.y)) }.max()!
    print(String(format: "orientation check (%d×%d upright, %d×%d buffer read with .right): the card's corners agree within %.3f of the frame (a wrong mapping puts them elsewhere)", W, H, H, W, worst))
}

// MARK: run

struct Read: Codable {
    var inside: [[Int]]
    var outside: [[Int]]
    /// Further outside (6.5% and 9%): the table, or the table past a border.
    var far: [[Int]]
    /// The text box: 24 samples, paper and ink.
    var inner: [Int]
}

struct Photo: Codable {
    var expected: String
    /// The card rectangle found (pixels, TL TR BR BL), when one was.
    var quad: [[Double]]?
    /// `quad`, `g094`/`g100`/`g106`, and the same on the dim copy as `dim.quad`, `dim.g100`, …
    var reads: [String: Read]
}

var out: [String: Photo] = [:]
/// T1_BORDER_PROFILES=<file>: also write every guide profile there (large; for tuning the edge search).
let dumpProfiles = ProcessInfo.processInfo.environment["T1_BORDER_PROFILES"]
var profiles2: [String: [[[Int]]]] = [:]
var tallies: [String: (right: Int, wrong: Int, unknown: Int, none: Int)] = [:]
var checked = false
for row in rows {
    let file = row[0], tags = Set(row[5].split(separator: ",").map(String.init))
    let expected: Border? = tags.contains("borderless") ? nil : tags.contains("white-border") ? .white : .black
    guard let expected else { continue }
    guard let ns = NSImage(contentsOf: root.appending(path: "photos/\(file)")),
          let image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    var photo = Photo(expected: expected.rawValue, quad: nil, reads: [:])
    let plain = Luma(image), dimmed = Luma(dim(image))
    if check && !checked, tags.contains("frame93") { try orientationCheck(image); checked = true }
    let found = try rectangles(image)
    if let q = found.first {
        photo.quad = q.map { [Double($0.x), Double($0.y)] }
        for (name, luma) in [("quad", plain), ("dim.quad", dimmed)] {
            let s = quadSamples(q, luma)
            photo.reads[name] = Read(inside: s.inside, outside: s.outside, far: s.far, inner: innerSamples(q, luma))
        }
        for g in guides {
            let box = guide(bounds(q), g)
            for (prefix, luma) in [("", plain), ("dim.", dimmed)] {
                let raw = guideProfiles(box, luma)
                let profiles = raw.map(edgeSamples)
                photo.reads[prefix + g.name] = Read(inside: profiles.map(\.inside), outside: profiles.map(\.outside), far: profiles.map(\.far), inner: innerSamples(boxQuad(box), luma))
                if dumpProfiles != nil { profiles2[file + "|" + prefix + g.name] = raw }
            }
        }
    }
    out[file] = photo
    if check {
        for name in ["quad", "dim.quad"] + guides.flatMap({ ["\($0.name)", "dim.\($0.name)"] }) {
            var t = tallies[name] ?? (0, 0, 0, 0)
            if let r = photo.reads[name] {
                let got = classify(inside: r.inside, outside: r.outside, far: r.far, inner: r.inner)
                if got == expected { t.right += 1 } else if got == .unknown { t.unknown += 1 } else { t.wrong += 1; print("  wrong \(name): \(file) expected \(expected) got \(got)") }
            } else { t.none += 1 }
            tallies[name] = t
            if tags.contains("frame93") {
                var o = tallies["old " + name] ?? (0, 0, 0, 0)
                if let r = photo.reads[name] {
                    let got = classify(inside: r.inside, outside: r.outside, far: r.far, inner: r.inner)
                    if got == expected { o.right += 1 } else if got == .unknown { o.unknown += 1 } else { o.wrong += 1 }
                } else { o.none += 1 }
                tallies["old " + name] = o
            }
        }
    }
    photo.reads = photo.reads.filter { kept.contains($0.key) }
    FileHandle.standardError.write("\(file)\n".data(using: .utf8)!)
}
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try enc.encode(out).write(to: root.appending(path: "border.json"))
print("\(out.count) photos with a border → border.json")
if let dumpProfiles { try JSONEncoder().encode(profiles2).write(to: URL(fileURLWithPath: dumpProfiles)) }
if check {
    for name in tallies.keys.sorted() {
        let t = tallies[name]!
        print("\(name): right \(t.right), wrong \(t.wrong), unknown \(t.unknown), no rectangle \(t.none)")
    }
}
