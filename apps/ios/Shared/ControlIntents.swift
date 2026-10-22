import AppIntents
import Foundation

/// Quick actions (contract/widgets-2026-10-22.md): Control Center and Lock Screen controls (iOS 18), App Shortcuts and
/// the Action Button. Each opens the app, so `perform` runs in the app's process and hands the route to the app.
struct OpenLifeTrackerIntent: AppIntent {
    static var title: LocalizedStringResource = "Open life tracker"
    static var description = IntentDescription("Opens a Table 1 life tracker for a game at the table.")
    static var openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentRouter.open(URL(string: "table1://tracker?src=control")!)
        return .result()
    }
}

struct ScanCardsIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan cards"
    static var description = IntentDescription("Opens the Table 1 card scanner to add cards to your collection.")
    static var openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentRouter.open(URL(string: "table1://scan?src=control")!)
        return .result()
    }
}

/// Where an intent's route goes: the app sets `handler` at launch; a route that arrives first waits in `pending`.
@MainActor
enum AppIntentRouter {
    static var handler: ((URL) -> Void)? {
        didSet { if let url = pending, let handler { pending = nil; handler(url) } }
    }
    private static var pending: URL?

    static func open(_ url: URL) {
        if let handler { handler(url) } else { pending = url }
    }
}
