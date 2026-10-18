import SwiftUI

/* Friends, profiles, sharing and trade matches screens (contract/friends-sharing-2026-10-18.md). They ride on
   LibraryRoute (`.social`) so the Collection tab and the Account tab can both push them, and a match can open
   the trade editor in place. */

enum SocialRoute: Hashable {
    case friends
    case profile(String) // user id
    case profileCards(String, String, String?, String) // user id, section, binder/list id, title
    case sharing
    case sharingItems(String) // binder / deck / cube
    case matches
    case match(String) // user id

    /// contract/telemetry-2026-10-15.md; never carries ids.
    var screenName: String {
        switch self {
        case .friends: "friends"
        case .profile: "profile"
        case .profileCards: "profile_cards"
        case .sharing, .sharingItems: "sharing"
        case .matches: "trade_matches"
        case .match: "trade_match"
        }
    }
}

struct SocialDestination: View {
    let route: SocialRoute
    @Binding var path: [LibraryRoute]

    var body: some View {
        switch route {
        case .friends: FriendsView(path: $path)
        case .profile(let id): ProfileScreen(userId: id, path: $path)
        case .profileCards(let id, let kind, let item, let title):
            ProfileCardsView(userId: id, section: ProfileSection(kind: kind, id: item), title: title, path: $path)
        case .sharing: SharingView(path: $path)
        case .sharingItems(let kind): SharingItemsView(kind: kind)
        case .matches: TradeMatchesView(path: $path)
        case .match(let id): TradeMatchView(userId: id, path: $path)
        }
    }
}

private func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? one : many ?? one + "s")"
}

/// Small accent / plain action at the end of a row.
private struct RowAction: View {
    let text: String
    var accent = false
    var danger = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            LabelText(text, color: accent ? T1.ink : danger ? T1.danger : T1.text)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(accent ? T1.accent : T1.surfaceHover)
        }
        .buttonStyle(.plain)
    }
}

// MARK: account and library rows

/// Account tab: Friends, Sharing and your own profile.
struct AccountSocialRows: View {
    @Binding var path: [LibraryRoute]
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        let friends = store.list?.friends.count ?? 0, waiting = store.requestsWaiting
        Section1("Friends and sharing")
        Button { path.append(.social(.friends)) } label: {
            ListRow(title: "Friends", detail: [plural(friends, "friend"), waiting > 0 ? "\(waiting) waiting" : nil].compactMap { $0 }.joined(separator: " · ")) {
                if waiting > 0 { LabelText("\(waiting) new", color: T1.accent) }
            }
        }.buttonStyle(.plain)
        Button { path.append(.social(.sharing)) } label: {
            ListRow(title: "Sharing", detail: store.sharing.map(SharingRules.summary) ?? "Who sees your profile and Library")
        }.buttonStyle(.plain)
        if let me = Repo.userId {
            Button { path.append(.social(.profile(me))) } label: {
                ListRow(title: "Your profile", detail: "Name, photo and what you share")
            }.buttonStyle(.plain)
        }
    }
}

/// Library home: who has what you want, who wants what you have.
struct TradeMatchesRow: View {
    @Binding var path: [LibraryRoute]
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        let m = store.matches ?? []
        let have = m.reduce(0) { $0 + $1.haveCopies }, want = m.reduce(0) { $0 + $1.wantCopies }
        Button { path.append(.social(.matches)) } label: {
            ListRow(title: "Trade matches", detail: store.matches == nil ? "Friends' trades against your wants"
                    : m.isEmpty ? "None yet · friends' trades against your wants"
                    : "\(plural(m.count, "person", "people")) · have \(have) · want \(want)") {
                if !m.isEmpty { Text(m.count.formatted()).font(T1.mono(17)).monospacedDigit() }
            }
        }
        .buttonStyle(.plain)
        .task { if store.matches == nil { await store.loadMatches() } }
    }
}

// MARK: friends

struct FriendsView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    @State private var busy: String?

    var body: some View {
        let l = store.list
        T1Screen {
            Bar(title: "Friends", subtitle: l.map { [plural($0.friends.count, "friend"), $0.incoming.isEmpty ? nil : "\($0.incoming.count) waiting"].compactMap { $0 }.joined(separator: " · ") },
                back: { dismiss() }) {
                BarButton("Add") { add() }
            }
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                Button { add() } label: {
                    ListRow(title: "Add a friend", detail: "Played with you, a name or an email")
                }.buttonStyle(.plain)
                if let l {
                    if !l.incoming.isEmpty {
                        Section1("Requests · \(l.incoming.count)")
                        ForEach(l.incoming) { p in
                            row(p, detail: "Asked you") {
                                HStack(spacing: 1) {
                                    RowAction(text: "Accept", accent: true) { run(p.userId) { try await store.respond(p.userId, accept: true) } }
                                    RowAction(text: "Decline") { run(p.userId) { try await store.respond(p.userId, accept: false) } }
                                }
                            }
                        }
                    }
                    Section1("Friends · \(l.friends.count)")
                    if l.friends.isEmpty {
                        Notice("No friends yet. Friends see what you share with them, show up first in Add players, and their trades are matched against your wants.")
                    }
                    ForEach(l.friends) { p in
                        Button { path.append(.social(.profile(p.userId))) } label: {
                            ListRow(title: p.displayName, detail: p.handle.map { "@\($0)" }, avatar: AvatarView(name: p.displayName, userId: p.userId))
                        }.buttonStyle(.plain)
                    }
                    if !l.outgoing.isEmpty {
                        Section1("Sent · \(l.outgoing.count)")
                        ForEach(l.outgoing) { p in
                            row(p, detail: "Requested") {
                                RowAction(text: "Cancel") { run(p.userId) { try await store.remove(p.userId) } }
                            }
                        }
                    }
                    if !l.blocked.isEmpty {
                        Section1("Blocked · \(l.blocked.count)")
                        ForEach(l.blocked) { p in
                            row(p, detail: "Can't see you or ask you") {
                                RowAction(text: "Unblock") { run(p.userId) { try await store.block(p.userId, false) } }
                            }
                        }
                    }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    private func row(_ p: Person, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        Button { path.append(.social(.profile(p.userId))) } label: {
            ListRow(title: p.displayName, detail: busy == p.userId ? "Working…" : detail, avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                trailing()
            }
        }
        .buttonStyle(.plain)
    }

    private func run(_ id: String, _ work: @escaping () async throws -> Void) {
        busy = id
        Task {
            defer { busy = nil }
            do { try await work() } catch { store.error = error.localizedDescription }
        }
    }

    private func add() {
        T1Overlays.shared.present(full: true) { FriendAddPanel().screen("friend_add") }
    }
}

/// Add a friend: people you've played with first; a name also finds public profiles; email reaches existing accounts
/// and never says whether one exists.
struct FriendAddPanel: View {
    private var store: FriendsStore { FriendsStore.shared }
    @State private var query = ""
    @State private var people: [Person]?
    @State private var email = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Add a friend", subtitle: "They accept to become friends") {
                BarButton("Done") { T1Overlays.shared.dismissPanel() }
            }
            T1SearchField(text: $query, prompt: "Name or handle")
            HairlineList {
                if let error { Notice(error, error: true) }
                if let notice { Notice(notice) }
                Section1(query.isEmpty ? "Played with you" : "Matches")
                if let people {
                    if people.isEmpty {
                        Notice(query.isEmpty ? "People you play events with show up here. Until then, add a friend by email below."
                                             : "No one you've played with or with a public profile matches \"\(query)\".")
                    }
                    ForEach(people) { p in
                        ListRow(title: p.displayName,
                                detail: [p.handle.map { "@\($0)" }, (p.sharedEvents ?? 0) > 0 ? plural(p.sharedEvents ?? 0, "event") + " together" : "Public profile"]
                                    .compactMap { $0 }.joined(separator: " · "),
                                avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                            action(p)
                        }
                    }
                } else {
                    Notice("Loading…")
                }
                Section1("By email")
                HStack(spacing: 1) {
                    TextField("", text: $email, prompt: Text("name@example.com").foregroundStyle(T1.muted))
                        .font(T1.mono(15)).tint(T1.accent)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                    Button { sendEmail() } label: {
                        LabelText("Ask", color: emailValid ? T1.ink : T1.muted)
                            .padding(.horizontal, 20).padding(.vertical, 16)
                            .background(emailValid ? T1.accent : T1.surface)
                    }
                    .buttonStyle(.plain)
                    .disabled(!emailValid || busy)
                }
                Notice("Works for people who already have a Table 1 account.")
            }
        }
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    @ViewBuilder private func action(_ p: Person) -> some View {
        switch p.relation ?? .none {
        case .friend: LabelText("Friends", color: T1.accent)
        case .requested: LabelText("Requested")
        case .incoming: RowAction(text: "Accept", accent: true) { ask(p) }
        case .blocked, .me: EmptyView()
        case .none: RowAction(text: "Add", accent: true) { ask(p) }
        }
    }

    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.count > 5 && e.contains("@") && e.split(separator: "@").last?.contains(".") == true
    }

    private func load() async {
        do {
            people = try await store.search(query)
            error = nil
        } catch {
            self.error = error.localizedDescription
            if people == nil { people = [] }
        }
    }

    private func ask(_ p: Person) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let status = try await store.request(p.userId, via: query.isEmpty ? "played_with" : "search")
                notice = status == "friends" ? "You and \(p.displayName) are friends." : "Asked \(p.displayName)."
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func sendEmail() {
        busy = true
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                try await store.requestByEmail(address)
                email = ""
                notice = "If \(address) has a Table 1 account, they'll get your request."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: profile

struct ProfileScreen: View {
    let userId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    @State private var data: ProfileData?
    @State private var match: TradeMatch?
    @State private var busy = false
    @State private var error: String?
    @State private var confirm: Confirm?

    enum Confirm: Identifiable { case unfriend, block; var id: Self { self } }

    var body: some View {
        T1Screen {
            Bar(title: data?.displayName ?? "Profile", subtitle: subtitle, back: { dismiss() }) {
                if let data, data.relation != .me { BarButton("More") { menu(data) } }
            }
            HairlineList {
                if let error { Notice(error, error: true) }
                if let data {
                    header(data)
                    relationActions(data)
                    sections(data)
                } else if error == nil {
                    Notice("Loading…")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert(confirm == .block ? "Block \(data?.displayName ?? "them")?" : "Unfriend \(data?.displayName ?? "them")?",
               isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(c == .block ? "Block" : "Unfriend", role: .destructive) {
                run { if c == .block { try await store.block(userId, true) } else { try await store.remove(userId) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c == .block ? "They won't be told. They can't ask you again or see anything of yours, even what's public."
                             : "You'll stop seeing what each of you shares with friends.")
        }
    }

    private var subtitle: String? {
        guard let data else { return nil }
        switch data.relation {
        case .me: return "You"
        case .friend: return "Friend"
        case .requested: return "Requested"
        case .incoming: return "Wants to be friends"
        case .blocked: return "Blocked"
        case .none: return data.handle.map { "@\($0)" } ?? "Profile"
        }
    }

    private func header(_ d: ProfileData) -> some View {
        VStack(spacing: 8) {
            AvatarView(name: d.displayName, userId: d.userId, size: 64)
            Text(d.displayName).font(T1.mono(17))
            if let h = d.handle { LabelText("@\(h)") }
            if let r = d.sections.record {
                Text("\(r.matchWins)-\(r.matchLosses)\(r.matchDraws > 0 ? "-\(r.matchDraws)" : "")")
                    .font(T1.mono(36)).tracking(3).foregroundStyle(T1.accent).padding(.top, 8)
                LabelText("\(plural(r.matchWins + r.matchLosses + r.matchDraws, "match", "matches")) · \(plural(r.eventsPlayed, "event"))")
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).background(T1.surface)
    }

    @ViewBuilder private func relationActions(_ d: ProfileData) -> some View {
        switch d.relation {
        case .none: Ghost(text: busy ? "Working…" : "Add friend", accent: true) { run { try await store.request(userId, via: "profile") } }
        case .requested: Ghost(text: busy ? "Working…" : "Requested · Cancel") { run { try await store.remove(userId) } }
        case .incoming:
            HStack(spacing: 1) {
                Ghost(text: "Accept", accent: true) { run { try await store.respond(userId, accept: true) } }
                Ghost(text: "Decline") { run { try await store.respond(userId, accept: false) } }
            }
        case .blocked: Ghost(text: "Unblock") { run { try await store.block(userId, false) } }
        case .friend, .me: EmptyView()
        }
    }

    @ViewBuilder private func sections(_ d: ProfileData) -> some View {
        let s = d.sections
        if d.relation == .me {
            Notice("You see everything here. Others see only what reaches them in Sharing.")
            Button { path.append(.social(.sharing)) } label: { ListRow(title: "Sharing", detail: "Choose who sees each part") }.buttonStyle(.plain)
        }
        if let match, d.relation != .me {
            Section1("Trade matches")
            Button { path.append(.social(.match(userId))) } label: {
                ListRow(title: match.short, detail: "The cards, and Start a trade") {
                    if match.haveUsd + match.wantUsd > 0, let v = PriceBook.text(match.haveUsd + match.wantUsd) { Text(v).font(T1.mono(15)).monospacedDigit() }
                }
            }.buttonStyle(.plain)
        }
        if !d.visible {
            Notice(d.relation == .blocked ? "You blocked \(d.displayName)." : "Only \(d.displayName)'s friends can see their profile.")
        } else if d.sectionCount == 0 && d.relation != .me {
            Notice("\(d.displayName) hasn't shared anything with you yet.")
        }
        if s.allCards != nil || s.forTrade != nil || s.wants != nil { Section1("Library") }
        if let c = s.allCards {
            open("All cards", detail: [plural(c.cards, "card"), c.valueUsd.flatMap { PriceBook.text($0) }].compactMap { $0 }.joined(separator: " · "), kind: "all_cards")
        }
        if let c = s.forTrade { open("For trade", detail: plural(c.cards, "card"), kind: "for_trade") }
        if let c = s.wants { open("Wants", detail: plural(c.cards, "card") + " wanted", kind: "wants") }
        if let b = s.binders, !b.isEmpty {
            Section1("Binders · \(b.count)")
            ForEach(b) { x in open(x.name, detail: [plural(x.cards, "card"), x.forTrade ? "For trade" : nil].compactMap { $0 }.joined(separator: " · "), kind: "binder", id: x.id) }
        }
        if let l = s.decks, !l.isEmpty {
            Section1("Decks · \(l.count)")
            ForEach(l) { x in open(x.name, detail: "\(x.format) · \(plural(x.cards, "card"))", kind: "deck", id: x.id) }
        }
        if let l = s.cubes, !l.isEmpty {
            Section1("Cubes · \(l.count)")
            ForEach(l) { x in open(x.name, detail: plural(x.cards, "card"), kind: "cube", id: x.id) }
        }
    }

    private func open(_ title: String, detail: String, kind: String, id: String? = nil) -> some View {
        Button {
            Telemetry.capture("profile_section_opened", ["section": kind])
            path.append(.social(.profileCards(userId, kind, id, title)))
        } label: { ListRow(title: title, detail: detail) }
        .buttonStyle(.plain)
    }

    private func menu(_ d: ProfileData) {
        var items: [T1MenuItem] = []
        if d.relation == .friend { items.append(T1MenuItem(title: "Unfriend") { confirm = .unfriend }) }
        if d.relation == .blocked {
            items.append(T1MenuItem(title: "Unblock") { run { try await store.block(userId, false) } })
        } else {
            items.append(T1MenuItem(title: "Block", detail: "They can't ask you or see anything of yours", destructive: true) { confirm = .block })
        }
        T1Overlays.shared.showMenu(d.displayName, items)
    }

    private func load() async {
        do {
            let d = try await store.profile(userId)
            if data == nil { Telemetry.capture("profile_viewed", ["relation": d.relation.rawValue, "sections": d.sectionCount]) }
            data = d
            error = nil
            if d.relation != .me && d.visible { match = try? await store.match(with: userId) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); await load() } catch { self.error = error.localizedDescription }
        }
    }
}

/// The cards behind one shared section: read-only rows; tap opens the card (your own copies of it).
struct ProfileCardsView: View {
    let userId: String
    let section: ProfileSection
    let title: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var rows: [ProfileCard]?
    @State private var groups: [(board: String, cards: [CardGroup])] = []
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        let copies = rows?.reduce(0) { $0 + $1.qty } ?? 0
        T1Screen {
            Bar(title: title, subtitle: rows == nil ? nil : plural(copies, "card"), back: { dismiss() })
            CatalogStatusRow(catalog: catalog)
            T1SearchField(text: $query, prompt: "Name or type")
            HairlineList {
                if let error { Notice(error, error: true) }
                if rows?.isEmpty == true { Notice("Nothing here.") }
                ForEach(groups, id: \.board) { g in
                    let shown = query.isEmpty ? g.cards : g.cards.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }
                    if groups.count > 1 && !shown.isEmpty { Section1("\(Self.boardName(g.board)) · \(shown.reduce(0) { $0 + $1.qty })") }
                    ForEach(shown) { c in
                        Button { if c.known { path.append(.card(c.id)) } } label: {
                            CardRow(printing: c.cover, title: c.name, detail: c.type) {
                                Text("\(c.qty)").font(T1.mono(17)).monospacedDigit()
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .task {
            do { rows = try await FriendsStore.shared.cards(userId, section) } catch { self.error = error.localizedDescription; rows = [] }
        }
        .task(id: "\(rows?.count ?? -1)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let rows, let db = catalog.db else { return }
            groups = await Task.detached(priority: .userInitiated) { Self.build(rows, db) }.value
        }
    }

    static func boardName(_ b: String) -> String {
        ["main": "Main", "side": "Sideboard", "commander": "Commander", "maybe": "Considering"][b] ?? "Cards"
    }

    /// Groups by board (decks and cubes) and card; wants for any printing show the card's cover printing.
    nonisolated static func build(_ rows: [ProfileCard], _ db: CatalogDB) -> [(board: String, cards: [CardGroup])] {
        var items: [String: [CollectionItem]] = [:]
        let oracles = rows.filter { $0.cardId == nil }.compactMap(\.oracleId).compactMap { db.oracle(id: $0) }
        let covers = db.covers(oracleIdxs: oracles.map(\.idx))
        let coverOf = Dictionary(oracles.map { ($0.oracleId, covers[$0.idx]?.cardId) }, uniquingKeysWith: { a, _ in a })
        for r in rows {
            guard let card = r.cardId ?? r.oracleId.flatMap({ coverOf[$0] ?? nil }) else { continue }
            items[r.board ?? "", default: []].append(CollectionItem(cardId: card, finish: r.finish ?? "nonfoil", condition: r.condition ?? "NM",
                                                                      lang: r.lang ?? "en", qty: r.qty, seq: 0))
        }
        let order = ["commander", "main", "", "side", "maybe"]
        return items.keys.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }.map { b in
            (b, CardGroup.build(items[b]!, db).sorted { $0.norm < $1.norm })
        }
    }
}

// MARK: sharing

struct SharingView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        T1Screen {
            Bar(title: "Sharing", subtitle: store.sharing.map(SharingRules.summary), back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                if let s = store.sharing {
                    Notice("Everything starts private. Friends see what's Friends or Public; anyone on Table 1 sees what's Public. Your profile caps the rest.")
                    part(.profile, s)
                    part(.record, s)
                    Section1("Library")
                    part(.library, s)
                    ForEach(SharePart.libraryParts, id: \.self) { p in
                        part(p, s)
                        if let kind = ["binders": "binder", "decks": "deck", "cubes": "cube"][p.rawValue] {
                            let items = s.items.filter { $0.kind == kind }
                            if !items.isEmpty {
                                Button { path.append(.social(.sharingItems(kind))) } label: {
                                    let own = items.filter { $0.visibility != nil }.count
                                    ListRow(title: "Each \(kind)", detail: "\(plural(items.count, kind)) · \(own == 0 ? "all \(SharingRules.effective(s, p).label.lowercased())" : "\(own) set on their own")") {
                                        LabelText("Open", color: T1.text)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task { await store.loadSharing() }
    }

    private func part(_ p: SharePart, _ s: SharingSettings) -> some View {
        SharingControl(title: p.label, detail: p.detail, own: s.own(p), inherits: p.inherits,
                       parent: p == .profile || p == .library || p == .record ? nil : ("Library", s.library),
                       settings: s, isProfile: p == .profile) { v in
            Task { await store.set(p, v) }
        }
    }
}

/// One part's row and its Private / Friends / Public control ("Same" first when it can follow the level above).
struct SharingControl: View {
    let title: String
    let detail: String
    let own: Visibility?
    let inherits: Bool
    let parent: (name: String, value: Visibility)?
    let settings: SharingSettings
    var isProfile = false
    let set: (Visibility?) -> Void

    private enum Choice: Hashable { case same, v(Visibility) }

    var body: some View {
        let effective = own ?? parent?.value ?? .private
        let capped = !isProfile && SharingRules.capped(settings, effective)
        VStack(spacing: 1) {
            ListRow(title: title, detail: detail) {
                LabelText(effective.label, color: effective == .private ? T1.muted : T1.accent)
            }
            let options: [(value: Choice, label: String)] = (inherits ? [(Choice.same, "Same")] : [])
                + Visibility.allCases.map { (Choice.v($0), $0.label) }
            T1Segmented(options: options, selection: Binding(
                get: { own.map { .v($0) } ?? .same },
                set: { c in if case .v(let v) = c { set(v) } else { set(nil) } }
            ))
            if own == nil, let parent {
                Notice("Same as \(parent.name): \(parent.value.label.lowercased()).")
            }
            if capped {
                Notice("Shows to \(SharingRules.reach(settings, effective) == .friends ? "friends" : "you") only: your profile is \(settings.profile.label.lowercased()).")
            }
        }
    }
}

struct SharingItemsView: View {
    let kind: String
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        let group: SharePart = kind == "binder" ? .binders : kind == "cube" ? .cubes : .decks
        T1Screen {
            Bar(title: group.label, subtitle: "Sharing", back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                if let s = store.sharing {
                    ForEach(s.items.filter { $0.kind == kind }) { item in
                        SharingControl(title: item.name, detail: item.forTrade == true ? "For trade" : kind.capitalized,
                                       own: item.visibility, inherits: true, parent: (group.label, SharingRules.effective(s, group)),
                                       settings: s) { v in
                            Task { await store.set(item, v) }
                        }
                    }
                }
            }
        }
        .task { if store.sharing == nil { await store.loadSharing() } }
    }
}

// MARK: matches

struct TradeMatchesView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        let m = store.matches
        T1Screen {
            Bar(title: "Trade matches", subtitle: m.map { plural($0.count, "person", "people") }, back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                Notice("Your wants against friends' for-trade cards, and theirs against yours. People you've played with count when they share publicly.")
                if let m {
                    if m.isEmpty {
                        Notice("No matches yet. Matches show once friends share For trade or Wants, and you have wants or a for-trade binder.")
                        Button { path.append(.social(.friends)) } label: { ListRow(title: "Friends", detail: "Add friends to trade with") }.buttonStyle(.plain)
                        Button { path.append(.social(.sharing)) } label: { ListRow(title: "Sharing", detail: "Share your For trade and Wants") }.buttonStyle(.plain)
                    }
                    ForEach(m) { x in
                        Button { path.append(.social(.match(x.userId))) } label: {
                            ListRow(title: x.displayName, detail: x.short + (x.friend ? "" : " · played with you"),
                                    avatar: AvatarView(name: x.displayName, userId: x.userId)) {
                                if x.haveUsd + x.wantUsd > 0, let v = PriceBook.text(x.haveUsd + x.wantUsd) { Text(v).font(T1.mono(15)).monospacedDigit() }
                            }
                        }.buttonStyle(.plain)
                    }
                } else {
                    Notice("Looking…")
                }
            }
        }
        .task {
            await store.loadMatches()
            if let m = store.matches {
                Telemetry.capture("trade_matches_viewed", ["people": m.count, "have": m.reduce(0) { $0 + $1.haveCopies },
                                                           "want": m.reduce(0) { $0 + $1.wantCopies }])
            }
        }
        .refreshable { await store.loadMatches() }
    }
}

/// One person's match: what they have that you want, what they want that you have; Start a trade drafts both.
struct TradeMatchView: View {
    let userId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var match: TradeMatch?
    @State private var loaded = false
    @State private var names: [String: (name: String, printing: CatalogPrinting?, oracleId: String?)] = [:]
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: match?.displayName ?? "Trade match", subtitle: match.map { $0.friend ? "Friend" : "Played with you" }, back: { dismiss() }) {
                BarButton("Profile") { path.append(.social(.profile(userId))) }
            }
            HairlineList {
                if let error { Notice(error, error: true) }
                if let m = match {
                    side("They have · \(m.haveCopies) you want", m.theyHave, value: m.haveUsd, have: true)
                    side("They want · \(m.wantCopies) you have", m.theyWant, value: m.wantUsd, have: false)
                } else if loaded {
                    Notice("Nothing matches with them right now.")
                } else {
                    Notice("Looking…")
                }
            }
            if match != nil {
                BigAction(text: "Start a trade", busy: busy, accent: true) { start() }
            }
        }
        .task {
            match = store.matches?.first { $0.userId == userId }
            do { match = try await store.match(with: userId) } catch { self.error = error.localizedDescription }
            loaded = true
        }
        .task(id: "\(match?.haveCopies ?? -1)-\(match?.wantCopies ?? -1)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let m = match, let db = catalog.db else { return }
            let ids = Array(Set((m.theyHave + m.theyWant).map(\.cardId)))
            await PriceBook.shared.load(ids)
            let p = db.printings(ids: ids)
            let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
            names = Dictionary(uniqueKeysWithValues: ids.map { id in
                let oracle = p[id].flatMap { o[$0.oracleIdx] }
                return (id, (oracle?.name ?? "Card not in local data yet", p[id], oracle?.oracleId))
            })
        }
    }

    @ViewBuilder private func side(_ title: String, _ lines: [MatchLine], value: Double, have: Bool) -> some View {
        Section1(title + (value > 0 ? PriceBook.text(value).map { " · \($0)" } ?? "" : ""))
        if lines.isEmpty { Notice(have ? "Nothing of theirs that you want." : "Nothing of yours that they want.") }
        ForEach(lines) { l in
            let n = names[l.cardId]
            Button { if let o = n?.oracleId { path.append(.card(o)) } } label: {
                CardRow(printing: n?.printing, title: n?.name ?? "…", detail: detail(l, n?.printing, have: have)) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(l.qty)").font(T1.mono(17)).monospacedDigit()
                        if l.overMax == true { LabelText("Over your max", color: T1.danger) }
                        else if let u = PriceBook.text(l.usd ?? PriceBook.shared.usd(l.cardId, l.finish)) { LabelText(u) }
                    }
                }
            }.buttonStyle(.plain)
        }
    }

    private func detail(_ l: MatchLine, _ p: CatalogPrinting?, have: Bool) -> String {
        let printing = p.map { "\($0.set.uppercased()) \($0.cn)" }
        let finish = l.finish == "nonfoil" ? nil : l.finish.capitalized
        let want = switch l.want.tier {
        case "exact": have ? "You want this printing and finish" : "Wants this printing and finish"
        case "printing": have ? "You want this printing" : "Wants this printing"
        default: have ? "You want any printing" : "Wants any printing"
        }
        return [printing, finish, l.condition == "NM" ? nil : l.condition, l.lang == "en" ? nil : l.lang.uppercased(), want]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func start() {
        guard let m = match else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let id = try await store.startTrade(m)
                path.append(.trade(id))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
