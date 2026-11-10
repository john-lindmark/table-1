import SwiftUI

/* Support (contract/support-2026-11-10.md): Account → Support. Answers to common questions (support/faq.json) and
   the user-facing part of the Feature Guide (support/guide.json, scrubbed by tools/support/make_guide.py), from the
   folder the app bundles from marketing/bundle/support, the same files the web and Android read. Search is one rule
   on every platform, checked by SupportTests against testdata/support-search/cases.json. */

struct SupportTopic: Decodable, Hashable { let key: String; let title: String }
struct SupportFaq: Decodable, Hashable, Identifiable {
    let id: String
    let topic: String
    let q: String
    let a: String
    var keywords: [String]?
    var guide: String?
}
struct GuideSection: Decodable, Hashable, Identifiable { let id: String; let title: String }
/// A guide entry: its section, the subheading it sits under, its lead (the bold words it opens on) and its text.
struct GuideEntry: Decodable, Hashable, Identifiable {
    let id: String
    let s: String
    var h: String?
    var t: String?
    let x: String
}

enum Support {
    struct FaqFile: Decodable {
        struct Contact: Decodable { let discord: String; let email: String }
        let updated: String
        let contact: Contact
        let topics: [SupportTopic]
        let faqs: [SupportFaq]
    }
    struct GuideFile: Decodable { let sections: [GuideSection]; let entries: [GuideEntry] }

    static let faq: FaqFile? = load("faq")
    static let guide: GuideFile? = load("guide")

    static func load<T: Decodable>(_ name: String, bundle: Bundle = .main) -> T? {
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "support"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func topicTitle(_ key: String) -> String { faq?.topics.first { $0.key == key }?.title ?? key }
    static func sectionTitle(_ id: String) -> String { guide?.sections.first { $0.id == id }?.title ?? id }
    static func faqs(of topic: String) -> [SupportFaq] { faq?.faqs.filter { $0.topic == topic } ?? [] }

    /// A section's entries by subheading, in order (entries before any subheading under "").
    static func groups(_ section: String) -> [(heading: String, entries: [GuideEntry])] {
        var out: [(heading: String, entries: [GuideEntry])] = []
        for e in guide?.entries ?? [] where e.s == section {
            let h = e.h ?? ""
            if let last = out.last, last.heading == h { out[out.count - 1].entries.append(e) } else { out.append((h, [e])) }
        }
        return out
    }

    // MARK: search

    static let stop: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "my", "me", "i",
        "is", "it", "do", "does", "how", "can", "what", "why", "when", "where", "you", "your", "are", "be", "at", "by",
        "from", "this", "that", "there", "as", "if", "not"]
    static let limit = 50

    /// Lowercase, accents off, apostrophes dropped (don't → dont); anything else that isn't a letter or digit splits.
    static func words(_ text: String) -> [String] {
        let folded = text.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) }
        var out: [String] = []
        var cur = ""
        for u in folded {
            if u == "'" || u == "\u{2019}" { continue }
            let l = Character(u).lowercased()
            if l.count == 1, let c = l.unicodeScalars.first, ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                cur.unicodeScalars.append(c)
            } else if !cur.isEmpty {
                out.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The words a search looks for: stop words left out (unless that leaves none), each once.
    static func queryWords(_ q: String) -> [String] {
        let all = words(q)
        let kept = all.filter { !stop.contains($0) }
        var seen = Set<String>()
        return (kept.isEmpty ? all : kept).filter { seen.insert($0).inserted }
    }

    static func hit(_ q: String, _ w: String) -> Bool {
        w.hasPrefix(q) || (q.count >= 4 && q.hasSuffix("s") && w.hasPrefix(String(q.dropLast())))
    }

    enum Doc: Hashable {
        case faq(SupportFaq)
        case guide(GuideEntry)
        var kind: String { if case .faq = self { "faq" } else { "guide" } }
        var id: String {
            switch self { case .faq(let f): f.id; case .guide(let e): e.id }
        }
        /// The question, or the entry's lead (else its opening words).
        var title: String {
            switch self {
            case .faq(let f): f.q
            case .guide(let e): e.t ?? Support.clip(e.x, 90)
            }
        }
        var detail: String {
            switch self {
            case .faq(let f): "FAQ · \(Support.topicTitle(f.topic))"
            case .guide(let e): "Guide · \(Support.sectionTitle(e.s))"
            }
        }
    }

    struct Indexed { let doc: Doc; let primary: [String]; let fields: [(Int, [String])] }

    /// Every FAQ in file order, then every guide entry, with their fields' words and weights.
    static let corpus: [Indexed] = {
        var out: [Indexed] = []
        for f in faq?.faqs ?? [] {
            out.append(Indexed(doc: .faq(f), primary: words(f.q), fields: [
                (4, words(f.q)), (3, words((f.keywords ?? []).joined(separator: " "))), (2, words(topicTitle(f.topic))), (1, words(f.a))]))
        }
        for e in guide?.entries ?? [] {
            out.append(Indexed(doc: .guide(e), primary: words(e.t ?? e.h ?? ""), fields: [
                (3, words(e.t ?? "")), (2, words(e.h ?? "")), (2, words(sectionTitle(e.s))), (1, words(e.x))]))
        }
        return out
    }()

    static func phrase(_ all: [String], _ primary: [String]) -> Bool {
        guard all.count >= 2, primary.count >= all.count else { return false }
        for i in 0...(primary.count - all.count) where all.indices.allSatisfy({ primary[i + $0].hasPrefix(all[$0]) }) {
            return true
        }
        return false
    }

    struct Hit: Hashable { let doc: Doc; let score: Int }

    /// Best first: every query word must start a word in some field (FAQ question 4, keywords 3, topic 2, answer 1;
    /// guide lead 3, subheading 2, section 2, text 1); the score is twice the best weights' sum, +6 when the whole
    /// query starts the question or lead in order, +1 for an FAQ. With nothing matching every word, the docs that match
    /// the most words, marked partial.
    static func search(_ q: String, in docs: [Indexed] = corpus) -> (hits: [Hit], partial: Bool) {
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { return ([], false) }
        let qw = queryWords(q)
        guard !qw.isEmpty else { return ([], false) }
        let all = words(q)
        var scored: [(matched: Int, score: Int, order: Int, doc: Doc)] = []
        for (order, d) in docs.enumerated() {
            var matched = 0, sum = 0
            for w in qw {
                var b = 0
                for (weight, field) in d.fields where weight > b && field.contains(where: { hit(w, $0) }) { b = weight }
                if b > 0 { matched += 1; sum += b }
            }
            guard matched > 0 else { continue }
            let score = 2 * sum + (phrase(all, d.primary) ? 6 : 0) + (d.doc.kind == "faq" ? 1 : 0)
            scored.append((matched, score, order, d.doc))
        }
        guard !scored.isEmpty else { return ([], false) }
        var full = scored.filter { $0.matched == qw.count }
        var partial = false
        if full.isEmpty {
            guard qw.count >= 2 else { return ([], false) }
            let top = scored.map(\.matched).max() ?? 0
            full = scored.filter { $0.matched == top }
            partial = true
        }
        full.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = $0.doc.kind == "faq" ? 0 : 1, b = $1.doc.kind == "faq" ? 0 : 1
            if a != b { return a < b }
            return $0.order < $1.order
        }
        return (full.prefix(limit).map { Hit(doc: $0.doc, score: $0.score) }, partial)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        var cut = String(s.prefix(n - 1))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut + "…"
    }
}

// MARK: screens

/// Account → Support: search over the FAQ and the guide, then the FAQ topics, the guide, and where to ask.
struct SupportView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @SceneStorage("support.query") private var query = ""
    @State private var reported: Task<Void, Never>?

    var body: some View {
        let searching = query.trimmingCharacters(in: .whitespaces).count >= 2
        let found = Support.search(query)
        T1Screen {
            Bar(title: "Support", back: { dismiss() })
            T1SearchField(text: $query, prompt: "Search questions and the guide")
            HairlineList {
                if searching {
                    if found.hits.isEmpty {
                        Notice("Nothing matches that. Try fewer or other words, or ask below.")
                    } else {
                        Section1("\(found.partial ? "Closest matches" : "Results") · \(found.hits.count)")
                    }
                    ForEach(Array(found.hits.enumerated()), id: \.element) { i, h in
                        Button { open(h.doc, rank: i) } label: { SupportRow(title: h.doc.title, detail: h.doc.detail) }
                            .buttonStyle(.plain)
                    }
                } else {
                    Section1("Questions")
                    ForEach(Support.faq?.topics ?? [], id: \.key) { t in
                        Button { path.append(.supportTopic(t.key)) } label: {
                            ListRow(title: t.title) { Text("\(Support.faqs(of: t.key).count)").font(T1.mono(13)) }
                        }
                        .buttonStyle(.plain)
                    }
                    Section1("Guide")
                    Button { path.append(.supportGuides) } label: {
                        ListRow(title: "Everything Table 1 does", detail: "\(Support.guide?.sections.count ?? 0) sections")
                    }
                    .buttonStyle(.plain)
                }
                SupportContact()
            }
        }
        .onChange(of: query) { _, q in
            // One event once typing settles: how many words and results, never the words themselves.
            reported?.cancel()
            guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
            reported = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                let r = Support.search(q)
                Telemetry.capture("support_searched", ["words": q.split(separator: " ").count, "results": r.hits.count, "partial": r.partial])
            }
        }
    }

    private func open(_ doc: Support.Doc, rank: Int) {
        Telemetry.capture("support_result_opened", ["kind": doc.kind, "rank": rank])
        switch doc {
        case .faq(let f): path.append(.supportFaq(f.id, "search"))
        case .guide(let e): path.append(.supportGuide(e.s, e.id, "search"))
        }
    }
}

/// A row whose title may need two lines (questions, guide excerpts).
private struct SupportRow: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(T1.mono(14)).lineLimit(2).multilineTextAlignment(.leading)
            LabelText(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(T1.surface)
        .contentShape(Rectangle())
    }
}

private struct SupportContact: View {
    var body: some View {
        Section1("Still stuck")
        if let c = Support.faq?.contact {
            if let url = URL(string: c.discord) {
                Link(destination: url) {
                    ListRow(title: "Ask in the Table 1 Discord", detail: "discord.gg") { LabelText("Open", color: T1.text) }
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Telemetry.capture("support_contact", ["how": "discord"]) })
            }
            if let url = URL(string: "mailto:\(c.email)") {
                Link(destination: url) {
                    ListRow(title: "Account and privacy", detail: c.email) { LabelText("Email", color: T1.text) }
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Telemetry.capture("support_contact", ["how": "email"]) })
            }
        }
    }
}

struct SupportGuidesView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        T1Screen {
            Bar(title: "Guide", back: { dismiss() })
            HairlineList {
                ForEach(Support.guide?.sections ?? []) { s in
                    Button { path.append(.supportGuide(s.id, nil, "index")) } label: { ListRow(title: s.title) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct SupportTopicView: View {
    let topic: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        T1Screen {
            Bar(title: Support.topicTitle(topic), back: { dismiss() })
            HairlineList {
                let faqs = Support.faqs(of: topic)
                if faqs.isEmpty { Notice("This isn't available.") }
                ForEach(faqs) { f in
                    Button { path.append(.supportFaq(f.id, "topic")) } label: {
                        SupportRow(title: f.q, detail: Support.topicTitle(f.topic))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct SupportFaqView: View {
    let id: String
    let from: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let faq = Support.faq?.faqs.first { $0.id == id }
        T1Screen {
            Bar(title: faq.map { Support.topicTitle($0.topic) } ?? "Support", back: { dismiss() })
            HairlineList {
                if let faq {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(faq.q).font(T1.mono(18)).lineSpacing(4)
                        ForEach(Array(faq.a.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, p in
                            Text(p).font(T1.mono(14)).lineSpacing(5).foregroundStyle(T1.text.opacity(0.9))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 20).background(T1.surface)
                    .textSelection(.enabled)
                    if let g = faq.guide {
                        Button { path.append(.supportGuide(g, nil, "faq")) } label: {
                            ListRow(title: Support.sectionTitle(g), detail: "In the guide")
                        }
                        .buttonStyle(.plain)
                    }
                    SupportContact()
                } else {
                    Notice("This isn't available.")
                }
            }
        }
        .task { if faq != nil { Telemetry.capture("support_opened", ["screen": "faq", "id": id, "from": from]) } }
    }
}

struct SupportGuideView: View {
    let section: String
    let entry: String?
    let from: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let groups = Support.groups(section)
        T1Screen {
            Bar(title: Support.sectionTitle(section), subtitle: "Guide", back: { dismiss() })
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if groups.isEmpty { Notice("This isn't available.") }
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                            if !g.heading.isEmpty { Section1(g.heading) }
                            ForEach(g.entries) { e in GuideEntryRow(entry: e, picked: e.id == entry).id(e.id) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .task {
                    Telemetry.capture("support_opened", ["screen": "guide", "id": section, "from": from])
                    if let entry {
                        try? await Task.sleep(for: .milliseconds(50))
                        reader.scrollTo(entry, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct GuideEntryRow: View {
    let entry: GuideEntry
    let picked: Bool
    var body: some View {
        (lead + Text(entry.x).foregroundStyle(T1.text.opacity(0.85)))
            .font(T1.mono(14)).lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(T1.surface)
            .overlay(alignment: .leading) { if picked { Rectangle().fill(T1.accent).frame(width: 1) } }
            .textSelection(.enabled)
    }

    /// "Event name: up to 80 characters"; a lead that's its own sentence, or text opening on "(" or ":", takes a space.
    private var lead: Text {
        guard let t = entry.t else { return Text("") }
        let sep = t.last.map { ".?!".contains($0) } == true || entry.x.first.map { "(:".contains($0) } == true ? " " : ": "
        return Text(t + sep).foregroundStyle(T1.text)
    }
}

/// Account → Support.
struct SupportAccountRow: View {
    @Binding var path: [LibraryRoute]
    var body: some View {
        Button { path.append(.support) } label: { ListRow(title: "Support", detail: "Questions and the guide") }
            .buttonStyle(.plain)
    }
}
