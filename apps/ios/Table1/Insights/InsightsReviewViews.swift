import Supabase
import SwiftUI

/// Moderators only (the server refuses everyone else): archetypes the nightly grouping proposed, bans the catalog's
/// legality check proposed, and card names the sources print that the catalog doesn't know
/// (contract/insights-2026-10-24.md § RPCs).
struct InsightsReviewView: View {
    @Binding var path: [InsightsRoute]
    @State private var review: Review?
    @State private var error: String?
    @State private var names: [Int: String] = [:]
    @State private var busy: Set<String> = []

    struct Review: Decodable {
        struct Proposal: Decodable, Identifiable {
            let id: Int; let format: String; let name: String; let family: String; let colors: String
            let signature: [String]; let decks: Int?; let missing: [String]; let blocked: Bool
        }
        struct Change: Decodable, Identifiable { let id: Int; let format: String; let on: String; let kind: String; let cards: [String] }
        struct Unmatched: Decodable, Hashable { let source: String; let name: String; let seen: Int; let last_seen: String }
        let archetypes: [Proposal]; let changes: [Change]; let unmatched: [Unmatched]
    }

    var body: some View {
        T1Screen {
            Bar(title: "Review", subtitle: "Archetypes and bans") { path.removeLast() }
            ScrollView {
                VStack(spacing: 1) {
                    if let error { Notice(error, error: true) }
                    if let r = review {
                        Section1("Proposed archetypes · \(r.archetypes.count)")
                        if r.archetypes.isEmpty { Notice("Nothing proposed.") }
                        ForEach(r.archetypes) { a in proposal(a) }
                        Section1("Proposed format changes · \(r.changes.count)")
                        if r.changes.isEmpty { Notice("Nothing proposed.") }
                        ForEach(r.changes) { c in
                            ListRow(title: "\(c.kind.capitalized): \(c.cards.prefix(4).joined(separator: ", "))\(c.cards.count > 4 ? "…" : "")",
                                    detail: "\(c.format) · \(InsightCharts.shortDay(c.on))")
                            HStack(spacing: 1) {
                                Ghost(text: "Confirm") { Task { await act("change", c.id, "confirm") } }
                                Ghost(text: "Reject") { Task { await act("change", c.id, "reject") } }
                            }
                        }
                        Section1("Names the catalog doesn't know")
                        ForEach(r.unmatched, id: \.self) { u in
                            ListRow(title: u.name, detail: "\(u.source) · seen \(u.seen)× · last \(InsightCharts.shortDay(u.last_seen))")
                        }
                    } else if error == nil { Notice("Loading…") }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func proposal(_ a: Review.Proposal) -> some View {
        VStack(spacing: 1) {
            ListRow(title: a.name, detail: "\(a.format) · \(a.family) · \(a.colors.isEmpty ? "colourless" : a.colors) · \(a.decks ?? 0) decks")
            Notice(a.signature.prefix(10).joined(separator: ", ") + (a.missing.isEmpty ? "" : "\nNot in the catalog: \(a.missing.joined(separator: ", "))"))
            Field(label: "Name", text: Binding(get: { names[a.id] ?? a.name }, set: { names[a.id] = $0 }))
            HStack(spacing: 1) {
                Ghost(text: "Approve") { Task { await act("archetype", a.id, "approve", name: names[a.id]) } }
                Ghost(text: "Reject") { Task { await act("archetype", a.id, "reject") } }
            }
        }
    }

    private func load() async {
        do {
            review = try await supabase.rpc("insights_review").execute().value
            error = nil
        } catch {
            if !error.isCancellation { self.error = "Review couldn't load: \(error.localizedDescription)" }
        }
    }

    private func act(_ what: String, _ id: Int, _ action: String, name: String? = nil) async {
        let key = "\(what)\(id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            if what == "archetype" {
                var p: [String: AnyJSON] = ["p_id": .integer(id), "p_action": .string(action)]
                if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { p["p_name"] = .string(name) }
                try await supabase.rpc("insights_review_archetype", params: p).execute()
            } else {
                try await supabase.rpc("insights_review_change", params: ["p_id": AnyJSON.integer(id), "p_action": .string(action)]).execute()
            }
            Telemetry.capture("insights_review_action", ["what": what, "action": action])
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
