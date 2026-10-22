import AppIntents

/// App Shortcuts: the Life tracker and Scan cards quick actions in Shortcuts, Spotlight and the Action Button
/// (iOS 17+; the same intents back the iOS 18 controls). Contract: contract/widgets-2026-10-22.md.
struct Table1Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenLifeTrackerIntent(),
                    phrases: ["Open \(.applicationName) life tracker", "Start a \(.applicationName) life tracker"],
                    shortTitle: "Life tracker", systemImageName: "heart.text.square")
        AppShortcut(intent: ScanCardsIntent(),
                    phrases: ["Scan cards with \(.applicationName)", "Scan cards into \(.applicationName)"],
                    shortTitle: "Scan cards", systemImageName: "camera.viewfinder")
    }
}
