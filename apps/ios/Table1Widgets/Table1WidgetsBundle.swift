import SwiftUI
import WidgetKit

@main
struct Table1WidgetsBundle: WidgetBundle {
    var body: some Widget {
        MatchWidget()
        NextEventWidget()
        ValueWidget()
        MetaBreakdownWidget()
        MatchupGridWidget()
        ArchetypeMatchupsWidget()
        LimitedCardsWidget()
        IconWidget()
        PlayerLiveActivity()
        OrganizerLiveActivity()
        if #available(iOS 18.0, *) {
            LifeTrackerControl()
            ScanCardsControl()
        }
    }
}
