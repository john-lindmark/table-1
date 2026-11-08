import SwiftUI
import UIKit

/* Account → Bugs (contract/bug-pipeline-2026-10-18.md § Inbox), for the bug watchers only. The inbox: what's waiting
   to ship, what the fix runner asked, what's open. A bug: its sample, its fix, severity and status, and notes the
   fix runner reads the next time it takes the bug. */

/// The Account row; shown only to watchers (the server answers {watcher: false} to everyone else).
struct BugsAccountRow: View {
    @Binding var path: [LibraryRoute]
    private var store: BugsStore { BugsStore.shared }

    var body: some View {
        Group {
            if let me = store.me, me.watcher {
                Button { path.append(.social(.bugs)) } label: {
                    ListRow(title: "Bugs", detail: summary(me)) {
                        if (me.needsYou ?? 0) > 0 { LabelText("\(me.needsYou ?? 0) need you", color: T1.accent) }
                    }
                }.buttonStyle(.plain)
            }
        }
        .task { await store.loadMe() }
    }

    private func summary(_ me: BugsMe) -> String {
        var parts = ["\(me.open ?? 0) open"]
        if (me.toShip ?? 0) > 0 { parts.append("build due") }
        return parts.joined(separator: " · ")
    }
}

// MARK: inbox

struct BugsView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: BugsStore { BugsStore.shared }

    var body: some View {
        let inbox = store.inbox
        T1Screen {
            Bar(title: "Bugs", subtitle: inbox.map { "\($0.needsYou.count) need you · \($0.open.count) open" }, back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                if let inbox {
                    if !inbox.pending.isEmpty {
                        Section1("To ship")
                        ForEach(inbox.pending) { p in pending(p, inbox) }
                    }
                    Section1("Needs you · \(inbox.needsYou.count)")
                    if inbox.needsYou.isEmpty { Notice("The fix runner has no questions.") }
                    ForEach(inbox.needsYou) { b in row(b, detail: b.lastNote ?? BugWords.line(b)) }
                    Section1("Open · \(inbox.open.count)")
                    if inbox.open.isEmpty { Notice("Nothing open.") }
                    ForEach(inbox.open) { b in row(b) }
                    if store.showClosed {
                        Section1("Closed in the last 30 days · \(inbox.closed.count)")
                        if inbox.closed.isEmpty { Notice("Nothing closed lately.") }
                        ForEach(inbox.closed) { b in row(b) }
                    }
                    Ghost(text: store.showClosed ? "Hide closed" : "Show closed") { Task { await store.setShowClosed(!store.showClosed) } }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task { await store.loadInbox() }
        .refreshable { await store.loadInbox() }
    }

    @ViewBuilder private func row(_ b: BugRow, detail: String? = nil) -> some View {
        Button { path.append(.social(.bug(b.id))) } label: {
            ListRow(title: b.title, detail: detail ?? BugWords.line(b)) {
                LabelText(b.severity ?? "–", color: b.severity == "S1" ? T1.danger : T1.text)
            }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func pending(_ p: BugPending, _ inbox: BugsInbox) -> some View {
        let name = BugWords.platform(p.platform)
        VStack(spacing: 1) {
            ListRow(title: p.platform == "server" ? "Server deploy" : "\(name) build",
                    detail: "\(p.fixes) fix\(p.fixes == 1 ? "" : "es") · worst \(p.worst)" + (p.due ? " · due now" : " · can wait")) {
                if p.due { LabelText("Due", color: T1.accent) }
            }
            ForEach(inbox.toShip(p.platform)) { b in row(b, detail: "\(b.severity ?? "–") · fixed \(BugWords.when(b.fixedAt) ?? "")") }
            Ghost(text: p.platform == "server" ? "Mark deployed" : "Mark \(name) shipped") { ship(p) }
        }
    }

    private func ship(_ p: BugPending) {
        let name = BugWords.platform(p.platform)
        let what = p.platform == "server" ? "the server deploy" : "the \(name) build"
        T1Overlays.shared.ask(p.platform == "server" ? "Mark \(p.fixes) server fix\(p.fixes == 1 ? "" : "es") deployed?" : "Mark \(p.fixes) \(name) fix\(p.fixes == 1 ? "" : "es") shipped?",
                              message: "Do this once \(what) with these fixes is out. A fix that comes back after this reopens as more urgent. All \(p.fixes) count, so if the build was cut before the newest fix, use bugs.py shipped --commit instead.",
                              action: p.platform == "server" ? "Mark deployed" : "Mark shipped") {
            Task {
                do { try await store.ship(p.platform) } catch { store.error = BugsStore.words(error) }
            }
        }
    }
}

// MARK: one bug

struct BugView: View {
    let id: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var store: BugsStore { BugsStore.shared }
    @State private var showCrumbs = false

    var body: some View {
        let b = store.details[id]
        T1Screen {
            Bar(title: "Bug #\(id)" + (b?.severity.map { " · \($0)" } ?? ""), subtitle: b.map { BugWords.status($0.status) }, back: { dismiss() }) {
                if let url = b?.sentryURL { BarButton("Sentry") { openURL(url) } }
            }
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                if let b { content(b) } else { Notice("Loading…") }
            }
        }
        .task {
            store.error = nil
            await store.loadDetail(id)
        }
        .refreshable { await store.loadDetail(id) }
    }

    @ViewBuilder private func content(_ b: BugDetail) -> some View {
        Text(b.title).font(T1.mono(15)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
        Notice(facts(b))

        if b.status == "needs_john" {
            Section1("The fix runner asks")
            Notice(b.notes ?? "It handed this to you without a note.")
            HStack(spacing: 1) {
                Ghost(text: "Answer", accent: true) { note(b, sendBack: true) }
                Ghost(text: "Won't fix") { change(b, status: "wontfix") }
            }
        }

        Section1("Severity")
        T1Segmented(options: ["S1", "S2", "S3", "S4"].map { ($0, $0) },
                    selection: Binding(get: { b.severity ?? "" }, set: { s in setSeverity(b, s) }))
        Notice(severityNote(b))

        Section1("Status")
        status(b)

        if b.status == "fixed" || b.fixCommit != nil {
            Section1("Fix")
            if let s = b.fixSummary { Notice(s) }
            Notice([b.fixCommit.map { "Commit \($0.prefix(9))" }, b.fixTest.map { "Test \($0)" }, BugWords.when(b.fixedAt).map { "merged \($0)" }]
                .compactMap { $0 }.joined(separator: " · "))
            ForEach(b.fixPlatforms, id: \.self) { p in
                ListRow(title: BugWords.platform(p), detail: p == "server" ? "Deploy" : "Build") {
                    LabelText(b.shipped.contains(p) ? "Shipped" : "Waiting", color: b.shipped.contains(p) ? T1.accent : T1.muted)
                }
            }
        }

        Section1("Notes")
        Notice("Your notes go to the fix runner with this bug, the next time it takes it.")
        ForEach(Array(b.log.enumerated()), id: \.offset) { _, e in
            VStack(alignment: .leading, spacing: 4) {
                LabelText((e.kind == "note" ? "You" : "Changed") + (BugWords.when(e.at).map { " · \($0)" } ?? ""))
                Text(e.body).font(T1.mono(13)).foregroundStyle(e.kind == "note" ? T1.text : T1.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
        }
        Ghost(text: "Add a note") { note(b, sendBack: false) }
        if b.status != "needs_john", let n = b.notes, !n.isEmpty {
            Section1("Fix runner notes")
            Notice(n)
        }

        sample(b)
    }

    private func facts(_ b: BugDetail) -> String {
        var parts = [BugWords.platform(b.platform), "\(b.events) time\(b.events == 1 ? "" : "s")"]
        if b.users > 0 { parts.append("\(b.users) \(b.users == 1 ? "person" : "people")") }
        if b.spikes > 0 { parts.append("\(b.spikes) spike\(b.spikes == 1 ? "" : "s")") }
        if b.regressed { parts.append("came back after a fix") }
        if let s = BugWords.when(b.firstSeen) { parts.append("first \(s)") }
        if let s = BugWords.when(b.lastSeen) { parts.append("last \(s)") }
        if let r = b.releases.last { parts.append(r.replacingOccurrences(of: "site.table1.events@", with: "")) }
        return parts.joined(separator: " · ")
    }

    private func severityNote(_ b: BugDetail) -> String {
        var who = b.severityBy == "john" ? "Set by you." : (b.severityReason ?? "").trimmingCharacters(in: .whitespaces)
        if !who.isEmpty && !".?!".contains(who.last!) { who += "." }
        return [who, "S1: the fix runner starts within 5 minutes. Others wait for the 08:00 and 18:00 runs."]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    @ViewBuilder private func status(_ b: BugDetail) -> some View {
        switch b.status {
        case "fixing":
            Notice("The fix runner took it \(BugWords.when(b.claimedAt) ?? "recently") (try \(b.attempts)). You can change the severity or add a note; the status waits until it's done.")
        case "new", "open":
            HStack(spacing: 1) {
                Ghost(text: "Keep for me") { change(b, status: "needs_john") }
                Ghost(text: "Won't fix") { change(b, status: "wontfix") }
            }
        case "needs_john":
            Ghost(text: "Send to the fix runner", accent: true) { change(b, status: "open") }
        case "fixed":
            Ghost(text: "Reopen: the fix didn't work") { change(b, status: "open") }
        default:
            if let d = b.duplicateOf { Notice("Same as #\(d)" + (b.duplicateTitle.map { ": \($0)" } ?? "")) }
            Ghost(text: "Reopen") { change(b, status: "open") }
        }
    }

    @ViewBuilder private func sample(_ b: BugDetail) -> some View {
        if let s = b.detail {
            Section1("Latest occurrence")
            if let culprit = b.culprit, !culprit.isEmpty, culprit != "?" { Notice("Where: \(culprit)") }
            ForEach(Array((s.exception ?? []).enumerated()), id: \.offset) { _, x in
                code([x.type, x.value].compactMap { $0 }.joined(separator: ": "))
                let frames = (x.frames ?? []).reversed().map(frameLine)
                if !frames.isEmpty { code(frames.joined(separator: "\n"), muted: true) }
            }
            if let i = s.issue { code([i.type, i.value, i.function, i.filename].compactMap { $0 }.joined(separator: "\n")) }
            if let job = s.job { code("Cron job \(job)") }
            if let st = s.status { code("HTTP \(st)" + (s.timedOut == true ? " · timed out" : "")) }
            if let m = s.message { code(m, muted: true) }
            if let tags = s.tags, !tags.isEmpty {
                code(tags.keys.sorted().filter { $0 != "app.device" }.map { "\($0): \(tags[$0] ?? "")" }.joined(separator: "\n"), muted: true)
            }
            if let crumbs = s.breadcrumbs, !crumbs.isEmpty {
                Ghost(text: showCrumbs ? "Hide breadcrumbs" : "Breadcrumbs · \(crumbs.count)") { showCrumbs.toggle() }
                if showCrumbs { code(crumbs.map(crumbLine).joined(separator: "\n"), muted: true) }
            }
        }
    }

    /// Innermost first, so the line that threw is on top.
    private func frameLine(_ f: BugSample.Frame) -> String {
        let place = [f.file, f.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
        return [f.fn, place.isEmpty ? f.module.map { ($0 as NSString).lastPathComponent } : place].compactMap { $0 }.joined(separator: "  ")
    }

    private func crumbLine(_ c: BugSample.Crumb) -> String {
        [c.category, c.message, c.url, c.status.map(String.init)].compactMap { $0 }.joined(separator: " ")
    }

    private func code(_ text: String, muted: Bool = false) -> some View {
        Text(text).font(T1.mono(12)).foregroundStyle(muted ? T1.muted : T1.text).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
    }

    private func setSeverity(_ b: BugDetail, _ s: String) {
        guard s != b.severity else { return }
        run { try await store.update(b.id, severity: s) }
    }

    private func change(_ b: BugDetail, status: String) {
        if status == "open" && b.severity == nil {
            store.error = "Pick a severity first."
            return
        }
        run { try await store.update(b.id, status: status) }
    }

    private func note(_ b: BugDetail, sendBack: Bool) {
        T1Overlays.shared.present { BugNotePanel(bug: b, sendBack: sendBack) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); store.error = nil } catch { store.error = BugsStore.words(error) }
        }
    }
}

/// A note for the fix runner; with sendBack, it also puts the bug back in the runner's queue (answering its question).
struct BugNotePanel: View {
    let bug: BugDetail
    let sendBack: Bool
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    /// One per panel: a retried send lands once.
    @State private var key = UUID()

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: sendBack ? "Answer" : "Note", subtitle: "Bug #\(bug.id)") { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            if let error { Notice(error, error: true) }
            if sendBack, let q = bug.notes?.split(separator: "\n").last { Notice(String(q)) }
            Notice(sendBack ? "Your answer goes to the fix runner, and the bug goes back in its queue."
                            : "The fix runner reads this the next time it takes the bug.")
            TextField("", text: $text, prompt: Text(sendBack ? "E.g. yes, add the upload step" : "What you saw, what to try").foregroundStyle(T1.muted), axis: .vertical)
                .lineLimit(3...8)
                .font(T1.mono(15)).tint(T1.accent)
                .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                .focusArea()
                .onChange(of: text) { _, v in if v.count > 2000 { text = String(v.prefix(2000)) } }
            BigAction(text: sendBack ? "Send to the fix runner" : "Save note",
                      enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, busy: busy, accent: true) { send() }
        }
    }

    private func send() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await BugsStore.shared.update(bug.id, status: sendBack && bug.severity != nil ? "open" : nil, note: text, key: key)
                T1Overlays.shared.dismissPanel()
            } catch {
                self.error = BugsStore.words(error)
            }
        }
    }
}
