#if DEBUG
import SwiftUI

/// Debug only: `-T1InsightsDemo [constructed|archetype|finish|ban|matchups|limited|pair|scatter|cardsearch|card|cardlist]` opens Insights on the packs
/// in DebugResources (insights-demo-*.json, from real MTGO pages and a 17Lands slice by tools/insights/demo_packs.sh),
/// without signing in.
struct InsightsDemoRoot: View {
    @State private var path: [InsightsRoute] = []
    @State private var ready = false

    var body: some View {
        NavigationStack(path: $path) {
            Group { if ready { InsightsHomeView(path: $path, isFront: false) } else { T1.bg } }
                .navigationDestination(for: InsightsRoute.self) { InsightsDestination(route: $0, path: $path) }
        }
        .background(T1.bg.ignoresSafeArea())
        .task {
            let store = InsightsStore.shared
            store.loadDemo()
            let args = ProcessInfo.processInfo.arguments
            let mode = args.firstIndex(of: "-T1InsightsDemo").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "constructed"
            store.section = ["limited", "pair", "scatter"].contains(mode) ? "limited" : "constructed"
            if store.constructed[store.format] == nil { store.format = "modern" }
            let pack = store.constructed[store.format]
            switch mode {
            case "archetype": if let a = pack?.tiers["all"]?.windows["30"]?.share.first(where: { $0.a != 0 })?.a { path = [.archetype(store.format, a)] }
            case "finish": if let a = pack?.tiers["all"]?.windows["30"]?.share.first(where: { $0.a != 0 })?.a { path = [.archetype(store.format, a), .finish(store.format, a, 0)] }
            case "ban": if let b = pack?.bans.first { path = [.ban(store.format, b.change)] }
            case "matchups": path = [.matchups(store.format)]
            case "cardsearch": path = [.cardSearch(store.format)]
            case "card", "cardlist":
                if let c = pack?.tiers["all"]?.windows["30"]?.cards["main"]?.up.first {
                    path = [.cardSearch(store.format), .card(store.format, c.c, c.n)] + (mode == "cardlist" ? [.cardFinish(store.format, c.c, 0)] : [])
                }
            case "pair":
                if let l = store.limitedPack, let ev = store.currentEvent(of: l), let p = l.events[ev]?.groups["all"]?.pairs.first {
                    path = [.pair(l.set_code, ev, "all", p.p)]
                }
            default: break
            }
            ready = true
        }
    }
}
#endif
