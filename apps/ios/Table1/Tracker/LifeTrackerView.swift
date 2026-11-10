import SwiftUI
import UIKit

/// The life tracker (Figma "Life tracker — On its own", 73:5420): two halves (mine at the bottom, the
/// opponent's rotated to face them) around the info strip with the round clock, Record, Options and Reset.
/// Options (231:9191) holds the chooser, dice, history and Leave tracker.
/// Swipe down on a half, in that player's orientation, to choose its counter columns. Full screen, no tab
/// bar, screen kept on.
///
/// A local tracker opens on Setup (2–5 players, 20/30/40 life), then the chooser; three to five players sit
/// around the phone (`TrackerTable.layout`), and 30+ life tracks commander damage
/// (contract/life-tracker-commander-2026-11-03.md).
struct LifeTrackerView: View {
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TrackerModel
    @State private var pendingRecord: WinnerChoice?
    @State private var decidedPrompt = false
    @State private var picker: Int?
    @State private var busy = false
    @State private var notice: String?
    @State private var actionError: String?
    @State private var resetPrompt = false
    /// Local trackers open on Setup.
    @State private var setup: Bool
    /// Games whose first commander damage has been counted for telemetry.
    @State private var commanderTapped: Set<Int> = []
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    struct WinnerChoice: Equatable {
        let winner: Int?
        var draw: Bool { winner == nil }
    }

    @MainActor
    init(matchId: String?, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _model = State(initialValue: TrackerModel(matchId: matchId))
        _setup = State(initialValue: matchId == nil)
    }

    var body: some View {
        VStack(spacing: 1) {
            switch model.phase {
            case .loading:
                Spacer()
                LabelText("Opening the life tracker…")
                Spacer()
                Ghost(text: "Close") { onClose() }
            case .failed(let message):
                Spacer()
                Notice(message, error: true)
                Ghost(text: "Close") { onClose() }
                Spacer()
            case .ready:
                if setup {
                    TrackerSetupView(canContinue: model.hasHistory || !model.games.isEmpty,
                                     start: { players, life in start(players: players, life: life) },
                                     resume: {
                                         setup = false
                                         Telemetry.capture("tracker_setup_continued", ["players": model.players])
                                     },
                                     close: onClose)
                } else {
                    // Foldables (contract/foldables-2026-11-10.md § The screens): tabletop stands every seat upright on
                    // the top half with the controls on the flat half; book puts the seats on the left page and the
                    // controls on the right. Flat, folded or not: the table as always.
                    FoldSplit(screen: "tracker", allow: [.tabletop, .book]) {
                        VStack(spacing: 1) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                switch row {
                                case .strip:
                                    infoStrip
                                case .seats(let places):
                                    HStack(spacing: 1) {
                                        ForEach(places, id: \.side) { seat($0) }
                                    }
                                    .background(T1.surface)
                                }
                            }
                        }
                    } first: { layout in
                        uprightSeats(book: layout.mode == .book)
                    } second: { layout in
                        foldControls(book: layout.mode == .book)
                    }
                }
            }
        }
        // The halves run edge to edge, under the Dynamic Island and home indicator: their tap zones and
        // column hairlines reach the very top and bottom of the screen.
        .ignoresSafeArea(.container, edges: isReady && !setup ? .all : [])
        // Hairlines between seats at a bigger table.
        .background((model.players > 2 && !setup ? T1.surface : T1.bg).ignoresSafeArea())
        .foregroundStyle(T1.text)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            haptic.prepare()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            let model = model
            Task { await model.flushNow() }
        }
        .task {
            await model.start()
            #if DEBUG
            debugPreset()
            #endif
        }
        .onChange(of: scenePhase) { _, now in
            if now == .active {
                Task { await model.refetch() }
            } else {
                Task { await model.flushNow() }
            }
        }
        .onChange(of: model.decidedSignal) { decidedPrompt = true }
        .alert(recordTitle, isPresented: Binding(get: { pendingRecord != nil }, set: { if !$0 { pendingRecord = nil } })) {
            Button("Cancel", role: .cancel) { pendingRecord = nil }
            Button("Record") {
                if let choice = pendingRecord { record(choice) }
                pendingRecord = nil
            }
        } message: {
            Text(recordMessage)
        }
        .alert(decidedTitle, isPresented: $decidedPrompt) {
            if model.isSynced && model.mySide != nil {
                Button("Not now", role: .cancel) {}
                Button("Report") { report() }
            } else {
                Button("New match") { model.newMatch() }
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(decidedMessage)
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .alert(resetTitle, isPresented: $resetPrompt) {
            Button("Cancel", role: .cancel) {}
            if model.canResetMatch {
                Button("Reset game") { reset(match: false) }
                Button("Reset match", role: .destructive) { reset(match: true) }
            } else {
                Button("Reset", role: .destructive) { reset(match: false) }
            }
        } message: {
            Text(resetMessage)
        }
    }

    private var isReady: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    /// Two players: mine at the bottom (the organizer watching sees side 0 there), the opponent's facing them.
    private var rows: [TrackerTable.Row] {
        guard model.players == 2 else { return TrackerTable.layout(model.players) }
        return [.seats([TrackerTable.Place(side: model.topSide, seat: .top)]), .strip,
                .seats([TrackerTable.Place(side: model.bottomSide, seat: .bottom)])]
    }

    private func seat(_ place: TrackerTable.Place) -> some View {
        TrackerHalf(model: model, side: place.side, seat: place.seat,
                    pickerOpen: Binding(get: { picker == place.side }, set: { picker = $0 ? place.side : nil }),
                    tap: tap)
    }

    // MARK: folded (contract/foldables-2026-11-10.md)

    /// Every seat facing whoever holds the phone: the opponent first, you last; at a bigger table P1 to P5.
    private func uprightSeats(book: Bool) -> some View {
        let order = model.players == 2 ? [model.topSide, model.bottomSide] : Array(model.sides)
        let stack = book ? AnyLayout(VStackLayout(spacing: 1)) : AnyLayout(HStackLayout(spacing: 1))
        return stack {
            ForEach(order, id: \.self) { side in
                // Side by side and all facing one way, the seats say whose they are.
                seat(TrackerTable.Place(side: side, seat: .bottom))
                    .overlay(alignment: .bottom) {
                        LabelText(model.name(side), color: T1.muted).padding(.bottom, 12).allowsHitTesting(false)
                    }
            }
        }
        .background(T1.surface)
    }

    /// The strip grown to fill the flat half (tabletop) or the right page (book): the round clock large, the match
    /// line, then Record · Options · Reset as full-size targets, kept away from the fold by the pane's own edge.
    private func foldControls(book: Bool) -> some View {
        VStack(spacing: 1) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = model.clock?.remaining(at: context.date)
                VStack(spacing: 12) {
                    Spacer(minLength: 0)
                    if let remaining {
                        Text(TrackerClock.format(remaining))
                            .font(T1.mono(56, .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
                            .foregroundStyle(Self.color(TrackerClock.tone(remaining)))
                    }
                    LabelText(contextLine, color: contextColor).truncationMode(.tail)
                    LabelText("Game \(model.currentGame) · \(model.scoreText)", color: T1.muted)
                    Spacer(minLength: 0)
                    if let remaining, let clock = model.clock {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                T1.surface
                                Self.color(TrackerClock.tone(remaining)).frame(width: geo.size.width * clock.progress(remaining))
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(T1.bg)
            let actions = book ? AnyLayout(VStackLayout(spacing: 1)) : AnyLayout(HStackLayout(spacing: 1))
            actions {
                if !model.readOnly {
                    FoldAction(text: busy ? "Saving…" : "Record", accent: model.settledWinner != nil) { if !busy { recordTapped() } }
                }
                FoldAction(text: "Options") { showOptions() }
                if !model.readOnly { FoldAction(text: "Reset") { resetPrompt = true } }
            }
            .frame(height: book ? 72 * (model.readOnly ? 1 : 3) + (model.readOnly ? 0 : 2) : 72)
        }
        .background(T1.surface)
    }

    // MARK: info strip (Lifetracker Info, 73:5617)

    private var infoStrip: some View {
        VStack(spacing: 1) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = model.clock?.remaining(at: context.date)
                VStack(spacing: 1) {
                    HStack(spacing: 0) {
                        if let remaining {
                            LabelText(TrackerClock.format(remaining), color: Self.color(TrackerClock.tone(remaining)))
                                .monospacedDigit()
                                .padding(.horizontal, 16)
                        }
                        Spacer(minLength: 0)
                        LabelText(contextLine, color: contextColor)
                            .truncationMode(.tail)
                            .padding(.horizontal, 16)
                    }
                    .frame(height: 48)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            T1.surface
                            if let remaining, let clock = model.clock {
                                Self.color(TrackerClock.tone(remaining))
                                    .frame(width: geo.size.width * clock.progress(remaining))
                            }
                        }
                    }
                    .frame(height: 4)
                }
            }
            HStack(spacing: 0) {
                // Equal sides keep Options centred, also when watching (no Record or Reset).
                ZStack(alignment: .leading) {
                    Color.clear
                    if !model.readOnly {
                        StripButton(busy ? "Saving…" : "Record", accent: model.settledWinner != nil) { if !busy { recordTapped() } }
                    }
                }
                .frame(maxWidth: .infinity)
                StripButton("Options") { showOptions() }
                ZStack(alignment: .trailing) {
                    Color.clear
                    if !model.readOnly { StripButton("Reset") { resetPrompt = true } }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 48)
        }
        .background(T1.bg)
    }

    private static func color(_ tone: TrackerClock.Tone) -> Color {
        switch tone {
        case .normal: T1.accent
        case .warning: T1.warning
        case .overtime: T1.error
        }
    }

    /// "R2 | Table 13 | Kai Budde"; status (a report sent, offline) takes the slot while it lasts.
    private var contextLine: String {
        if let notice { return notice }
        if model.offline { return "Offline | changes will sync" }
        guard model.isSynced else { return model.players > 2 ? "Local game | \(model.players) players" : "Local game" }
        var parts: [String] = []
        if model.readOnly { parts.append("Watching") }
        if let r = model.round { parts.append("R\(r)") }
        if let t = model.table { parts.append("Table \(t)") }
        parts.append(model.readOnly ? "\(model.name(0)) vs \(model.name(1))" : model.name(model.topSide))
        return parts.joined(separator: " | ")
    }

    private var contextColor: Color {
        notice != nil ? T1.accent : model.offline ? T1.danger : T1.disabled
    }

    // MARK: menus (app-drawn)

    private func showOptions() {
        T1Overlays.shared.present {
            TrackerOptionsPanel(
                chooser: { showChooser() },
                dice: { T1Overlays.shared.present { TrackerDicePanel() } },
                history: { showHistory() },
                newMatch: model.isSynced ? nil : { newTable() },
                leave: { onClose() }
            )
        }
    }

    private func showChooser() {
        T1Overlays.shared.present(full: true, swipeBack: false) { TrackerChooserScreen() }
    }

    private func showHistory() {
        let model = model
        T1Overlays.shared.present(full: true) {
            TrackerHistoryPanel(
                model: model,
                newMatch: { newTable() },
                reportNow: { decidedPrompt = true }
            )
        }
    }

    /// Back to Setup (local only).
    private func newTable() {
        picker = nil
        withAnimation(.easeOut(duration: 0.15)) { setup = true }
    }

    /// Setup's Start: a fresh table, then the chooser picks who goes first.
    private func start(players: Int, life: Int) {
        model.configure(players: players, life: life)
        TrackerTable.lastPlayers = players
        TrackerTable.lastLife = life
        commanderTapped = []
        picker = nil
        setup = false
        Telemetry.capture("tracker_setup_started", ["players": players, "life": life])
        showChooser()
    }

    private func recordTapped() {
        if let winner = model.settledWinner {
            pendingRecord = WinnerChoice(winner: winner)
        } else {
            chooseWinner()
        }
    }

    private func chooseWinner() {
        let items: [T1MenuItem] = model.players == 2
            ? [T1MenuItem(title: "Me") { pendingRecord = WinnerChoice(winner: model.bottomSide) },
               T1MenuItem(title: model.name(model.topSide)) { pendingRecord = WinnerChoice(winner: model.topSide) }]
            : model.sides.map { side in T1MenuItem(title: model.name(side)) { pendingRecord = WinnerChoice(winner: side) } }
        T1Overlays.shared.showMenu("Who won game \(model.currentGame)?",
                                   items + [T1MenuItem(title: "Draw") { pendingRecord = WinnerChoice(winner: nil) }])
    }

    // MARK: copy

    private var recordTitle: String {
        guard let choice = pendingRecord else { return "Record game \(model.currentGame)?" }
        if choice.draw { return "Record game \(model.currentGame) as a draw?" }
        if model.players > 2, let winner = choice.winner { return "Record game \(model.currentGame): \(model.name(winner)) won?" }
        return choice.winner == model.bottomSide
            ? "Record game \(model.currentGame): you won?"
            : "Record game \(model.currentGame): \(model.name(model.topSide)) won?"
    }

    private var recordMessage: String {
        guard let choice = pendingRecord else { return "" }
        if model.players > 2 { return "Game \(model.currentGame + 1) starts at \(model.startingLife)." }
        let mine = model.wins(model.bottomSide) + (choice.winner == model.bottomSide ? 1 : 0)
        let theirs = model.wins(model.topSide) + (choice.winner == model.topSide ? 1 : 0)
        return "Match is \(mine)–\(theirs)."
    }

    private var resetTitle: String { model.canResetMatch ? "Reset?" : "Reset game \(model.currentGame)?" }

    private var resetMessage: String {
        let life = "Life goes back to \(model.startingLife) and counters to 0."
        if model.canResetMatch { return life + " Reset match also clears the games (\(model.scoreText))." }
        if model.isSynced && !model.games.isEmpty { return life + " Recorded games stay (\(model.scoreText))." }
        return life
    }

    private var decidedTitle: String {
        model.isSynced && model.mySide != nil ? "Report \(model.reportText) to the event?" : "Match over"
    }

    private var decidedMessage: String {
        if model.isSynced && model.mySide != nil {
            return "\(model.name(model.topSide)) confirms or disputes it, as usual."
        }
        let mine = model.wins(model.bottomSide), theirs = model.wins(model.topSide)
        if mine == theirs { return "Drawn \(model.reportText)." }
        let winner = mine > theirs ? "\(model.name(model.bottomSide)) won" : "\(model.name(model.topSide)) won"
        return "\(winner) \(model.reportText)."
    }

    // MARK: actions

    /// Fires on touch-down; returns the change so a touch that turns into a swipe can take it back.
    private func tap(_ side: Int, _ counter: TrackerCounter, _ delta: Int) -> String? {
        let id = model.tap(side: side, counter: counter, delta: delta)
        if id != nil { haptic.impactOccurred() }
        if id != nil, counter.commanderFrom != nil, !commanderTapped.contains(model.currentGame) {
            commanderTapped.insert(model.currentGame)
            Telemetry.capture("tracker_commander_damage", ["players": model.players])
        }
        return id
    }

    #if DEBUG
    /// Design QA: `-T1Tracker <players>:<life>[:cmd][:pick<side>]` skips Setup (e.g. `4:40:cmd:pick2`); `cmd`
    /// turns on commander damage columns with some damage dealt, `pick` opens a seat's counter picker.
    private func debugPreset() {
        let args = ProcessInfo.processInfo.arguments
        guard model.matchId == nil, let i = args.firstIndex(of: "-T1Tracker"), args.indices.contains(i + 1) else { return }
        let parts = args[i + 1].split(separator: ":").map(String.init)
        guard parts.count >= 2, let players = Int(parts[0]), let life = Int(parts[1]) else { return }
        model.configure(players: players, life: life)
        setup = false
        if parts.contains("cmd") {
            for side in model.sides {
                let from = (side + 1) % model.players
                model.toggleCounter(.commander(from), side: side)
                model.tap(side: side, counter: .commander(from), delta: 3 + side * 4)
            }
        }
        if let pick = parts.first(where: { $0.hasPrefix("pick") }), let side = Int(pick.dropFirst(4)) { picker = side }
    }
    #endif

    private func reset(match: Bool) {
        if match { model.resetMatch() } else { model.resetGame() }
        Telemetry.capture("tracker_reset", ["scope": match ? "match" : "game", "mode": model.isSynced ? "match" : "local"])
    }

    private func record(_ choice: WinnerChoice) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.record(winner: choice.winner, draw: choice.draw)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func report() {
        let score = model.reportText
        Task {
            do {
                try await model.report()
                notice = "Reported \(score) | waiting on \(model.name(model.topSide))"
                await LiveActivityController.shared.refresh(force: true)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: one seat (Me, Counters=0…3)

/// One player's half (two players) or seat (three to five). Laid out in screen order so touches land where the
/// player sees things (`TrackerSeat`): columns, tap zones and picker rows placed by the seat, text turned.
private struct TrackerHalf: View {
    let model: TrackerModel
    let side: Int
    let seat: TrackerSeat
    @Binding var pickerOpen: Bool
    let tap: (Int, TrackerCounter, Int) -> String?

    var body: some View {
        let counters = model.visibleCounters(side)
        let enabled = !model.readOnly
        let name = model.name(side)
        let life = model.total(side, .life)
        // Seats at a bigger table are a third to a half the size of a two-player half.
        let scale: CGFloat = model.players > 2 ? 0.6 : 1
        let lifeColumn = CounterColumn(value: life, label: nil, size: (counters.isEmpty ? 162 : 120) * scale,
                                       lost: life <= 0, seat: seat, enabled: enabled,
                                       name: "\(name) life", retract: { model.retract($0) }) { tap(side, .life, $0) }
        // Life first on the player's left.
        let columns: [AnyView] = [AnyView(lifeColumn)] + counters.map { counter in
            let value = model.total(side, counter)
            let lost = counter == .poison ? value >= 10 : counter.commanderFrom != nil && value >= TrackerTable.commanderLoss
            return AnyView(CounterColumn(value: value, label: model.shortLabel(counter),
                                         size: (counters.count == 1 ? 80 : counters.count == 2 ? 64 : 44) * scale,
                                         lost: lost, seat: seat, enabled: enabled, name: "\(name) \(model.label(counter))",
                                         retract: { model.retract($0) }) { tap(side, counter, $0) })
        }
        let ordered = seat.reversed ? Array(columns.reversed()) : columns
        let stack = seat.sideways ? AnyLayout(VStackLayout(spacing: 1)) : AnyLayout(HStackLayout(spacing: 1))
        ZStack(alignment: seat.farAlignment) {
            stack {
                ForEach(ordered.indices, id: \.self) { ordered[$0] }
            }
            .background(T1.surface)
            if counters.isEmpty {
                // The hairline mark sits 8 pt from the player's far edge (the strip, with two players).
                Rectangle().fill(T1.surface)
                    .frame(width: seat.sideways ? 1 : 26, height: seat.sideways ? 26 : 1)
                    .padding(Edge.Set(seat.farEdge), 8).allowsHitTesting(false)
            }
            if pickerOpen {
                CounterPicker(model: model, side: side, seat: seat) {
                    withAnimation(.easeOut(duration: 0.15)) { pickerOpen = false }
                }
                .transition(.move(edge: seat.farEdge))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
                guard !pickerOpen, seat.opensPicker(value.translation) else { return }
                withAnimation(.easeOut(duration: 0.15)) { pickerOpen = true }
            }
        )
    }
}

/// Counter Column: its own +1 (the player's top half) / −1 zones, the total, and a label for counters.
private struct CounterColumn: View {
    let value: Int
    let label: String?
    let size: CGFloat
    let lost: Bool
    let seat: TrackerSeat
    let enabled: Bool
    let name: String
    let retract: (String) -> Void
    let onDelta: (Int) -> String?

    var body: some View {
        let first = seat.firstZoneDelta
        let zones = seat.sideways ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
        ZStack {
            zones {
                TapZone(enabled: enabled, label: "\(name) \(first > 0 ? "+1" : "−1")", retract: retract) { onDelta(first) }
                TapZone(enabled: enabled, label: "\(name) \(first > 0 ? "−1" : "+1")", retract: retract) { onDelta(-first) }
            }
            Turned(seat: seat) {
                VStack(spacing: 8) {
                    Text("\(value)")
                        .font(T1.mono(size, .semibold)).tracking(-size * 0.025).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.25)
                        .foregroundStyle(lost ? T1.error : T1.text)
                        .contentTransition(.numericText(value: Double(value)))
                        .animation(.snappy(duration: 0.1), value: value)
                    if let label { LabelText(label, color: T1.disabled).lineLimit(1).minimumScaleFactor(0.6) }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 32)
            }
        }
        .background(T1.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Increment Button. A tap fires on touch-down so the total moves the instant a finger lands; if the touch
/// then travels more than 10 pt (a swipe, e.g. opening the counter picker) that change is taken back, so a
/// swipe still never changes a total. Holding repeats after 0.4 s, then every 0.1 s. Pressed = surface, at once.
private struct TapZone: View {
    let enabled: Bool
    let label: String
    let retract: (String) -> Void
    let fire: () -> String?
    /// The finger's travel while it's down; SwiftUI resets it however the touch ends (even when cancelled).
    @GestureState private var travel: CGFloat?
    @State private var cancelled = false
    @State private var held = false
    @State private var repeater: Task<Void, Never>?
    /// The change this touch made on landing (taken back if the touch becomes a swipe).
    @State private var landed: String?

    var body: some View {
        let pressed = travel != nil && !cancelled
        Rectangle()
            .fill(pressed ? T1.surface : T1.bg)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($travel) { value, state, _ in
                        state = hypot(value.translation.width, value.translation.height)
                    }
                    .onEnded { _ in },
                including: enabled ? .all : .subviews
            )
            .onChange(of: travel == nil) { _, up in
                // onEnded has already read these for the touch that just finished.
                repeater?.cancel()
                repeater = nil
                cancelled = false
                held = false
                landed = nil
                guard !up, enabled else { return }
                landed = fire()
                repeater = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, !cancelled else { return }
                    held = true
                    while !Task.isCancelled {
                        _ = fire()
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            .onChange(of: travel ?? 0) { _, moved in
                guard moved > 10, !held, !cancelled else { return }
                cancelled = true
                repeater?.cancel()
                repeater = nil
                if let landed { retract(landed) }
                landed = nil
            }
            .onDisappear { repeater?.cancel() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { _ = fire() } }
    }
}

/// Counter Picker: which counters this seat shows, three at most; commander damage from each opponent first at
/// 30+ life. Swipe away or Done closes it. Rows run from the player's far edge in screen order (sideways seats
/// scroll across), each row's content turned to face them.
private struct CounterPicker: View {
    let model: TrackerModel
    let side: Int
    let seat: TrackerSeat
    let done: () -> Void

    var body: some View {
        let shown = model.visibleCounters(side)
        let full = shown.count >= TrackerModel.maxCounters
        let all = model.pickerCounters(side)
        let rows = seat.topFirst ? all : all.reversed()
        let stack = seat.sideways ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
        stack {
            if seat.topFirst { header(shown.count) }
            ScrollView(seat.sideways ? .horizontal : .vertical) {
                stack {
                    ForEach(rows) { counter in
                        let on = shown.contains(counter)
                        let disabled = !on && full
                        Button { model.toggleCounter(counter, side: side) } label: {
                            Turned(seat: seat) {
                                HStack {
                                    LabelText(model.label(counter), color: disabled ? T1.bg : T1.text)
                                    Spacer()
                                    LabelText(on ? "On" : disabled ? "Max 3" : "Off",
                                              color: disabled ? T1.bg : on ? T1.text : T1.disabled)
                                }
                                .padding(.horizontal, 16)
                            }
                            .frame(width: seat.sideways ? 48 : nil, height: seat.sideways ? nil : 48)
                            .frame(maxWidth: seat.sideways ? nil : .infinity, maxHeight: seat.sideways ? .infinity : nil)
                            .background(disabled ? T1.disabled : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressFill())
                        .disabled(disabled)
                    }
                }
                .background(T1.surface)
            }
            .defaultScrollAnchor(seat.topFirst ? (seat.sideways ? .leading : .top) : (seat.sideways ? .trailing : .bottom))
            .background(T1.bg)
            if !seat.topFirst { header(shown.count) }
        }
        .background(T1.surface)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: seat.farAlignment)
    }

    /// "Counters · 1 of 3" then Done, on the player's left to right.
    private func header(_ count: Int) -> some View {
        let stack = seat.sideways ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let parts: [AnyView] = [
            AnyView(Turned(seat: seat) {
                LabelText("Counters · \(count) of \(TrackerModel.maxCounters)", color: T1.disabled)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }),
            AnyView(Button(action: done) {
                Turned(seat: seat) { LabelText("Done", color: T1.text) }
                    .frame(width: seat.sideways ? 48 : 80, height: seat.sideways ? 80 : 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFill())),
        ]
        let ordered = seat.reversed ? Array(parts.reversed()) : parts
        return stack {
            ForEach(ordered.indices, id: \.self) { ordered[$0] }
        }
        .frame(width: seat.sideways ? 48 : nil, height: seat.sideways ? nil : 48)
        .background(T1.bg)
    }
}

/// Strip Button: a label with a surface fill while pressed. Accent means "the result" (a game was lost).
/// One of the folded tracker's controls: a full-width target on the flat half.
private struct FoldAction: View {
    let text: String
    var accent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            LabelText(text, color: accent ? T1.accent : T1.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFill())
    }
}

struct StripButton: View {
    let title: String
    var accent = false
    var rotated = false
    let action: () -> Void
    init(_ title: String, accent: Bool = false, rotated: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.accent = accent
        self.rotated = rotated
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            LabelText(title, color: accent ? T1.accent : T1.text)
                .rotationEffect(.degrees(rotated ? 180 : 0))
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFill())
    }
}

struct PressFill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? T1.surface : T1.bg)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: history

/// Full-screen history, newest first, one entry per change group; Undo last pushes the inverse.
/// The footer holds what used to be in the ⋯ menu.
private struct TrackerHistoryPanel: View {
    let model: TrackerModel
    let newMatch: () -> Void
    let reportNow: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "History", subtitle: model.isSynced ? model.eventName : "Life") {
                if !model.readOnly && model.canUndo {
                    BarButton("Undo last") { model.undoLast() }
                }
                BarButton("Done") { T1Overlays.shared.dismissPanel() }
            }
            HairlineList {
                if !model.hasHistory { Notice("No changes yet") }
                ForEach(Array((1...model.currentGame).reversed()), id: \.self) { game in
                    let groups = model.visibleGroups(game: game)
                    if !groups.isEmpty || model.games.contains(where: { $0.gameNo == game }) {
                        Section1(header(game))
                        ForEach(groups.reversed()) { group in
                            ListRow(title: line(group), detail: meta(group))
                        }
                    }
                }
                Section1(model.players > 2 ? "Games · \(model.scoreText)" : "Match \(model.scoreText)")
                if !model.readOnly {
                    action("Reset game") { model.resetGame() }
                }
                if !model.isSynced {
                    action("New match", detail: "\(model.players) · \(model.startingLife)") { newMatch() }
                }
                if model.isSynced && model.mySide != nil {
                    action("Report now") { reportNow() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(T1.bg.ignoresSafeArea())
        .foregroundStyle(T1.text)
    }

    private func action(_ title: String, detail: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button {
            T1Overlays.shared.dismissPanel()
            run()
        } label: {
            ListRow(title: title, detail: detail).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func line(_ g: TrackerModel.ChangeGroup) -> String {
        let delta = g.delta > 0 ? "+\(g.delta)" : "−\(abs(g.delta))"
        return "\(model.name(g.side)) · \(model.label(g.counter)) \(delta) → \(g.result)"
    }

    private func meta(_ g: TrackerModel.ChangeGroup) -> String {
        var parts = [g.end.formatted(date: .omitted, time: .standard)]
        if model.isSynced, let mine = g.mine {
            if mine {
                parts.append("by you")
            } else if let me = model.mySide {
                parts.append("by \(model.name(1 - me))")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func header(_ game: Int) -> String {
        guard let result = model.games.first(where: { $0.gameNo == game }) else { return "Game \(game)" }
        if result.isDraw { return "Game \(game) · draw" }
        return "Game \(game) · \(model.name(result.winnerSide ?? 0)) won"
    }
}
