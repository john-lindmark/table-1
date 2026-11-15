import SwiftUI

/* The main navigation (contract/main-nav-2026-11-14.md, Figma 765:113609): four tabs, each with a strip of sub-tabs
   above the tab bar. Each tab remembers its last sub-tab on the device; Life tracker opens full screen and is never
   remembered. Cases: testdata/main-nav/cases.json (MainNavTests). */

enum Tab: String, Hashable, CaseIterable { case events, collection, insights, account }

/// Every sub-tab, by its wire id (cases `tabs[].subs[].id`).
enum SubTab: String, Hashable, CaseIterable {
    case events, tracker
    case collection, trade, wants
    case constructed, limited, rankings
    case profile, records, settings
}

enum MainNav {
    struct Sub: Equatable {
        let id: SubTab
        let label: String
        /// Opens over everything (the life tracker) instead of becoming the tab's root.
        var fullScreen = false
    }

    static func label(_ tab: Tab) -> String {
        switch tab {
        case .events: "Play"
        case .collection: "Cards"
        case .insights: "Insights"
        case .account: "Account"
        }
    }

    static func subs(_ tab: Tab) -> [Sub] {
        switch tab {
        case .events: [Sub(id: .events, label: "Events"), Sub(id: .tracker, label: "Life tracker", fullScreen: true)]
        case .collection: [Sub(id: .collection, label: "Collection"), Sub(id: .trade, label: "Trade"), Sub(id: .wants, label: "Wants")]
        case .insights: [Sub(id: .constructed, label: "Constructed"), Sub(id: .limited, label: "Limited"), Sub(id: .rankings, label: "Rankings")]
        case .account: [Sub(id: .profile, label: "Profile"), Sub(id: .records, label: "Records"), Sub(id: .settings, label: "Settings")]
        }
    }

    static func defaultSub(_ tab: Tab) -> SubTab { subs(tab)[0].id }

    /// What a tab opens on for the value kept on the device: one of its own sub-tabs that isn't full screen, else
    /// its default (cases `remembered`).
    static func remembered(_ tab: Tab, _ stored: String?) -> SubTab {
        guard let stored, let sub = subs(tab).first(where: { $0.id.rawValue == stored }), !sub.fullScreen else { return defaultSub(tab) }
        return sub.id
    }

    static func key(_ tab: Tab) -> String { "nav.sub.\(tab.rawValue)" }

    static func load(_ tab: Tab, _ defaults: UserDefaults = .standard) -> SubTab {
        remembered(tab, defaults.string(forKey: key(tab)))
    }

    static func save(_ sub: SubTab, for tab: Tab, _ defaults: UserDefaults = .standard) {
        guard subs(tab).contains(where: { $0.id == sub && !$0.fullScreen }) else { return }
        defaults.set(sub.rawValue, forKey: key(tab))
    }

    /// A Cards path that starts on a sub-tab's own screen (a link or push to Trades or Wants) opens that sub-tab
    /// with the rest pushed on it, instead of a pushed copy (contract § 2).
    static func cards(_ path: [LibraryRoute]) -> (sub: SubTab?, rest: [LibraryRoute]) {
        switch path.first {
        case .trades?: (.trade, Array(path.dropFirst()))
        case .wants?: (.wants, Array(path.dropFirst()))
        default: (nil, path)
        }
    }

    /// A Cards path holding every ranking of yours (table-1.site/library/rankings): that's Insights → Rankings now, with
    /// what follows it pushed there; nil for any other path.
    static func rankingsIn(_ path: [LibraryRoute]) -> [LibraryRoute]? {
        guard let i = path.firstIndex(of: .rankings(nil)) else { return nil }
        return Array(path[(i + 1)...])
    }

    /// The same for Insights: every ranking of yours is the Rankings sub-tab.
    static func insights(_ path: [InsightsRoute]) -> (sub: SubTab?, rest: [InsightsRoute]) {
        if case .library(.rankings(nil))? = path.first { return (.rankings, Array(path.dropFirst())) }
        return (nil, path)
    }

    /// contract/telemetry-2026-10-15.md: the root's screen name.
    static func screen(_ sub: SubTab) -> String {
        switch sub {
        case .events: "events_home"
        case .tracker: "life_tracker"
        case .collection: "library_home"
        case .trade: "trades"
        case .wants: "wants"
        case .constructed: "insights_constructed"
        case .limited: "insights_limited"
        case .rankings: "rankings"
        case .profile: "account_profile"
        case .records: "account_records"
        case .settings: "account_settings"
        }
    }
}

/// The sub-tab strip above the tab bar (Figma 765:113447): equal cells, 44 pt, 9 pt labels; the current one white under
/// a 1 pt accent line along its top, the others muted.
struct T1SubTabBar: View {
    let items: [MainNav.Sub]
    let selection: SubTab
    let onSelect: (MainNav.Sub) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.id) { item in
                let on = item.id == selection
                Button { onSelect(item) } label: {
                    Text(item.label.uppercased()).font(T1.mono(9)).tracking(1.5)
                        .foregroundStyle(on ? T1.text : T1.muted).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .overlay(alignment: .top) { if on { T1.accent.frame(height: 1) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(T1.bg)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension View {
    /// A sub-tab root kept alive while another sub-tab of its tab is showing.
    func subRoot(_ on: Bool) -> some View {
        opacity(on ? 1 : 0).allowsHitTesting(on).accessibilityHidden(!on)
    }
}

#if DEBUG
/// Design QA: `-T1Sub <sub-tab>` starts a demo's strip on that sub-tab.
enum EventsDemoArgs {
    static func sub(_ fallback: SubTab) -> SubTab {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-T1Sub"), i + 1 < args.count, let s = SubTab(rawValue: args[i + 1]) else { return fallback }
        return s
    }
}
#endif
