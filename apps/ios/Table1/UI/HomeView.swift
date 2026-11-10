import SwiftUI
import WidgetKit

/// The Events tab. What's happening now comes first and biggest; getting into events (scan, nearby,
/// create) is secondary until there's nothing to show.
struct EventsHomeView: View {
    @Binding var path: [Route]
    /// False while the Account tab is showing, so a foreground never yanks the user across tabs.
    let isFront: Bool
    @Environment(SessionModel.self) private var session
    @State private var data: HomeData?
    @State private var snapshots: [String: LiveSnapshot] = [:]
    @State private var showPast = false
    @State private var error: String?
    /// When `data` was fetched (this launch's, or the device's saved copy), and the notice when a refresh fails
    /// (contract/offline-2026-10-31.md § 1).
    @State private var savedAt: Date?
    @State private var stale: String?
    /// Events you follow but aren't in (contract/event-follows-2026-11-09.md).
    @State private var followed: [FollowedEvent] = []

    private var live: [HomeEvent] { data?.events.filter { $0.bucket == "live" } ?? [] }
    private var upcoming: [HomeEvent] { data?.events.filter { $0.bucket == "upcoming" } ?? [] }
    private var past: [HomeEvent] { data?.events.filter { $0.bucket == "past" } ?? [] }
    private var invites: [HomeInvite] { data?.invites ?? [] }
    /// The match you're playing right now, if any: "Life" opens its synced tracker so the game is recorded.
    private var liveMatchId: String? {
        live.lazy.compactMap { e in snapshots[e.id]?.state }.first { $0.isPlaying && $0.matchId != nil }?.matchId
    }
    private var isEmpty: Bool { data != nil && data!.events.isEmpty && invites.isEmpty && data!.waitlist.isEmpty && followed.isEmpty }

    var body: some View {
        T1Screen {
            Bar(title: "Events", subtitle: live.isEmpty ? nil : "\(live.count) live") {
                BarButton("Life") { session.openTracker(matchId: liveMatchId, source: "home_life") }
                BarButton("+ New") { path.append(.create) }
            }
            if let error { Notice(error, error: true) }
            if let stale { Notice(stale) }
            HairlineList {
                if data == nil {
                    Notice("Loading…")
                } else if isEmpty {
                    if error != nil { Ghost(text: "Try again") { Task { await load() } } }
                    EmptyEvents(path: $path)
                } else {
                    ForEach(live) { e in
                        Button { path.append(.event(e.id)) } label: {
                            if e.playing && !e.organizing {
                                PlayerHero(e: e, snap: snapshots[e.id], reload: load)
                            } else {
                                OrganizerHero(e: e)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if !invites.isEmpty {
                        Section1("Invitations")
                        Notice(JoinNotice.text)
                        ForEach(invites) { invite in
                            ListRow(title: invite.name, detail: inviteDetail(invite)) {
                                BarButton("Decline") { answer(invite, accept: false) }
                                BarButton("Join") { answer(invite, accept: true) }
                            }
                        }
                    }
                    HStack(spacing: 1) {
                        Ghost(text: "Scan QR") { path.append(.scan) }
                        Ghost(text: "Nearby") { path.append(.nearby) }
                    }
                    JoinCodeRow(path: $path)
                    if !upcoming.isEmpty {
                        Section1("Upcoming")
                        ForEach(upcoming) { e in EventLine(e: e) { path.append(.event(e.id)) } }
                    }
                    if let waiting = data?.waitlist, !waiting.isEmpty {
                        Section1("Waitlist")
                        ForEach(waiting) { w in
                            Button { path.append(.eventPage(w.eventId, signUp: false)) } label: {
                                ListRow(title: w.name, detail: ["Number \(w.position ?? 1) on the waitlist", EventRules.when(w.startsAt), w.venueName]
                                    .compactMap { $0 }.joined(separator: " · "))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !followed.isEmpty {
                        Section1("Following")
                        ForEach(followed) { f in
                            Button { path.append(.eventPage(f.eventId, signUp: false)) } label: {
                                ListRow(title: f.name, detail: f.detail)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !past.isEmpty {
                        Button { withAnimation(.snappy) { showPast.toggle() } } label: {
                            Section1(showPast ? "Past · hide" : "Past · \(past.count)")
                        }
                        .buttonStyle(.plain)
                        if showPast {
                            ForEach(past) { e in EventLine(e: e) { path.append(.event(e.id)) } }
                        }
                    }
                }
            }
        }
        .refreshable { await load() }
        .task(id: session.foregrounds) { await load() }
        // While something is live, keep the cards fresh; the clocks themselves tick locally.
        .task(id: live.map(\.id)) {
            guard !live.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                await load()
            }
        }
        .task {
            #if DEBUG
            if DemoScreens.home != nil { return }   // the design demo: no server, no location
            #endif
            // Keep this account's area cell fresh for nearby alerts (opt-in on the Nearby screen). Never prompts: the
            // permissions step after sign-in asks, or Nearby / Create when they need a fix.
            if let fix = await LocationFix.shared.currentIfAllowed() { try? await Repo.updatePresence(lat: fix.lat, lng: fix.lng) }
        }
    }

    private func inviteDetail(_ i: HomeInvite) -> String {
        var parts = [i.source == "nearby_alert" ? "Starting near you" : "From \(i.invitedBy ?? "an organizer")"]
        if let label = i.formatLabel { parts.append(label) }
        if let when = T1Date.short(i.startsAt) { parts.append(when) }
        if let venue = i.venueName { parts.append(venue) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        #if DEBUG
        // `-T1EventsDemo home|homeorg`: sample data instead of the server's answer (EventsDemo.swift).
        if let demo = DemoScreens.home {
            data = demo
            snapshots = Dictionary(DemoScreens.snapshots.map { ($0.eventId, $0) }, uniquingKeysWith: { a, _ in a })
            return
        }
        #endif
        await BuildFlavor.resolve()
        // What this account last saw shows at once; the server's answer replaces it.
        if data == nil, let saved = Repo.savedHome() {
            data = saved.value
            savedAt = saved.at
        }
        do {
            let home = try await Repo.eventsHome()
            data = home
            // A server without event follows (or a failed read) just shows no Following section.
            followed = (try? await Repo.eventsFollowed()) ?? followed
            error = nil
            stale = nil
            savedAt = .now
            // The Next event widget reads the same data from the App Group.
            if NextEventStore.save(events: home.events.map(NextEventItem.init), invites: home.invites.count) {
                WidgetCenter.shared.reloadTimelines(ofKind: "site.table1.next")
            }
        } catch where error.isCancellation {
            // At launch the app turning active restarts this task; the newer load shows the result.
            return
        } catch {
            let age = Offline.age(savedAt)
            let n = Offline.notice(failed: true, savedAgo: age, error: error.localizedDescription)
            if let n, !n.isError {
                stale = n.text
                Telemetry.capture("offline_shown", ["screen": "home", "age_s": age ?? 0])
            } else if data == nil {
                self.error = n?.text
                data = HomeData()
            }
        }
        await LiveActivityController.shared.refresh()
        snapshots = Dictionary(LiveStore.load().map { ($0.eventId, $0) }, uniquingKeysWith: { a, _ in a })
        autoOpen()
    }

    /// While a round you're playing is running, open straight into it (once per launch/foreground):
    /// the life tracker for that match when the player tracks games here, otherwise the event.
    private func autoOpen() {
        guard session.autoOpenArmed, isFront, path.isEmpty, session.tracker == nil,
              let e = live.first(where: \.playingNow) else { return }
        session.autoOpenArmed = false
        if session.trackerMode == .tracker, let s = snapshots[e.id]?.state, s.isPlaying, let matchId = s.matchId {
            session.openTracker(matchId: matchId)
        } else {
            path.append(.event(e.id))
        }
    }

    private func answer(_ invite: HomeInvite, accept: Bool) {
        Task {
            do {
                _ = try await Repo.respondToInvite(invite.eventId, accept: accept)
                data?.invites.removeAll { $0.eventId == invite.eventId }
                if accept { path.append(.event(invite.eventId)) }
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: hero cards

/// A round you're playing: clock, table, opponent and ranks, and one-tap reporting.
private struct PlayerHero: View {
    let e: HomeEvent
    let snap: LiveSnapshot?
    let reload: () async -> Void
    @Environment(SessionModel.self) private var session
    @State private var sending = false

    var body: some View {
        let s = snap?.state
        VStack(spacing: 1) {
            HStack {
                LabelText("Playing · Round \(e.round?.number ?? e.currentRound) of \(e.numberOfRounds)", color: T1.accent)
                Spacer()
                LabelText("Open ›", color: T1.text)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(T1.surface)

            VStack(spacing: 6) {
                Text(e.name).font(T1.mono(15)).lineLimit(1)
                if e.clockShown {
                    Countdown(end: s?.endDate ?? e.round?.endDate, paused: s?.pausedRemaining ?? e.round?.remainingSeconds, size: 56)
                } else {
                    LabelText("Round \(e.round?.number ?? e.currentRound) of \(e.numberOfRounds)", color: T1.text)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16).background(T1.bg)

            if let s, s.isPlaying {
                HStack(spacing: 12) {
                    Stat(label: "Table", value: s.table.map(String.init) ?? "–", accent: true)
                    Stat(label: "You", value: "\(s.myRankText) · \(s.myRecord)")
                    Stat(label: s.oppRankText, value: s.oppName ?? "Opponent", alignment: .trailing)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
                Notice(s.statusLine)
                if session.trackerMode == .tracker, let matchId = s.matchId {
                    // Tracking here: the life tracker leads; results are secondary.
                    Button { session.openTracker(matchId: matchId) } label: {
                        LabelText("Open life tracker", color: T1.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 18).background(T1.accent)
                    }
                    .buttonStyle(.plain)
                    results(s)
                } else {
                    results(s)
                    if let matchId = s.matchId {
                        Ghost(text: "Open life tracker") { session.openTracker(matchId: matchId) }
                    }
                }
            } else if let s {
                Notice(s.statusLine)
            } else {
                Notice("Open the event for your table and opponent.")
            }
        }
    }

    @ViewBuilder
    private func results(_ s: LiveState) -> some View {
        if s.canReportNow {
            HStack(spacing: 1) {
                ForEach(MatchOutcome.allCases, id: \.label) { o in
                    Button { report(s, o) } label: {
                        Text(o.label).font(T1.mono(14))
                            .frame(maxWidth: .infinity).padding(.vertical, 14).background(T1.surfaceHover)
                    }
                    .buttonStyle(.plain)
                    .disabled(sending)
                }
            }
        } else if s.needsMyAnswer {
            HStack(spacing: 1) {
                Ghost(text: "Dispute") { respond(s, accept: false) }
                Ghost(text: "Confirm", accent: true) { respond(s, accept: true) }
            }
        }
    }

    private func report(_ s: LiveState, _ o: MatchOutcome) {
        guard let matchId = s.matchId, let side = s.mySide, let pid = snap?.participantId else { return }
        sending = true
        Task {
            defer { sending = false }
            let before = await LiveSync.apply(participantId: pid) {
                $0.status = "reported_me"; $0.myWins = o.wins.my; $0.theirWins = o.wins.their
            }
            do {
                try await LiveAPI.report(matchId: matchId, mySide: side, my: o.wins.my, their: o.wins.their, version: s.matchVersion)
            } catch {
                if let before { await LiveSync.restore(participantId: pid, to: before) }
            }
            await LiveActivityController.shared.refresh(force: true)
            await reload()
        }
    }

    private func respond(_ s: LiveState, accept: Bool) {
        guard let matchId = s.matchId else { return }
        Task {
            try? await LiveAPI.respond(matchId: matchId, accept: accept)
            await LiveActivityController.shared.refresh(force: true)
            await reload()
        }
    }
}

/// A round you're running: clock and how many results are in.
private struct OrganizerHero: View {
    let e: HomeEvent

    var body: some View {
        VStack(spacing: 1) {
            HStack {
                LabelText(e.round.map { "Organizing · Round \($0.number) of \(e.numberOfRounds)" } ?? "Organizing · Seating", color: T1.accent)
                Spacer()
                LabelText("Open ›", color: T1.text)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(T1.surface)
            VStack(spacing: 6) {
                Text(e.name).font(T1.mono(15)).lineLimit(1)
                if let r = e.round, e.clockShown {
                    Countdown(end: r.endDate, paused: r.remainingSeconds, size: 44)
                } else {
                    Text("\(e.players) players").font(T1.mono(28))
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14).background(T1.bg)
            if let r = e.round {
                HStack(spacing: 12) {
                    Stat(label: "Results in", value: "\(r.resultsIn) of \(r.matches)", accent: r.resultsIn == r.matches)
                    Stat(label: "Disputed", value: "\(r.disputed)", accent: false)
                    Stat(label: "Players", value: "\(e.players)", alignment: .trailing)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(r.disputed > 0 ? T1.danger.opacity(0.15) : T1.surface)
            } else {
                Notice("Pair round 1 when everyone is seated.")
            }
        }
    }
}

private struct EventLine: View {
    let e: HomeEvent
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ListRow(title: e.name, detail: detail) {
                if e.isCancelled { LabelText("Cancelled", color: T1.danger) }
                else if e.isDemo { LabelText("Demo") }
            }
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        var parts = [e.organizing ? "Organizing" : "Playing", e.label]
        if e.bucket == "upcoming" {
            if let when = EventRules.when(e.startsAt) { parts.append(when) }
            parts.append(e.capacity.map { "\(e.players)/\($0) signed up" } ?? "\(e.players) signed up")
            if e.owesDecklist { parts.append("Add your decklist") }
        } else if e.isCancelled {
            if let reason = e.cancelReason { parts.append(reason) }
        } else {
            parts.append("\(e.numberOfRounds) rounds · \(e.players) players")
        }
        return parts.joined(separator: " · ")
    }
}

/// No events and no invitations: the ways in become the screen.
private struct EmptyEvents: View {
    @Binding var path: [Route]
    var body: some View {
        VStack(spacing: 1) {
            VStack(spacing: 8) {
                Text("No events yet").font(T1.mono(20))
                Text("Scan an organizer's QR code, enter their event code, find an event happening near you, or run your own.")
                    .font(T1.mono(12)).foregroundStyle(T1.muted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24).background(T1.surface)
            BigAction(text: "Scan QR", accent: true) { path.append(.scan) }
            BigAction(text: "Find nearby") { path.append(.nearby) }
            JoinCodeRow(path: $path)
            Ghost(text: "Create an event") { path.append(.create) }
        }
    }
}

/// Join with the organizer's event code: typed, or Paste, which reads a code, a join link or the QR's link out of what
/// was copied (JoinCode.parse; contract/qr-sign-up-2026-10-23.md § Enter or paste a code). A long paste into the field
/// is read the same way.
struct JoinCodeRow: View {
    @Binding var path: [Route]
    @State private var code = ""
    @State private var link: JoinLink?
    @State private var busy = false
    @State private var error: String?
    @State private var canPaste = UIPasteboard.general.hasStrings
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                TextField("", text: $code, prompt: Text("EVENT CODE").foregroundStyle(T1.muted))
                    .font(T1.mono(16)).tracking(4).tint(T1.accent)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .submitLabel(.join).onSubmit(join)
                    .focused($focused)
                    .padding(.horizontal, 16).frame(height: 50).frame(maxWidth: .infinity)
                    .background(T1.surface)
                    .onChange(of: code) { _, typed in take(typed, via: "typed") }
                    .accessibilityLabel("Event code")
                if canPaste && code.isEmpty {
                    cell("Paste", fill: T1.surface, ink: T1.text) { paste() }
                }
                cell(busy ? "…" : "Join", fill: code.count == 4 && !busy ? T1.text : T1.disabled, ink: T1.ink) { join() }
                    .disabled(code.count != 4 || busy)
            }
            if let error { Notice(error, error: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in canPaste = UIPasteboard.general.hasStrings }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in canPaste = UIPasteboard.general.hasStrings }
    }

    private func cell(_ text: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabelText(text, color: ink).padding(.horizontal, 18).frame(height: 50).background(fill).contentShape(Rectangle())
        }
        .buttonStyle(FlatPress())
    }

    /// What's in the field: a code typed in keeps to 4 letters and digits; anything longer (a pasted message or link)
    /// is read for its code.
    private func take(_ text: String, via: String) {
        error = nil
        let plain = String(text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        if text.count <= 4 && plain == text { if link?.code.uppercased() != text { link = nil }; return }
        switch JoinCode.parse(text) {
        case .code(let c)?: link = nil; set(c)
        case .qr(let l)?: link = l; set(l.code)
        case nil:
            if text.count > 6 { error = "That has no event code in it." }
            set(String(plain.prefix(4)))
        }
        if text.count > 4 { Telemetry.capture("join_code_pasted", ["via": via, "found": code.count == 4]) }
    }

    private func set(_ c: String) { if code != c { code = c } }

    private func paste() {
        guard let text = UIPasteboard.general.string else { return }
        guard let found = JoinCode.parse(text) else {
            error = "What you copied has no event code in it."
            Telemetry.capture("join_code_pasted", ["via": "paste", "found": false])
            return
        }
        switch found {
        case .code(let c): link = nil; code = c
        case .qr(let l): link = l; code = l.code
        }
        Telemetry.capture("join_code_pasted", ["via": "paste", "found": true])
        join()
    }

    private func join() {
        guard code.count == 4, !busy else { return }
        busy = true
        error = nil
        focused = false
        let qr = link.flatMap { $0.code.uppercased() == code ? $0 : nil }
        Task {
            defer { busy = false }
            do {
                let seat = qr != nil ? try await Repo.joinByQr(qr!, via: "paste") : try await Repo.joinByCode(code, via: "code")
                code = ""; link = nil
                path.append(.event(seat.eventId))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    let onLink: (JoinLink) -> Void
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Scan to join", subtitle: "Point at the organizer's QR", back: { dismiss() })
            if QRScanner.isAvailable {
                QRScanner { raw in
                    if let link = JoinLink(raw) {
                        dismiss()
                        onLink(link)
                    } else {
                        error = "That QR code isn't a Table 1 event."
                    }
                }
                .frame(maxHeight: .infinity)
                Notice(JoinNotice.text)
            } else {
                Notice("This device can't scan here. Use the Camera app instead — the link opens Table 1.")
            }
            if let error { Notice(error, error: true) }
        }
    }
}
