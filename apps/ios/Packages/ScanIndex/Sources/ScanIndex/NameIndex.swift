/// Normalized card names sorted by UTF-8 bytes, with byte trigrams for misread names: the data and lookups behind
/// the scanner's ScanNames (Table1/Library/CardMatcher.swift, which says which names go in). Built optimized in
/// every configuration (Package.swift), so Debug builds don't spend seconds on it.
public final class NameIndex: @unchecked Sendable {
    /// Names, sorted by UTF-8 bytes (cut-off names are looked up by prefix), with their card and language bits.
    public let keys: [String]
    public let idxs: [Int]
    /// Per key, a bit per language (0 = an English name).
    public let langBits: [UInt32]
    private let byKey: [String: Int]
    /// Trigram → the keys containing it, as a range of `postings` (key positions, ascending).
    private let grams: [Int: Range<Int>]
    private let postings: [Int32]

    /// English names (a card's highest printing count wins a name two cards share; the first on a tie), then
    /// printed names in other languages: never over an English name, one card's languages merged, and left out
    /// when two cards share one.
    public init(english: [(norm: String, idx: Int, printings: Int)], foreign: [(norm: String, idx: Int, lang: UInt32)]) {
        // printings -1 marks a printed name in another language; idx -1 one that two cards share.
        var best: [String: (idx: Int, printings: Int, langs: UInt32)] = [:]
        best.reserveCapacity(english.count + foreign.count)
        for e in english where best[e.norm].map({ e.printings > $0.printings }) ?? true { best[e.norm] = (e.idx, e.printings, 0) }
        for n in foreign {
            if let b = best[n.norm] {
                if b.printings < 0 && b.idx != n.idx { best[n.norm] = (-1, -1, 0) }
                else if b.printings < 0 && b.idx == n.idx { best[n.norm] = (b.idx, -1, b.langs | n.lang) }
            } else {
                best[n.norm] = (n.idx, -1, n.lang)
            }
        }
        // Byte order: the same as String's < for these normalized names, without its Unicode comparison.
        let sorted = best.filter { $0.value.idx >= 0 }.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        keys = sorted.map(\.key)
        idxs = sorted.map(\.value.idx)
        langBits = sorted.map(\.value.langs)
        var by: [String: Int] = [:]
        by.reserveCapacity(keys.count)
        for (i, k) in keys.enumerated() { by[k] = i }
        byKey = by
        // Every (trigram, key position), keys in order; a stable radix sort on the 24-bit trigram then gives one
        // ascending posting list per trigram.
        var tri: [UInt32] = [], pos: [Int32] = []
        tri.reserveCapacity(keys.count * 20)
        pos.reserveCapacity(keys.count * 20)
        var codes: [Int] = []
        for (i, k) in keys.enumerated() {
            codes.removeAll(keepingCapacity: true)
            Self.trigrams(k, into: &codes)
            codes.sort()
            var last = -1
            for c in codes where c != last { tri.append(UInt32(c)); pos.append(Int32(i)); last = c }
        }
        var t2 = [UInt32](repeating: 0, count: tri.count), p2 = [Int32](repeating: 0, count: pos.count)
        for shift in [0, 12] as [UInt32] {
            Self.radixPass(tri, pos, shift, &t2, &p2)
            swap(&tri, &t2)
            swap(&pos, &p2)
        }
        var g: [Int: Range<Int>] = [:]
        var start = 0
        for j in tri.indices where j + 1 == tri.count || tri[j + 1] != tri[j] {
            g[Int(tri[j])] = start..<(j + 1)
            start = j + 1
        }
        grams = g
        postings = pos
    }

    /// One stable counting-sort pass on 12 bits of the trigram.
    private static func radixPass(_ tri: [UInt32], _ pos: [Int32], _ shift: UInt32, _ t2: inout [UInt32], _ p2: inout [Int32]) {
        var count = [Int](repeating: 0, count: 4097)
        for v in tri { count[Int(v >> shift & 0xFFF) + 1] += 1 }
        for d in 1..<count.count { count[d] += count[d - 1] }
        for j in tri.indices {
            let d = Int(tri[j] >> shift & 0xFFF)
            t2[count[d]] = tri[j]
            p2[count[d]] = pos[j]
            count[d] += 1
        }
    }

    /// Byte trigrams of the name padded with a space each side.
    public static func trigrams(_ s: String, into out: inout [Int]) {
        var a = 32, b = -1
        for c in s.utf8 {
            if b >= 0 { out.append(a << 16 | b << 8 | Int(c)); a = b }
            b = Int(c)
        }
        if b >= 0 { out.append(a << 16 | b << 8 | 32) }
    }

    public static func trigrams(_ s: String) -> Set<Int> {
        var out: [Int] = []
        trigrams(s, into: &out)
        return Set(out)
    }

    /// The key position of a name.
    public func position(_ q: String) -> Int? { byKey[q] }

    /// The first key position not before `q` in byte order.
    public func lowerBound(_ q: String) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid].utf8.lexicographicallyPrecedes(q.utf8) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The key positions sharing at least `enough` of the trigrams, most shared first (then by position). A name
    /// missing from all of the shortest `lists.count - enough + 1` posting lists shares too few, so only those are
    /// walked to find candidates; the long lists (" th", "es ", the bulk of a long misread line) are only searched
    /// for the candidates still able to reach `enough`.
    public func sharing(_ tg: Set<Int>, _ enough: Int) -> [Int] {
        let lists = tg.compactMap { grams[$0] }.sorted { $0.count < $1.count }
        // Trigrams no name has count as empty lists, the shortest of all.
        let seed = lists.count - enough + 1
        guard seed > 0 else { return [] }
        // Shared trigrams per key position.
        var sh = [UInt8](repeating: 0, count: keys.count)
        var live: [Int32] = []
        live.reserveCapacity(lists[..<seed].reduce(0) { $0 + $1.count })
        /// Drops the candidates that can't reach `enough` with `left` lists to go.
        func prune(_ left: Int) { live.removeAll { Int(sh[Int($0)]) + left < enough } }
        for r in lists[..<seed] {
            for j in r {
                let i = Int(postings[j])
                if sh[i] == 0 { live.append(postings[j]) }
                sh[i] &+= 1
            }
        }
        var left = lists.count - seed
        prune(left)
        for r in lists[seed...] where !live.isEmpty {
            left -= 1
            // Walk the list, or binary-search it for each candidate, whichever reads fewer postings.
            if live.count * (Int.bitWidth - r.count.leadingZeroBitCount) < r.count {
                for i in live {
                    var lo = r.lowerBound, hi = r.upperBound
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if postings[mid] < i { lo = mid + 1 } else { hi = mid }
                    }
                    if lo < r.upperBound && postings[lo] == i { sh[Int(i)] &+= 1 }
                }
            } else {
                for j in r {
                    let i = Int(postings[j])
                    if sh[i] != 0 { sh[i] &+= 1 }
                }
            }
            prune(left)
        }
        return live.map(Int.init).sorted { sh[$0] != sh[$1] ? sh[$0] > sh[$1] : $0 < $1 }
    }

    /// Levenshtein distance, giving up (cap + 1) once it's sure to exceed cap.
    public static func distance(_ a: [UInt32], _ b: [UInt32], cap: Int) -> Int {
        if abs(a.count - b.count) > cap { return cap + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            var low = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                low = min(low, cur[j])
            }
            if low > cap { return cap + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
