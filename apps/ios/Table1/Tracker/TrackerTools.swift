import Foundation

/// Roll dice from the tracker's Options. Pure, so the tests can pass a seeded generator.
enum Dice {
    static let sides = [4, 6, 8, 10, 12, 20]
    static let maxCount = 10

    /// `count` dice of `sides` faces, each 1…sides. Count is clamped to 1…maxCount.
    static func roll<G: RandomNumberGenerator>(sides: Int, count: Int, using rng: inout G) -> [Int] {
        let n = min(max(count, 1), maxCount)
        let faces = max(sides, 2)
        return (0..<n).map { _ in Int.random(in: 1...faces, using: &rng) }
    }

    static func roll(sides: Int, count: Int) -> [Int] {
        var rng = SystemRandomNumberGenerator()
        return roll(sides: sides, count: count, using: &rng)
    }

    /// "3 + 5 + 1"; nothing for a single die (the total says it).
    static func breakdown(_ rolls: [Int]) -> String? {
        rolls.count > 1 ? rolls.map(String.init).joined(separator: " + ") : nil
    }
}

/// The chooser: everyone puts a finger on the screen; once the fingers on it have stayed the same for
/// `settle` seconds (two or more of them), one is picked at random. It stays picked until every finger
/// lifts; fingers that land after the pick are ignored until then.
struct Chooser {
    static let settle: TimeInterval = 2.0
    static let minFingers = 2
    /// After the pick the tracker comes back on its own this much later.
    static let returnAfter: TimeInterval = 1.5

    struct Finger: Equatable {
        let id: Int
        var x: Double
        var y: Double
    }

    private(set) var fingers: [Finger] = []
    /// When the set of fingers last changed (a finger landed or lifted); moving one doesn't count.
    private(set) var changedAt: Date?
    private(set) var winner: Int?
    /// After the pick every circle stays drawn until the last finger lifts; these are the ones still down.
    private var pressed: Set<Int> = []

    var picked: Bool { winner != nil }

    mutating func down(_ id: Int, x: Double, y: Double, at now: Date) {
        guard !picked, !fingers.contains(where: { $0.id == id }) else { return }
        fingers.append(Finger(id: id, x: x, y: y))
        pressed.insert(id)
        changedAt = now
    }

    mutating func move(_ id: Int, x: Double, y: Double) {
        guard let i = fingers.firstIndex(where: { $0.id == id }) else { return }
        fingers[i].x = x
        fingers[i].y = y
    }

    mutating func up(_ id: Int, at now: Date) {
        guard pressed.remove(id) != nil else { return }
        if picked {
            if pressed.isEmpty { reset() }
            return
        }
        fingers.removeAll { $0.id == id }
        changedAt = fingers.isEmpty ? nil : now
    }

    mutating func reset() {
        fingers = []
        pressed = []
        changedAt = nil
        winner = nil
    }

    /// Share of the settle time gone (0…1) while waiting to pick; nil when there aren't enough fingers.
    func progress(at now: Date) -> Double? {
        guard !picked, fingers.count >= Self.minFingers, let changedAt else { return nil }
        return min(1, max(0, now.timeIntervalSince(changedAt) / Self.settle))
    }

    /// Picks once the fingers have settled; returns the winner when this call picked one.
    mutating func tick<G: RandomNumberGenerator>(at now: Date, using rng: inout G) -> Int? {
        guard let p = progress(at: now), p >= 1, let pick = fingers.randomElement(using: &rng) else { return nil }
        winner = pick.id
        return pick.id
    }

    mutating func tick(at now: Date) -> Int? {
        var rng = SystemRandomNumberGenerator()
        return tick(at: now, using: &rng)
    }
}
