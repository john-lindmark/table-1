import SwiftUI
import UIKit

/// The life tracker (Figma "Life tracker — On its own", 73:5420): two halves (mine at the bottom, the
/// opponent's rotated to face them) around the info strip with the round clock, Close, Record and History.
/// Swipe down on a half, in that player's orientation, to choose its counter columns. Full screen, no tab
/// bar, screen kept on.
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
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    struct WinnerChoice: Equatable {
        let winner: Int?
        var draw: Bool { winner == nil }
    }

    @MainActor
    init(matchId: String?, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _model = State(initialValue: TrackerModel(matchId: matchId))
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
                half(model.topSide, rotated: true)
                infoStrip
                half(model.bottomSide, rotated: false)
            }
        }
        // The halves run edge to edge, under the Dynamic Island and home indicator: their tap zones and
        // column hairlines reach the very top and bottom of the screen.
        .ignoresSafeArea(.container, edges: isReady ? .all : [])
        .background(T1.bg.ignoresSafeArea())
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
        .task { await model.start() }
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
    }

    private var isReady: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    private func half(_ side: Int, rotated: Bool) -> some View {
        TrackerHalf(model: model, side: side, rotated: rotated,
                    pickerOpen: Binding(get: { picker == side }, set: { picker = $0 ? side : nil }),
                    tap: tap)
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
                StripButton("Close") { onClose() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !model.readOnly {
                    StripButton(busy ? "Saving…" : "Record", accent: model.losingSide != nil) { if !busy { recordTapped() } }
                }
                StripButton("History") { showHistory() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
        guard model.isSynced else { return "Local game" }
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

    private func showHistory() {
        let model = model
        T1Overlays.shared.present(full: true) {
            TrackerHistoryPanel(
                model: model,
                chooseStartingLife: { chooseStartingLife() },
                reportNow: { decidedPrompt = true }
            )
        }
    }

    private func recordTapped() {
        if let losing = model.losingSide {
            pendingRecord = WinnerChoice(winner: 1 - losing.side)
        } else {
            chooseWinner()
        }
    }

    private func chooseWinner() {
        T1Overlays.shared.showMenu("Who won game \(model.currentGame)?", [
            T1MenuItem(title: "Me") { pendingRecord = WinnerChoice(winner: model.bottomSide) },
            T1MenuItem(title: model.name(model.topSide)) { pendingRecord = WinnerChoice(winner: model.topSide) },
            T1MenuItem(title: "Draw") { pendingRecord = WinnerChoice(winner: nil) },
        ])
    }

    private func chooseStartingLife() {
        let model = model
        T1Overlays.shared.showMenu("Starting life", TrackerModel.lifeChoices.map { life in
            T1MenuItem(title: "\(life)", checked: life == model.startingLife) { model.setStartingLife(life) }
        })
    }

    // MARK: copy

    private var recordTitle: String {
        guard let choice = pendingRecord else { return "Record game \(model.currentGame)?" }
        if choice.draw { return "Record game \(model.currentGame) as a draw?" }
        return choice.winner == model.bottomSide
            ? "Record game \(model.currentGame): you won?"
            : "Record game \(model.currentGame): \(model.name(model.topSide)) won?"
    }

    private var recordMessage: String {
        guard let choice = pendingRecord else { return "" }
        let mine = model.wins(model.bottomSide) + (choice.winner == model.bottomSide ? 1 : 0)
        let theirs = model.wins(model.topSide) + (choice.winner == model.topSide ? 1 : 0)
        return "Match is \(mine)–\(theirs)."
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
        return id
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

// MARK: one half (Me, Counters=0…3)

/// The opponent's half faces them. `rotationEffect` turns only the drawing, not where touches land, so a
/// rotated half is laid out in screen order instead (columns, zones and picker rows reversed) and only the
/// text is turned 180°.
private struct TrackerHalf: View {
    let model: TrackerModel
    let side: Int
    /// The opponent's half: their "down" is up on screen.
    let rotated: Bool
    @Binding var pickerOpen: Bool
    let tap: (Int, TrackerCounter, Int) -> String?

    var body: some View {
        let counters = model.visibleCounters(side)
        let enabled = !model.readOnly
        let name = model.name(side)
        let life = model.total(side, .life)
        let lifeColumn = CounterColumn(value: life, label: nil, size: counters.isEmpty ? 162 : 120, lost: life <= 0,
                                       rotated: rotated, enabled: enabled, name: "\(name) life",
                                       retract: { model.retract($0) }) { tap(side, .life, $0) }
        ZStack(alignment: rotated ? .bottom : .top) {
            HStack(spacing: 1) {
                if !rotated { lifeColumn }
                if !counters.isEmpty {
                    HStack(spacing: 1) {
                        ForEach(rotated ? counters.reversed() : counters) { counter in
                            let value = model.total(side, counter)
                            CounterColumn(value: value, label: counter.shortLabel,
                                          size: counters.count == 1 ? 80 : counters.count == 2 ? 64 : 44,
                                          lost: counter == .poison && value >= 10, rotated: rotated,
                                          enabled: enabled, name: "\(name) \(counter.label)",
                                          retract: { model.retract($0) }) { tap(side, counter, $0) }
                        }
                    }
                }
                if rotated { lifeColumn }
            }
            .background(T1.surface)
            if counters.isEmpty {
                // The hairline mark sits 8 pt from the strip.
                Rectangle().fill(T1.surface).frame(width: 26, height: 1)
                    .padding(rotated ? .bottom : .top, 8).allowsHitTesting(false)
            }
            if pickerOpen {
                CounterPicker(model: model, side: side, rotated: rotated) {
                    withAnimation(.easeOut(duration: 0.15)) { pickerOpen = false }
                }
                .transition(.move(edge: rotated ? .bottom : .top))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
                let dy = value.translation.height * (rotated ? -1 : 1)
                guard abs(dy) > abs(value.translation.width) * 1.5 else { return }
                withAnimation(.easeOut(duration: 0.15)) { pickerOpen = dy > 0 }
            }
        )
    }
}

/// Counter Column: its own top +1 / bottom −1 zones, the total, and a label for counters.
private struct CounterColumn: View {
    let value: Int
    let label: String?
    let size: CGFloat
    let lost: Bool
    let rotated: Bool
    let enabled: Bool
    let name: String
    let retract: (String) -> Void
    let onDelta: (Int) -> String?

    var body: some View {
        ZStack {
            // +1 on top in the player's orientation: on screen, the rotated half has −1 on top.
            VStack(spacing: 1) {
                TapZone(enabled: enabled, label: "\(name) \(rotated ? "−1" : "+1")", retract: retract) { onDelta(rotated ? -1 : 1) }
                TapZone(enabled: enabled, label: "\(name) \(rotated ? "+1" : "−1")", retract: retract) { onDelta(rotated ? 1 : -1) }
            }
            VStack(spacing: 8) {
                Text("\(value)")
                    .font(T1.mono(size, .semibold)).tracking(-size * 0.025).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .foregroundStyle(lost ? T1.error : T1.text)
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(.snappy(duration: 0.1), value: value)
                if let label { LabelText(label, color: T1.disabled) }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 32)
            .rotationEffect(.degrees(rotated ? 180 : 0))
            .allowsHitTesting(false)
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

/// Counter Picker: which counters this side shows, three at most. Swipe up or Done closes it.
private struct CounterPicker: View {
    let model: TrackerModel
    let side: Int
    /// Rows run bottom-up on screen and each row's content is turned 180° (see TrackerHalf).
    let rotated: Bool
    let done: () -> Void

    var body: some View {
        let shown = model.visibleCounters(side)
        let full = shown.count >= TrackerModel.maxCounters
        let rows = rotated ? TrackerCounter.extras.reversed() : TrackerCounter.extras
        VStack(spacing: 1) {
            if !rotated { header(shown.count) }
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(rows) { counter in
                        let on = shown.contains(counter)
                        let disabled = !on && full
                        Button { model.toggleCounter(counter, side: side) } label: {
                            HStack {
                                LabelText(counter.label, color: disabled ? T1.bg : T1.text)
                                Spacer()
                                LabelText(on ? "On" : disabled ? "Max 3" : "Off",
                                          color: disabled ? T1.bg : on ? T1.text : T1.disabled)
                            }
                            .padding(.horizontal, 16)
                            .rotationEffect(.degrees(rotated ? 180 : 0))
                            .frame(height: 48)
                            .background(disabled ? T1.disabled : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressFill())
                        .disabled(disabled)
                    }
                }
                .background(T1.surface)
            }
            .defaultScrollAnchor(rotated ? .bottom : .top)
            .background(T1.bg)
            if rotated { header(shown.count) }
        }
        .background(T1.surface)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rotated ? .bottom : .top)
    }

    private func header(_ count: Int) -> some View {
        HStack(spacing: 0) {
            if rotated { StripButton("Done", rotated: true) { done() } }
            LabelText("Counters · \(count) of \(TrackerModel.maxCounters)", color: T1.disabled)
                .rotationEffect(.degrees(rotated ? 180 : 0))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: rotated ? .trailing : .leading)
            if !rotated { StripButton("Done") { done() } }
        }
        .background(T1.bg)
    }
}

/// Strip Button: a label with a surface fill while pressed. Accent means "the result" (a game was lost).
private struct StripButton: View {
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

private struct PressFill: ButtonStyle {
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
    let chooseStartingLife: () -> Void
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
                Section1("Match \(model.scoreText)")
                if !model.readOnly {
                    action("Reset game") { model.resetGame() }
                }
                if !model.isSynced {
                    action("Starting life", detail: "\(model.startingLife)") { chooseStartingLife() }
                    action("New match") { model.newMatch() }
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
        return "\(model.name(g.side)) · \(g.counter.label) \(delta) → \(g.result)"
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
