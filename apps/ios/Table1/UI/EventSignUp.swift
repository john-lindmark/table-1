import SwiftUI

// Scheduled events, the sign-up link, the waitlist, top 8 and decklists (contract/scheduled-events-2026-10-27.md):
// the form pieces Create and Setup → Details share, the in-app event page behind https://table-1.site/s/<id>,
// the waitlist and decklist rows of Setup → Players, the top 8 bracket, and the decklist screen.

// MARK: share link

/// The share sheet with the event's sign-up link (the standings page once round 1 is paired).
@MainActor
func shareEventLink(_ e: EventRow) {
    let when = EventRules.when(e.startsAt).map { " · \($0)" } ?? ""
    let text = "\(e.name)\(when)\n\(e.isBeforeRound1 ? "Sign up" : "Standings"): \(WebLink.standingsURL(e.id).absoluteString)"
    Telemetry.capture("event_link_shared", ["before_round_1": e.isBeforeRound1])
    let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return }
    var top = root
    while let next = top.presentedViewController { top = next }
    vc.popoverPresentationController?.sourceView = top.view
    top.present(vc, animated: true)
}

// MARK: form pieces (Create and Details)

/// When (Now | Later with a date and time), where, and the player cap.
struct ScheduleFields: View {
    @Binding var schedule: EventSchedule

    private static func defaultStart() -> Date {
        // Tomorrow at 18:00 local, a usual store night.
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        Section1("When")
        T1Segmented(options: [(value: false, label: "Now"), (value: true, label: "Later")], selection: Binding(
            get: { schedule.startsAt != nil },
            set: { later in schedule.startsAt = later ? (schedule.startsAt ?? Self.defaultStart()) : nil }
        ))
        if let start = schedule.startsAt {
            ListRow(title: "Starts", detail: EventRules.when(Repo.iso(start))) {
                DatePicker("Starts", selection: Binding(get: { start }, set: { schedule.startsAt = $0 }),
                           in: Date()...Date().addingTimeInterval(365 * 86_400),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().tint(T1.accent).colorScheme(.dark)
            }
            Notice("Shown on the event and its sign-up link. You still start round 1 yourself.")
        }
        Field(label: "Where (optional)", text: $schedule.venue)
            .onChange(of: schedule.venue) { _, v in if v.count > 80 { schedule.venue = String(v.prefix(80)) } }
        T1Switch(title: "Player cap", detail: schedule.capacity.map { "\($0) players" } ?? "No cap", isOn: Binding(
            get: { schedule.capacity != nil },
            set: { schedule.capacity = $0 ? (schedule.capacity ?? 8) : nil }
        ))
        if schedule.capacity != nil {
            T1Stepper(label: "Cap", value: Binding(get: { schedule.capacity ?? 8 }, set: { schedule.capacity = $0 }), range: 4...512)
            Notice("Sign-ups past the cap join a waitlist. You can still add players yourself.")
        }
    }
}

/// Automatic rounds and the top cut (Swiss events of players only), then the rounds stepper when set by hand.
struct CutAndRoundsFields: View {
    @Binding var autoRounds: Bool
    @Binding var rounds: Int
    @Binding var topCut: Int
    let players: Int
    /// Swiss events of players (not team events or round robin).
    let swiss: Bool
    /// Drafts with pods: the automatic count follows the pods (DraftPods.autoLabel).
    var autoDetail: String?

    var body: some View {
        if swiss {
            T1Switch(title: "Automatic rounds", detail: autoRounds ? (autoDetail ?? EventRules.autoLabel(players: players)) : "Set by hand",
                     isOn: $autoRounds)
        }
        if !swiss || !autoRounds {
            T1Stepper(label: "Rounds", value: $rounds, range: 1...15)
        }
        if swiss {
            T1Segmented(options: [(value: 0, label: "No top cut"), (value: 8, label: "Top 8")], selection: $topCut)
            if topCut == 8 {
                Notice(players > 8 || players < 2
                       ? "After Swiss, the top 8 play single elimination: quarterfinals, semifinals, final."
                       : "Top 8 needs 9 or more players: with \(players) the event ends after Swiss.")
            }
        }
    }
}

/// Drafts: how many pods (Auto = pods of up to 8) and how rounds 2+ pair (contract/draft-pods-2026-11-09.md).
struct DraftPodFields: View {
    @Binding var pods: Int?
    @Binding var pairing: String
    let players: Int
    /// The seats are drawn: a new number of pods re-draws them.
    var seated = false

    var body: some View {
        Section1("Pods")
        T1Segmented(options: [(value: false, label: "Auto"), (value: true, label: "Choose")],
                    selection: Binding(get: { pods != nil },
                                       set: { on in pods = on ? max(2, DraftPods.count(players: players, pods: nil)) : nil }))
        if let n = pods {
            T1Stepper(label: "Pods", value: Binding(get: { n }, set: { pods = $0 }), range: 1...16)
        }
        Notice(DraftPods.label(players: players, pods: pods) + (seated ? " · a new number re-draws the seats" : ""))
        T1Segmented(options: [(value: DraftPods.inside, label: "Inside pods"), (value: DraftPods.across, label: "Across pods")],
                    selection: $pairing)
        Notice(pairing == DraftPods.inside ? "After round 1 you play your own pod." : "After round 1, Swiss across every pod.")
    }
}

/// Decklists for constructed events: off, optional or required before round 1.
struct DecklistsFields: View {
    @Binding var mode: String

    var body: some View {
        Section1("Decklists")
        T1Segmented(options: [(value: "off", label: "Off"), (value: "optional", label: "Optional"), (value: "required", label: "Required")],
                    selection: $mode)
        switch mode {
        case "required": Notice("Players add their list as text or from their Table 1 decks. Round 1 waits until every list is in.")
        case "optional": Notice("Players can add their list as text or from their Table 1 decks. Only you see them.")
        default: EmptyView()
        }
    }
}

// MARK: Setup → Players

/// The waitlist under the players: Let in (past the cap) or Remove.
struct WaitlistRows: View {
    let b: EventBundle
    let act: (@escaping () async throws -> Void) -> Void

    var body: some View {
        if !b.waitlist.isEmpty {
            Section1("Waitlist · \(b.waitlist.count)")
            ForEach(b.waitlist) { w in
                ListRow(title: "#\(w.position) \(w.displayName)", detail: b.event.isBeforeRound1 ? nil : "Didn't get in",
                        avatar: AvatarView(name: w.displayName, userId: w.userId)) {
                    if b.event.isBeforeRound1 {
                        HStack(spacing: 16) {
                            Button { admit(w) } label: { LabelText("Let in", color: T1.accent) }.buttonStyle(.plain)
                            Button { remove(w) } label: { LabelText("Remove", color: T1.danger) }.buttonStyle(.plain)
                        }
                    }
                }
                .opensProfile(w.userId, from: "waitlist")
            }
        }
    }

    @MainActor private func admit(_ w: WaitlistEntry) {
        let id = b.event.id
        act { try await Repo.waitlistAdmit(id, userId: w.userId) }
    }

    @MainActor private func remove(_ w: WaitlistEntry) {
        let id = b.event.id
        act { try await Repo.waitlistRemove(id, userId: w.userId) }
    }
}

extension EventBundle {
    /// "Decklist ✓" / "No decklist" for a player's row (events that take lists).
    func decklistDetail(_ p: ParticipantRow) -> String? {
        guard event.takesDecklists else { return nil }
        return decklist(p.id) == nil ? "No decklist" : "Decklist ✓"
    }

    var decklistsMissing: Int {
        participants.filter { $0.status == "active" && decklist($0.id) == nil }.count
    }
}

// MARK: top 8

/// Standings → Top 8: each playoff stage paired so far, "(1) Ana 2–0 (8) Bo", the winner in the accent, then the
/// Standings header (rank is the final order once the cut is made).
struct BracketRows: View {
    let bracket: [BracketStage]

    var body: some View {
        if !bracket.isEmpty {
            Section1("Top 8")
            ForEach(bracket, id: \.stage) { stage in
                LabelText(stage.title).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(T1.bg)
                ForEach(stage.matches) { m in
                    HStack(spacing: 8) {
                        side(m, 0)
                        Text(m.status == "pending" ? "v" : "\(m.sides.first?.gameWins ?? 0)–\(m.sides.dropFirst().first?.gameWins ?? 0)")
                            .font(T1.mono(14)).foregroundStyle(T1.muted)
                        side(m, 1)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T1.surface)
                }
            }
            Section1("Standings")
        }
    }

    private func side(_ m: BracketStage.Match, _ n: Int) -> some View {
        let s = m.sides.indices.contains(n) ? m.sides[n] : nil
        let won = s?.participantId != nil && s?.participantId == m.winner
        return Text("(\(s?.seed.map(String.init) ?? "–")) \(s?.displayName ?? "—")")
            .font(T1.mono(14, won ? .bold : .regular)).lineLimit(1)
            .foregroundStyle(won ? T1.accent : T1.text)
            .frame(maxWidth: .infinity, alignment: n == 0 ? .leading : .trailing)
    }
}

// MARK: event page (/s/<id>)

/// What anyone with the link sees before round 1: when, where, how many are in, and Sign up / the waitlist.
/// Organizers and players go to the event itself. After round 1 it's the standings page, drawn here too (Standings |
/// Matchups, as on the web), so a link never drops someone who isn't playing into a web sheet
/// (contract/event-links-2026-11-09.md).
struct EventPageView: View {
    let eventId: String
    /// Arrived through sign-in from the link: sign up straight away.
    var signUpNow = false
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var page: EventPage?
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var confirmLeave = false
    @State private var signedUpOnce = false
    /// After round 1: the engine's standings (top 8 bracket included) and which tab.
    @State private var standings: StandingsResponse?
    @State private var matchups = false
    /// Following it when you're not in it (contract/event-follows-2026-11-09.md).
    @State private var follow: EventFollow?

    private var state: EventRules.PageButton {
        EventRules.button(signedIn: true, signUp: page?.signUp, me: page?.me)
    }

    var body: some View {
        T1Screen {
            Bar(title: page?.name ?? "Event",
                subtitle: page.map { $0.available && $0.showsResults ? $0.resultsTitle : $0.shortCode.map { "Event \($0)" } } ?? nil,
                back: { dismiss() })
            if let page, page.available, page.showsResults {
                results(page)
            } else {
                signUpBody
            }
        }
        .task { await load(signUp: signUpNow) }
        .task(id: page?.showsResults == true) {
            // The standings page follows the event while it's open, like the web's.
            guard page?.showsResults == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { break }
                await load(signUp: false)
            }
        }
        .alert("Leave \(page?.name ?? "the event")?", isPresented: $confirmLeave) {
            Button("Stay", role: .cancel) {}
            Button("Leave", role: .destructive) { leave() }
        } message: {
            Text(state == .waitlisted ? "You'll lose your place on the waitlist."
                 : (page?.waitlist ?? 0) > 0 ? "Your place goes to the next person on the waitlist." : "You can sign up again while there's room.")
        }
        .onAppear { Telemetry.capture("event_page_viewed", ["state": page?.showsResults == true ? "results" : state.rawValue]) }
    }

    /// After round 1: Standings (the top 8 first once cut) and Matchups (every round, newest first).
    @ViewBuilder
    private func results(_ page: EventPage) -> some View {
        if page.me == "waitlisted" { Notice("Sign-ups are closed: you didn't get in this time.") }
        followRow
        T1Segmented(options: [(value: false, label: "Standings"), (value: true, label: "Matchups")], selection: $matchups)
        HairlineList {
            if let error { Notice(error, error: true) }
            if !matchups {
                if let standings {
                    BracketRows(bracket: standings.bracket ?? [])
                    StandingsRows(engine: standings, highlight: nil)
                    Notice("Ordered by match points, then opponents' match-win %, then game-win %, then opponents' game-win %. Percentages floored at 33% per the Magic Tournament Rules.")
                } else if error == nil {
                    Notice("Loading…")
                }
            } else if page.matchupRounds.isEmpty {
                Notice("No rounds yet")
            } else {
                ForEach(page.matchupRounds) { r in
                    Section1(r.title)
                    ForEach(r.matches ?? []) { m in PublicMatchRow(match: m) }
                }
            }
        }
        .refreshable { await load(signUp: false) }
        if page.me == "organizer" || page.me == "player" {
            BigAction(text: "Open event", accent: true) { path = [.event(eventId)] }
        }
    }

    private var signUpBody: some View {
        Group {
            ScrollView {
                VStack(spacing: 1) {
                    if let page, page.available {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.name ?? "Event").font(T1.mono(22)).lineLimit(3)
                            if !page.facts.isEmpty { Text(page.facts).font(T1.mono(12)).foregroundStyle(T1.muted) }
                            LabelText(page.roundsLine)
                            if (page.decklists ?? "off") != "off" {
                                LabelText(page.decklists == "required" ? "Decklist required" : "Decklists welcome")
                            }
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(T1.surface)
                        ListRow(title: page.signUpLine)
                        followRow
                        if let message { Notice(message) }
                        if let error { Notice(error, error: true) }
                        status
                    } else if page != nil {
                        Notice("That event isn't available.", error: true)
                    }
                }
            }
            action
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .in: Notice("You're in. Your event is on the Events tab.")
        case .waitlisted: Notice("You're number \(page?.position ?? 1) on the waitlist. We'll tell you if a place opens.")
        case .organizer: Notice("You're running this event.")
        case .closed: Notice("Sign-ups are closed.")
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .signUp, .signIn: BigAction(text: "Sign up", busy: busy, accent: true) { signUp() }
        case .waitlist: BigAction(text: "Join the waitlist", busy: busy, accent: true) { signUp() }
        case .in, .organizer:
            HStack(spacing: 1) {
                if state == .in { Ghost(text: "Leave") { confirmLeave = true } }
                Ghost(text: "Open event", accent: true) { path = [.event(eventId)] }
            }
        case .waitlisted: BigAction(text: "Leave the waitlist", busy: busy) { confirmLeave = true }
        case .closed: EmptyView()
        }
    }

    /// Follow / Following for anyone signed in who doesn't run or play in it (and can, or already does).
    @ViewBuilder
    private var followRow: some View {
        if let f = follow, page?.me != "organizer", page?.me != "player", f.following || f.canFollow == true {
            Button { followTapped(f) } label: {
                ListRow(title: f.following ? "Following" : "Follow",
                        detail: f.following ? (f.notify ? "Each round and the final standings" : "Notifications off") : nil) {
                    LabelText(f.following ? "✓" : "Follow", color: f.following ? T1.accent : T1.text)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func followTapped(_ f: EventFollow) {
        guard f.following else { setFollow(true, nil); return }
        T1Overlays.shared.showMenu(page?.name ?? "Event", [
            T1MenuItem(title: f.notify ? "Turn notifications off" : "Turn notifications on") { setFollow(true, !f.notify) },
            T1MenuItem(title: "Unfollow") { setFollow(false, nil) },
        ])
    }

    private func setFollow(_ on: Bool, _ notify: Bool?) {
        let id = eventId
        Task { @MainActor in
            do { follow = try await Repo.setEventFollow(id, follow: on, notify: notify); follow?.canFollow = true }
            catch { self.error = error.localizedDescription }
        }
    }

    @MainActor
    private func load(signUp: Bool) async {
        do {
            page = try await Repo.eventPage(eventId)
            if page?.available == true, page?.me != "organizer", page?.me != "player" {
                follow = try? await Repo.eventFollow(eventId)
            }
            if page?.available == true, page?.showsResults == true {
                do { standings = try await Repo.standings(eventId); error = nil } catch where !error.isCancellation {
                    if standings == nil { self.error = error.localizedDescription }
                }
            }
            if signUp && !signedUpOnce && (state == .signUp || state == .waitlist) { self.signUp() }
        } catch {
            if !error.isCancellation { page = EventPage(eventId: nil) }
        }
    }

    @MainActor
    private func signUp() {
        signedUpOnce = true
        busy = true
        error = nil
        let id = eventId
        let now = signUpNow
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = try await Repo.signUp(id, signedInNow: now)
                message = r.status == "waitlisted" || r.status == "already_waitlisted"
                    ? "It's full, so you're on the waitlist (number \(r.position ?? 1))." : "You're signed up."
                await load(signUp: false)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func leave() {
        busy = true
        let id = eventId
        let waiting = state == .waitlisted
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Repo.leaveEvent(id, waitlist: waiting)
                message = waiting ? "You left the waitlist." : "You left the event."
                await load(signUp: false)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// "T3 · Ana 2–1 Bo" on the public page's Matchups ("Bye · Ana" for a bye).
struct PublicMatchRow: View {
    let match: PublicMatch

    var body: some View {
        HStack(spacing: 12) {
            LabelText(match.tableLabel).frame(width: 40, alignment: .leading)
            Text(match.name(0)).font(T1.mono(13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if match.isBye != true {
                Text(match.score).font(T1.mono(13)).monospacedDigit().foregroundStyle(T1.muted).frame(width: 56)
                Text(match.name(1)).font(T1.mono(13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(T1.surface)
    }
}

/// Over sign-in when a sign-up link is waiting: which event, and that any way in makes the account.
struct SignUpHeader: View {
    let page: EventPage
    var naming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabelText("Signing up for")
            Text(page.name ?? "An event").font(T1.mono(17, .bold))
            if !page.facts.isEmpty { Text(page.facts).font(T1.mono(12)).foregroundStyle(T1.muted) }
            Text(page.signUpLine).font(T1.mono(12)).foregroundStyle(T1.muted)
            Text(naming ? "Add your name and you're signed up." : "New to Table 1? Any option below makes your account, then you're signed up.")
                .font(T1.mono(12)).lineSpacing(4).foregroundStyle(T1.muted).padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
        .onAppear { if !naming { Telemetry.capture("event_page_viewed", ["state": "signed_out"]) } }
    }
}

// MARK: decklist screen

/// Your list for a constructed event (or, for the organizer, anyone's): from your decks in the event's format, or
/// pasted text. Counts as you type; Send replaces any list already sent.
struct DecklistPanel: View {
    let event: EventRow
    let participantId: String
    let playerName: String
    let byOrganizer: Bool
    let done: () -> Void
    @State private var source = "deck"
    @State private var text = ""
    @State private var listId: String?
    @State private var existing: Decklist?
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    private var locked: Bool { !byOrganizer && !event.isBeforeRound1 }
    private var decks: [CardList] {
        let want = EventRules.deckFormat(event.formatName)
        return ListsStore.shared.lists(.deck).filter { want == nil || $0.format == want }
    }
    private var counts: EventRules.Counts { EventRules.decklistCounts(text) }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Decklist", subtitle: "\(playerName) · \(event.label)") {
                BarButton("Done") { done() }
            }
            ScrollView {
                VStack(spacing: 1) {
                    if let existing {
                        ListRow(title: "Sent", detail: EventRules.countsText(main: existing.mainCount, side: existing.sideCount)
                                + (existing.listName.map { " · from \($0)" } ?? ""))
                    }
                    if locked {
                        Notice("Decklists lock when round 1 is paired. Ask the organizer to change yours.")
                        if let existing { listText(existing.body) }
                    } else {
                        if !byOrganizer {
                            T1Segmented(options: [(value: "deck", label: "From my decks"), (value: "text", label: "Paste text")], selection: $source)
                        }
                        if source == "deck" && !byOrganizer {
                            if decks.isEmpty {
                                Notice("No \(EventRules.deckFormat(event.formatName).map(formatName) ?? "") decks in your Library yet. Paste the list instead.")
                            }
                            ForEach(decks) { d in
                                Button { pick(d) } label: {
                                    ListRow(title: d.name, detail: "\(d.count("main")) main · \(d.count("side")) sideboard") {
                                        if listId == d.id { LabelText("Picked", color: T1.accent) }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if source == "text" || byOrganizer || listId != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                LabelText(listId == nil ? "The list" : "From your deck")
                                TextEditor(text: Binding(get: { text }, set: { text = $0; if source == "text" { listId = nil } }))
                                    .font(T1.mono(13)).tint(T1.accent).scrollContentBackground(.hidden)
                                    .frame(minHeight: 200).autocorrectionDisabled().textInputAutocapitalization(.never)
                                    .disabled(listId != nil)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
                            .focusArea()
                            ListRow(title: EventRules.countsText(main: counts.main, side: counts.side), detail: "One card a line: 4 Lightning Bolt. Sideboard after a Sideboard line or a blank line.")
                        }
                        if let error { Notice(error, error: true) }
                        HStack(spacing: 1) {
                            if existing != nil { Ghost(text: "Remove") { remove() } }
                            Ghost(text: busy ? "Sending…" : (existing == nil ? "Send" : "Send again"), accent: true) { send() }
                                .disabled(busy || counts.main == 0)
                        }
                    }
                }
            }
        }
        .foregroundStyle(T1.text)
        .task {
            if let userId = Repo.userId { await ListsStore.shared.start(userId: userId) }
            CatalogStore.shared.load(userInitiated: true)
            existing = try? await Repo.decklist(participantId)
            if let existing { text = existing.body; listId = existing.listId; source = existing.listId == nil ? "text" : "deck" }
            if byOrganizer { source = "text" }
            loaded = true
        }
    }

    private func listText(_ body: String) -> some View {
        Text(body).font(T1.mono(13)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(T1.surface).textSelection(.enabled)
    }

    /// The deck's current version as plain text (main deck, then sideboard; Considering left out).
    @MainActor
    private func pick(_ d: CardList) {
        guard let db = CatalogStore.shared.db, let v = d.current else {
            error = "The card data is still loading. Try again in a moment, or paste the list."
            return
        }
        let entries = v.entries.filter { $0.board != "maybe" }
        let (lines, left) = ListExport.lines(entries, db)
        text = ListExport.render(lines, kind: .deck, format: .text)
        listId = d.id
        error = left > 0 ? "\(left) card\(left == 1 ? "" : "s") in that deck aren't in the card data yet and were left out." : nil
    }

    @MainActor
    private func send() {
        busy = true
        error = nil
        let body = text, list = listId, pid = participantId, org = byOrganizer
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Repo.submitDecklist(participantId: pid, body: body, listId: list, byOrganizer: org)
                done()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func remove() {
        busy = true
        let pid = participantId
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Repo.removeDecklist(pid)
                done()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Opens the decklist panel; `refresh` runs when it closes.
@MainActor
func presentDecklist(event: EventRow, participantId: String, playerName: String, byOrganizer: Bool,
                     refresh: @escaping () async -> Void) {
    T1Overlays.shared.present {
        DecklistPanel(event: event, participantId: participantId, playerName: playerName, byOrganizer: byOrganizer) {
            T1Overlays.shared.dismissPanel()
            Task { await refresh() }
        }
    }
}
