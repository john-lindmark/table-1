import AppIntents
import SwiftUI
import WidgetKit

/// Control Center and Lock Screen controls (iOS 18). Each runs an intent that opens the app (ControlIntents.swift).
@available(iOS 18.0, *)
struct LifeTrackerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "site.table1.control.tracker") {
            ControlWidgetButton(action: OpenLifeTrackerIntent()) {
                Label("Life tracker", systemImage: "heart.text.square")
            }
        }
        .displayName("Life tracker")
        .description("Open a Table 1 life tracker.")
    }
}

@available(iOS 18.0, *)
struct ScanCardsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "site.table1.control.scan") {
            ControlWidgetButton(action: ScanCardsIntent()) {
                Label("Scan cards", systemImage: "camera.viewfinder")
            }
        }
        .displayName("Scan cards")
        .description("Scan cards into your Table 1 collection.")
    }
}
