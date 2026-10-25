import Foundation
import Observation
import Supabase

struct InsightsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The Insights tab's data (contract/insights-2026-10-24.md): the published pack index, the packs themselves (kept
/// on the device and refetched only when their version changes) and what the viewer has picked, remembered per
/// device. Archetype and card pages come from their RPCs on demand.
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

    var section: String = UserDefaults.standard.string(forKey: "insights.section") ?? "constructed" {
        didSet { UserDefaults.standard.set(section, forKey: "insights.section"); Telemetry.capture("insights_section_changed", ["section": section]) }
    }
    var format: String = UserDefaults.standard.string(forKey: "insights.format") ?? "modern" {
        didSet { UserDefaults.standard.set(format, forKey: "insights.format"); Telemetry.capture("insights_format_changed", ["format": format]) }
    }
    /// The tier the viewer picked; nil = the pack's default (Big events unless they're thin).
    var tierPicked: Insights.Tier? = UserDefaults.standard.string(forKey: "insights.tier").flatMap(Insights.Tier.init) {
        didSet {
            UserDefaults.standard.set(tierPicked?.rawValue, forKey: "insights.tier")
            if let t = tierPicked { Telemetry.capture("insights_tier_changed", ["tier": t.rawValue]) }
        }
    }
    var days: Int = { let d = UserDefaults.standard.integer(forKey: "insights.days"); return Insights.windows.contains(d) ? d : 30 }() {
        didSet { UserDefaults.standard.set(days, forKey: "insights.days"); Telemetry.capture("insights_window_changed", ["days": days]) }
    }
    var setCode: String? = UserDefaults.standard.string(forKey: "insights.set") {
        didSet { UserDefaults.standard.set(setCode, forKey: "insights.set"); captureSet() }
    }
    var event: String = UserDefaults.standard.string(forKey: "insights.event") ?? "PremierDraft" {
        didSet { UserDefaults.standard.set(event, forKey: "insights.event"); captureSet() }
    }
    var group: String = UserDefaults.standard.string(forKey: "insights.group") ?? "all" {
        didSet { UserDefaults.standard.set(group, forKey: "insights.group") }
    }
    private func captureSet() { Telemetry.capture("insights_set_changed", ["set": setCode ?? "", "event": event]) }

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
        for e in index where (e.kind == "constructed" && e.key != format) || e.kind == "limited" { await fetch(e) }
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
