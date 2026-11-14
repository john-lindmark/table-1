import SwiftUI
import WebKit
import AVFoundation
import Supabase

// The organizer's tools for the room (contract/room-tools-2026-11-13.md): the Display panel (address, QR, what the
// TV shows, an announcement, a second screen from the phone), extra time for a table, judge calls, and the rules level
// and decklist deadline of Setup → Details. Every part reads `EventSide.of(event).room`, which stays nil on a server
// without it, so nothing here draws there.

// MARK: the display remote

/// Live → More → Display: the display's address and QR, Copy link, Showing, Announcement, and a second screen.
struct DisplayPanel: View {
    let eventId: String
    let name: String
    @State private var show = "auto"
    @State private var message = ""
    @State private var shown = ""
    @State private var copied = false
    @State private var error: String?
    private var second: SecondScreen { SecondScreen.shared }

    private var url: URL { RoomRules.displayURL(eventId) }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Display", subtitle: nil, back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    VStack(spacing: 12) {
                        Image(uiImage: qrImage(url.absoluteString)).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 200, height: 200).padding(8).background(Color.white)
                        Text(url.absoluteString.replacingOccurrences(of: "https://", with: "")).font(T1.mono(13)).textSelection(.enabled)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity).padding(20).background(T1.surface)
                    Ghost(text: copied ? "Copied" : "Copy link") {
                        UIPasteboard.general.string = url.absoluteString
                        copied = true
                    }
                    if let error { Notice(error, error: true) }

                    Section1("Showing")
                    T1Segmented(options: RoomRules.shows.map { (value: $0.key, label: $0.label) },
                                selection: Binding(get: { show }, set: { set(show: $0) }))

                    Section1("Announcement")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            LabelText(shown.isEmpty ? "Not showing" : "Showing", color: shown.isEmpty ? T1.muted : T1.accent)
                            Spacer()
                            LabelText(RoomRules.count(message))
                        }
                        TextField("", text: $message, axis: .vertical)
                            .font(T1.mono(15)).tint(T1.accent).lineLimit(1...4)
                            .onChange(of: message) { _, v in if v.count > RoomRules.messageLimit { message = String(v.prefix(RoomRules.messageLimit)) } }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).background(T1.surface)
                    .focusArea()
                    HStack(spacing: 1) {
                        Ghost(text: "Clear") { message = ""; set(message: "") }
                        Ghost(text: "Show", accent: !trimmed.isEmpty && trimmed != shown) { if !trimmed.isEmpty { set(message: trimmed) } }
                            .keepsKeyboard()
                    }

                    Section1("Second screen")
                    if let screen = second.screenName {
                        if second.showing == eventId {
                            ListRow(title: "On \(screen)") { LabelText("Showing", color: T1.accent) }
                            Ghost(text: "Stop showing") { second.stop() }
                        } else {
                            Ghost(text: "Show on \(screen)", accent: true) { second.show(eventId) }
                        }
                    } else {
                        Notice("Mirror your screen, or open the address on the TV.")
                    }
                }
            }
        }
        .foregroundStyle(T1.text)
        .task {
            second.look()
            let side = EventSide.of(eventId)
            if side.room == nil { await side.refreshRoom() }
            if let d = side.room?.display {
                show = d.show
                shown = d.message ?? ""
                message = d.message ?? ""
            }
        }
    }

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func set(show next: String) {
        let before = show
        show = next
        save(["show": .string(next)]) { show = before }
    }

    private func set(message text: String) {
        save(["message": text.isEmpty ? .null : .string(text)]) {}
    }

    private func save(_ patch: [String: AnyJSON], undo: @escaping () -> Void) {
        Task { @MainActor in
            do {
                let d = try await Repo.setDisplay(eventId, patch: patch)
                show = d.show
                shown = d.message ?? ""
                error = nil
                await EventSide.of(eventId).refreshRoom()
            } catch {
                undo()
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: a second screen from the phone

/// An external display (a cable, or AirPlay with the phone not mirrored) filled with the event's display page, in a
/// web view the app owns; the phone keeps the organizer screen. The system hands the app a window scene for a
/// connected display (`AppDelegate` answers for its role); nothing is put on it until Show, and Stop takes it off.
@MainActor
@Observable
final class SecondScreen {
    static let shared = SecondScreen()
    /// Off in Release until the second screen has been tried on hardware (AirPlay and a cable): see AppDelegate.
    #if DEBUG
    static let available = true
    #else
    static let available = false
    #endif
    /// The connected display's scene, when there is one.
    private(set) var scene: UIWindowScene?
    /// The event whose display page is up.
    private(set) var showing: String?
    private var window: UIWindow?
    #if DEBUG
    /// The design demo's stand-in for a connected screen (`-T1EventsDemo display -T1Screen <name>`).
    var demoName: String?
    #endif

    /// What to call the screen: the AirPlay or HDMI route's name when the system says, else "the second screen".
    var screenName: String? {
        #if DEBUG
        if let demoName { return demoName }
        #endif
        guard scene != nil else { return nil }
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay || $0.portType == .HDMI }
        return out.map(\.portName).flatMap { $0.isEmpty ? nil : $0 } ?? "the second screen"
    }

    /// Finds the connected display (the panel asks as it opens; the scene's own connect and disconnect call in too).
    func look() {
        guard Self.available else { return }
        scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowExternalDisplayNonInteractive }
        if scene == nil { clear() }
    }

    func connected(_ s: UIWindowScene) { scene = s }

    func disconnected(_ s: UIWindowScene) {
        if scene === s { scene = nil; clear() }
    }

    func show(_ eventId: String) {
        look()
        guard let scene else { return }
        let w = UIWindow(windowScene: scene)
        w.rootViewController = DisplayPageController(url: RoomRules.displayURL(eventId))
        w.isHidden = false
        window = w
        showing = eventId
        Telemetry.capture("display_second_screen", ["on": true])
    }

    func stop() {
        guard showing != nil else { return }
        clear()
        Telemetry.capture("display_second_screen", ["on": false])
    }

    private func clear() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        showing = nil
    }
}

/// The display page, edge to edge on the second screen. No one can touch it there, so nothing is interactive.
final class DisplayPageController: UIViewController {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(T1.bg)
        web.scrollView.backgroundColor = UIColor(T1.bg)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        web.load(URLRequest(url: url))
        view = web
    }
}

/// The scene delegate of a connected display: tells `SecondScreen` it's there, and when it goes.
final class SecondScreenSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let s = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated { SecondScreen.shared.connected(s) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let s = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated { SecondScreen.shared.disconnected(s) }
    }
}

// MARK: extra time

@MainActor
enum ExtraTime {
    /// A match's Extra time menu: +3 min, +5 min, +10 min, Take it back.
    static func menu(eventId: String, matchId: String, table: Int?, failed: @escaping (String) -> Void = { _ in }) {
        let now = EventSide.of(eventId).room?.extra(matchId) ?? 0
        func add(_ seconds: Int) {
            Task { @MainActor in
                do { try await Repo.extendMatch(matchId, seconds: seconds) } catch { failed(error.localizedDescription) }
                await EventSide.of(eventId).refreshRoom()
            }
        }
        var items = RoomRules.extras.map { s in T1MenuItem(title: "+\(s / 60) min", enabled: now + s <= 3600) { add(s) } }
        if now > 0 { items.append(T1MenuItem(title: "Take it back", detail: RoomRules.extensionText(now)) { add(-now) }) }
        T1Overlays.shared.showMenu("Extra time · table \(table.map(String.init) ?? "–")", message: now > 0 ? RoomRules.extensionText(now) : nil, items)
    }
}

// MARK: judge calls

/// Leading the organizer's Round tab: every open call, oldest first, `JUDGE · TABLE 7 · BEA · 2 MIN` with Done.
struct JudgeCallRows: View {
    let eventId: String
    var failed: (String) -> Void = { _ in }

    var body: some View {
        let calls = EventSide.of(eventId).room?.calls ?? []
        if !calls.isEmpty {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                VStack(spacing: 1) {
                    ForEach(calls) { c in
                        HStack(spacing: 12) {
                            LabelText(RoomRules.judgeLine(table: c.tableNumber, by: c.by, calledAt: Leagues.parseDate(c.calledAt), now: context.date), color: T1.accent)
                            Spacer(minLength: 0)
                            BarButton("Done") { resolve(c) }
                                .accessibilityLabel("Done, table \(c.tableNumber.map(String.init) ?? "")")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                        .overlay(alignment: .leading) { T1.accent.frame(width: 1) }
                    }
                }
            }
        }
    }

    private func resolve(_ c: EventRoom.Call) {
        Task { @MainActor in
            do { try await Repo.judgeResolve(c.callId) } catch { failed(error.localizedDescription) }
            await EventSide.of(eventId).refreshRoom()
        }
    }
}

/// On the player's match: Call a judge (a confirm), or `JUDGE CALLED` in accent with Cancel. Nothing unless the server
/// says this is your table in the round being played.
struct JudgeCallRow: View {
    let eventId: String
    let matchId: String
    @State private var error: String?

    var body: some View {
        if let mine = EventSide.of(eventId).room?.myMatch, mine.matchId == matchId {
            if let error { Notice(error, error: true) }
            if mine.callOpen == true {
                ListRow(title: mine.tableNumber.map { "Table \($0)" } ?? "Your table") {
                    HStack(spacing: 16) {
                        LabelText("Judge called", color: T1.accent)
                        BarButton("Cancel") { JudgeCalls.cancel(eventId: eventId, matchId: matchId) { error = $0 } }
                    }
                }
            } else {
                Ghost(text: "Call a judge") { JudgeCalls.ask(eventId: eventId, matchId: matchId, table: mine.tableNumber) { error = $0 } }
            }
        }
    }
}

@MainActor
enum JudgeCalls {
    static func ask(eventId: String, matchId: String, table: Int?, failed: @escaping (String) -> Void = { _ in }) {
        T1Overlays.shared.ask("Call a judge?", message: "The organizers are told table \(table.map(String.init) ?? "yours") needs a judge.", action: "Call a judge") {
            Task { @MainActor in
                do { try await Repo.judgeCall(matchId) } catch { failed(error.localizedDescription) }
                await EventSide.of(eventId).refreshRoom()
            }
        }
    }

    static func cancel(eventId: String, matchId: String, failed: @escaping (String) -> Void = { _ in }) {
        Task { @MainActor in
            do { try await Repo.judgeCancel(matchId) } catch { failed(error.localizedDescription) }
            await EventSide.of(eventId).refreshRoom()
        }
    }
}

// MARK: rules level and the decklist deadline (Setup → Details)

/// Rules (Not said | Casual | Competitive) and, when decklists are on, Decklists due (a date and time).
struct RulesFields: View {
    let eventId: String
    let decklistsOn: Bool
    let startsAt: Date?
    @State var rel: String
    @State var due: Date?
    var failed: (String) -> Void = { _ in }

    var body: some View {
        Section1("Rules")
        T1Segmented(options: RoomRules.rels.map { (value: $0.key, label: $0.label) },
                    selection: Binding(get: { rel }, set: { v in
                        rel = v
                        save { try await Repo.setEventRules(eventId, rel: .some(v.isEmpty ? nil : v)) }
                    }))
        if decklistsOn {
            T1Switch(title: "Decklists due", detail: due.map { RoomRules.dueText($0) } ?? "Before round 1", isOn: Binding(
                get: { due != nil },
                set: { on in
                    let next = on ? (startsAt.map { $0.addingTimeInterval(-30 * 60) } ?? Date().addingTimeInterval(3600)) : nil
                    due = next
                    save { try await Repo.setEventRules(eventId, due: .some(next)) }
                }))
            if let d = due {
                ListRow(title: "Due", detail: RoomRules.dueText(d)) {
                    DatePicker("Decklists due", selection: Binding(get: { d }, set: { v in
                        due = v
                        save { try await Repo.setEventRules(eventId, due: .some(v)) }
                    }), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().tint(T1.accent).colorScheme(.dark)
                }
            }
        }
    }

    private func save(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { failed(error.localizedDescription) }
        }
    }
}
