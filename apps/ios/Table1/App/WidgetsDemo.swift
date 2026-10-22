#if DEBUG
import SwiftUI
import WidgetKit

/// Design QA for the widgets batch without a home screen: `-T1WidgetsDemo [organizer|next|value]` draws every
/// family on sample data at its real size (iPhone 17 points). Debug only.
struct WidgetsDemoRoot: View {
    private let only: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-T1WidgetsDemo"), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
        return args[i + 1]
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if only == nil || only == "organizer" { organizer }
                if only == nil || only == "next" { next }
                if only == nil || only == "value" { value }
            }
            .padding(16)
        }
        .background(Color(white: 0.32).ignoresSafeArea())
    }

    private static var between: OrganizerSnapshot {
        var s = OrganizerSnapshot.sample
        s.state.phase = "between"; s.state.endsAt = nil; s.state.matches = 0; s.state.done = 0; s.state.waiting = 0
        s.state.disputes = 0; s.state.guestWaiting = 0
        return s
    }

    private static var ready: OrganizerSnapshot {
        var s = OrganizerSnapshot.sample
        s.state.round = 4; s.state.done = 8; s.state.waiting = 0; s.state.disputes = 0; s.state.guestWaiting = 0
        s.state.endsAt = nil; s.state.pausedRemaining = 312
        return s
    }

    @ViewBuilder private var organizer: some View {
        caption("Organizer Live Activity · lock screen")
        OrganizerLockScreenView(snap: .sample).frame(width: 370).background(W1.bg)
        OrganizerLockScreenView(snap: Self.ready).frame(width: 370).background(W1.bg)
        OrganizerLockScreenView(snap: Self.between).frame(width: 370).background(W1.bg)
    }

    @ViewBuilder private var next: some View {
        let data = NextEventData(events: [
            NextEventItem(id: "a", name: "Friday Modern", status: "open", bucket: "upcoming", organizing: true, playing: true,
                          venueName: "Mox Boarding House", startsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(2 * 3600 + 600)),
                          numberOfRounds: 4, currentRound: 0, players: 12, formatLabel: "Modern", format: "modern"),
            NextEventItem(id: "b", name: "Sunday Vintage Cube", status: "open", bucket: "upcoming", organizing: false, playing: true,
                          venueName: nil, startsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(2 * 86400)),
                          numberOfRounds: 3, currentRound: 0, players: 8, formatLabel: "Cube draft", format: "cube"),
        ], invites: 2)
        caption("Next event · small, medium, lock screen, empty")
        HStack(spacing: 16) {
            tile(.systemSmall) { NextEventView(family: .systemSmall, data: data) }
            tile(.systemSmall) { NextEventView(family: .systemSmall, data: NextEventData()) }
        }
        tile(.systemMedium) { NextEventView(family: .systemMedium, data: data) }
        tile(.accessoryRectangular) { NextEventView(family: .accessoryRectangular, data: data) }
        tile(.accessoryInline) { NextEventView(family: .accessoryInline, data: data) }
    }

    @ViewBuilder private var value: some View {
        caption("Collection value · small, medium, no history")
        HStack(spacing: 16) {
            tile(.systemSmall) { ValueView(family: .systemSmall, record: .sample) }
            tile(.systemSmall) {
                ValueView(family: .systemSmall, record: ValueRecord(userId: "x", points: [ValuePoint(day: ValueHistory.day(.now), usd: 812.4)]))
            }
        }
        tile(.systemMedium) { ValueView(family: .systemMedium, record: .sample) }
    }

    private func caption(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 11, design: .monospaced)).tracking(1.2).foregroundStyle(.white)
    }

    private func tile(_ family: WidgetFamily, @ViewBuilder _ content: () -> some View) -> some View {
        let size: CGSize = switch family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 250, height: 22)
        default: CGSize(width: 170, height: 170)
        }
        let system = family == .systemSmall || family == .systemMedium
        return content()
            .padding(system ? 16 : 0)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .foregroundStyle(.white)
            .background(system ? W1.bg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: system ? 22 : 0))
    }
}
#endif
