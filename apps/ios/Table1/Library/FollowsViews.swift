import SwiftUI

/* Following screens (contract/follows-2026-10-25.md): the Follow rows on someone else's binder, deck or cube, the
   Library home row, Following, and an item's Changes. */

private var store: FollowsStore { FollowsStore.shared }

@MainActor
enum FollowActions {
    /// Turn pushes off / on, Unfollow.
    static func menu(title: String, kind: String, id: String, push: Bool, from: String) {
        func run(_ work: @escaping () async throws -> Void) {
            Task { do { try await work() } catch { store.error = FriendsStore.message(error) } }
        }
        T1Overlays.shared.showMenu(title, [
            T1MenuItem(title: push ? "Turn pushes off" : "Turn pushes on",
                       detail: push ? "Changes still show in Following" : "A push when a round of changes is done") {
                run { try await store.set(kind: kind, id: id, follow: true, push: !push, from: from) }
            },
            T1MenuItem(title: "Unfollow", destructive: true) {
                run { try await store.set(kind: kind, id: id, follow: false, from: from) }
            },
        ])
    }
}

/// On a binder, deck or cube someone else shares with you: Follow, or Following and its Changes.
struct FollowRows: View {
    let kind: String
    let id: String
    let title: String
    var owner: String?
    /// Opened through a share link: the follow lasts as long as that link.
    var token: String?
    @Binding var path: [LibraryRoute]
    @State private var busy = false

    var body: some View {
        let s = store.states[id]
        // A VStack, not a Group: an empty Group never runs its .task.
        VStack(spacing: 1) {
            if let s, s.following {
                Button { FollowActions.menu(title: title, kind: kind, id: id, push: s.push, from: "item") } label: {
                    ListRow(title: "Following", detail: s.push ? "Pushes on" : "Pushes off · changes show in Following") {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(T1.accent)
                    }
                }.buttonStyle(.plain)
                if let u = s.lastUpdate {
                    Button { path.append(.social(.followChanges(kind, id))) } label: {
                        ListRow(title: "Changes", detail: Follows.since(u, now: Date())) {
                            if s.unseen > 0 { LabelText("\(s.unseen) new", color: T1.accent) }
                        }
                    }.buttonStyle(.plain)
                }
            } else if s != nil {
                Button(action: follow) {
                    ListRow(title: "Follow", detail: "Get a push when \(owner ?? "they") change\(owner == nil ? "" : "s") it") {
                        LabelText(busy ? "…" : "Follow", color: T1.ink)
                            .padding(.horizontal, 12).padding(.vertical, 10).background(T1.accent)
                    }
                }.buttonStyle(.plain).disabled(busy)
            }
        }
        .task(id: id) { await store.state(kind: kind, id: id) }
    }

    private func follow() {
        busy = true
        Task {
            do { try await store.set(kind: kind, id: id, follow: true, token: token, from: "item") }
            catch { store.error = FriendsStore.message(error) }
            busy = false
        }
    }
}

/// Library home, once you follow anything.
struct FollowingRow: View {
    @Binding var path: [LibraryRoute]

    var body: some View {
        VStack(spacing: 1) {
            if let items = store.items, !items.isEmpty {
                let updated = items.filter { $0.available && $0.unseen > 0 }.count
                Button { path.append(.social(.following)) } label: {
                    ListRow(title: "Following", detail: Follows.home(items)) {
                        if updated > 0 { LabelText("\(updated) new", color: T1.accent) }
                    }
                }.buttonStyle(.plain)
            }
        }
        .task { if store.items == nil { await store.load() } }
    }
}

struct FollowingView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        T1Screen {
            Bar(title: "Following", subtitle: store.items.map { Follows.home($0) }, back: { dismiss() })
            HairlineList {
                if let e = store.error { Notice(e, error: true) }
                if let items = store.items {
                    if items.isEmpty { Notice("Follow a friend's deck, cube or binder to see their changes here.") }
                    ForEach(items) { f in row(f) }
                } else {
                    Notice("Loading…")
                }
            }
            .refreshable { await store.load() }
        }
        .task {
            await store.load()
            let items = store.items ?? []
            Telemetry.capture("following_viewed", ["items": items.count, "updated": items.filter { $0.available && $0.unseen > 0 }.count])
        }
    }

    private func row(_ f: Follow) -> some View {
        Button { open(f) } label: {
            ListRow(title: f.title, detail: [f.available ? f.subtitle : nil, Follows.detail(f, now: Date())].compactMap { $0 }.joined(separator: " · ")) {
                if f.available && f.unseen > 0 { LabelText("\(f.unseen) new", color: T1.accent) }
            }
        }
        .buttonStyle(.plain)
        .personMenu { more(f) }
    }

    private func open(_ f: Follow) {
        guard T1Overlays.shared.menu == nil else { return }
        if let r = FollowsStore.route(f) { path.append(.social(r)) } else { more(f) }
    }

    private func more(_ f: Follow) {
        if f.available {
            FollowActions.menu(title: f.title, kind: f.kind, id: f.id, push: f.push, from: "following")
        } else {
            T1Overlays.shared.showMenu("This isn't available", message: "It may have been made private or deleted.", [
                T1MenuItem(title: "Unfollow", destructive: true) {
                    Task {
                        do { try await store.set(kind: f.kind, id: f.id, follow: false, from: "following") }
                        catch { store.error = FriendsStore.message(error) }
                    }
                },
            ])
        }
    }
}

/// An item's updates since you followed, newest first: Added, then Taken out.
struct FollowChangesView: View {
    let kind: String
    let id: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var changes: FollowChanges?
    @State private var error: String?
    @State private var printings: [String: CatalogPrinting] = [:]
    @State private var oracles: [Int: CatalogOracle] = [:]

    var body: some View {
        T1Screen {
            Bar(title: changes?.name ?? "Changes", subtitle: "Changes", back: { dismiss() })
            CatalogStatusRow(catalog: catalog)
            HairlineList {
                if let error { Notice(error, error: true) }
                if let changes {
                    if changes.updates.isEmpty { Notice("No changes since you followed.") }
                    ForEach(changes.updates) { u in update(u) }
                } else if error == nil {
                    Notice("Loading…")
                }
            }
        }
        .task {
            do { changes = try await store.changes(kind: kind, id: id) }
            catch where !error.isCancellation { self.error = FriendsStore.message(error) }
            catch {}
        }
        .task(id: "\(changes?.updates.count ?? -1)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let changes, let db = catalog.db else { return }
            let ids = Array(Set(changes.updates.flatMap { $0.cards.map(\.cardId) }))
            let p = db.printings(ids: ids)
            printings = p
            oracles = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
        }
    }

    @ViewBuilder private func update(_ u: FollowUpdate) -> some View {
        let s = Follows.sections(u.cards)
        Section1(Follows.since(FollowUpdateSummary(at: u.at, added: u.added, removed: u.removed), now: Date()))
        if !s.added.isEmpty {
            BoardHeader(title: "Added", count: s.added.reduce(0) { $0 + $1.qty })
            ForEach(s.added, id: \.self) { c in card(c, sign: "+") }
        }
        if !s.removed.isEmpty {
            BoardHeader(title: "Taken out", count: s.removed.reduce(0) { $0 + $1.qty })
            ForEach(s.removed, id: \.self) { c in card(c, sign: Follows.minus) }
        }
    }

    private func card(_ c: FollowCard, sign: String) -> some View {
        let p = printings[c.cardId], o = p.flatMap { oracles[$0.oracleIdx] }
        let section = kind == "deck" ? ["main": "Main deck", "side": "Sideboard", "commander": "Commander"][c.board ?? ""] : nil
        return Button { if let o { path.append(.cardIn(o.oracleId, .search)) } } label: {
            CardRow(printing: p, title: o?.name ?? "Unknown card", detail: [section, p?.setLabel].compactMap { $0 }.joined(separator: " · ")) {
                Text("\(sign)\(c.qty)").font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }
}
