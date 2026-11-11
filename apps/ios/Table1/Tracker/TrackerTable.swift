import CoreGraphics
import SwiftUI

/// Where a player sits around the phone (contract/life-tracker-commander-2026-11-03.md). Each seat faces its own
/// edge: `bottom` reads normally, `top` is turned 180°, `left` 90° clockwise, `right` 90° counter-clockwise.
///
/// SwiftUI's rotation turns only the drawing, so a seat is laid out in screen order (columns, tap zones and
/// picker rows placed where that player sees them) and only its text is turned (`Turned`).
enum TrackerSeat: String {
    case bottom, top, left, right

    var degrees: Double {
        switch self {
        case .bottom: 0
        case .top: 180
        case .left: 90
        case .right: -90
        }
    }

    /// Left and right seats run their columns down the screen.
    var sideways: Bool { self == .left || self == .right }

    /// The player's left-to-right (columns, a header's label then its button) runs against screen order.
    var reversed: Bool { self == .top || self == .right }

    /// The edge farthest from the player: their "top", where the counter picker comes down from.
    var farEdge: Edge {
        switch self {
        case .bottom: .top
        case .top: .bottom
        case .left: .trailing
        case .right: .leading
        }
    }

    var farAlignment: Alignment {
        switch self {
        case .bottom: .top
        case .top: .bottom
        case .left: .trailing
        case .right: .leading
        }
    }

    /// The player's top comes first in screen order (top, or left for sideways seats): their +1 tap zone, and
    /// the counter picker's header and first rows.
    var topFirst: Bool { self == .bottom || self == .right }

    /// The delta of the first tap zone in screen order: +1 sits on the player's top half of a column.
    var firstZoneDelta: Int { topFirst ? 1 : -1 }

    /// A drag in screen points, measured toward the player (their "down") and across.
    func toward(_ t: CGSize) -> (down: CGFloat, across: CGFloat) {
        switch self {
        case .bottom: (t.height, t.width)
        case .top: (-t.height, t.width)
        case .left: (-t.width, t.height)
        case .right: (t.width, t.height)
        }
    }

    /// A swipe toward the player opens their counter picker. No swipe closes it, only Done: swiping away is also
    /// how the picker's rows scroll (commander damage made the list long).
    func opensPicker(_ t: CGSize, min: CGFloat = TrackerTouch.swipe) -> Bool {
        let (down, across) = toward(t)
        return down >= min && down > abs(across) * 1.5
    }

    /// How far a point in a box (screen points, origin top-left) is from this player's far edge, their "top".
    func far(_ p: CGPoint, in size: CGSize) -> CGFloat {
        switch self {
        case .bottom: p.y
        case .top: size.height - p.y
        case .left: size.width - p.x
        case .right: p.x
        }
    }
}

/// The touch rule (contract/life-tracker-options-2026-10-20.md § Taps and the pull band, cases
/// testdata/tracker-touch/cases.json). A touch on a +1 / −1 zone always counts, however far it drifts; only one
/// that starts in the pull band along the player's far edge and travels toward them opens the counter picker.
enum TrackerTouch {
    /// The pull band's depth from the player's far edge.
    static let band: CGFloat = 44
    /// Travel toward the player that opens the picker.
    static let swipe: CGFloat = 24
    /// Travel before the hold delay that makes a touch a rolled tap, not a hold (no repeat).
    static let holdSlop: CGFloat = 24
    /// The old cancel distance: telemetry counts the taps that travelled past it (they used to be lost).
    static let moved: CGFloat = 10

    static func inBand(_ seat: TrackerSeat, at p: CGPoint, in size: CGSize) -> Bool { seat.far(p, in: size) <= band }

    static func pulls(_ seat: TrackerSeat, from p: CGPoint, in size: CGSize, by t: CGSize) -> Bool {
        inBand(seat, at: p, in: size) && seat.opensPicker(t)
    }

    static func holds(_ t: CGSize) -> Bool { hypot(t.width, t.height) <= holdSlop }
}

/// What the tracker's touches did while it was open, sent as `tracker_touches` when it closes: taps, taps that
/// travelled past the old 10 pt cancel (`moved`), pulls that opened the picker, holds.
@MainActor
final class TrackerTouchStats {
    static let shared = TrackerTouchStats()
    var taps = 0, moved = 0, pulls = 0, holds = 0, bandTaps = 0

    func flush(players: Int, mode: String) {
        defer { taps = 0; moved = 0; pulls = 0; holds = 0; bandTaps = 0 }
        guard taps + pulls > 0 else { return }
        Telemetry.capture("tracker_touches", ["taps": taps, "moved": moved, "pulls": pulls, "holds": holds,
                                              "band_taps": bandTaps, "players": players, "mode": mode])
    }
}

/// The table a local tracker is set up for: 2–5 players and their starting life.
enum TrackerTable {
    static let playerChoices = [2, 3, 4, 5]
    static let lifeChoices = [20, 30, 40]
    /// Commander damage counts from this starting life (Commander 40, Pauper Commander 30; Oathbreaker is 20).
    static let commanderFrom = 30
    /// Commander damage from one opponent that loses the game.
    static let commanderLoss = 21

    struct Place: Equatable {
        let side: Int
        let seat: TrackerSeat
    }

    enum Row: Equatable {
        case seats([Place])
        case strip
    }

    /// Rows top to bottom on screen; seats go clockwise from the bottom.
    static func layout(_ players: Int) -> [Row] {
        switch players {
        case 3:
            [.seats([Place(side: 1, seat: .left), Place(side: 2, seat: .right)]), .strip, .seats([Place(side: 0, seat: .bottom)])]
        case 4:
            [.seats([Place(side: 1, seat: .left), Place(side: 2, seat: .right)]), .strip,
             .seats([Place(side: 0, seat: .left), Place(side: 3, seat: .right)])]
        case 5:
            [.seats([Place(side: 2, seat: .left), Place(side: 3, seat: .right)]),
             .seats([Place(side: 1, seat: .left), Place(side: 4, seat: .right)]), .strip,
             .seats([Place(side: 0, seat: .bottom)])]
        default:
            [.seats([Place(side: 1, seat: .top)]), .strip, .seats([Place(side: 0, seat: .bottom)])]
        }
    }

    static func names(_ players: Int) -> [String] {
        players <= 2 ? ["You", "Opponent"] : (1...players).map { "P\($0)" }
    }

    /// The last setup used on this device.
    static var lastPlayers: Int {
        get { playerChoices.contains(UserDefaults.standard.integer(forKey: "tracker.setup.players")) ? UserDefaults.standard.integer(forKey: "tracker.setup.players") : 2 }
        set { UserDefaults.standard.set(newValue, forKey: "tracker.setup.players") }
    }

    static var lastLife: Int {
        get { lifeChoices.contains(UserDefaults.standard.integer(forKey: "tracker.setup.life")) ? UserDefaults.standard.integer(forKey: "tracker.setup.life") : 20 }
        set { UserDefaults.standard.set(newValue, forKey: "tracker.setup.life") }
    }
}

/// Draws its content turned to face a seat. The content is laid out in the seat's own frame (width and height
/// swapped for sideways seats) so wrapping and `minimumScaleFactor` work as the player reads it. Drawing only:
/// touches go to whatever sits under it in screen order.
struct Turned<Content: View>: View {
    let seat: TrackerSeat
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let w = seat.sideways ? geo.size.height : geo.size.width
            let h = seat.sideways ? geo.size.width : geo.size.height
            content
                .frame(width: w, height: h)
                .rotationEffect(.degrees(seat.degrees))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}
