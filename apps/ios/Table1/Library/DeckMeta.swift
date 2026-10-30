import SwiftUI

/// A deck's archetype on the deck's own screen (contract/insights-2026-10-24.md § A deck's archetype): its name, 30-day
/// win rate and change on last week (opens the archetype in Insights), then its best and worst matchups. Same as web
/// DeckMetaRows and Android DeckMetaRows.
struct DeckMetaRows: View {
    let listId: String
    @Environment(SessionModel.self) private var session
    @State private var answer: Insights.DeckInsightAnswer?

    var body: some View {
        // A stack, not a Group: a Group with nothing in it passes .task to no view, so the rows never loaded (build 39).
        VStack(spacing: 1) {
            if let answer {
                let d = Insights.deckInsight(answer)
                if let title = d.title, let a = answer.a {
                    let open = {
                        Telemetry.capture("deck_insight_opened", ["format": answer.format, "archetype": a])
                        session.pendingInsights = .archetype(answer.format, a)
                    }
                    Button(action: open) {
                        ListRow(title: title, detail: [d.win ?? "Too few matches for a win rate", d.change].compactMap { $0 }.joined(separator: " · ")) {
                            Text("Insights").font(T1.mono(13))
                        }
                    }.buttonStyle(.plain)
                    if !d.good.isEmpty { Button(action: open) { LinesRow(title: "Good against", lines: d.good) }.buttonStyle(.plain) }
                    if !d.bad.isEmpty { Button(action: open) { LinesRow(title: "Bad against", lines: d.bad) }.buttonStyle(.plain) }
                } else if let note = d.note {
                    ListRow(title: "In the meta", detail: note)
                }
            }
        }
        .task(id: listId) {
            answer = nil
            guard let r = await InsightsStore.shared.deckInsight(listId: listId) else { return }
            answer = r
            if let a = r.a, a != 0 { Telemetry.capture("deck_insight_shown", ["format": r.format, "archetype": a]) }
        }
    }
}

/// ListRow with one matchup a line, so a phone shows all three.
private struct LinesRow: View {
    let title: String
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(T1.mono(14)).lineLimit(1)
            ForEach(lines, id: \.self) { LabelText($0) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
        .contentShape(Rectangle())
    }
}
