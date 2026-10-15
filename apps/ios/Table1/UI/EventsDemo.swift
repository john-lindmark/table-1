#if DEBUG
import SwiftUI

/// Design QA without signing in (Debug only): `-T1EventsDemo [create|setup|seating]` opens the create form,
/// the organizer's Setup on a sample draft, or the seating table for 8, 7 and a 3 v 3 team draft.
/// Server calls made from here fail (no session); everything on screen is sample data.
struct EventsDemoRoot: View {
    @State private var screen: String
    @State private var path: [Route] = []

    init() {
        let args = ProcessInfo.processInfo.arguments
        let i = args.firstIndex(of: "-T1EventsDemo").map { $0 + 1 }
        let pick = i.flatMap { $0 < args.count ? args[$0] : nil } ?? "create"
        _screen = State(initialValue: ["create", "setup", "seating"].contains(pick) ? pick : "create")
    }

    var body: some View {
        VStack(spacing: 0) {
            T1Segmented(options: [(value: "create", label: "Create"), (value: "setup", label: "Setup"),
                                  (value: "seating", label: "Seating")], selection: $screen)
            switch screen {
            case "setup":
                OrganizerView(b: DemoData.bundle, engine: DemoData.engine, refresh: {}, showSeating: { _ in }) {}
            case "seating":
                T1Screen {
                    Bar(title: "Seating", subtitle: "Sample pods")
                    HairlineList {
                        SeatingTable(pods: [DemoData.pod(8)], highlight: "p3")
                        SeatingTable(pods: [DemoData.pod(7)])
                        SeatingTable(pods: [DemoData.teamPod], teamDraft: true)
                    }
                }
            default:
                NavigationStack(path: $path) { CreateEventView(path: $path) }
            }
        }
        .background(T1.bg)
        .environment(SessionModel())
    }
}

private enum DemoData {
    static let names = ["Ann Ito", "Bo Lindqvist", "Cy Park", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Hal Brandt"]

    static func pod(_ n: Int) -> SeatingPod {
        decode(SeatingPod.self, """
        {"pod_id": "pod\(n)", "name": "Pod 1", "seats": [\((1...n).map { """
        {"seat": \($0), "participant_id": "p\($0)", "display_name": "\(names[$0 - 1])", "team": null}
        """ }.joined(separator: ","))]}
        """)
    }

    static let teamPod: SeatingPod = decode(SeatingPod.self, """
    {"pod_id": "team", "name": "Pod 1", "seats": [\((1...6).map { """
    {"seat": \($0), "participant_id": "t\($0)", "display_name": "\(names[$0 - 1])", "team": "\($0 % 2 == 1 ? "Ravens" : "Owls")"}
    """ }.joined(separator: ","))]}
    """)

    static let bundle = EventBundle(
        event: decode(EventRow.self, """
        {"id": "demo-event", "short_code": "K7Q2", "name": "Draft · Duskmourn: House of Horror · Tue 14 Oct",
         "format": "draft", "status": "seated", "number_of_rounds": 3, "current_round": 0,
         "round_length_seconds": 3000, "format_name": "draft", "format_label": "Draft · Duskmourn: House of Horror",
         "set_code": "dsk", "set_name": "Duskmourn: House of Horror", "show_clock": true, "auto_name": true}
        """),
        participants: (1...8).map { i in
            decode(ParticipantRow.self, """
            {"id": "p\(i)", "event_id": "demo-event", "display_name": "\(names[i - 1])", "seat": \(i), "status": "active",
             "user_id": \(i == 1 ? "\"me\"" : i % 3 == 0 ? "null" : "\"u\(i)\""), "pod_id": "pod8"}
            """)
        },
        rounds: [],
        isOrganizer: true
    )

    static let engine: StandingsResponse = {
        var r = StandingsResponse()
        r.seating = [pod(8)]
        return r
    }()

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! wireDecoder.decode(T.self, from: Data(json.utf8))
    }
}
#endif
