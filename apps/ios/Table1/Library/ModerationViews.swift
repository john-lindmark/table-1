import SwiftUI

/* Moderation screens (contract/moderation-2026-10-18.md): Account → From Table 1 (what changed on your content, why,
   and one appeal per change) and, for moderators, Account → Review (held content, appeals, flagged accounts). */

/// Account tab rows: a restriction notice, From Table 1 when there are notices, Review for moderators.
struct ModerationAccountRows: View {
    @Binding var path: [LibraryRoute]
    private var store: ModerationStore { ModerationStore.shared }

    var body: some View {
        Group {
            if let until = store.me?.restrictedUntil, let d = ModerationWords.date(until) {
                Notice("You can't send friend requests until \(d). Your profile is hidden until then. Events aren't affected.", error: true)
            }
            if let n = store.notices, !n.isEmpty {
                let unseen = store.me?.unseen ?? 0
                Button { path.append(.social(.notices)) } label: {
                    ListRow(title: "From Table 1", detail: unseen > 0 ? "\(unseen) new · changes to your content" : "Changes to your content") {
                        if unseen > 0 { LabelText("\(unseen) new", color: T1.accent) }
                    }
                }.buttonStyle(.plain)
            }
            if store.me?.moderator == true {
                Button { path.append(.social(.review)) } label: {
                    ListRow(title: "Review", detail: store.queue.map { "\($0.waiting) waiting · \($0.mode == "shadow" ? "shadow mode" : "enforcing")" } ?? "Moderation queue")
                }.buttonStyle(.plain)
            }
        }
        .task {
            await store.loadMe()
            await store.loadNotices()
            if store.me?.moderator == true { await store.loadQueue() }
        }
    }
}

// MARK: notices

struct NoticesView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: ModerationStore { ModerationStore.shared }

    var body: some View {
        T1Screen {
            Bar(title: "From Table 1", subtitle: "Changes to your content", back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                Notice("Content other players see is checked automatically. When something breaks the rules, Table 1 makes the smallest change it can and tells you here. You can appeal each change once; a person reviews it.")
                if let n = store.notices {
                    if n.isEmpty { Notice("Nothing here.") }
                    ForEach(n) { x in
                        VStack(spacing: 1) {
                            ListRow(title: x.label, detail: [x.whatChanged, ModerationWords.date(x.at)].compactMap { $0 }.joined(separator: " · ")) {
                                LabelText(status(x), color: x.appeal == "reverted" ? T1.accent : T1.muted)
                            }
                            Notice(x.reasonText + (x.action == "unshare" && x.appeal != "reverted" ? " Rename it to share it again." : ""))
                            if x.canAppeal {
                                Ghost(text: "Appeal") {
                                    T1Overlays.shared.present { AppealPanel(notice: x) }
                                }
                            }
                        }
                    }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task {
            await store.loadNotices()
            Telemetry.capture("moderation_notice_opened")
            await store.markSeen()
        }
        .refreshable { await store.loadNotices() }
    }

    private func status(_ x: ModerationNotice) -> String {
        switch x.appeal {
        case "open": "Appeal sent"
        case "reverted": "Restored"
        case "upheld": "Upheld"
        default: x.seen ? "" : "New"
        }
    }
}

/// One appeal: an optional note, sent once.
struct AppealPanel: View {
    let notice: ModerationNotice
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Appeal", subtitle: notice.label) { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            if let error { Notice(error, error: true) }
            Notice("Say why this should come back (optional). A person reads it. You can appeal once.")
            TextField("", text: $note, prompt: Text("E.g. it's a card name").foregroundStyle(T1.muted), axis: .vertical)
                .lineLimit(3...6)
                .font(T1.mono(15)).tint(T1.accent)
                .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                .focusArea()
                .onChange(of: note) { _, v in if v.count > 500 { note = String(v.prefix(500)) } }
            BigAction(text: "Send appeal", busy: busy, accent: true) { send() }
        }
    }

    private func send() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await ModerationStore.shared.appeal(notice.id, note: note)
                T1Overlays.shared.dismissPanel()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: review (moderators)

struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: ModerationStore { ModerationStore.shared }
    @State private var photos: [String: URL] = [:]
    @State private var revealed: Set<String> = []

    var body: some View {
        let q = store.queue
        T1Screen {
            Bar(title: "Review", subtitle: q.map { "\($0.waiting) waiting" }, back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                if let q {
                    T1Segmented(options: [("shadow", "Shadow"), ("enforce", "Enforce")], selection: Binding(get: { q.mode }, set: { m in setMode(m) }))
                    Notice(q.mode == "shadow"
                           ? "Shadow mode: verdicts are recorded and held here; nothing changes for players except child-safety takedowns. Block applies your decision."
                           : "Enforcing: blocks change content at once and the owner is told. Allow undoes it.")
                    Section1("Held content · \(q.checks.count)")
                    if q.checks.isEmpty { Notice("Nothing held.") }
                    ForEach(q.checks) { c in check(c) }
                    Section1("Appeals · \(q.appeals.count)")
                    if q.appeals.isEmpty { Notice("No appeals.") }
                    ForEach(q.appeals) { a in appeal(a) }
                    Section1("Flagged accounts · \(q.flagged.count)")
                    if q.flagged.isEmpty { Notice("No accounts with 3+ strikes or reporters.") }
                    ForEach(q.flagged) { f in flagged(f) }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task {
            await store.loadQueue()
            await loadPhotos()
        }
        .refreshable { await store.loadQueue(); await loadPhotos() }
    }

    private func loadPhotos() async {
        guard let q = store.queue else { return }
        let items = q.checks.compactMap { c in c.bucket.flatMap { b in c.path.map { (bucket: b, path: $0) } } }
            + q.appeals.compactMap { a in a.bucket.flatMap { b in a.path.map { (bucket: b, path: $0) } } }
        photos = await store.photoURLs(items)
    }

    @ViewBuilder private func check(_ c: ReviewCheck) -> some View {
        VStack(spacing: 1) {
            ListRow(title: ModerationWords.subject(c.subjectKind) + " · " + ModerationWords.category(c.category),
                    detail: [c.owner?.displayName, c.strikes > 0 ? "\(c.strikes) strike\(c.strikes == 1 ? "" : "s")" : nil, c.reports > 0 ? "\(c.reports) report\(c.reports == 1 ? "" : "s")" : nil,
                             c.source == "report" ? "reported" : nil, c.enforced ? "already applied" : nil]
                        .compactMap { $0 }.joined(separator: " · ")) {
                LabelText(c.status == "block" ? "Block" : "Review", color: c.status == "block" ? T1.danger : T1.muted)
            }
            content(text: c.text, path: c.path, childSafety: c.category == "child_safety")
            if let r = c.reason, !r.isEmpty { Notice("Why: \(r)") }
            HStack(spacing: 1) {
                Ghost(text: c.enforced ? "Allow · undo" : "Allow") { run { try await store.resolve(c, "allow") } }
                Ghost(text: "Block", accent: true) { run { try await store.resolve(c, "block") } }
            }
        }
    }

    @ViewBuilder private func appeal(_ a: ReviewAppeal) -> some View {
        VStack(spacing: 1) {
            ListRow(title: a.label, detail: [a.owner?.displayName, ModerationWords.category(a.category)].compactMap { $0 }.joined(separator: " · "))
            content(text: a.text, path: a.path, childSafety: a.category == "child_safety")
            if let n = a.note, !n.isEmpty { Notice("They say: \(n)") }
            HStack(spacing: 1) {
                Ghost(text: "Uphold") { run { try await store.resolveAppeal(a, "uphold") } }
                Ghost(text: "Revert", accent: true) { run { try await store.resolveAppeal(a, "revert") } }
            }
        }
    }

    @ViewBuilder private func flagged(_ f: FlaggedAccount) -> some View {
        VStack(spacing: 1) {
            ListRow(title: f.displayName, detail: "\(f.strikes) strikes in 90 days · \(f.reporters) reporters in 14 days"
                    + (ModerationWords.date(f.restrictedUntil).map { " · restricted until \($0)" } ?? ""))
            HStack(spacing: 1) {
                if f.restrictedUntil != nil {
                    Ghost(text: "Lift restriction") { run { try await store.restrict(f.userId, days: 0, reason: "") } }
                } else {
                    Ghost(text: "Restrict 7 days", accent: true) {
                        T1Overlays.shared.ask("Restrict \(f.displayName) for 7 days?",
                                              message: "They can't send friend requests and their profile is hidden. Events aren't affected. They're told.",
                                              action: "Restrict", destructive: true) {
                            run { try await store.restrict(f.userId, days: 7, reason: "Repeated violations or reports") }
                        }
                    }
                }
            }
        }
    }

    /// The text, or the photo blurred until tapped. Child-safety photos are never shown.
    @ViewBuilder private func content(text: String?, path: String?, childSafety: Bool) -> some View {
        if let text {
            Text(text).font(T1.mono(15)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
        } else if let path {
            if childSafety {
                Notice("Photo hidden and quarantined (child safety). US law requires a report to the NCMEC CyberTipline (report.cybertip.org). Don't download or share it.", error: true)
            } else if let url = photos[path] {
                Button { revealed.insert(path) } label: {
                    AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .blur(radius: revealed.contains(path) ? 0 : 24)
                        .overlay { if !revealed.contains(path) { LabelText("Tap to show") } }
                        .clipped()
                        .background(T1.surface)
                }.buttonStyle(.plain)
            } else {
                Notice("Photo: \(path)")
            }
        }
    }

    private func setMode(_ m: String) {
        guard m != store.queue?.mode else { return }
        if m == "enforce" {
            T1Overlays.shared.ask("Start enforcing?", message: "Blocks will change players' content at once and tell them. Check a week of shadow verdicts first.",
                                  action: "Enforce") { run { try await store.setMode(m) } }
        } else {
            run { try await store.setMode(m) }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { store.error = error.localizedDescription }
        }
    }
}
