import Foundation
import Observation
import Supabase

struct InsightsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The Insights tab's data (contract/insights-2026-10-24.md): the published pack index, the packs themselves (kept
/// on the device and refetched only when their version changes) and what the viewer has picked, kept on the account
/// (user_settings.insights) with a copy on the device. Archetype and card pages come from their RPCs on demand.
@MainActor @Observable
final class InsightsStore {
    static let shared = InsightsStore()

    private(set) var index: [Insights.IndexEntry] = []
    private(set) var constructed: [String: Insights.ConstructedPack] = [:]
    private(set) var limited: [String: Insights.LimitedPack] = [:]
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    /// "Couldn't refresh · last updated …" while the index on screen is the device's saved one, or a refresh failed
    /// (contract/offline-2026-10-31.md § 1).
    private(set) var stale: String?
    private static let indexKey = "insights-index"
    /// Debug demo (-T1InsightsDemo): packs and pages from DebugResources, nothing from the network.
    @ObservationIgnored var demoPages: [String: Data]?
    /// Sets and Arena cube versions to rank (limited_rankable), newest first; loaded with the index.
    private(set) var rankable: [RankableSet] = []
    /// Whether `rankable` holds an answer (this launch's, or the device's last one for this account). Limited's picker
    /// waits for it, so sets with no 17Lands data yet don't arrive at the front of the picker a moment after it draws.
    private(set) var rankableReady = false
    /// "New in Insights" pushes on for the account; nil until loaded.
    private(set) var alerts: Bool?

    var section: String = UserDefaults.standard.string(forKey: "insights.section") ?? "constructed" {
        didSet { UserDefaults.standard.set(section, forKey: "insights.section"); if !applying { Telemetry.capture("insights_section_changed", ["section": section]) }; picksChanged() }
    }
    var format: String = UserDefaults.standard.string(forKey: "insights.format") ?? "modern" {
        didSet { UserDefaults.standard.set(format, forKey: "insights.format"); if !applying { Telemetry.capture("insights_format_changed", ["format": format]) }; picksChanged() }
    }
    /// The tier the viewer picked; nil = the pack's default (Big events unless they're thin).
    var tierPicked: Insights.Tier? = UserDefaults.standard.string(forKey: "insights.tier").flatMap(Insights.Tier.init) {
        didSet {
            UserDefaults.standard.set(tierPicked?.rawValue, forKey: "insights.tier")
            if let t = tierPicked, !applying { Telemetry.capture("insights_tier_changed", ["tier": t.rawValue]) }
            picksChanged()
        }
    }
    var days: Int = { let d = UserDefaults.standard.integer(forKey: "insights.days"); return Insights.windows.contains(d) ? d : 30 }() {
        didSet { UserDefaults.standard.set(days, forKey: "insights.days"); if !applying { Telemetry.capture("insights_window_changed", ["days": days]) }; picksChanged() }
    }
    /// The Limited page's Sort, Rarity and Color for this session; a tapped Limited cards widget sets them to its own.
    var limitedSort = "gih"
    var limitedRarity: [String] = []
    var limitedColor: [String] = []
    /// Formats and sets kept out of the pickers on this device (Insights → Edit).
    var hiddenFormats: [String] = UserDefaults.standard.stringArray(forKey: "insights.hiddenFormats") ?? [] {
        didSet { UserDefaults.standard.set(hiddenFormats, forKey: "insights.hiddenFormats"); picksChanged() }
    }
    var hiddenSets: [String] = UserDefaults.standard.stringArray(forKey: "insights.hiddenSets") ?? [] {
        didSet { UserDefaults.standard.set(hiddenSets, forKey: "insights.hiddenSets"); picksChanged() }
    }
    var shownFormats: [(key: String, label: String)] {
        let keys = Insights.visibleKeys(Insights.formats.map(\.key), hiddenFormats)
        return Insights.formats.filter { keys.contains($0.key) }
    }
    /// Every chip of the Limited set picker: sets with no 17Lands data yet, then the index's packs.
    var limitedChips: [LimitedPicker.Chip] {
        LimitedPicker.chips(packs: limitedSets.map { ($0.key, $0.name) }, rankable: rankable, today: LimitedPicker.today)
    }
    /// The chips Edit leaves shown (sets with no data yet hide like the packs).
    var shownChips: [LimitedPicker.Chip] { LimitedPicker.shown(limitedChips, hidden: hiddenSets) }
    /// A Limited key's full name: the index's, else the set to rank's.
    func limitedName(_ key: String) -> String? {
        limitedSets.first { $0.key == key }?.name ?? rankable.first { $0.key == key }?.name
    }
    /// Shows or hides a format (or a set); a picked one that's hidden gives way to the first one still shown.
    func setHidden(format: Bool, _ key: String, _ hide: Bool) {
        if format {
            hiddenFormats = hiddenFormats.filter { $0 != key } + (hide ? [key] : [])
            if !shownFormats.contains(where: { $0.key == self.format }), let first = shownFormats.first { self.format = first.key }
        } else {
            hiddenSets = hiddenSets.filter { $0 != key } + (hide ? [key] : [])
            if let s = setCode, !shownChips.contains(where: { $0.key == s }) { setCode = shownChips.first?.key }
        }
        Telemetry.capture("insights_picker_edited", ["picker": format ? "formats" : "sets", "hidden": format ? hiddenFormats.count : hiddenSets.count])
    }
    var setCode: String? = UserDefaults.standard.string(forKey: "insights.set") {
        didSet { UserDefaults.standard.set(setCode, forKey: "insights.set"); captureSet(); picksChanged() }
    }
    var event: String = UserDefaults.standard.string(forKey: "insights.event") ?? "PremierDraft" {
        didSet { UserDefaults.standard.set(event, forKey: "insights.event"); captureSet(); picksChanged() }
    }
    var group: String = UserDefaults.standard.string(forKey: "insights.group") ?? "all" {
        didSet { UserDefaults.standard.set(group, forKey: "insights.group"); picksChanged() }
    }
    private func captureSet() { if !applying { Telemetry.capture("insights_set_changed", ["set": setCode ?? "", "event": event]) } }

    // MARK: picks on the account (contract § What the viewer picked)

    /// Setting the account's picks: no "changed" telemetry and no write back for a change nobody made here.
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var heldPicks: [String: AnyJSON]?
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    var picks: Insights.Picks {
        .init(section: section, format: format, tier: tierPicked?.rawValue, days: days, set: setCode, event: event, group: group,
              hidden_formats: hiddenFormats, hidden_sets: hiddenSets)
    }

    /// Written a moment after the last change.
    private func picksChanged() {
        guard !applying, demoPages == nil, Repo.userId != nil else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let next = Insights.Picks.write(picks, held: heldPicks)
            if (try? await Repo.setInsightsPicks(next)) != nil { heldPicks = next }
        }
    }

    /// The account's picks over this device's; a device whose account has none yet sends its own.
    private func pullPicks() async {
        guard let held = await Repo.insightsPicks() else { return }
        heldPicks = held
        if held.isEmpty { picksChanged(); return }
        let p = Insights.Picks.read(held)
        applying = true
        defer { applying = false }
        if let v = p.section { section = v }
        if let v = p.format { format = v }
        if let v = p.tier.flatMap(Insights.Tier.init) { tierPicked = v }
        if let v = p.days, Insights.windows.contains(v) { days = v }
        if let v = p.set { setCode = v }
        if let v = p.event { event = v }
        if let v = p.group { group = v }
        if let v = p.hidden_formats { hiddenFormats = v }
        if let v = p.hidden_sets { hiddenSets = v }
    }

    var pack: Insights.ConstructedPack? { constructed[format] }
    func tier(for pack: Insights.ConstructedPack) -> Insights.Tier { tierPicked ?? pack.default_tier }
    var limitedSets: [Insights.IndexEntry] { index.filter { $0.kind == "limited" } }
    /// The picked set's pack, or the first set's when the pick has none (a set to rank with no 17Lands data yet).
    var limitedPack: Insights.LimitedPack? {
        (setCode.flatMap { s in limitedSets.contains { $0.key == s } ? s : nil } ?? limitedSets.first?.key).flatMap { limited[$0] }
    }
    /// Events the set has data for, in the usual order; the picked one when it has data.
    func events(of p: Insights.LimitedPack) -> [String] { Insights.eventOrder.filter { p.events[$0] != nil } }
    func currentEvent(of p: Insights.LimitedPack) -> String? { events(of: p).contains(event) ? event : events(of: p).first }

    // MARK: loading

    /// The load in flight, shared by every caller. It isn't the caller's task: leaving the tab cancelled build 39's
    /// load after the index and before the pack, and the ten-minute skip then kept Modern empty.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Whether the pack on screen is in (or the index has none for it).
    private var onScreenLoaded: Bool {
        if section == "limited" { return limitedSets.isEmpty || limitedPack != nil }
        return !index.contains { $0.kind == "constructed" && $0.key == format } || constructed[format] != nil
    }

    /// The index, then the pack on screen (and the other formats' in the background).
    func load(force: Bool = false) async {
        if demoPages != nil { return }
        if let running = loadTask { await running.value; return }
        if !force, Insights.reuseLoad(loadedAt: loadedAt, now: .now, packOnScreen: onScreenLoaded) { return }
        let task = Task { await loadNow() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func loadNow() async {
        loading = true
        defer { loading = false }
        // Sets to rank alongside the index: Limited's picker waits for both.
        Task { await loadExtras() }
        await pullPicks()
        do {
            let data = try await supabase.rpc("insights_index").execute().data
            index = try wireDecoder.decode([Insights.IndexEntry].self, from: data)
            OfflineCache.save("_", Self.indexKey, data)
            // The Limited cards widget's set picker reads the sets from here.
            LimitedSetsStore.save(limitedSets.map { LimitedSetsStore.Set(key: $0.key, name: $0.name) })
            error = nil
            stale = nil
            loadedAt = .now
        } catch where error.isCancellation {
        } catch {
            // The device's saved index: every pack whose version matches a file on the device then loads from it.
            var savedAt = loadedAt
            if index.isEmpty, let saved = OfflineCache.load("_", Self.indexKey, as: [Insights.IndexEntry].self) {
                index = saved.value
                savedAt = saved.at
            }
            let age = Offline.age(savedAt)
            let n = Offline.notice(failed: true, savedAgo: index.isEmpty ? nil : age, error: error.localizedDescription)
            if let n, !n.isError {
                stale = n.text
                Telemetry.capture("offline_shown", ["screen": "insights", "age_s": age ?? 0])
            } else {
                self.error = "Insights couldn't load: \(error.localizedDescription)"
            }
        }
        for e in index where e.kind == "constructed" && e.key == format { await fetch(e) }
        if let first = (setCode.flatMap { s in index.first { $0.kind == "limited" && $0.key == s } } ?? limitedSets.first), section == "limited" {
            await fetch(first)
        }
        // The rest three at a time: a pack is a download and a decode, and there's one per set and cube version.
        let rest = index.filter { ($0.kind == "constructed" && $0.key != format) || $0.kind == "limited" }
        for batch in stride(from: 0, to: rest.count, by: 3).map({ Array(rest[$0..<min($0 + 3, rest.count)]) }) {
            await withTaskGroup(of: Void.self) { g in for e in batch { g.addTask { await self.fetch(e) } } }
        }
    }

    /// Sets to rank and the alerts switch (Limited's extras); quietly empty when they can't load.
    func loadExtras() async {
        #if DEBUG
        if demoPages != nil {
            if rankable.isEmpty {
                rankable = [RankableSet(key: "FRA", name: "Foundations Remastered", released: "2026-09-23", kind: "set", cards: 281, pack: true, mine: 0, rankings: 1),
                            RankableSet(key: "NHZ", name: "New Horizons", released: String(ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 86400)).prefix(10)), kind: "set",
                                        cards: 264, pack: false, mine: 0, rankings: 0),
                            RankableSet(key: "PWR-2510", name: "Arena Powered Cube · Oct 2025", released: "2025-10-30", kind: "cube", cards: 540,
                                        pack: true, mine: 0, rankings: 0)]
            }
            if alerts == nil { alerts = true }
            rankableReady = true
            return
        }
        #endif
        defer { rankableReady = true }
        guard let uid = Repo.userId else { return }
        if !rankableReady, let data = UserDefaults.standard.data(forKey: Self.rankableKey),
           let held = try? JSONDecoder().decode(HeldRankable.self, from: data), held.user == uid {
            rankable = held.sets
            rankableReady = true
        }
        async let sets = RankingsStore.shared.rankableSets()
        struct On: Decodable { let on: Bool }
        async let on: On = supabase.rpc("insights_alerts").execute().value
        if let s = try? await sets {
            rankable = s
            if let data = try? JSONEncoder().encode(HeldRankable(user: uid, sets: s)) { UserDefaults.standard.set(data, forKey: Self.rankableKey) }
        }
        if let a = try? await on { alerts = a.on }
    }

    /// The last sets to rank this device saw, for whom.
    private struct HeldRankable: Codable { let user: String; let sets: [RankableSet] }
    private static let rankableKey = "insights.rankable"

    func setAlerts(_ on: Bool) async {
        let was = alerts
        alerts = on
        Telemetry.capture("insights_alerts_changed", ["on": on])
        if demoPages != nil { return }
        struct On: Decodable { let on: Bool }
        do {
            let a: On = try await supabase.rpc("insights_alerts_set", params: ["p_on": AnyJSON.bool(on)]).execute().value
            alerts = a.on
        } catch {
            alerts = was
            self.error = "Couldn't change New in Insights: \(error.localizedDescription)"
        }
    }

    func ensure(format f: String) async {
        if constructed[f] != nil { return }
        if let e = index.first(where: { $0.kind == "constructed" && $0.key == f }) { await fetch(e) }
    }

    private func cacheURL(_ e: Insights.IndexEntry) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "insights", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(e.kind)-\(e.key).json")
    }

    /// A pack from the device when its version matches, else from the bucket.
    private func fetch(_ e: Insights.IndexEntry) async {
        let file = cacheURL(e), versionFile = file.appendingPathExtension("version")
        var data: Data?
        if (try? String(contentsOf: versionFile, encoding: .utf8)) == e.version { data = try? Data(contentsOf: file) }
        if data == nil, let url = URL(string: e.url + "?v=" + e.version) {
            data = try? await URLSession.shared.data(from: url).0
            if let data {
                try? data.write(to: file, options: .atomic)
                try? e.version.write(to: versionFile, atomically: true, encoding: .utf8)
            }
        }
        guard let data else { return }
        // Off the main thread: a Limited pack is most of a megabyte.
        let kind = e.kind
        put(e.key, await Task.detached(priority: .userInitiated) { Self.decode(kind, data) }.value)
    }

    private func put(_ key: String, _ pack: Pack?) {
        switch pack {
        case .constructed(let p): constructed[key] = p
        case .limited(let p): limited[key] = p
        case nil: error = "An Insights pack couldn't be read (\(key))."
        }
    }

    private enum Pack { case constructed(Insights.ConstructedPack), limited(Insights.LimitedPack) }

    private nonisolated static func decode(_ kind: String, _ data: Data) -> Pack? {
        if kind == "constructed" { return (try? JSONDecoder().decode(Insights.ConstructedPack.self, from: data)).map(Pack.constructed) }
        return (try? JSONDecoder().decode(Insights.LimitedPack.self, from: data)).map(Pack.limited)
    }

    // MARK: pages

    func archetype(format: String, id: Int, tier: Insights.Tier, days: Int) async throws -> Insights.ArchetypePage {
        if let pages = demoPages {
            guard let d = pages["arch:\(format):\(id)"] ?? pages["arch:any"] else { throw InsightsError(message: "No demo page") }
            return try JSONDecoder().decode(Insights.ArchetypePage.self, from: d)
        }
        return try await supabase.rpc("meta_archetype", params: [
            "p_format": AnyJSON.string(format), "p_archetype": .integer(id), "p_tier": .string(tier.rawValue), "p_days": .integer(days),
        ]).execute().value
    }

    func card(format: String, oracleId: String, tier: Insights.Tier, days: Int) async throws -> Insights.CardPage {
        if let pages = demoPages {
            guard let d = pages["card:\(format):\(oracleId)"] ?? pages["card:any"] else { throw InsightsError(message: "No demo page") }
            return try JSONDecoder().decode(Insights.CardPage.self, from: d)
        }
        return try await supabase.rpc("meta_card", params: [
            "p_format": AnyJSON.string(format), "p_oracle_id": .string(oracleId), "p_tier": .string(tier.rawValue), "p_days": .integer(days),
        ]).execute().value
    }

    /// meta_card_search: cards played in the format this year whose name matches (contract § Card search).
    func searchCards(format: String, query: String) async throws -> [Insights.CardHit] {
        if let pages = demoPages {
            // the demo's card pages stand in: every page of the format whose name holds the words
            let q = query.lowercased()
            return pages.compactMap { k, d -> Insights.CardHit? in
                guard k.hasPrefix("card:\(format):"), let p = try? JSONDecoder().decode(Insights.CardPage.self, from: d),
                      let n = p.n, n.lowercased().contains(q) else { return nil }
                let main = p.series.main.last.flatMap { $0 } ?? 0, side = p.series.side.last.flatMap { $0 } ?? 0
                return .init(c: p.c, n: n, type: nil, main: main, side: side, year: p.by_archetype.count)
            }.sorted { ($0.main + $0.side, $1.n) > ($1.main + $1.side, $0.n) }
        }
        return try await supabase.rpc("meta_card_search", params: [
            "p_format": AnyJSON.string(format), "p_query": .string(query), "p_limit": .integer(30),
        ]).execute().value
    }

    /// Your decks and collection coverage in a format (`insights_mine`), once per format a session; nil signed out or
    /// on failure (the grid then keeps its order).
    @ObservationIgnored private var mines: [String: Insights.Mine] = [:]
    func mine(format: String) async -> Insights.Mine? {
        if let pages = demoPages { return pages["mine:\(format)"].flatMap { try? JSONDecoder().decode(Insights.Mine.self, from: $0) } }
        if let m = mines[format] { return m }
        guard Repo.userId != nil else { return nil }
        let m: Insights.Mine? = try? await supabase.rpc("insights_mine", params: ["p_format": AnyJSON.string(format)]).execute().value
        if let m { mines[format] = m }
        return m
    }

    /// list_insight for a deck, once per deck a session; nil when it fails (the rows don't show).
    @ObservationIgnored private var deckInsights: [String: Insights.DeckInsightAnswer] = [:]
    func deckInsight(listId: String) async -> Insights.DeckInsightAnswer? {
        #if DEBUG
        if CollectionStore.shared.demo != nil {
            return Bundle.main.url(forResource: "insights-demo-deck", withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Insights.DeckInsightAnswer.self, from: $0) }
        }
        #endif
        if let r = deckInsights[listId] { return r }
        let r: Insights.DeckInsightAnswer? = try? await supabase.rpc("list_insight", params: ["p_list_id": AnyJSON.string(listId)]).execute().value
        if let r { deckInsights[listId] = r }
        return r
    }

    // MARK: demo

    #if DEBUG
    /// Loads DebugResources/insights-demo-*.json (made by tools/insights/demo_packs.sh from real MTGO pages and a
    /// 17Lands slice).
    func loadDemo() {
        var pages: [String: Data] = [:]
        for f in Insights.formats.map(\.key) {
            if let url = Bundle.main.url(forResource: "insights-demo-constructed-\(f)", withExtension: "json"), let d = try? Data(contentsOf: url) {
                put(f, Self.decode("constructed", d))
                index.append(.init(kind: "constructed", key: f, name: f.capitalized, version: "demo", url: "", bytes: d.count, through: nil))
            }
        }
        for url in Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] where url.lastPathComponent.hasPrefix("insights-demo-limited-") {
            let key = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "insights-demo-limited-", with: "")
            if let d = try? Data(contentsOf: url) {
                put(key, Self.decode("limited", d))
                index.append(.init(kind: "limited", key: key, name: key, version: "demo", url: "", bytes: d.count, through: nil))
            }
        }
        for f in Insights.formats.map(\.key) {
            if let url = Bundle.main.url(forResource: "insights-demo-mine-\(f)", withExtension: "json"), let d = try? Data(contentsOf: url) { pages["mine:\(f)"] = d }
        }
        if let url = Bundle.main.url(forResource: "insights-demo-pages", withExtension: "json"), let d = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj { pages[k] = try? JSONSerialization.data(withJSONObject: v) }
        }
        demoPages = pages
        loadedAt = .now
    }
    #endif
}
