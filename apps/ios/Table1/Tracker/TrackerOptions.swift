import SwiftUI
import UIKit

// MARK: Options (Figma 231:9191)

/// The tracker's Options panel, rising from the bottom: Chooser, Roll dice, History, New match (local trackers:
/// back to Setup), Leave tracker.
struct TrackerOptionsPanel: View {
    let chooser: () -> Void
    let dice: () -> Void
    let history: () -> Void
    var newMatch: (() -> Void)?
    let leave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row("Chooser", chooser)
            row("Roll dice", dice)
            row("History", history)
            if let newMatch { row("New match", newMatch) }
            row("Leave tracker", leave)
        }
        .padding(16)
        .padding(.bottom, 30)
        .background(T1.bg)
    }

    /// Closes the panel first, so whatever the row opens sits on the tracker, not on the panel.
    private func row(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            T1Overlays.shared.dismissPanel()
            run()
        } label: {
            Text(title.uppercased()).font(T1.mono(12)).tracking(1.5).lineSpacing(6)
                .foregroundStyle(T1.disabled)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFill())
    }
}

// MARK: Roll dice

/// Pick a die and how many, then Roll: the total in accent (the result), each die under it.
/// Tapping the total rolls again. The choice of die is remembered on this device.
struct TrackerDicePanel: View {
    @AppStorage("tracker.dice.sides") private var sides = 20
    @AppStorage("tracker.dice.count") private var count = 1
    @State private var rolls: [Int] = []
    @State private var rolledAs: (sides: Int, count: Int)?
    @State private var rollCount = 0

    var body: some View {
        VStack(spacing: 1) {
            HStack {
                LabelText("Roll dice", color: T1.disabled)
                Spacer()
                StripButton("Done") { T1Overlays.shared.dismissPanel() }
            }
            .padding(.leading, 16)
            .background(T1.bg)
            Button(action: roll) {
                VStack(spacing: 8) {
                    Text(rolls.isEmpty ? "–" : "\(rolls.reduce(0, +))")
                        .font(T1.mono(96, .semibold)).tracking(-2.4).monospacedDigit()
                        .foregroundStyle(rolls.isEmpty ? T1.disabled : T1.accent)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.15), value: rollCount)
                    LabelText(caption, color: T1.disabled)
                }
                .frame(maxWidth: .infinity).frame(height: 180)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFill())
            .accessibilityLabel(rolls.isEmpty ? "Not rolled yet" : "Rolled \(rolls.reduce(0, +))")
            T1Segmented(options: Dice.sides.map { (value: $0, label: "D\($0)") }, selection: $sides)
            T1Stepper(label: "Dice", value: $count, range: 1...Dice.maxCount)
            BigAction(text: "Roll", action: roll)
        }
        .background(T1.surface)
        .sensoryFeedback(.impact, trigger: rollCount)
    }

    /// "2D6 · 3 + 4", "D20", or what to do before the first roll.
    private var caption: String {
        guard let r = rolledAs else { return "Tap roll" }
        let die = (r.count > 1 ? "\(r.count)" : "") + "D\(r.sides)"
        return [die, Dice.breakdown(rolls)].compactMap { $0 }.joined(separator: " · ")
    }

    private func roll() {
        rolls = Dice.roll(sides: sides, count: count)
        rolledAs = (sides, rolls.count)
        rollCount += 1
        Telemetry.capture("tracker_dice_rolled", ["sides": sides, "count": rolls.count])
    }
}

// MARK: Chooser

/// Covers the screen. Everyone puts a finger down; when the fingers have stayed put for two seconds one is
/// picked at random and turns accent. Lift every finger to go again.
struct TrackerChooserScreen: View {
    @State private var chooser = Chooser()
    @State private var pickCount = 0

    var body: some View {
        ZStack {
            MultiTouchSurface(
                down: { id, p in chooser.down(id, x: p.x, y: p.y, at: .now) },
                move: { id, p in chooser.move(id, x: p.x, y: p.y) },
                up: { id in chooser.up(id, at: .now) }
            )
            TimelineView(.animation(paused: chooser.fingers.count < Chooser.minFingers)) { context in
                ZStack {
                    ForEach(chooser.fingers, id: \.id) { finger in
                        FingerMark(state: markState(finger.id), progress: chooser.progress(at: context.date) ?? 0)
                            .position(x: finger.x, y: finger.y)
                    }
                }
                .onChange(of: context.date) { _, now in tick(now) }
            }
            .allowsHitTesting(false)
            if chooser.fingers.count < Chooser.minFingers && !chooser.picked {
                LabelText(chooser.fingers.isEmpty ? "Everyone put a finger down" : "One more finger",
                          color: T1.disabled)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            StripButton("Done") { T1Overlays.shared.dismissPanel() }
        }
        .background(T1.bg.ignoresSafeArea())
        .statusBarHidden()
        .sensoryFeedback(.success, trigger: pickCount)
        .onAppear { Telemetry.capture("tracker_chooser_opened") }
    }

    private func markState(_ id: Int) -> FingerMark.State {
        guard let winner = chooser.winner else { return .waiting }
        return id == winner ? .picked : .lost
    }

    private func tick(_ now: Date) {
        guard chooser.tick(at: now) != nil else { return }
        pickCount += 1
        Telemetry.capture("tracker_chooser_picked", ["fingers": chooser.fingers.count])
    }
}

private struct FingerMark: View {
    enum State { case waiting, picked, lost }
    let state: State
    /// How far through the two seconds (drawn as a ring closing around the finger).
    let progress: Double

    var body: some View {
        ZStack {
            switch state {
            case .waiting:
                Circle().stroke(T1.surface, lineWidth: 2)
                Circle().trim(from: 0, to: progress).stroke(T1.text, lineWidth: 2).rotationEffect(.degrees(-90))
            case .picked:
                Circle().fill(T1.accent)
            case .lost:
                Circle().stroke(T1.disabled, lineWidth: 2)
            }
        }
        .frame(width: state == .picked ? 132 : 96, height: state == .picked ? 132 : 96)
        .animation(.snappy(duration: 0.2), value: state)
    }
}

/// SwiftUI has no per-finger touches; this view reports every finger by id, in its own coordinates.
private struct MultiTouchSurface: UIViewRepresentable {
    let down: (Int, CGPoint) -> Void
    let move: (Int, CGPoint) -> Void
    let up: (Int) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onDown = down
        view.onMove = move
        view.onUp = up
    }

    final class TouchView: UIView {
        var onDown: ((Int, CGPoint) -> Void)?
        var onMove: ((Int, CGPoint) -> Void)?
        var onUp: ((Int) -> Void)?

        private func id(_ t: UITouch) -> Int { ObjectIdentifier(t).hashValue }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { onDown?(id(t), t.location(in: self)) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { onMove?(id(t), t.location(in: self)) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { onUp?(id(t)) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { onUp?(id(t)) }
        }
    }
}

// MARK: Setup

/// A local tracker's first screen (contract/life-tracker-commander-2026-11-03.md): how many players and their
/// starting life, then Start (the chooser opens next). Continue reopens the saved table as it was.
struct TrackerSetupView: View {
    let canContinue: Bool
    let start: (_ players: Int, _ life: Int) -> Void
    let resume: () -> Void
    let close: () -> Void
    @State private var players = TrackerTable.lastPlayers
    @State private var life = TrackerTable.lastLife

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Life tracker", back: close)
            VStack(spacing: 1) {
                field("Players") {
                    T1Segmented(options: TrackerTable.playerChoices.map { (value: $0, label: "\($0)") }, selection: $players)
                }
                field("Starting life") {
                    T1Segmented(options: TrackerTable.lifeChoices.map { (value: $0, label: "\($0)") }, selection: $life)
                }
            }
            Spacer(minLength: 0)
            if canContinue { Ghost(text: "Continue", action: resume) }
            BigAction(text: "Start") { start(players, life) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T1.bg.ignoresSafeArea())
    }

    private func field(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabelText(label, color: T1.disabled)
            control()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.bg)
    }
}
