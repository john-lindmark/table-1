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
    /// Debug demo (-T1InsightsDemo): packs and pages from DebugResources, nothing from the network.
    @ObservationIgnored var demoPages: [String: Data]?
    /// Sets and Arena cube versions to rank (limited_rankable), newest first; loaded with Limited.
    private(set) var rankable: [RankableSet] = []
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
    var shownSets: [Insights.IndexEntry] {
        let keys = Insights.visibleKeys(limitedSets.map(\.key), hiddenSets)
        return limitedSets.filter { keys.contains($0.key) }
    }
    /// Shows or hides a format (or a set); a picked one that's hidden gives way to the first one still shown.
    func setHidden(format: Bool, _ key: String, _ hide: Bool) {
        if format {
            hiddenFormats = hiddenFormats.filter { $0 != key } + (hide ? [key] : [])
            if !shownFormats.contains(where: { $0.key == self.format }), let first = shownFormats.first { self.format = first.key }
        } else {
            hiddenSets = hiddenSets.filter { $0 != key } + (hide ? [key] : [])
            if let s = setCode, !shownSets.contains(where: { $0.key == s }) { setCode = shownSets.first?.key }
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
    var limitedPack: Insights.LimitedPack? { (setCode ?? limitedSets.first?.key).flatMap { limited[$0] } }
    /// Events the set has data for, in the usual order; the picked one when it has data.
    func events(of p: Insights.LimitedPack) -> [String] { Insights.eventOrder.filter { p.events[$0] != nil } }
    func currentEvent(of p: Insights.LimitedPack) -> String? { events(of: p).contains(event) ? event : events(of: p).first }

    // MARK: loading

    /// The index, then the pack on screen (and the other formats' in the background).
    func load(force: Bool = false) async {
        if demoPages != nil { return }
        if !force, let at = loadedAt, Date().timeIntervalSince(at) < 600 { return }
        loading = true
        defer { loading = false }
        await pullPicks()
        do {
            index = try await supabase.rpc("insights_index").execute().value
            error = nil
            loadedAt = .now
        } catch {
            if !error.isCancellation { self.error = "Insights couldn't load: \(error.localizedDescription)" }
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
            return
        }
        #endif
        guard Repo.userId != nil else { return }
        async let sets = RankingsStore.shared.rankableSets()
        struct On: Decodable { let on: Bool }
        async let on: On = supabase.rpc("insights_alerts").execute().value
        if let s = try? await sets { rankable = s }
        if let a = try? await on { alerts = a.on }
    }

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
        put(e.kind, e.key, data)
    }

    private func put(_ kind: String, _ key: String, _ data: Data) {
        do {
            if kind == "constructed" { constructed[key] = try JSONDecoder().decode(Insights.ConstructedPack.self, from: data) }
            else { limited[key] = try JSONDecoder().decode(Insights.LimitedPack.self, from: data) }
        } catch {
            self.error = "An Insights pack couldn't be read (\(key))."
        }
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

    func card(format: String, oracleId: String, tier: Insights.Tier) async throws -> Insights.CardPage {
        if let pages = demoPages {
            guard let d = pages["card:\(format):\(oracleId)"] ?? pages["card:any"] else { throw InsightsError(message: "No demo page") }
            return try JSONDecoder().decode(Insights.CardPage.self, from: d)
        }
        return try await supabase.rpc("meta_card", params: [
            "p_format": AnyJSON.string(format), "p_oracle_id": .string(oracleId), "p_tier": .string(tier.rawValue),
        ]).execute().value
    }

    // MARK: demo

    #if DEBUG
    /// Loads DebugResources/insights-demo-*.json (made by tools/insights/demo_packs.sh from real MTGO pages and a
    /// 17Lands slice).
    func loadDemo() {
        var pages: [String: Data] = [:]
        for f in Insights.formats.map(\.key) {
            if let url = Bundle.main.url(forResource: "insights-demo-constructed-\(f)", withExtension: "json"), let d = try? Data(contentsOf: url) {
                put("constructed", f, d)
                index.append(.init(kind: "constructed", key: f, name: f.capitalized, version: "demo", url: "", bytes: d.count, through: nil))
            }
        }
        for url in Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] where url.lastPathComponent.hasPrefix("insights-demo-limited-") {
            let key = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "insights-demo-limited-", with: "")
            if let d = try? Data(contentsOf: url) {
                put("limited", key, d)
                index.append(.init(kind: "limited", key: key, name: key, version: "demo", url: "", bytes: d.count, through: nil))
            }
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
