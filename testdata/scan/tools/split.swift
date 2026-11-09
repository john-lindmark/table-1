// Makes testdata/scan/split.json: how Apple Vision reads split cards (Boom // Bust, Fire // Ice, Wear // Tear, fuse,
// Aftermath, Rooms) held every way round, with each line's corners, for the tests of ScanOrder and the split-card
// name rules (README § Split cards). A split card's two half-faces are printed sideways, so held upright in the
// guide its text runs up or down the frame; Vision reads it, but sorted by the top of each line's box (as the
// scanners hand lines on) the halves' names land among the rules text, under the type lines.
//
// Each source is read at four orientations of the image (up, right, left, down: the card as photographed, turned
// a quarter either way, and upside down), with .accurate recognition and language correction, as the iOS scanner
// reads. Lines are kept in the scanners' order (top of the box first) with their four corners (top-left,
// top-right, bottom-right, bottom-left of the text, in pixels of the turned image, origin top-left), so the tests
// can order them by the text's own direction the way CardScanner does.
//
// Sources: the photo set's split cards (055 Wear // Tear, 169 Polluted Cistern // Dim Oubliette), and Scryfall's
// large scan of a few more printings (fetched into $T1_SPLIT_CACHE, default /tmp/t1-split; not kept in the repo),
// drawn smaller on a dark mat with a little blur, roughly as a phone sees a card held in the guide.
//
// Run from the repo root:  swiftc -O -o /tmp/split testdata/scan/tools/split.swift && /tmp/split
import AppKit
import CoreImage
import Foundation
import Vision

let root = URL(fileURLWithPath: "testdata/scan")
let cache = URL(fileURLWithPath: ProcessInfo.processInfo.environment["T1_SPLIT_CACHE"] ?? "/tmp/t1-split")
try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

struct Source { let id: String; let name: String; let photo: String?; let set: String; let cn: String }
let sources = [
    Source(id: "055-wear", name: "Wear // Tear", photo: "photos/055-wear.jpg", set: "dgm", cn: "135"),
    Source(id: "169-polluted-cistern", name: "Polluted Cistern // Dim Oubliette", photo: "photos/169-polluted-cistern.jpg", set: "dsc", cn: "23"),
    Source(id: "boom-plc", name: "Boom // Bust", photo: nil, set: "plc", cn: "112"),
    Source(id: "fire-apc", name: "Fire // Ice", photo: nil, set: "apc", cn: "128"),
    Source(id: "fire-mh2", name: "Fire // Ice", photo: nil, set: "mh2", cn: "290"),
    Source(id: "wear-dgm", name: "Wear // Tear", photo: nil, set: "dgm", cn: "135"),
    Source(id: "breaking-dgm", name: "Breaking // Entering", photo: nil, set: "dgm", cn: "124"),
    Source(id: "commit-akh", name: "Commit // Memory", photo: nil, set: "akh", cn: "211"),
    Source(id: "dead-plc", name: "Dead // Gone", photo: nil, set: "plc", cn: "113"),
]

let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.httpAdditionalHeaders = ["User-Agent": "Table1ScanTests/0.1 (lindmark table-1.site)", "Accept": "image/*"]
    return URLSession(configuration: c)
}()

func fetch(_ s: Source) throws -> URL {
    let file = cache.appending(path: "\(s.id).jpg")
    if FileManager.default.fileExists(atPath: file.path) { return file }
    let url = URL(string: "https://api.scryfall.com/cards/\(s.set)/\(s.cn)?format=image&version=large")!
    let done = DispatchSemaphore(value: 0)
    var out: Result<Data, Error> = .failure(URLError(.unknown))
    session.dataTask(with: url) { data, response, error in
        if let data, (response as? HTTPURLResponse)?.statusCode == 200 { out = .success(data) } else { out = .failure(error ?? URLError(.badServerResponse)) }
        done.signal()
    }.resume()
    done.wait()
    try out.get().write(to: file)
    Thread.sleep(forTimeInterval: 0.15) // Scryfall asks for 50–100 ms between requests
    return file
}

let ci = CIContext(options: [.cacheIntermediates: false])

/// The scan drawn 640 px tall on a 1000×1200 dark mat, slightly blurred: closer to a camera frame than a clean scan.
func onMat(_ image: CGImage) -> CGImage {
    let w = 1000, h = 1200
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let ch = 640.0, cw = ch * Double(image.width) / Double(image.height)
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: (Double(w) - cw) / 2, y: (Double(h) - ch) / 2, width: cw, height: ch))
    let blurred = CIImage(cgImage: ctx.makeImage()!).applyingGaussianBlur(sigma: 0.8).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    return ci.createCGImage(blurred, from: blurred.extent)!
}

func load(_ url: URL) -> CGImage { NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)! }

/// Lines as the scanners order them (top of the box first), with their corners in pixels, origin top-left.
func read(_ image: CGImage, _ o: CGImagePropertyOrientation) throws -> (w: Int, h: Int, lines: [[String: Any]]) {
    let r = VNRecognizeTextRequest()
    r.recognitionLevel = .accurate
    r.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, orientation: o).perform([r])
    let turned = [.right, .left, .rightMirrored, .leftMirrored].contains(o)
    let w = turned ? image.height : image.width, h = turned ? image.width : image.height
    func px(_ p: CGPoint) -> [Int] { [Int((p.x * Double(w)).rounded()), Int(((1 - p.y) * Double(h)).rounded())] }
    let lines: [[String: Any]] = (r.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }.compactMap { x in
        guard let t = x.topCandidates(1).first?.string else { return nil }
        return ["t": t, "q": [x.topLeft, x.topRight, x.bottomRight, x.bottomLeft].flatMap(px)]
    }
    return (w, h, lines)
}

var out: [[String: Any]] = []
for s in sources {
    let image = try s.photo.map { load(root.appending(path: $0)) } ?? onMat(load(fetch(s)))
    for (name, o) in [("up", CGImagePropertyOrientation.up), ("right", .right), ("left", .left), ("down", .down)] {
        let r = try read(image, o)
        out.append(["id": "\(s.id)-\(name)", "name": s.name, "set": s.set, "cn": s.cn, "w": r.w, "h": r.h, "lines": r.lines])
        print(s.id, name, r.lines.count, "lines:", r.lines.prefix(4).map { $0["t"] as! String })
    }
}
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try data.write(to: root.appending(path: "split.json"))
print("wrote \(out.count) reads to testdata/scan/split.json")
