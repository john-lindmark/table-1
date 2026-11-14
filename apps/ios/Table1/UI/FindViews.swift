import SwiftUI
import WidgetKit

/* Finding events (contract/public-events-leagues-2026-11-13.md § 1 Clients): the Events home's Find events section and
   Find (Events | Leagues | Boards). One set of picks on the device feeds both. */

/// The Find events picks on this device and what they find. A server without the feature (`missing`) hides the
/// section; any other failure shows the error with Try again.
@MainActor
@Observable
final class FindStore {
    static let shared = FindStore()
    private(set) var filters = Leagues.Picks.load()
    private(set) var events: [FoundEvent]?
    private(set) var error: String?
    private(set) var missing = false
    /// Said once after a distance was picked and location was refused.
    private(set) var notice: String?
    private var run = 0

    /// A pick: kept on the device, counted, and the list read again.
    func change(_ filter: String, _ edit: (inout Leagues.Filters) -> Void) {
        var next = filters
        edit(&next)
        guard next != filters else { return }
        filters = next
        notice = nil
        Leagues.Picks.save(next)
        Telemetry.capture("find_filtered", ["filter": filter])
        Task { await load() }
    }

    func clear() { change("clear") { $0 = Leagues.Filters() } }

    /// Signed out: what the last account could find (its friends' events too) goes; the picks stay on the device.
    func stop() {
        run += 1
        events = nil
        error = nil
        notice = nil
        LeagueCache.pages = [:]
    }

    /// Where you are, only as far as the picks need it: a distance asks (and falls back to Everywhere when refused);
    /// otherwise a place is used only when location is already allowed, so rows can say how far.
    private func here() async -> Fix? {
        #if DEBUG
        if LeaguesDemo.on { return nil }
        #endif
        if filters.km != nil {
            if let fix = await LocationFix.shared.current() { UpcomingPlace.save(lat: fix.lat, lng: fix.lng); return fix }
            filters.km = nil
            Leagues.Picks.save(filters)
            notice = "Location is off, so this shows events everywhere."
            return nil
        }
        return await LocationFix.shared.currentIfAllowed()
    }

    func fetch(q: String = "") async throws -> [FoundEvent] {
        try await Repo.findEvents(filters, q: q, here: await here())
    }

    func load() async {
        run += 1
        let mine = run
        do {
            let found = try await fetch()
            guard mine == run else { return }
            events = found
            error = nil
            missing = false
        } catch where error.isCancellation {
            return
        } catch {
            guard mine == run else { return }
            if Leagues.isMissing(error) { missing = true; events = nil; return }
            self.error = Offline.notice(failed: true, savedAgo: nil, error: error.localizedDescription)?.text
        }
    }
}

extension FoundEvent {
    /// Organizers and players get the event itself; anyone else its page (sign-up, then standings).
    var route: Route { me == "organizer" || me == "player" ? .event(eventId) : .eventPage(eventId, signUp: false) }
}

/// A found event: the league (or FRIENDS) small above the name, one line of data, IN when you're in it.
struct FoundEventRow: View {
    let event: FoundEvent
    let open: (Route) -> Void

    /// The line with its pieces held together (no-break spaces inside each), so it wraps after a `·`.
    static func wrapping(_ line: String) -> String {
        line.components(separatedBy: " · ").map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "\u{00A0}· ")
    }

    var body: some View {
        Button {
            Telemetry.capture("found_event_opened", ["format_key": event.formatKey ?? "other", "visibility": event.visibility ?? "public",
                                                     "km": event.km ?? -1])
            open(event.route)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let label = event.rowLabel {
                        Text(label).font(T1.mono(9)).tracking(1.5).foregroundStyle(T1.muted).lineLimit(1)
                    }
                    Text(event.name).font(T1.mono(14)).lineLimit(1)
                    // The whole line of data (the distance sits at its end): onto a second line when it's long,
                    // breaking only between its pieces.
                    Text(Self.wrapping(event.line())).font(T1.mono(11)).tracking(1.5).foregroundStyle(T1.muted).lineLimit(2)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // First call on the row's width, so the line is measured against all of it.
                .layoutPriority(1)
                if event.isIn { LabelText("In", color: T1.accent).fixedSize() }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(T1.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Format · Where · When · More as attribute cells, each opening its picker.
struct FindFilterRow: View {
    private var store: FindStore { FindStore.shared }

    var body: some View {
        let f = store.filters
        let labels = Leagues.filterLabels(f)
        FilterRow(cells: [
            FilterCell(name: "Format", value: labels.format,
                       options: [SelectorOption(value: LimitedFilter.any, label: "Any format")]
                           + Leagues.formatKeys.map { SelectorOption(value: $0.key, label: $0.label) },
                       current: nil, picked: f.formats) { v in
                store.change("format") { if v == LimitedFilter.any { $0.formats = [] } else { $0.toggle(format: v) } }
            },
            FilterCell(name: "Where", value: labels.where,
                       options: [SelectorOption(value: "0", label: "Everywhere")] + Leagues.distances.map { SelectorOption(value: "\($0)", label: "\($0) km") },
                       current: "\(f.km ?? 0)") { v in
                store.change("where") { $0.km = Int(v).flatMap { $0 > 0 ? $0 : nil } }
            },
            FilterCell(name: "When", value: labels.when, options: Leagues.whens.map { SelectorOption(value: $0.key, label: $0.label) },
                       current: f.when) { v in
                store.change("when") { $0.when = v }
            },
            FilterCell(name: "More", value: labels.more, options: [], current: nil, open: {
                T1Overlays.shared.present { FindMorePanel().screen("find_filter_picker") }
            }) { _ in },
        ], event: nil, screen: "find_filter_picker", compact: true)
    }
}

/// More: Listed (All | Public | Friends), then Team events, League events and Seats left, each in or out.
struct FindMorePanel: View {
    private var store: FindStore { FindStore.shared }

    var body: some View {
        let f = store.filters
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MORE").font(T1.mono(12)).tracking(1.5).foregroundStyle(T1.muted)
                Spacer()
                Button { T1Overlays.shared.dismissPanel() } label: {
                    Text("DONE").font(T1.mono(12)).tracking(1.5).foregroundStyle(T1.text).padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .frame(height: 18)
            VStack(spacing: 0) {
                Text("LISTED").font(T1.mono(8)).tracking(1.5).foregroundStyle(T1.muted).frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
                HStack(spacing: 0) {
                    option("All", on: f.scope == "all") { store.change("scope") { $0.scope = "all" } }
                    option("Public", on: f.scope == "public") { store.change("scope") { $0.scope = "public" } }
                    option("Friends", on: f.scope == "friends") { store.change("scope") { $0.scope = "friends" } }
                }
                Color.clear.frame(height: 10)
                option("Team events", on: f.team) { store.change("team") { $0.team.toggle() } }
                option("League events", on: f.league) { store.change("league") { $0.league.toggle() } }
                option("Seats left", on: f.open) { store.change("open") { $0.open.toggle() } }
            }
        }
        .padding(16)
        .background(T1.bg)
    }

    private func option(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.uppercased()).font(T1.mono(12)).tracking(1.5).foregroundStyle(on ? T1.text : T1.muted).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 50)
                .overlay { if on { Rectangle().stroke(T1.accent, lineWidth: 1) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Nothing found: with picks, the way to clear them; with none, the way to make the first public event.
struct FindEmpty: View {
    let filtered: Bool
    let create: () -> Void

    var body: some View {
        if filtered {
            ListRow(title: "No events match") { BarButton("Clear filters") { FindStore.shared.clear() } }
        } else {
            ListRow(title: "No public events yet") { BarButton("Create an event", action: create) }
        }
    }
}

/// The Events home's Find events: the filter row, the first five and All N. Nothing at all on a server without it.
struct FindEventsSection: View {
    @Binding var path: [Route]
    private var store: FindStore { FindStore.shared }

    var body: some View {
        if !store.missing, store.events != nil || store.error != nil {
            Section1("Find events")
            FindFilterRow()
            if let notice = store.notice { Notice(notice) }
            if let error = store.error {
                ListRow(title: error) { BarButton("Try again") { Task { await store.load() } } }
            }
            if let events = store.events {
                if events.isEmpty {
                    FindEmpty(filtered: !store.filters.isDefault) { path.append(.create) }
                }
                ForEach(events.prefix(5)) { e in FoundEventRow(event: e) { path.append($0) } }
                if events.count > 5 {
                    Button { path.append(.find("events")) } label: {
                        ListRow(title: "All \(events.count)") { T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Find

/// Find: Events (everything you can find, with a search box), Leagues and Boards.
struct FindView: View {
    @Binding var path: [Route]
    @State var tab: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        T1Screen {
            Bar(title: "Find", back: { dismiss() }) {
                if tab == "leagues" {
                    T1IconButton(icon: .plus, label: "New league") {
                        T1Overlays.shared.present(full: true) {
                            LeagueEditPanel(league: nil) { made in path.append(.league(made.slug)) }.screen("league_new")
                        }
                    }
                    .padding(.vertical, -16).padding(.trailing, -16)
                }
            }
            T1Segmented(options: [(value: "events", label: "Events"), (value: "leagues", label: "Leagues"), (value: "boards", label: "Boards")],
                        selection: $tab)
            switch tab {
            case "leagues": FindLeaguesTab(path: $path)
            case "boards": FindBoardsTab(path: $path)
            default: FindEventsTab(path: $path)
            }
        }
        .onAppear { Telemetry.capture("find_opened", ["tab": tab]) }
        .onChange(of: tab) { _, t in Telemetry.capture("find_opened", ["tab": t]) }
    }
}

private struct FindEventsTab: View {
    @Binding var path: [Route]
    @State private var q = ""
    /// What the search box found (2+ characters); nil while it's empty.
    @State private var searched: [FoundEvent]?
    private var store: FindStore { FindStore.shared }

    private var words: String { q.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        T1SearchField(text: $q, prompt: "Name, venue or league")
        FindFilterRow()
        if let notice = store.notice { Notice(notice) }
        HairlineList {
            if store.missing {
                Notice("Finding events isn't available yet.")
            } else if let error = store.error {
                ListRow(title: error) { BarButton("Try again") { Task { await store.load() } } }
            }
            if let events = words.count >= 2 ? searched : store.events {
                if events.isEmpty, !store.missing {
                    FindEmpty(filtered: !store.filters.isDefault || words.count >= 2) { path.append(.create) }
                }
                ForEach(events) { e in FoundEventRow(event: e) { path.append($0) } }
            } else if store.error == nil, !store.missing {
                Notice("Loading…")
            }
            // Alerts for new public events (contract/teams-finals-alerts-2026-11-13.md § 4).
            if !store.missing, words.count < 2 {
                Color.clear.frame(height: 15)
                AlertsRow()
            }
        }
        .refreshable { await store.load(); await search() }
        .task { if store.events == nil { await store.load() } }
        .task(id: words) {
            // 0.25 s after the last key.
            guard words.count >= 2 else { searched = nil; return }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await search()
        }
        .onChange(of: store.filters) { Task { await search() } }
    }

    private func search() async {
        guard words.count >= 2 else { return }
        if let found = try? await store.fetch(q: words) { searched = found }
    }
}

private struct FindLeaguesTab: View {
    @Binding var path: [Route]
    @State private var home: LeaguesHome?
    @State private var q = ""
    @State private var error: String?
    @State private var missing = false

    private var words: String { q.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HairlineList {
            if missing {
                Notice("Leagues aren't available yet.")
            } else if let error {
                ListRow(title: error) { BarButton("Try again") { Task { await load() } } }
            }
            if let home {
                if !home.mine.isEmpty {
                    Section1("Yours")
                    ForEach(home.mine) { row($0) }
                }
                if !home.following.isEmpty {
                    Section1("Following")
                    ForEach(home.following) { row($0) }
                }
                T1SearchField(text: $q, prompt: "Name or region")
                ForEach(home.found) { row($0) }
                if words.count >= 2, home.found.isEmpty { ListRow(title: "No leagues match") }
            } else if error == nil, !missing {
                Notice("Loading…")
            }
        }
        .task(id: words) {
            if home != nil, words.count >= 2 { try? await Task.sleep(for: .milliseconds(250)) }
            if Task.isCancelled { return }
            await load()
        }
        // Coming back to it (a league just made, followed or archived).
        .onAppear { if home != nil { Task { await load() } } }
    }

    private func row(_ c: LeagueCard) -> some View {
        Button {
            Telemetry.capture("league_opened", ["from": "find"])
            path.append(.league(c.slug))
        } label: {
            ListRow(title: c.name, detail: c.line.isEmpty ? nil : c.line)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        do {
            home = try await Repo.leaguesHome(query: words.count >= 2 ? words : "")
            error = nil
        } catch where error.isCancellation {
            return
        } catch {
            if Leagues.isMissing(error) { missing = true } else { self.error = error.localizedDescription }
        }
    }
}

private struct FindBoardsTab: View {
    @Binding var path: [Route]
    @State private var boards: FormatBoards?
    @State private var error: String?
    @State private var missing = false

    var body: some View {
        HairlineList {
            if missing {
                Notice("Boards aren't available yet.")
            } else if let error {
                ListRow(title: error) { BarButton("Try again") { Task { await load() } } }
            }
            if let boards {
                ForEach(boards.boards) { b in
                    Button { path.append(.board(b.board)) } label: {
                        ListRow(title: b.label.uppercased(), detail: b.line)
                    }
                    .buttonStyle(.plain)
                }
            } else if error == nil, !missing {
                Notice("Loading…")
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            boards = try await Repo.formatBoards()
            error = nil
        } catch where error.isCancellation {
            return
        } catch {
            if Leagues.isMissing(error) { missing = true } else { self.error = error.localizedDescription }
        }
    }
}

// MARK: text (an event's or a league's description)

/// A full-screen box for a long text with its counter (`1,240 / 2,000`); Done hands the text back.
struct TextPanel: View {
    let title: String
    var limit = 2000
    @State var text: String
    let done: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: title) {
                LabelText(TextCount.text(text.count, of: limit))
                BarButton("Done") {
                    done(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    T1Overlays.shared.dismissPanel()
                }
            }
            TextEditor(text: $text)
                .font(T1.mono(15)).tint(T1.accent).scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(T1.surface)
                .onChange(of: text) { _, v in if v.count > limit { text = String(v.prefix(limit)) } }
        }
        .foregroundStyle(T1.text)
        .onAppear { focused = true }
    }
}

/// Prose with its `https://` links tappable (an event's or a league's description; plain text, line breaks kept).
struct LinkedText: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text)).font(T1.mono(15)).lineSpacing(5).tint(T1.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(T1.surface)
            .textSelection(.enabled)
    }

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = m.url, url.scheme == "https", let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: out), let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].link = url
            out[lo..<hi].underlineStyle = .single
        }
        return out
    }
}

/// Runs `load` once, the first time it's drawn, and takes no room once it has. A section that draws nothing until
/// its answer arrives can't hang `.task` on itself: a view with no content never runs one.
struct LoadOnce: View {
    let load: () async -> Void
    @State private var done = false

    var body: some View {
        if !done {
            // One point tall: a lazy list never draws (or runs the task of) a view with no height.
            Color.clear.frame(height: 1).task {
                await load()
                done = true
            }
        }
    }
}

/// A label on the left, its value on the right (design guidance § The flip): a details screen's rows.
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            LabelText(label)
            Spacer(minLength: 0)
            Text(value).font(T1.mono(13)).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(T1.surface)
    }
}

// MARK: the event page's About and league rows

/// On an event's screens: About (when it has a description or an address) and the league it's in. Shows nothing
/// until the server answers, and nothing at all on a server without it.
struct EventAboutRows: View {
    let eventId: String
    let open: (Route) -> Void
    /// Hands the answer up (the event page's sign-up notice needs it).
    var loaded: ((EventAbout) -> Void)?
    @State private var about: EventAbout?

    var body: some View {
        Group {
            LoadOnce {
                guard let a = try? await Repo.eventAbout(eventId) else { return }
                about = a
                loaded?(a)
            }
            if let about {
                if about.hasAbout {
                    Button {
                        T1Overlays.shared.present(full: true) { EventAboutPanel(about: about).screen("event_about") }
                    } label: {
                        ListRow(title: "About", detail: Self.rulesLine(about).nilIfEmpty ?? about.venueAddress) { T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18) }
                    }
                    .buttonStyle(.plain)
                }
                if let league = about.league, let target = league.slug ?? league.id {
                    Button {
                        Telemetry.capture("league_opened", ["from": "event"])
                        open(.league(target))
                    } label: {
                        ListRow(title: [league.name, league.season].compactMap { $0 }.joined(separator: " · "),
                                detail: Self.leagueDetail(league)) { T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// `COMPETITIVE · DECKLISTS DUE SAT 14 NOV 09:30` in the device's zone (contract/room-tools-2026-11-13.md § 4).
    static func rulesLine(_ a: EventAbout) -> String {
        RoomRules.rulesLine(rel: a.rel, due: a.decklistDueAt.flatMap(Leagues.parseDate).map { RoomRules.dueText($0) })
    }

    /// "League · final", "League · 2× points".
    static func leagueDetail(_ l: EventLeague) -> String {
        var parts = ["League"]
        if l.final == true { parts.append("Final") }
        else if let m = l.multiplier, m != 1 { parts.append("\(Leagues.multiplierText(m)) points") }
        return parts.joined(separator: " · ")
    }
}

private struct EventAboutPanel: View {
    let about: EventAbout

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "About", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    let rules = EventAboutRows.rulesLine(about)
                    if !rules.isEmpty {
                        LabelText(rules, color: T1.text).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                    }
                    if let seats = about.seatFormats, seats.count == 3 {
                        InfoRow(label: "Seats", value: (1...3).map { TeamRules.seatLabel(slot: $0, seatFormats: seats) }.joined(separator: "\n"))
                    }
                    if let d = about.description, !d.isEmpty { LinkedText(text: d) }
                    if let a = about.venueAddress, !a.isEmpty { InfoRow(label: "Address", value: a) }
                }
            }
        }
        .foregroundStyle(T1.text)
    }
}

/// Said once per device at sign-up for a public or league event (contract § 4 Clients).
enum PublicResultsNotice {
    static let text = "Results in public events are public: standings, league points and format boards. You can hide yourself from the boards in Sharing."
    private static let key = "leagues.publicResultsNoticeSeen"
    static var seen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}

// MARK: the widget's place

extension UpcomingPlace {
    /// The app's last rough place for the Upcoming events widget's Near me: only ever written when location is
    /// already allowed, rounded to 0.1°, kept in the App Group; the widget reloads when it moves.
    static func save(lat: Double, lng: Double) {
        if store(lat: lat, lng: lng) { WidgetCenter.shared.reloadTimelines(ofKind: UpcomingWidgets.kind) }
    }
}

// MARK: Create and Setup → Details

/// Description (its own text panel, counted to 2,000) and Address, on Create and Setup → Details.
struct ListingFields: View {
    let description: String
    @Binding var address: String
    let setDescription: (String) -> Void

    var body: some View {
        Button {
            T1Overlays.shared.present(full: true) {
                TextPanel(title: "Description", text: description, done: setDescription).screen("event_description")
            }
        } label: {
            ListRow(title: "Description", detail: description.isEmpty ? nil : TextCount.text(description.count, of: 2000)) {
                LabelText(description.isEmpty ? "Add" : "Change", color: T1.text)
            }
        }
        .buttonStyle(.plain)
        Field(label: "Address (optional)", text: $address)
    }
}

/// `1,240 / 2,000`.
enum TextCount {
    static func text(_ n: Int, of limit: Int) -> String {
        let us = Locale(identifier: "en_US")
        return "\(n.formatted(.number.locale(us))) / \(limit.formatted(.number.locale(us)))"
    }
}
