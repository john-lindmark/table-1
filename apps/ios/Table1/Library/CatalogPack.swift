import Compression
import Foundation

// The offline card catalog pack, format 1 (contract/catalog-2026-10-14.md). Pure code with no app or
// Supabase dependencies, so the unit tests compile it on its own.

/// Same steps as public.card_name_norm: NFKD, lowercase, drop combining marks, æ → ae, œ → oe, drop
/// apostrophes, every other run outside [a-z0-9] becomes one space, trimmed.
enum CardName {
    static func norm(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        func emit(_ u: Unicode.Scalar) {
            if gap && !out.isEmpty { out.append(" ") }
            gap = false
            out.append(u)
        }
        for u in s.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch u.value {
            case 0x300...0x36F, 0x27, 0x2019: continue // removed outright, not a gap
            case 0xE6: emit("a"); emit("e")
            case 0x153: emit("o"); emit("e")
            case 0x61...0x7A, 0x30...0x39: emit(u)
            default: gap = true
            }
        }
        return String(out)
    }
}

struct PackHeader: Equatable {
    let version: String
    let oracles: Int
    let printings: Int
}

struct PackOracle: Equatable {
    let idx: Int
    let oracleId: String
    let name: String
    let nameNorm: String
    let typeLine: String
    let manaCost: String
    let cmc: Double
    let colors: String
    let faceNames: String
    /// One character per format in `CatalogPack.legalityFormats`: L legal, R restricted, B banned, - not legal.
    var legal: String = ""
}

struct PackPrinting: Equatable {
    let cardId: String
    let oracleIdx: Int
    let set: String
    let cn: String
    let lang: String
    let rarity: String
    let finishes: String
    let releasedAt: String
    let imageTs: String
    let imageFaces: Int
    let printedName: String
    /// The card's original paper printing, the one adds use by default.
    var original: Bool = false
}

enum CatalogPack {
    enum Failure: LocalizedError {
        case format, gzip, checksum
        var errorDescription: String? {
            switch self {
            case .format: "Unknown card data format"
            case .gzip: "Card data is damaged"
            case .checksum: "Card data didn't download completely"
            }
        }
    }

    /// Formats in an O line's legality code, in order.
    static let legalityFormats = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander", "premodern"]

    /// A legality code read for one format: "legal", "restricted", "banned", "not_legal", or nil when the
    /// format isn't one the code covers (or the pack predates codes).
    static func legality(_ code: String, _ format: String) -> String? {
        guard let i = legalityFormats.firstIndex(of: format.lowercased()), i < code.count else { return nil }
        switch code[code.index(code.startIndex, offsetBy: i)] {
        case "L": return "legal"
        case "R": return "restricted"
        case "B": return "banned"
        default: return "not_legal"
        }
    }

    static let finishName: [Character: String] = ["n": "nonfoil", "f": "foil", "e": "etched"]
    static let rarityName: [String: String] = [
        "c": "Common", "u": "Uncommon", "r": "Rare", "m": "Mythic", "s": "Special", "b": "Bonus",
    ]

    /// Streams the (already gunzipped) pack: `oracle` for each O line, `printing` for each P line, in file
    /// order. Unknown line types and extra trailing fields are ignored; a different format is refused.
    @discardableResult
    static func parse(_ data: Data, oracle: (PackOracle) throws -> Void, printing: (PackPrinting) throws -> Void) throws -> PackHeader {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> PackHeader in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var header: PackHeader?
            var o = 0, p = 0
            var start = 0
            var fields: [String] = []
            fields.reserveCapacity(12)
            while start < n {
                var end = start
                while end < n && bytes[end] != 0x0A { end += 1 }
                if end > start {
                    fields.removeAll(keepingCapacity: true)
                    var f = start
                    for i in start...end where i == end || bytes[i] == 0x09 {
                        fields.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[f..<i]), as: UTF8.self))
                        f = i + 1
                    }
                    func at(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
                    if let h = header {
                        if fields[0] == "O", o < h.oracles {
                            try oracle(PackOracle(
                                idx: Int(at(1)) ?? o, oracleId: at(2), name: at(3), nameNorm: at(4), typeLine: at(5),
                                manaCost: at(6), cmc: Double(at(7)) ?? 0, colors: at(8), faceNames: at(9), legal: at(10)))
                            o += 1
                        } else if fields[0] == "P", p < h.printings {
                            try printing(PackPrinting(
                                cardId: at(1), oracleIdx: Int(at(2)) ?? -1, set: at(3), cn: at(4), lang: at(5),
                                rarity: at(6), finishes: at(7), releasedAt: at(8), imageTs: at(9),
                                imageFaces: Int(at(10)) ?? 0, printedName: at(11), original: at(12) == "1"))
                            p += 1
                        }
                        // Unknown line types are skipped (format rule).
                    } else {
                        guard at(0) == "#t1catalog", at(1) == "1" else { throw Failure.format }
                        header = PackHeader(version: at(2), oracles: Int(at(3)) ?? 0, printings: Int(at(4)) ?? 0)
                    }
                }
                start = end + 1
            }
            guard let header else { throw Failure.format }
            return header
        }
    }

    /// The pack is a gzip object (not HTTP Content-Encoding). Strips the gzip framing and inflates the raw
    /// DEFLATE body, which is what Compression's ZLIB algorithm reads.
    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw Failure.gzip }
        let flags = b[3]
        var pos = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard pos + 2 <= b.count else { throw Failure.gzip }
            pos += 2 + (Int(b[pos]) | Int(b[pos + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT: zero-terminated
            while pos < b.count && b[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 0x02 != 0 { pos += 2 } // FHCRC
        let bodyEnd = b.count - 8
        guard pos < bodyEnd else { throw Failure.gzip }
        let size = Int(UInt32(b[bodyEnd + 4]) | UInt32(b[bodyEnd + 5]) << 8 | UInt32(b[bodyEnd + 6]) << 16 | UInt32(b[bodyEnd + 7]) << 24)
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            b.withUnsafeBufferPointer { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.baseAddress! + pos, bodyEnd - pos, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.gzip }
        return out
    }

    /// Scryfall CDN image for one printing; images never go through our servers.
    static func imageURL(cardId: String, imageTs: String, size: String = "normal", back: Bool = false) -> URL? {
        guard cardId.count >= 2 else { return nil }
        let a = cardId.prefix(1), b = cardId.dropFirst().prefix(1)
        let ts = imageTs.isEmpty ? "" : "?\(imageTs)"
        return URL(string: "https://cards.scryfall.io/\(size)/\(back ? "back" : "front")/\(a)/\(b)/\(cardId).jpg\(ts)")
    }

    struct SearchCandidate {
        let idx: Int
        let norm: String
        let type: String
        let printings: Int
    }

    private static let extra = try! Regex(#"^(Token|Card|Emblem)\b|\bToken\b"#)

    /// Name search ranking, same as the web client: exact name, then a word starting with the query, then any
    /// substring, then tokens and art cards; within a tier the most-reprinted card first, then shorter names.
    /// `candidates` may be any superset of the cards whose name contains the query.
    static func rank(_ candidates: [SearchCandidate], query: String, limit: Int = 30) -> [Int] {
        let q = CardName.norm(query)
        guard q.count >= 2 else { return [] }
        let word = " " + q
        var tiers: [[SearchCandidate]] = [[], [], [], []]
        for c in candidates {
            var t: Int
            if c.norm == q { t = 0 }
            else if c.norm.hasPrefix(q) || c.norm.contains(word) { t = 1 }
            else if c.norm.contains(q) { t = 2 }
            else { continue }
            if t > 0 && c.type.contains(extra) { t = 3 }
            tiers[t].append(c)
        }
        var out: [Int] = []
        for tier in tiers {
            let sorted = tier.sorted {
                if $0.printings != $1.printings { return $0.printings > $1.printings }
                if $0.norm.count != $1.norm.count { return $0.norm.count < $1.norm.count }
                return $0.norm < $1.norm
            }
            for c in sorted {
                out.append(c.idx)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
