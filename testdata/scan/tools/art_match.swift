// Art matching spike, step 3 (testdata/scan/README.md, "Art matching spike"): can a card be named by how it looks,
// its artwork or the whole card, instead of (or as well as) by its text?
//
// Two reference indexes, made by art_refs.py and downloaded by art_fetch.swift into ~/Library/Caches/table1-art-spike:
//   arts   Scryfall art_crop, one per illustration (~50k), the arts the test photos show first, then random ones.
//   cards  Scryfall border_crop (the whole card), the exact printings the photos show first, then one printing per
//          illustration in the same order as arts.
// Each image is embedded with Apple Vision's image feature print (VNGenerateImageFeaturePrintRequest, built into iOS,
// nothing to ship) and two 64-bit perceptual hashes (dHash, DCT pHash), cached next to the images, so only new
// downloads are embedded on a rerun.
//
// Each photo: the card is found and deskewed as in ocr.swift (VNDetectRectanglesRequest, the largest card-shaped
// rectangle, CIPerspectiveCorrection to 630×880; with none, the whole photo is taken as the card). Then:
//   art     the art box cropped from the card: `modern` (2003+ frame) and `old` (1993/1997), each also turned 180°;
//           `+rect` adds the detected rectangle itself as the art box (the detector often finds the art, not the card,
//           since the art box is card-shaped too), also turned.
//   card    the whole deskewed card, and turned 180°.
// The best score over a method's crops counts. Nearest neighbours are looked up in the first N references for growing
// N; `centered` subtracts the index's mean vector first (stops a few references being everyone's nearest neighbour).
//
// It prints top-1/top-5 (right card, right art or printing), the wrong-card rate when it answers only with a clear
// margin, time per frame, how well it confirms the text matcher's pick, and synthetic negatives (a keyboard, a list of
// card names on a screen).
//
// Run from the repo root:  swiftc -O testdata/scan/tools/art_match.swift -o /tmp/art_match && /tmp/art_match [picks.tsv]
// picks.tsv: the text matcher's pick per photo (file, mode, card name, set, cn) from the app's CardMatcher, optional.
// T1_DETAIL=1 lists every miss of the best method.
import Accelerate
import AppKit
import CoreImage
import Foundation
import Vision

setvbuf(stdout, nil, _IOLBF, 0)
let root = URL(fileURLWithPath: "testdata/scan")
let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/table1-art-spike")
let ci = CIContext(options: [.cacheIntermediates: false])
let detail = ProcessInfo.processInfo.environment["T1_DETAIL"] != nil

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func key(_ name: String) -> String {
    name.components(separatedBy: " // ")[0].folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .filter { $0.isLetter || $0.isNumber }
}
func cnKey(_ s: String) -> String { String(s.lowercased().replacingOccurrences(of: "★", with: "").drop { $0 == "0" }) }
func f3(_ x: Float) -> String { String(format: "%.3f", x) }

// MARK: embeddings

let fpRequest = VNGenerateImageFeaturePrintRequest()
fpRequest.imageCropAndScaleOption = .scaleFill

/// Vision's feature print, L2-normalized.
func featurePrint(_ image: CGImage) -> [Float] {
    try! VNImageRequestHandler(cgImage: image).perform([fpRequest])
    let o = fpRequest.results!.first!
    return normalized(o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(o.elementCount)) })
}

func normalized(_ v: [Float]) -> [Float] {
    var v = v, n: Float = 0
    vDSP_svesq(v, 1, &n, vDSP_Length(v.count))
    n = sqrt(n)
    vDSP_vsdiv(v, 1, &n, &v, 1, vDSP_Length(v.count))
    return v
}

/// Grey pixels of the image scaled to w×h.
func grey(_ image: CGImage, _ w: Int, _ h: Int) -> [Float] {
    var px = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return px.map(Float.init)
}

func dHash(_ image: CGImage) -> UInt64 {
    let g = grey(image, 9, 8)
    var h: UInt64 = 0
    for y in 0..<8 { for x in 0..<8 { h = h << 1 | (g[y * 9 + x] < g[y * 9 + x + 1] ? 1 : 0) } }
    return h
}

let dct: [[Float]] = (0..<8).map { u in (0..<32).map { x in cos(Float.pi * Float(u) * (2 * Float(x) + 1) / 64) } }
func pHash(_ image: CGImage) -> UInt64 {
    let g = grey(image, 32, 32)
    var c = [Float](repeating: 0, count: 64)
    for u in 0..<8 { for v in 0..<8 {
        var s: Float = 0
        for y in 0..<32 { for x in 0..<32 { s += g[y * 32 + x] * dct[u][y] * dct[v][x] } }
        c[u * 8 + v] = s
    } }
    let median = c.dropFirst().sorted()[31]
    return c.reduce(UInt64(0)) { $0 << 1 | ($1 > median ? 1 : 0) }
}

struct Embedding { var fp: [Float]; var d: UInt64; var p: UInt64 }
func embed(_ image: CGImage) -> Embedding { Embedding(fp: featurePrint(image), d: dHash(image), p: pHash(image)) }

// MARK: reference indexes

struct Ref { let file: String, name: String, key: String, ill: String, set: String, cn: String }

struct Index {
    let kind: String
    let refs: [Ref]
    let dim: Int
    let fp: [Float]
    let centered: [Float]
    let mean: [Float]
    let hashes: [(UInt64, UInt64)]
    var count: Int { hashes.count }

    /// Embeds the downloaded images in list order up to the first missing one (cached in index-<kind>-*.bin).
    init(_ kind: String) {
        self.kind = kind
        let all: [Ref] = try! String(contentsOf: cache.appending(path: "\(kind).tsv"), encoding: .utf8).split(separator: "\n").map {
            let c = $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return Ref(file: c[1], name: c[2], key: key(c[2]), ill: kind == "arts" ? c[1] : c[8], set: c[4], cn: c[5])
        }
        let fpURL = cache.appending(path: "index-\(kind)-fp.bin"), hURL = cache.appending(path: "index-\(kind)-hash.bin")
        var fp = (try? Data(contentsOf: fpURL)).map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? []
        var h = (try? Data(contentsOf: hURL)).map { d in d.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) } } ?? []
        let started = now()
        var added = 0
        for r in all[(h.count / 2)...] {
            guard let src = CGImageSourceCreateWithURL(cache.appending(path: "\(kind)/\(r.file).jpg") as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { break }
            let e = embed(img)
            fp += e.fp
            h += [e.d, e.p]
            added += 1
            if added % 5000 == 0 { print("  \(kind): embedded \(h.count / 2)") }
        }
        if added > 0 {
            try! fp.withUnsafeBytes { try Data($0).write(to: fpURL) }
            try! h.withUnsafeBytes { try Data($0).write(to: hURL) }
            print("  \(kind): embedded \(added) new, \(String(format: "%.1f", (now() - started) / Double(added) * 1000)) ms each")
        }
        let n = h.count / 2
        dim = fp.count / n
        refs = Array(all.prefix(n))
        self.fp = fp
        hashes = stride(from: 0, to: h.count, by: 2).map { (h[$0], h[$0 + 1]) }
        var m = [Float](repeating: 0, count: dim)
        for i in 0..<n { vDSP_vadd(m, 1, Array(fp[(i * dim)..<((i + 1) * dim)]), 1, &m, 1, vDSP_Length(dim)) }
        mean = m.map { $0 / Float(n) }
        var c: [Float] = []
        c.reserveCapacity(fp.count)
        for i in 0..<n { c += normalized(zip(fp[(i * dim)..<((i + 1) * dim)], m).map { $0 - $1 / Float(n) }) }
        centered = c
    }
}

// MARK: finding the card

/// The largest card-shaped rectangle, deskewed twice: upright as a card (630×880) and lying down as an art box
/// (880×630). With none, the whole photo stretched to both.
func detect(_ image: CGImage) -> (card: CIImage, rect: CIImage, found: Bool) {
    let r = VNDetectRectanglesRequest()
    r.minimumAspectRatio = 0.6
    r.maximumAspectRatio = 0.85
    r.minimumSize = 0.2
    r.maximumObservations = 4
    r.quadratureTolerance = 20
    try! VNImageRequestHandler(cgImage: image).perform([r])
    let w = CGFloat(image.width), h = CGFloat(image.height)
    func fit(_ i: CIImage, _ W: CGFloat, _ H: CGFloat) -> CIImage {
        let e = i.extent
        return i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: W / e.width, y: H / e.height))
    }
    guard let o = (r.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
    else { let i = CIImage(cgImage: image); return (fit(i, 630, 880), fit(i, 880, 630), false) }
    func correct(_ tl: CGPoint, _ tr: CGPoint, _ br: CGPoint, _ bl: CGPoint) -> CIImage {
        let f = CIFilter(name: "CIPerspectiveCorrection")!
        f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        for (k, p) in [("inputTopLeft", tl), ("inputTopRight", tr), ("inputBottomRight", br), ("inputBottomLeft", bl)] {
            f.setValue(CIVector(x: p.x * w, y: p.y * h), forKey: k)
        }
        return f.outputImage!
    }
    var (tl, tr, br, bl) = (o.topLeft, o.topRight, o.bottomRight, o.bottomLeft)
    // A card lying sideways: the long side is its height.
    if hypot((tr.x - tl.x) * w, (tr.y - tl.y) * h) > hypot((tl.x - bl.x) * w, (tl.y - bl.y) * h) { (tl, tr, br, bl) = (tr, br, bl, tl) }
    return (fit(correct(tl, tr, br, bl), 630, 880), fit(correct(bl, tl, tr, br), 880, 630), true)
}

/// Art boxes as fractions of the card: x from the left, y from the top.
let boxes: [(name: String, x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat)] = [
    ("modern", 0.08, 0.92, 0.115, 0.555),
    ("old", 0.12, 0.88, 0.10, 0.505),
]

func turned(_ i: CIImage) -> CIImage {
    let e = i.extent
    return i.transformed(by: CGAffineTransform(rotationAngle: .pi).translatedBy(x: -e.width, y: -e.height))
}

func render(_ i: CIImage, _ rect: CGRect? = nil) -> CGImage { ci.createCGImage(i, from: rect ?? i.extent)! }

/// Every crop of a photo, embedded: art-modern, art-old, art-rect, card; each also "-180".
func crops(_ image: CGImage, ms: inout [String: Double]) -> ([String: Embedding], found: Bool) {
    var t = now()
    let (card, rect, found) = detect(image)
    ms["detect+deskew"] = (now() - t) * 1000
    var out: [String: Embedding] = [:]
    var images: [(String, CGImage)] = []
    t = now()
    for flip in [false, true] {
        let c = flip ? turned(card) : card, s = flip ? "-180" : ""
        for b in boxes {
            images.append(("art-\(b.name)\(s)", render(c, CGRect(x: 630 * b.x0, y: 880 * (1 - b.y1), width: 630 * (b.x1 - b.x0), height: 880 * (b.y1 - b.y0)))))
        }
        images.append(("art-rect\(s)", render(flip ? turned(rect) : rect)))
        images.append(("card\(s)", render(c)))
    }
    ms["crops"] = (now() - t) * 1000
    t = now()
    for (k, im) in images { out[k] = embed(im) }
    ms["featureprint (each)"] = (now() - t) * 1000 / Double(images.count)
    return (out, found)
}

// MARK: search

/// Cosine similarity of the query to the first n references.
func cosines(_ q: [Float], _ m: [Float], dim: Int, n: Int) -> [Float] {
    var out = [Float](repeating: 0, count: n)
    m.withUnsafeBufferPointer { m in
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(dim), 1, m.baseAddress, Int32(dim), q, 1, 0, &out, 1)
    }
    return out
}

func top(_ s: [Float], _ k: Int) -> [Int] {
    var best: [Int] = []
    for i in s.indices where best.count < k || s[i] > s[best.last!] {
        best.insert(i, at: best.firstIndex { s[i] > s[$0] } ?? best.count)
        if best.count > k { best.removeLast() }
    }
    return best
}

/// References by score, one per card (top-5 is five different cards, not five arts of one).
func ranked(_ s: [Float], _ refs: [Ref], _ k: Int) -> [(Int, Float)] {
    var seen = Set<String>(), out: [(Int, Float)] = []
    for i in top(s, 1000) where out.count < k && seen.insert(refs[i].key).inserted { out.append((i, s[i])) }
    return out
}

struct Method {
    let name: String
    let index: Index
    let crops: [String]
    var centered = false
    var int8 = false
    var hash: Int? = nil  // 0 dHash, 1 pHash

    func scores(_ q: [String: Embedding], n: Int) -> [Float] {
        var best = [Float](repeating: -2, count: n)
        for c in crops {
            let e = q[c]!
            let s: [Float]
            if let hash {
                let h = hash == 0 ? e.d : e.p
                s = (0..<n).map { 1 - Float((h ^ (hash == 0 ? index.hashes[$0].0 : index.hashes[$0].1)).nonzeroBitCount) / 64 }
            } else if centered {
                s = cosines(normalized(zip(e.fp, index.mean).map { $0 - $1 }), index.centered, dim: index.dim, n: n)
            } else {
                s = cosines(e.fp, int8 ? int8Index(index) : index.fp, dim: index.dim, n: n)
            }
            vDSP_vmax(best, 1, s, 1, &best, 1, vDSP_Length(n))
        }
        return best
    }
}

/// int8 copy of an index (one scale for all; normalized feature print values are within ±0.25).
var int8Cache: [String: [Float]] = [:]
func int8Index(_ i: Index) -> [Float] {
    if let c = int8Cache[i.kind] { return c }
    let q = i.fp.map { Float(Int8(clamping: Int(($0 * 127 * 4).rounded()))) / (127 * 4) }
    int8Cache[i.kind] = q
    return q
}

// MARK: run

let photos = try String(contentsOf: root.appending(path: "photos.tsv"), encoding: .utf8).split(separator: "\n").dropFirst()
    .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
let expected: [String: Set<String>] = Dictionary(uniqueKeysWithValues: try String(contentsOf: cache.appending(path: "expected.tsv"), encoding: .utf8)
    .split(separator: "\n").map { l in
        let c = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return (c[0], Set(c[2].split(separator: ",").map(String.init)))
    })
var picks: [String: String] = [:]
if CommandLine.arguments.count > 1 {
    for l in try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n") {
        let c = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if c[1] == "multi" && !c[2].isEmpty { picks[c[0]] = c[2] }
    }
}

print("Indexes:")
let arts = Index("arts"), cards = Index("cards")
for i in [arts, cards] { print("  \(i.kind): \(i.count) embedded, feature print \(i.dim) floats") }

struct Query { let file: String, name: String, set: String, cn: String, tags: Set<String>, found: Bool, crops: [String: Embedding], ms: [String: Double] }
var queries: [Query] = []
for p in photos {
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(root.appending(path: "photos/\(p[0])") as CFURL, nil)!, 0, nil)!
    var ms: [String: Double] = [:]
    let (c, found) = crops(img, ms: &ms)
    let tags = Set(p[5].split(separator: ",").map(String.init) + [p[4] == "en" ? "english" : "lang", found ? "rectangle" : "no-rectangle"])
    queries.append(Query(file: p[0], name: p[1], set: p[2], cn: p[3], tags: tags, found: found, crops: c, ms: ms))
}
let found = queries.filter(\.found).count
print("Photos: \(queries.count), card-shaped rectangle found in \(found)")

func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }

let artBoxes = ["art-modern", "art-old", "art-modern-180", "art-old-180"]
let artRect = artBoxes + ["art-rect", "art-rect-180"]
var methods = [
    Method(name: "art modern, feature print", index: arts, crops: ["art-modern"]),
    Method(name: "art boxes, feature print", index: arts, crops: artBoxes),
    Method(name: "art boxes+rect, feature print", index: arts, crops: artRect),
    Method(name: "art boxes+rect, feature print centered", index: arts, crops: artRect, centered: true),
    Method(name: "art boxes+rect, feature print int8", index: arts, crops: artRect, int8: true),
    Method(name: "art boxes+rect, dHash", index: arts, crops: artRect, hash: 0),
    Method(name: "art boxes+rect, pHash", index: arts, crops: artRect, hash: 1),
    Method(name: "whole card, feature print", index: cards, crops: ["card", "card-180"]),
    Method(name: "whole card, feature print centered", index: cards, crops: ["card", "card-180"], centered: true),
]

struct Hit { let q: Query, card1: Bool, art1: Bool, print1: Bool, card5: Bool, s1: Float, s2: Float, best: Ref }
var hits: [String: [Hit]] = [:]  // at the largest size
let common = min(arts.count, cards.count)
let positives = arts.refs.filter { r in expected.values.contains { $0.contains(r.ill) } }.count
let sizes = [positives, 2_000, 5_000, 10_000, 20_000, 30_000, 40_000, common].filter { $0 <= common }
    .reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
print("Index sizes: the \(positives) arts the photos show (cards: their printings first), then random distractors")

for m in methods {
    print("\n\(m.name): size → top-1 card (art/printing), top-5 card | rectangle found (\(found))")
    for n in sizes {
        var hs: [Hit] = []
        for q in queries {
            let s = m.scores(q.crops, n: n)
            let r = ranked(s, m.index.refs, 5)
            let b = m.index.refs[r[0].0], k = key(q.name)
            hs.append(Hit(q: q, card1: b.key == k, art1: expected[q.file]!.contains(b.ill),
                          print1: q.set != "*" && b.set == q.set && (q.cn == "*" || cnKey(b.cn) == cnKey(q.cn)),
                          card5: r.contains { m.index.refs[$0.0].key == k }, s1: r[0].1, s2: r.count > 1 ? r[1].1 : -2, best: b))
        }
        hits[m.name] = hs
        let f = hs.filter(\.q.found), checked = hs.filter { $0.q.set != "*" }.count
        let what = m.index.kind == "arts" ? "art \(hs.filter(\.art1).count)" : "printing \(hs.filter(\.print1).count)/\(checked)"
        print("  \(String(n).padding(toLength: 6, withPad: " ", startingAt: 0)) \(hs.filter(\.card1).count) (\(pct(hs.filter(\.card1).count, hs.count))) (\(what)), "
              + "top-5 \(hs.filter(\.card5).count) (\(pct(hs.filter(\.card5).count, hs.count)))  |  \(f.filter(\.card1).count) (\(pct(f.filter(\.card1).count, f.count)))")
    }
    // Answering only with a clear margin over the next card.
    let hs = hits[m.name]!
    let worst = hs.filter { !$0.card1 }.map { $0.s1 - $0.s2 }.sorted(by: >)
    for (label, t) in [("above every wrong answer", worst.first ?? 0), ("above all but 1% of photos wrong", worst.count > hs.count / 100 ? worst[hs.count / 100] : 0)] {
        let ans = hs.filter { $0.s1 - $0.s2 > t }
        print("  margin > \(f3(t)) (\(label)): answers \(ans.count), right \(ans.filter(\.card1).count), wrong \(ans.filter { !$0.card1 }.count)")
    }
}

// MARK: best methods in detail

func byTag(_ m: String) {
    let hs = hits[m]!
    var t: [String: (Int, Int)] = [:]
    for h in hs { for tag in h.q.tags { t[tag, default: (0, 0)].1 += 1; if h.card1 { t[tag]!.0 += 1 } } }
    print("  by tag (≥ 8 photos): " + t.filter { $0.value.1 >= 8 }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: ", "))
    let worst = hs.filter { !$0.card1 }.map { $0.s1 - $0.s2 }.max() ?? 0
    let missed = hs.filter { picks[$0.q.file] == nil }
    print("  photos the text matcher names nothing on: \(missed.count); top-1 right on \(missed.filter(\.card1).count), "
          + "with a margin above every wrong answer \(missed.filter { $0.s1 - $0.s2 > worst }.count)")
    if detail { for h in hs where !h.card1 { print("    miss \(h.q.file): \(h.best.name) \(f3(h.s1)) (margin \(f3(h.s1 - h.s2)))") } }
}
let artBest = methods.filter { $0.index.kind == "arts" }.max { hits[$0.name]!.filter(\.card1).count < hits[$1.name]!.filter(\.card1).count }!
let cardBest = methods.filter { $0.index.kind == "cards" }.max { hits[$0.name]!.filter(\.card1).count < hits[$1.name]!.filter(\.card1).count }!
for m in [artBest, cardBest] { print("\n\(m.name) at \(common):"); byTag(m.name) }
do {
    // Either: the card both name, or the one with the clearer margin.
    let a = hits[artBest.name]!, c = hits[cardBest.name]!
    let either = zip(a, c).filter { $0.0.card1 || $0.1.card1 }.count
    let fused = zip(a, c).filter { ($0.0.s1 - $0.0.s2 >= $0.1.s1 - $0.1.s2) ? $0.0.card1 : $0.1.card1 }.count
    let agree = zip(a, c).filter { $0.0.best.key == $0.1.best.key }
    print("\nArt and whole card together: either right \(either), larger margin wins \(fused); both name the same card on \(agree.count), right on \(agree.filter { $0.0.card1 }.count)")
}

// MARK: timing

print("\nTime per frame (median over photos, ms; Mac, \(ProcessInfo.processInfo.processorCount) cores):")
for k in ["detect+deskew", "crops", "featureprint (each)"] { print("  \(k): \(String(format: "%.1f", median(queries.map { $0.ms[k]! })))") }
for i in [arts, cards] {
    let q = queries[0].crops["card"]!.fp
    let t = now()
    for _ in 0..<50 { _ = top(cosines(q, i.fp, dim: i.dim, n: i.count), 5) }
    print("  search \(i.count) \(i.kind), float32, per crop: \(String(format: "%.2f", (now() - t) * 1000 / 50))")
}
let fullArts = 49_742, printings = 109_573
print("Index size, feature print \(arts.dim) floats: \(fullArts) arts float32 \(fullArts * arts.dim * 4 / 1_000_000) MB, int8 \(fullArts * arts.dim / 1_000_000) MB; "
      + "every printing (\(printings)) float32 \(printings * arts.dim * 4 / 1_000_000) MB, int8 \(printings * arts.dim / 1_000_000) MB; a 64-bit hash per art \(fullArts * 8 / 1000) kB")

// MARK: confirmation

/// The query's best score against any reference of a card, and that card's rank among cards.
func claim(_ s: [Float], _ refs: [Ref], _ name: String) -> (Float, Int) {
    let k = key(name)
    let score = s.indices.filter { refs[$0].key == k }.map { s[$0] }.max() ?? -2
    return (score, Set(s.indices.filter { s[$0] > score }.map { refs[$0].key }).count + 1)
}

let names = Array(Set(arts.refs.map(\.name))).sorted()
var rng = SystemRandomNumberGenerator()
let impostorNames = queries.map { q in [names.randomElement(using: &rng)!, "Opt"].filter { key($0) != key(q.name) } }

/// Synthetic scenes the text gate exists for.
func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    body(ctx)
    return ctx.makeImage()!
}
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]).draw(at: CGPoint(x: x, y: y))
}
let keyboard = draw(1280, 960) { c in
    c.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 1280, height: 960))
    let rows = [["esc", "1", "2", "3", "4", "5", "6", "7", "8", "9"], ["tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O"],
                ["caps", "A", "S", "D", "F", "G", "H", "J", "K", "L"], ["shift", "Z", "X", "C", "V", "B", "N", "M", ",", "."],
                ["fn", "control", "option", "command", "", "command", "option", "<", ">", "^"]]
    for (r, row) in rows.enumerated() { for (i, k) in row.enumerated() {
        let rect = CGRect(x: 40 + i * 122, y: 760 - r * 170, width: 110, height: 150)
        c.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        c.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)); c.fillPath()
        text(k, rect.minX + 12, rect.minY + 14, 26, .black)
    } }
}
let screenList = draw(1280, 960) { c in
    c.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 1280, height: 960))
    c.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); c.fill(CGRect(x: 340, y: 40, width: 600, height: 880))
    for (i, n) in ["4 Opt", "4 Lightning Bolt", "4 Counterspell", "2 Brainstorm", "3 Delver of Secrets", "1 Ponder",
                   "4 Snapcaster Mage", "2 Island", "2 Volcanic Island", "4 Force of Will"].enumerated() {
        text(n, 380, CGFloat(860 - i * 80), 40, .white)
    }
}
var negatives: [(String, [String: Embedding], Bool, [String])] = []
for (label, img, claims) in [("keyboard", keyboard, ["Opt"]), ("list of names on a screen", screenList, ["Opt", "Lightning Bolt", "Counterspell"])] {
    var ms: [String: Double] = [:]
    let (c, f) = crops(img, ms: &ms)
    negatives.append((label, c, f, claims))
}

for m in [artBest, cardBest] {
    let refs = m.index.refs, n = m.index.count
    var genuine: [(Float, Int)] = [], impostor: [(Float, Int)] = []
    for (q, others) in zip(queries, impostorNames) {
        let s = m.scores(q.crops, n: n)
        if let pick = picks[q.file], key(pick) == key(q.name) { genuine.append(claim(s, refs, pick)) }
        for o in others { impostor.append(claim(s, refs, o)) }
    }
    print("\nConfirming the text matcher's pick, \(m.name), \(n) references: \(genuine.count) right picks, \(impostor.count) wrong claims (a random card, and Opt)")
    let g = genuine.map(\.0).sorted()
    for t in [g[g.count / 100], g[g.count / 20], g[g.count / 10]] {
        print("  claimed card scores ≥ \(f3(t)): keeps \(genuine.filter { $0.0 >= t }.count), lets through \(impostor.filter { $0.0 >= t }.count) wrong")
    }
    for k in [1, 5, 20, 100] {
        print("  claimed card in the top \(k) cards: keeps \(genuine.filter { $0.1 <= k }.count), lets through \(impostor.filter { $0.1 <= k }.count) wrong")
    }
    for k in [1, 5] { for t in [g[g.count / 20], g[g.count / 10]] {
        print("  claimed card in the top \(k) and scores ≥ \(f3(t)): keeps \(genuine.filter { $0.1 <= k && $0.0 >= t }.count), lets through \(impostor.filter { $0.1 <= k && $0.0 >= t }.count) wrong")
    } }
    for (label, c, f, claims) in negatives {
        let s = m.scores(c, n: n)
        let b = ranked(s, refs, 1)[0]
        print("  \(label): rectangle \(f ? "found" : "not found"), nearest \(refs[b.0].name) \(f3(b.1));"
              + claims.map { o -> String in let (sc, r) = claim(s, refs, o); return " \(o) \(f3(sc)) (rank \(r))" }.joined(separator: ","))
    }
}
