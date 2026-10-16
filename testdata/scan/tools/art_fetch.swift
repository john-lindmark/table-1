// Art matching spike, step 2: downloads the images of the first N rows of the cache's arts.tsv (art_crop) or cards.tsv
// (border_crop, whole cards), both made by art_refs.py, from cards.scryfall.io, scaled to 384 px on the long side, into
// ~/Library/Caches/table1-art-spike/arts or /cards.
// Files already there are skipped, so it can be stopped and rerun. Sixteen requests at a time (the CDN takes ~1 s for an image it has not cached), at most ~15 a second
// (Scryfall's image CDN has no rate limit, but asks for reasonable use).
//
// Run from the repo root:  swiftc -O testdata/scan/tools/art_fetch.swift -o /tmp/art_fetch && /tmp/art_fetch arts|cards [N]
import Foundation
import ImageIO
import UniformTypeIdentifiers

let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/table1-art-spike")
let kind = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "arts"
let dir = cache.appending(path: kind)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let limit = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : Int.max
let rows = try String(contentsOf: cache.appending(path: "\(kind).tsv"), encoding: .utf8)
    .split(separator: "\n").prefix(limit).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }

func shrink(_ data: Data, to out: URL) -> Bool {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                 kCGImageSourceThumbnailMaxPixelSize: 384,
                                                                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
          let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    return CGImageDestinationFinalize(dst)
}

let config = URLSessionConfiguration.default
config.httpAdditionalHeaders = ["User-Agent": "Table1ArtSpike/0.1 (lindmark table-1.site)", "Accept": "image/*"]
let session = URLSession(configuration: config)
let todo = rows.filter { !FileManager.default.fileExists(atPath: dir.appending(path: "\($0[1]).jpg").path) }
print("\(rows.count - todo.count) cached, \(todo.count) to fetch")
let started = Date()
var done = 0, failed = 0
await withTaskGroup(of: Bool.self) { group in
    var it = todo.makeIterator()
    func add() -> Bool {
        guard let r = it.next() else { return false }
        group.addTask {
            let out = dir.appending(path: "\(r[1]).jpg")
            for attempt in 0..<3 {
                if let (data, resp) = try? await session.data(from: URL(string: r.last!)!),
                   (resp as? HTTPURLResponse)?.statusCode == 200, shrink(data, to: out) { return true }
                try? await Task.sleep(for: .seconds(2 << attempt))
            }
            return false
        }
        return true
    }
    for _ in 0..<16 { _ = add() }
    while let ok = await group.next() {
        done += 1
        if !ok { failed += 1 }
        if done % 1000 == 0 { print("\(done)/\(todo.count), \(failed) failed, \(Int(Date().timeIntervalSince(started)))s") }
        // ~15 a second at most.
        let ahead = Double(done) / 15 - Date().timeIntervalSince(started)
        if ahead > 0 { try? await Task.sleep(for: .seconds(ahead)) }
        _ = add()
    }
}
print("done: \(done), \(failed) failed, \(Int(Date().timeIntervalSince(started)))s")
